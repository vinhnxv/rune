# CSO — Claude Search Optimization for Skill Descriptions

A guide for writing skill `description:` fields that maximize correct auto-discovery by Claude's model. Poor descriptions cause missed loads (skill not triggered when needed) and false positives (skill loaded when irrelevant).

---

## Purpose

Claude uses skill descriptions to decide:
1. Whether to auto-load a skill's full content into context (model invocation)
2. Whether to suggest a skill to the user
3. Which skill to prefer when multiple match

A description optimized for Claude search — not human readability — dramatically increases correct skill selection.

---

## Description Quality Checklist

Every skill description should satisfy these 7 criteria:

- [ ] **Starts with "Use when..."** — actionable trigger, not a definition
- [ ] **Names the error signature** — what the user sees that makes this skill relevant (exit code, error message, hook code)
- [ ] **Includes specific keywords** — terms the user is likely to type verbatim (command names, flag names, file names)
- [ ] **Covers the failure case** — when would NOT having this skill cause a problem?
- [ ] **Includes at least one quantified threshold** — specific numbers reduce ambiguity (e.g., "up to 8 parallel", "17 phases", "3-layer")
- [ ] **Avoids workflow summary** — descriptions are triggers, not documentation
- [ ] **Is under 300 characters per paragraph** — Claude truncates long descriptions during context loading

---

## Good vs Bad Patterns

### Trigger-Focused vs Workflow Summary

**Bad (workflow summary):**
```yaml
description: |
  Runs the full development pipeline: forge, work, review, mend, ship, merge.
  17 phases with checkpoint resume and convergence loops.
```
Problem: Describes what the skill does, not when to load it. A user who types "resume arc" won't match this.

**Good (trigger-focused):**
```yaml
description: |
  Use when running end-to-end pipeline from plan to merged PR, when resuming
  a failed arc with --resume, or when any of the 17 arc phases fail (forge,
  plan-review, plan-refinement, verification, semantic-verification, work,
  goldmask-verification,
  code-review, goldmask-correlation, mend, verify-mend, test, ship, merge).
```

---

### Error-Driven vs Prescriptive

**Bad (prescriptive):**
```yaml
description: |
  Use this skill when doing multi-account setup. Provides CHOME pattern docs.
```
Problem: "Multi-account setup" is rarely what the user types. They type the error they see.

**Good (error-driven):**
```yaml
description: |
  Use when a Bash command references ~/.claude/ and fails with "path not found"
  or "No such file or directory" in multi-account setups. Use when writing
  rm -rf for team directories, when CLAUDE_CONFIG_DIR is set to a custom path.
  Keywords: CLAUDE_CONFIG_DIR, CHOME, ~/.claude, multi-account, config directory.
```

---

## Keyword Line Convention

Add an explicit keyword line when the skill covers concepts with multiple synonyms:

```yaml
description: |
  Use when...
  [trigger content]
  Keywords: worktree, isolation, wave, merge broker, branch merge, conflict.
```

Keyword lines are NOT needed if the description already contains all relevant terms naturally.

---

## Quantified Threshold Convention

Include numbers when the skill governs limits or phases:

| Vague | Specific |
|-------|----------|
| "multiple phases" | "17 phases" |
| "several reviewers" | "up to 8 parallel reviewers" |
| "self-review" | "3-layer self-review" |
| "retry logic" | "5th attempt triggers escalation" |

---

## Audit Command

Run this to check all skill descriptions for trigger-focused framing:

```bash
for f in plugins/rune/skills/*/SKILL.md; do
  skill=$(basename "$(dirname "$f")")
  desc=$(awk '/^description:/,/^[a-z]/' "$f" | head -5)
  if ! echo "$desc" | grep -q "Use when\|use when"; then
    echo "MISSING 'Use when' trigger: $skill"
  fi
done
```

Expected output: empty (all skills have trigger framing).
