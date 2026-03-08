#!/usr/bin/env python3
"""
measure-startup-tokens.sh — Token overhead measurement tool
Measures Claude Code startup token overhead from Rune plugin components
"""
import os
import sys
import re
import json
from pathlib import Path

# Colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'

PLUGIN_ROOT = Path(__file__).parent.parent

def count_tokens(text: str) -> int:
    """Approximate token count (~4 chars per token)"""
    return len(text) // 4

def extract_description(file_path: Path) -> str:
    """Extract description from YAML frontmatter"""
    try:
        content = file_path.read_text()
    except Exception:
        return ""

    # Match frontmatter
    fm_match = re.search(r'^---\n(.*?)^---', content, re.MULTILINE | re.DOTALL)
    if not fm_match:
        return ""

    fm = fm_match.group(1)

    # Multi-line with |
    desc_match = re.search(r'^description:\s*\|\s*\n((?:[ \t]+.*\n?)*)', fm, re.MULTILINE)
    if desc_match:
        desc = desc_match.group(1)
        desc = re.sub(r'^[ \t]+', '', desc, flags=re.MULTILINE)
        return desc.strip()

    # Single-line
    desc_match = re.search(r'^description:\s*"(.*?)"', fm, re.MULTILINE | re.DOTALL)
    if desc_match:
        return desc_match.group(1).strip()

    desc_match = re.search(r'^description:\s*(.+?)$', fm, re.MULTILINE)
    if desc_match:
        return desc_match.group(1).strip()

    return ""

def has_dmi(file_path: Path) -> bool:
    """Check if skill has disable-model-invocation: true"""
    try:
        content = file_path.read_text()
        return bool(re.search(r'disable-model-invocation:\s*true', content))
    except Exception:
        return False

def is_background(file_path: Path) -> bool:
    """Check if skill has user-invocable: false"""
    try:
        content = file_path.read_text()
        return bool(re.search(r'user-invocable:\s*false', content))
    except Exception:
        return False

def main():
    print(f"{BLUE}=== Rune Startup Token Measurement ==={NC}\n")

    # 1. Skill descriptions
    print(f"{YELLOW}## Skill Descriptions{NC}")
    skill_total = 0
    skill_count = 0
    skill_dmi_count = 0
    skill_background_count = 0
    skill_breakdown = []

    for skill_dir in PLUGIN_ROOT.joinpath("skills").iterdir():
        skill_file = skill_dir / "SKILL.md"
        if not skill_file.exists():
            continue

        skill_name = skill_dir.name

        if has_dmi(skill_file):
            skill_dmi_count += 1
            continue

        if is_background(skill_file):
            skill_background_count += 1

        desc = extract_description(skill_file)
        if desc:
            tokens = count_tokens(desc)
            skill_total += tokens
            skill_count += 1
            skill_breakdown.append((tokens, skill_name))

    skill_breakdown.sort(reverse=True)
    print("Top skill descriptions by tokens:")
    for tokens, name in skill_breakdown[:15]:
        print(f"  {tokens:5d} {name}")
    print(f"  ... and {skill_count - 15} more skills")
    print()
    print(f"  Skills with disable-model-invocation: {skill_dmi_count} (deferred)")
    print(f"  Background skills (user-invocable: false): {skill_background_count}")
    print(f"  {GREEN}Total skill description tokens: {skill_total}{NC}")

    # 2. Agent descriptions
    print(f"\n{YELLOW}## Agent Descriptions{NC}")
    agent_total = 0
    agent_count = 0
    agent_breakdown = []

    for agent_dir in PLUGIN_ROOT.joinpath("agents").iterdir():
        if agent_dir.is_dir():
            for agent_file in agent_dir.glob("*.md"):
                agent_name = agent_file.stem
                desc = extract_description(agent_file)
                if desc:
                    tokens = count_tokens(desc)
                    agent_total += tokens
                    agent_count += 1
                    agent_breakdown.append((tokens, agent_name))

    agent_breakdown.sort(reverse=True)
    print("Top agent descriptions by tokens:")
    for tokens, name in agent_breakdown[:15]:
        print(f"  {tokens:5d} {name}")
    print(f"  ... and {agent_count - 15} more agents")
    print(f"  {GREEN}Total agent description tokens: {agent_total}{NC}")

    # 3. CLAUDE.md
    print(f"\n{YELLOW}## CLAUDE.md{NC}")
    claude_md = PLUGIN_ROOT / "CLAUDE.md"
    claude_tokens = 0
    if claude_md.exists():
        claude_chars = len(claude_md.read_text())
        claude_tokens = claude_chars // 4
        print(f"  Character count: {claude_chars}")
        print(f"  {GREEN}Estimated tokens: {claude_tokens}{NC}")

    # 4. hooks.json
    print(f"\n{YELLOW}## hooks.json{NC}")
    hooks_file = PLUGIN_ROOT / "hooks" / "hooks.json"
    hooks_tokens = 0
    if hooks_file.exists():
        hooks_chars = len(hooks_file.read_text())
        hooks_tokens = hooks_chars // 4
        print(f"  Character count: {hooks_chars}")
        print(f"  {GREEN}Estimated tokens: {hooks_tokens}{NC}")

    # Summary
    print(f"\n{BLUE}=== Summary ==={NC}")
    total = skill_total + agent_total + claude_tokens + hooks_tokens
    print(f"  Skill descriptions:    {skill_total:6d} tokens ({skill_count} loaded)")
    print(f"  Agent descriptions:    {agent_total:6d} tokens ({agent_count} agents)")
    print(f"  CLAUDE.md:             {claude_tokens:6d} tokens")
    print(f"  hooks.json:            {hooks_tokens:6d} tokens")
    print()
    print(f"  {GREEN}TOTAL STARTUP OVERHEAD: {total} tokens{NC}")

    target = 18300
    threshold = 20000
    if total < threshold:
        print(f"  {GREEN}✓ Under threshold ({threshold} tokens){NC}")
    else:
        print(f"  {RED}✗ Above threshold ({threshold} tokens){NC}")

    # Save baseline
    baseline_file = Path("tmp/token-opt-baseline.json")
    baseline_file.parent.mkdir(exist_ok=True)
    baseline = {
        "skill_descriptions": skill_total,
        "skill_count": skill_count,
        "skill_dmi_count": skill_dmi_count,
        "skill_background_count": skill_background_count,
        "agent_descriptions": agent_total,
        "agent_count": agent_count,
        "claude_md": claude_tokens,
        "hooks_json": hooks_tokens,
        "total": total,
        "target": target,
        "threshold": threshold
    }
    baseline_file.write_text(json.dumps(baseline, indent=2))
    print(f"\nBaseline saved to: {baseline_file}")

if __name__ == "__main__":
    main()