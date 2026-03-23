#!/usr/bin/env bash
# validate-talisman-consistency.sh — Semantic validation for talisman.yml
# Phase 4 of /rune:talisman audit — cross-field consistency checks
#
# Checks:
#   TC-001: max_ashes >= built-in (7) + custom agent count
#   TC-002: ashes.custom[].source: local → .claude/agents/{agent}.md exists
#   TC-003: ashes.custom[].source: plugin → registry or agents dir has file
#   TC-004: total context_budget of custom ashes <= 100%
#   TC-005: audit.deep.max_dimension_agents >= dimension agent count
#   TC-006: dedup_hierarchy prefixes match spawnable agents
#
# Usage: bash validate-talisman-consistency.sh [talisman-path] [project-dir] [plugin-root]
# Exit 0 + JSON on stdout (findings array)
# Requires: python3 + PyYAML (graceful fallback if missing)

set -euo pipefail

_VTC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VTC_SCRIPT_DIR}/lib/rune-state.sh"

TALISMAN_PATH="${1:-${RUNE_STATE}/talisman.yml}"
PROJECT_DIR="${2:-.}"
PLUGIN_ROOT="${3:-plugins/rune}"

# ── Helpers ──

findings=()
add_finding() {
  local id="$1" severity="$2" message="$3" fix="$4"
  findings+=("{\"id\":\"$id\",\"severity\":\"$severity\",\"message\":$(printf '%s' "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$message\""),\"fix\":$(printf '%s' "$fix" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$fix\"")}")
}

# ── Pre-check: talisman exists ──

if [ ! -f "$TALISMAN_PATH" ]; then
  echo '{"findings":[],"error":"talisman.yml not found","checks_run":0}'
  exit 0
fi

# ── Parse talisman with Python (PyYAML) ──
# SEC-001 FIX: Pass TALISMAN_PATH via sys.argv instead of shell interpolation

PARSED=$(python3 - "$TALISMAN_PATH" <<'PYEOF'
import yaml, json, sys

with open(sys.argv[1]) as f:
    t = yaml.safe_load(f) or {}

settings = t.get('settings', {})
ashes = t.get('ashes', {})
custom = ashes.get('custom', []) or []
audit_cfg = t.get('audit', {})
deep = audit_cfg.get('deep', {})
dimensions = deep.get('dimensions', []) or []

result = {
    'max_ashes': settings.get('max_ashes', 9),
    'custom_count': len(custom),
    'custom_agents': [],
    'total_context_budget': 0,
    'max_dimension_agents': deep.get('max_dimension_agents', 7),
    'dimension_count': len(dimensions),
    'dedup_hierarchy': settings.get('dedup_hierarchy', []),
}

for c in custom:
    agent = {
        'name': c.get('name', ''),
        'agent': c.get('agent', ''),
        'source': c.get('source', 'local'),
        'finding_prefix': c.get('finding_prefix', ''),
        'context_budget': c.get('context_budget', 20),
    }
    result['custom_agents'].append(agent)
    result['total_context_budget'] += agent['context_budget']

json.dump(result, sys.stdout)
PYEOF
) || {
  echo '{"findings":[],"error":"PyYAML not available","checks_run":0}'
  exit 0
}

# ── Extract values (use jq instead of python3 for each field) ──

max_ashes=$(printf '%s\n' "$PARSED" | jq -r '.max_ashes' 2>/dev/null || echo "9")
custom_count=$(printf '%s\n' "$PARSED" | jq -r '.custom_count' 2>/dev/null || echo "0")
total_budget=$(printf '%s\n' "$PARSED" | jq -r '.total_context_budget' 2>/dev/null || echo "0")
max_dim_agents=$(printf '%s\n' "$PARSED" | jq -r '.max_dimension_agents' 2>/dev/null || echo "7")
dim_count=$(printf '%s\n' "$PARSED" | jq -r '.dimension_count' 2>/dev/null || echo "0")

checks_run=0

# ── TC-001: max_ashes capacity ──

checks_run=$((checks_run + 1))
builtin_count=7
needed=$((builtin_count + custom_count))
if [ "$max_ashes" -lt "$needed" ]; then
  add_finding "TC-001" "CRITICAL" \
    "max_ashes ($max_ashes) < built-in ($builtin_count) + custom ($custom_count) = $needed. Some custom agents will be trimmed." \
    "Set settings.max_ashes to at least $needed (recommend $((needed + 1)) for buffer)"
fi

# ── TC-002 / TC-003: custom agent source resolution ──
# FIX: Use process substitution instead of pipe to preserve add_finding state

checks_run=$((checks_run + 1))
while IFS='|' read -r id severity message fix; do
  [[ -z "$id" ]] && continue
  add_finding "$id" "$severity" "$message" "$fix"
done < <(printf '%s\n' "$PARSED" | python3 - "$PROJECT_DIR" "$PLUGIN_ROOT" <<'PYEOF'
import sys, json, os

d = json.load(sys.stdin)
project_dir = sys.argv[1]
plugin_root = sys.argv[2]

for agent in d['custom_agents']:
    name = agent['name']
    agent_file = agent['agent']
    source = agent['source']

    if source == 'local':
        path = os.path.join(project_dir, '.claude', 'agents', agent_file + '.md')
        if not os.path.isfile(path):
            print(f'TC-002|CRITICAL|Custom ash "{name}" has source: local but {path} does not exist. Agent will never spawn.|Change source to "plugin" if agent is in registry/, or create .claude/agents/{agent_file}.md')
    elif source == 'plugin':
        registry_path = os.path.join(plugin_root, 'registry')
        agents_path = os.path.join(plugin_root, 'agents')
        found = False
        for root_dir in [registry_path, agents_path]:
            for dirpath, dirnames, filenames in os.walk(root_dir):
                if agent_file + '.md' in filenames:
                    found = True
                    break
            if found:
                break
        if not found:
            print(f'TC-003|HIGH|Custom ash "{name}" has source: plugin but no {agent_file}.md found in {plugin_root}/agents/ or {plugin_root}/registry/.|Verify agent file exists or change source')
PYEOF
)

# ── TC-004: total context_budget ──

checks_run=$((checks_run + 1))
if [ "$total_budget" -gt 100 ]; then
  add_finding "TC-004" "HIGH" \
    "Total custom agent context_budget is ${total_budget}% (exceeds 100%). Each agent will receive less than requested." \
    "Reduce individual context_budget values so total <= 100% (recommend 15-20% per agent)"
fi

# ── TC-005: max_dimension_agents vs dimensions count ──

checks_run=$((checks_run + 1))
if [ "$dim_count" -gt 0 ] && [ "$max_dim_agents" -lt "$dim_count" ]; then
  add_finding "TC-005" "HIGH" \
    "audit.deep.max_dimension_agents ($max_dim_agents) < dimensions array count ($dim_count). Some dimension agents will be skipped." \
    "Set max_dimension_agents to at least $dim_count"
elif [ "$dim_count" -gt 0 ] && [ "$max_dim_agents" -eq "$dim_count" ]; then
  add_finding "TC-005" "INFO" \
    "audit.deep.max_dimension_agents ($max_dim_agents) == dimensions count ($dim_count). No room for future additions." \
    "Consider setting max_dimension_agents to $((dim_count + 1)) for buffer"
fi

# ── TC-006: dedup_hierarchy vs custom agent prefixes ──
# FIX: Use process substitution instead of pipe to preserve add_finding state

checks_run=$((checks_run + 1))
while IFS='|' read -r id severity message fix; do
  [[ -z "$id" ]] && continue
  add_finding "$id" "$severity" "$message" "$fix"
done < <(printf '%s\n' "$PARSED" | python3 <<'PYEOF'
import sys, json

d = json.load(sys.stdin)
hierarchy = d.get('dedup_hierarchy', [])
custom_prefixes = {a['finding_prefix'] for a in d['custom_agents'] if a.get('finding_prefix')}

missing = custom_prefixes - set(hierarchy)
if missing:
    for prefix in sorted(missing):
        print(f'TC-006|HIGH|Custom ash prefix "{prefix}" not in dedup_hierarchy. Findings with this prefix may not deduplicate correctly.|Add "{prefix}" to settings.dedup_hierarchy')

known_builtin = {'SEC', 'BACK', 'VEIL', 'DOUBT', 'DOC', 'QUAL', 'FRONT', 'CDX',
                 'PY', 'TSR', 'RST', 'PHP', 'FAPI', 'DJG', 'LARV', 'SQLA', 'TDD', 'DDD', 'DI',
                 'UXH', 'UXI', 'UXF', 'UIQA', 'DES', 'SHARD'}
all_known = known_builtin | custom_prefixes
orphaned = [p for p in hierarchy if p not in all_known]
if orphaned:
    for prefix in orphaned:
        print(f'TC-006|INFO|Dedup hierarchy entry "{prefix}" has no matching built-in or custom agent.|Remove if agent was retired, or verify prefix is correct')
PYEOF
)

# ── Output JSON ──

findings_json="["
first=true
for f in "${findings[@]+"${findings[@]}"}"; do
  if [ "$first" = true ]; then
    first=false
  else
    findings_json+=","
  fi
  findings_json+="$f"
done
findings_json+="]"

echo "{\"findings\":$findings_json,\"checks_run\":$checks_run}"
