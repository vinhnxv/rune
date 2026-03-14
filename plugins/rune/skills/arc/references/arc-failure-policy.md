# Arc Failure Policy (ARC-5)

Per-phase failure handling matrix and error recovery strategies.
Extracted from SKILL.md in v1.110.0 for phase-isolated context architecture.

## Failure Matrix

| Phase | On Failure | Recovery |
|-------|-----------|----------|
| FORGE | Proceed with original plan copy + warn. Offer `--no-forge` on retry | `/rune:arc --resume --no-forge` |
| PLAN REVIEW | Halt if any BLOCK verdict | User fixes plan, `/rune:arc --resume` |
| PLAN REFINEMENT | Non-blocking — proceed with deferred concerns | Advisory phase |
| VERIFICATION | Non-blocking — proceed with warnings | Informational |
| SEMANTIC VERIFICATION | Non-blocking — Codex timeout/unavailable → skip, proceed | Informational (v1.39.0) |
| DESIGN EXTRACTION | Non-blocking — design_sync disabled or no Figma URL → skip cleanly. Timeout/MCP error → skip with warning | Conditional (v1.109.0) |
| TASK DECOMPOSITION | Non-blocking — Codex timeout/unavailable → skip, proceed | Advisory (v1.51.0) |
| WORK | Halt if <50% tasks complete. Partial commits preserved | `/rune:arc --resume` |
| DRIFT REVIEW | Non-blocking — skip on error (non-critical) | Advisory phase — pipeline continues |
| DESIGN VERIFICATION | Non-blocking — no VSM files from design_extraction → skip cleanly. Reviewer failure → skip with warning | Conditional (v1.109.0) |
| GAP ANALYSIS | Non-blocking — WARN only | Advisory context for code review |
| CODEX GAP ANALYSIS | Non-blocking — Codex timeout/unavailable → skip, proceed | Advisory (v1.39.0) |
| GAP REMEDIATION | Non-blocking — gate miss → skip cleanly. Fixer timeout → partial fixes, proceed | Advisory (v1.51.0) |
| CODE REVIEW | Does not halt | Produces findings or clean report |
| MEND | Halt if >3 FAILED findings | User fixes, `/rune:arc --resume` |
| VERIFY MEND | Non-blocking — retries up to tier max cycles, then proceeds | Convergence gate is advisory (DECREE-002: max_rounds enforced in evaluateConvergence()) |
| DESIGN ITERATION | Non-blocking — fidelity score >= threshold → skip cleanly. Agent-browser unavailable → skip with warning | Conditional (v1.109.0) |
| TEST | Non-blocking WARN only. Test failures recorded in report | `--no-test` to skip entirely |
| TEST COVERAGE CRITIQUE | Non-blocking — Codex timeout/unavailable → skip, proceed | Advisory (v1.51.0) |
| PRE-SHIP VALIDATION | Non-blocking — BLOCK verdict proceeds with warning in PR body | Orchestrator-only |
| RELEASE QUALITY CHECK | Non-blocking — Codex timeout/unavailable → skip, proceed | Advisory (v1.51.0) |
| BOT_REVIEW_WAIT | Non-blocking — timeout or disabled → skip cleanly | Advisory (v1.88.0) |
| PR_COMMENT_RESOLUTION | Non-blocking — unresolvable comments logged in report | Advisory (v1.88.0) |
| SHIP | Skip PR creation, proceed to completion report. Branch was pushed | User creates PR manually: `gh pr create` |
| MERGE | Skip merge, PR remains open. Rebase conflicts → warn with resolution steps | User merges manually: `gh pr merge --squash` |

## Error Handling Table

| Error | Recovery |
|-------|----------|
| Concurrent arc session active | Abort with warning, suggest `/rune:cancel-arc` |
| Plan file not found | Suggest `/rune:devise` first |
| Checkpoint corrupted | Warn user, offer fresh start or manual fix |
| Artifact hash mismatch on resume | Demote phase to pending, re-run |
| Phase timeout | Halt, preserve checkpoint, suggest `--resume` |
| BLOCK verdict in plan review | Halt, report blocker details |
| All-CONCERN escalation (3x CONCERN) | Auto-proceed with warning (use `--confirm` to pause) |
| <50% work tasks complete | Halt, partial commits preserved |
| >3 FAILED mend findings | Halt, resolution report available |
| Worker crash mid-phase | Phase team cleanup, checkpoint preserved |
| Branch conflict | Warn user, suggest manual resolution |
| Total pipeline timeout (dynamic: 156-320 min) | Halt, preserve checkpoint, suggest `--resume` |
| Plan freshness STALE | AskUserQuestion with Re-plan/Override/Abort |
| Schema v1-v16 checkpoint on --resume | Auto-migrate to v17 |
| Convergence circuit breaker | Stop retrying, proceed to test |
| Ship phase: gh CLI not available | Skip PR creation |
| Merge phase: Rebase conflicts | Abort rebase, warn with manual resolution |
| Zombie teammates after arc completion (ARC-9) | Final sweep, fallback: `/rune:cancel-arc` |
