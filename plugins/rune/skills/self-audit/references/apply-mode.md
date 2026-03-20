# --apply Interactive Approval Protocol

The `--apply` flag on `/rune:self-audit` activates the fix proposal pipeline.
This document specifies the full protocol for generating, presenting, and
applying fix proposals with human-in-the-loop safety.

## Prerequisites

Before entering --apply mode:

1. **Run full audit first** — proposals require findings with recurrence data
2. **No active arc** — check for `.rune/arc-phase-loop.local.md`
3. **Clean working tree recommended** — applied fixes create atomic commits

## Eligibility Criteria

Not all findings produce proposals. A finding must meet ALL of:

| Criterion | Default | Talisman key |
|-----------|---------|-------------|
| Echo tier >= Etched | Etched or higher | (not configurable) |
| Recurrence count >= N | 3 | `self_audit.apply_mode.min_recurrence` |
| Confidence = HIGH | Required | `self_audit.apply_mode.require_high_confidence` |
| Not previously rejected | No `suppress_future: true` | (automatic) |
| Not in deferred state | No active arc | (automatic) |

## Proposal Generation

### Step 1: Filter Eligible Findings

```javascript
function filterEligible(findings, echoEntries) {
  const minRecurrence = readTalismanSection('misc')
    ?.self_audit?.apply_mode?.min_recurrence ?? 3
  const requireHigh = readTalismanSection('misc')
    ?.self_audit?.apply_mode?.require_high_confidence ?? true

  return findings.filter(f => {
    const echo = echoEntries.find(e => e.finding_id === f.id)
    if (!echo) return false
    if (echo.layer !== 'etched' && echo.layer !== 'inscribed') return false
    if (echo.recurrence_count < minRecurrence) return false
    if (requireHigh && echo.confidence !== 'HIGH') return false
    if (echo.suppress_future) return false
    return true
  })
}
```

### Step 2: Spawn Improvement Advisor

For eligible findings, spawn the `improvement-advisor` agent:

```javascript
Agent({
  subagent_type: 'rune:meta-qa:improvement-advisor',
  prompt: `Analyze these findings and generate fix proposals:
    ${JSON.stringify(eligibleFindings)}

    For each finding, produce a FIX proposal with:
    - Target file and line range
    - Current code snippet
    - Proposed replacement
    - Rationale and impact assessment
    - Confidence level (HIGH/MEDIUM)
    - Risk of regression (LOW/MEDIUM/HIGH)`,
  description: 'Generate fix proposals'
})
```

The advisor writes proposals to `tmp/self-audit/{timestamp}/proposals.md`.

### Step 3: Parse Proposals

Each proposal follows the format:

```markdown
### FIX-{NNN}: {Title}

- **Finding**: SA-{DIM}-{NNN} (recurrence: {N}x)
- **Target file**: `{file_path}`
- **Target lines**: {start}-{end}
- **Severity**: P1 | P2
- **Confidence**: HIGH | MEDIUM
- **Rationale**: {Why this fix addresses the root cause}

#### Current code:
```
{exact current content}
```

#### Proposed change:
```
{exact replacement content}
```

#### Impact assessment:
- Files affected: {list}
- Risk of regression: LOW | MEDIUM | HIGH
- Requires testing: {yes/no, what tests}
```

## Interactive Approval

### Per-Proposal AskUserQuestion

Each proposal is presented individually:

```javascript
const response = AskUserQuestion({
  questions: [{
    question: `Apply fix ${proposal.findingId}? (recurrence: ${proposal.recurrence}x, confidence: ${proposal.confidence})`,
    header: "Fix Proposal",
    options: [
      {
        label: "Apply",
        description: `Edit ${proposal.targetFile}`,
        preview: `--- Current (line ${proposal.startLine}-${proposal.endLine}) ---\n${proposal.currentCode}\n\n--- Proposed ---\n${proposal.proposedCode}`
      },
      {
        label: "Skip",
        description: "Skip this fix for now (won't be proposed again this session)"
      },
      {
        label: "Reject",
        description: "Mark as false positive — won't be proposed in future audits"
      }
    ],
    multiSelect: false
  }]
})
```

### Action Handling

#### Apply

```javascript
if (response === 'Apply') {
  // 1. Edit the target file
  Edit({
    file_path: proposal.targetFile,
    old_string: proposal.currentCode,
    new_string: proposal.proposedCode
  })

  // 2. Create atomic commit (never git add -A)
  Bash(`git add "${proposal.targetFile}"`)
  Bash(`git commit -m "$(cat <<'EOF'
self-audit-fix(${proposal.context}): [${proposal.findingId}] ${proposal.title}
EOF
)"`)

  applied.push(proposal.findingId)
}
```

#### Skip

```javascript
if (response === 'Skip') {
  // No persistent action — just skip for this session
  skipped.push(proposal.findingId)
}
```

#### Reject

```javascript
if (response === 'Reject') {
  // Ask for rejection reason
  const reason = AskUserQuestion({
    questions: [{
      question: `Why reject ${proposal.findingId}?`,
      header: "Rejection Reason",
      options: [
        { label: "False positive", description: "Finding is incorrect" },
        { label: "Intentional", description: "Current behavior is intentional" },
        { label: "Too risky", description: "Fix could break something" },
        { label: "Other", description: "Custom reason" }
      ]
    }]
  })

  // Record rejection in meta-qa echoes
  appendToEcho('.rune/echoes/meta-qa/MEMORY.md', `
### [${today}] Rejected: ${proposal.findingId} ${proposal.title}
- **layer**: notes
- **source**: rune:self-audit apply-${runId}
- **confidence**: 1.0
- **rejection_reason**: "${reason}"
- **suppress_future**: true
- User rejected proposal. Reason: ${reason}.
`)

  rejected.push({ id: proposal.findingId, reason })
}
```

## Deferred Proposals

When an active arc is detected (`.rune/arc-phase-loop.local.md` exists),
proposals are saved instead of presented:

```javascript
const arcActive = Glob('.rune/arc-phase-loop.local.md')
if (arcActive.length > 0) {
  Write('.rune/echoes/meta-qa/deferred-proposals.md', formatProposals(proposals))
  log('Active arc detected. Proposals deferred.')
  log('Run /rune:self-audit --apply after arc completes.')
  return
}
```

On the next `--apply` invocation without an active arc, deferred proposals
are loaded and presented alongside any new proposals.

## Summary Report

After all proposals are processed:

```markdown
## --apply Summary

| Action | Count | Finding IDs |
|--------|-------|-------------|
| Applied | 3 | SA-AGT-001, SA-WF-004, SA-HK-006 |
| Skipped | 1 | SA-RC-002 |
| Rejected | 1 | SA-AGT-003 (intentional) |

### Applied Commits
- `abc1234` self-audit-fix(prompt): [SA-AGT-001] Add missing maxTurns
- `def5678` self-audit-fix(workflow): [SA-WF-004] Update phase count
- `ghi9012` self-audit-fix(hook): [SA-HK-006] Add missing hook row
```

## Safety Constraints

1. **Never auto-apply** — every fix requires explicit human approval
2. **Atomic commits** — each fix is a separate commit for easy revert (`git revert <sha>`)
3. **Specific git add** — never `git add -A`, only the target file
4. **No security-critical changes** — improvement-advisor never proposes changes to
   `enforce-readonly.sh`, `enforce-teams.sh`, or other security hooks
5. **No rule removal** — proposals can align, update, or add rules, never remove
6. **Confidence-gated** — only HIGH confidence proposals by default
7. **Recurrence-gated** — only findings seen 3+ times (proven patterns, not noise)

## --dry-run Mode

When `--dry-run` is passed alongside `--apply`, the full pipeline runs but:
- Proposals are generated and displayed
- No AskUserQuestion is shown
- No files are edited
- No commits are created
- Output clearly marked as `[DRY RUN]`

This allows reviewing what `--apply` would do without side effects.
