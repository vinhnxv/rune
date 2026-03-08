#!/bin/bash
# measure-startup-tokens.sh — Token overhead measurement tool
# Measures Claude Code startup token overhead from Rune plugin components

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Count tokens (approximate: ~4 chars per token)
count_tokens() {
    local text="$1"
    local char_count=${#text}
    echo $(( char_count / 4 ))
}

# Extract description from YAML frontmatter (handles | multi-line)
extract_description() {
    local file="$1"
    python3 2>/dev/null << 'PYEOF' "$file" || perl -0777 -ne '
if (/^---\n(.*?)^---/ms) {
    $fm = $1;
    if ($fm =~ /^description:\s*[|'"'"']?\s*\n((?:[ \t]+.*\n?)*)/m) {
        $desc = $1;
        $desc =~ s/^[ \t]+//gm;
        $desc =~ s/\n+$//;
        print $desc;
    } elsif ($fm =~ /^description:\s*"(.*?)"/m) {
        print $1;
    } elsif ($fm =~ /^description:\s*(.+?)$/m) {
        print $1;
    }
}
' "$1" || echo ""
import sys
import re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Match frontmatter
fm_match = re.search(r'^---\n(.*?)^---', content, re.MULTILINE | re.DOTALL)
if not fm_match:
    sys.exit(0)

fm = fm_match.group(1)

# Extract description - handle multi-line with |
desc_match = re.search(r'^description:\s*[|\']?\s*\n((?:[ \t]+.*\n?)*)', fm, re.MULTILINE)
if desc_match:
    desc = desc_match.group(1)
    desc = re.sub(r'^[ \t]+', '', desc, flags=re.MULTILINE)
    desc = desc.strip()
    print(desc)
else:
    # Single-line description
    desc_match = re.search(r'^description:\s*"?([^"\n]+)"?', fm, re.MULTILINE)
    if desc_match:
        print(desc_match.group(1).strip())
PYEOF
}

# Check if skill has disable-model-invocation: true
has_dmi() {
    grep -q "disable-model-invocation:[[:space:]]*true" "$1" 2>/dev/null
}

# Check if skill has user-invocable: false (background skill)
is_background() {
    grep -q "user-invocable:[[:space:]]*false" "$1" 2>/dev/null
}

echo -e "${BLUE}=== Rune Startup Token Measurement ===${NC}"
echo ""

# 1. Skill descriptions
echo -e "${YELLOW}## Skill Descriptions${NC}"
skill_total=0
skill_count=0
skill_dmi_count=0
skill_background_count=0
skill_breakdown=""

for skill_file in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
    [[ -f "$skill_file" ]] || continue
    skill_name=$(basename "$(dirname "$skill_file")")

    if has_dmi "$skill_file"; then
        skill_dmi_count=$((skill_dmi_count + 1))
        continue
    fi

    if is_background "$skill_file"; then
        skill_background_count=$((skill_background_count + 1))
    fi

    desc=$(extract_description "$skill_file")
    if [[ -n "$desc" ]]; then
        tokens=$(count_tokens "$desc")
        skill_total=$((skill_total + tokens))
        skill_count=$((skill_count + 1))
        skill_breakdown+="  $tokens $skill_name"$'\n'
    fi
done

echo "Top skill descriptions by tokens:"
echo "$skill_breakdown" | sort -rn | head -15
echo "  ... and $((skill_count - 15)) more skills"
echo ""
echo "  Skills with disable-model-invocation: $skill_dmi_count (deferred)"
echo "  Background skills (user-invocable: false): $skill_background_count"
echo -e "  ${GREEN}Total skill description tokens: $skill_total${NC}"

# 2. Agent descriptions
echo ""
echo -e "${YELLOW}## Agent Descriptions${NC}"
agent_total=0
agent_count=0
agent_breakdown=""

for agent_file in "$PLUGIN_ROOT"/agents/*/*.md; do
    [[ -f "$agent_file" ]] || continue
    agent_name=$(basename "$agent_file" .md)

    desc=$(extract_description "$agent_file")
    if [[ -n "$desc" ]]; then
        tokens=$(count_tokens "$desc")
        agent_total=$((agent_total + tokens))
        agent_count=$((agent_count + 1))
        agent_breakdown+="  $tokens $agent_name"$'\n'
    fi
done

echo "Top agent descriptions by tokens:"
echo "$agent_breakdown" | sort -rn | head -15
echo "  ... and $((agent_count - 15)) more agents"
echo -e "  ${GREEN}Total agent description tokens: $agent_total${NC}"

# 3. CLAUDE.md
echo ""
echo -e "${YELLOW}## CLAUDE.md${NC}"
claude_md="$PLUGIN_ROOT/CLAUDE.md"
claude_tokens=0
if [[ -f "$claude_md" ]]; then
    claude_chars=$(wc -c < "$claude_md" | tr -d ' ')
    claude_tokens=$(( claude_chars / 4 ))
    echo "  Character count: $claude_chars"
    echo -e "  ${GREEN}Estimated tokens: $claude_tokens${NC}"
fi

# 4. hooks.json
echo ""
echo -e "${YELLOW}## hooks.json${NC}"
hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
hooks_tokens=0
if [[ -f "$hooks_file" ]]; then
    hooks_chars=$(wc -c < "$hooks_file" | tr -d ' ')
    hooks_tokens=$(( hooks_chars / 4 ))
    echo "  Character count: $hooks_chars"
    echo -e "  ${GREEN}Estimated tokens: $hooks_tokens${NC}"
fi

# 5. Summary
echo ""
echo -e "${BLUE}=== Summary ===${NC}"
total=$((skill_total + agent_total + claude_tokens + hooks_tokens))
echo "  Skill descriptions:    $skill_total tokens ($skill_count loaded)"
echo "  Agent descriptions:    $agent_total tokens ($agent_count agents)"
echo "  CLAUDE.md:             $claude_tokens tokens"
echo "  hooks.json:            $hooks_tokens tokens"
echo ""
echo -e "${GREEN}  TOTAL STARTUP OVERHEAD: $total tokens${NC}"

# Target comparison
target=18300
threshold=20000
if [[ $total -lt $threshold ]]; then
    echo -e "${GREEN}  ✓ Under threshold ($threshold tokens)${NC}"
else
    echo -e "${RED}  ✗ Above threshold ($threshold tokens)${NC}"
fi

# Save baseline
baseline_file="tmp/token-opt-baseline.json"
mkdir -p tmp 2>/dev/null || true
cat > "$baseline_file" << EOF
{
  "skill_descriptions": $skill_total,
  "skill_count": $skill_count,
  "skill_dmi_count": $skill_dmi_count,
  "skill_background_count": $skill_background_count,
  "agent_descriptions": $agent_total,
  "agent_count": $agent_count,
  "claude_md": $claude_tokens,
  "hooks_json": $hooks_tokens,
  "total": $total,
  "target": $target,
  "threshold": $threshold,
  "measured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo ""
echo "Baseline saved to: $baseline_file"