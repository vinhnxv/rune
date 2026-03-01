# /rune:learn — Creation Log

## Problem Statement

Rune workflows generate valuable learning signals that go uncaptured: CLI commands
that failed and were corrected, review findings that recur across TOMEs without being
echoed, arc phases that repeatedly fail, and hook denials that reveal workflow friction.
Without automated extraction, these patterns are lost between sessions and must be
rediscovered repeatedly.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Manual echo writing | High friction — users must remember to write echoes after each session. In practice, this rarely happens. |
| Always-on hook that writes echoes automatically | Too aggressive — would write low-quality, unreviewed entries. Echoes should be curated, not noise. Phase 4 confirmation gate preserves quality. |
| Single monolithic detector script | Harder to test, extend, and maintain. Modular detectors (cli, review, arc, hook) allow independent evolution and targeted `--detector` invocations. |
| Levenshtein distance for dedup | Requires more complex implementation with no stdlib equivalent in bash/python2. Jaccard word-overlap is simpler, faster, and works well for CLI command dedup where word identity matters more than edit distance. |
| flock-based locking in echo-writer.sh | Not portable across macOS (BSD) and Linux. mkdir-based locking is atomic on all POSIX systems and requires no additional tools. |

## Key Design Decisions

- **4-phase execution with confirmation gate**: Phase 4 AskUserQuestion prevents
  unsupervised echo writes. The skill surfaces patterns for human review before
  persisting them, maintaining echo quality.

- **Modular detector scripts**: Each detector is a standalone script with its own
  input/output contract, making them independently testable and invocable. The
  arc/hook detectors are intentionally inline (grep-based) to avoid over-engineering
  for what are simple pattern scans. The tradeoff: inline saves ~2 files and one shell
  spawn per invocation, at the cost of testability. For arc/hook detection, the
  patterns are stable one-liners (`jq -r '...status == "failed"'`, grep for
  `permissionDecision`), making external scripts unnecessary overhead.

- **Hook denial JSONL field — `permissionDecision` (not `hookDecision`)**: The correct
  field name in Claude Code session JSONL for hook denial events is
  `"permissionDecision":"deny"`, as confirmed in `references/detectors.md`. The inline
  grep in `SKILL.md` originally used `"hookDecision":"deny"`, which is incorrect and
  would produce zero matches. Corrected per VEIL-004 audit finding. Any inline hook
  detector or grep pattern must use `permissionDecision`, not `hookDecision`.

- **mtime-based session exclusion (60s window)**: Using `$CLAUDE_SESSION_ID` for
  current-session exclusion would require the script to know its own session ID,
  creating a coupling problem. mtime < 60s is a robust, portable heuristic that
  correctly excludes in-progress sessions without any session ID dependency.

- **Jaccard word-overlap for dedup**: Both cli-correction-detector and
  review-recurrence-detector use the same Jaccard threshold (80%) for deduplication.
  This is simpler than Levenshtein and effective for the use cases: CLI commands share
  keyword vocabulary, and finding descriptions share domain terminology.

- **Confidence → layer mapping**: High-confidence patterns (>= 0.8) go to `inscribed`
  (stable, verified knowledge). Lower confidence goes to `notes` or `observations`
  (provisional, needs verification). This respects the 5-tier echo hierarchy.

- **`disable-model-invocation: true`**: Prevents Claude from auto-loading this skill
  when it sees learning-related keywords in normal conversation. The skill should only
  run when explicitly invoked via `/rune:learn`.

- **sensitive-patterns.sh as shared library**: Located in `scripts/lib/` (not
  `scripts/learn/`) because it may be reused by future skills that need to redact
  credentials before writing to any persistent store.

## Iteration History

| Date | Version | Change | Trigger |
|------|---------|--------|---------|
| 2026-03-01 | v1.0 | Initial creation — 4 detectors (cli, review, arc, hook), echo-writer integration, Phase 4 confirmation gate | Session Self-Learning feature (v1.125.0) |
| 2026-03-01 | v1.0.1 | Corrected inline hook denial grep: `hookDecision` → `permissionDecision` (VEIL-004). Added design rationale for inline arc/hook detector choice and field name correctness. | Audit finding DOC-007 / VEIL-004 |
