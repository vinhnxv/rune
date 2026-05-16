# Arc Failure Policy (ARC-5)

Per-phase failure handling matrix and error recovery strategies.
Extracted from SKILL.md in v1.110.0 for phase-isolated context architecture.

## Failure Matrix

| Phase | On Failure | Recovery |
|-------|-----------|----------|
| FORGE | Proceed with original plan copy + warn. Offer `--no-forge` on retry | `/rune:arc --resume --no-forge` |
| PLAN REVIEW | Halt if any BLOCK verdict; non-blocking CONCERN extraction post-step proceeds with deferred concerns (absorbed `plan_refine` v3.0.0-alpha.6 C4a) | User fixes plan, `/rune:arc --resume` |
| VERIFICATION | Non-blocking — proceed with warnings | Informational |
| WORK | evaluateReaction("work_incomplete", ctx) — halt if min_completion not met after retries. Partial commits preserved | `/rune:arc --resume` |
| GAP ANALYSIS | Non-blocking — WARN only | Advisory context for code review |
| GAP REMEDIATION | Non-blocking — gate miss → skip cleanly. Fixer timeout → partial fixes, proceed | Advisory (v1.51.0) |
| INSPECT | Non-blocking — audit (VERDICT.md with completion %), fix (FIXABLE gap-fixer agents), and convergence eval all in one phase. P1 gaps surfaced as findings | Self-contained; converges in up to `inspect_convergence.max_rounds` cycles |
| CODE REVIEW | Does not halt | Produces findings or clean report |
| VERIFY (findings) | Non-blocking — classifies TOME findings TRUE_POSITIVE/FALSE_POSITIVE/NEEDS_CONTEXT | Pre-mend filter (conditional on `arc.verify.enabled`) |
| MEND | evaluateReaction("mend_findings_exceeded", ctx) — halt if max_failed_findings exceeded after retries | User fixes, `/rune:arc --resume` |
| MEND QA | QA gate scores mend's resolution report (FAIL/MARGINAL → retry up to MAX_QA_RETRIES). On PASS/EXCELLENT, the absorbed `verify_mend` convergence post-step (v3.0.0-alpha.6 C4d) decides converge/retry/halt; retry resets code_review + mend to pending | Retries up to tier max cycles, then proceeds (DECREE-002) |
| TEST | Non-blocking WARN only. Test failures recorded in report | `--no-test` to skip entirely |
| SHIP | preShipValidator pre-step (absorbed `pre_ship_validation` v3.0.0-alpha.6 C4e) emits non-blocking diagnostics; PR creation proceeds. On gh failure: branch was pushed, user creates PR manually: `gh pr create` | — |
| MERGE | Skip merge, PR remains open. Rebase conflicts → warn with resolution steps | User merges manually: `gh pr merge --squash` |

> **Removed phases (v3.0.0-alpha.1+)**: DESIGN EXTRACTION, DESIGN VERIFICATION, DESIGN ITERATION, STORYBOOK VERIFICATION, UX VERIFICATION, BROWSER TEST/FIX/VERIFY, GOLDMASK VERIFICATION/CORRELATION, BOT REVIEW WAIT, PR COMMENT RESOLUTION, SEMANTIC VERIFICATION, TASK DECOMPOSITION, TEST COVERAGE CRITIQUE, RELEASE QUALITY CHECK. Their failure rows were removed from this matrix as those phases no longer dispatch.

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
| Work completion below reactions.work_incomplete.min_completion | evaluateReaction("work_incomplete") — halt after retry budget exhausted |
| Mend findings exceed reactions.mend_findings_exceeded.max_failed_findings | evaluateReaction("mend_findings_exceeded") — halt after retry budget exhausted |
| Worker crash mid-phase | Phase team cleanup, checkpoint preserved |
| Branch conflict | Warn user, suggest manual resolution |
| Total pipeline timeout (dynamic: 156-320 min) | Halt, preserve checkpoint, suggest `--resume` |
| Plan freshness STALE | AskUserQuestion with Re-plan/Override/Abort |
| Schema v1-v16 checkpoint on --resume | Auto-migrate to v17 |
| Convergence circuit breaker | Stop retrying, proceed to test |
| Ship phase: gh CLI not available | Skip PR creation |
| Merge phase: Rebase conflicts | Abort rebase, warn with manual resolution |
| Zombie teammates after arc completion (ARC-9) | Final sweep, fallback: `/rune:cancel-arc` |
