---
name: learn
description: |
  Use /rune:learn to extract and persist CLI correction patterns and review
  recurrence findings from session history into Rune Echoes memory. Runs detectors
  over recent session JSONL files and TOME findings, then writes high-confidence
  patterns to .claude/echoes/ for future workflow improvement.

  Trigger keywords: learn, session learning, persist patterns, corrections, recurrences,
  self-learning, extract patterns from sessions, cli corrections.

  <example>
  user: "/rune:learn"
  assistant: "Scanning last 7 days... Found 3 CLI corrections, 2 review recurrences. Write 5 patterns? [y/N]"
  </example>

  <example>
  user: "/rune:learn --since 14 --detector review"
  assistant: "Running review-recurrence detector only... Found 4 recurring findings. Write 4 patterns? [y/N]"
  </example>

  <example>
  user: "/rune:learn --dry-run"
  assistant: "Dry run: 5 patterns found. No entries written."
  </example>
user-invocable: true
disable-model-invocation: true
argument-hint: "[--since DAYS] [--detector cli|review|arc|hook|all] [--dry-run]"
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# /rune:learn — Session Self-Learning

Extract CLI correction patterns and review recurrence findings from session history, then persist them as Rune Echoes memory entries for future workflow improvement.

## Overview

```
/rune:learn [--since DAYS] [--detector cli|review|arc|hook|all] [--dry-run]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--since DAYS` | 7 | Scan session files from last N days |
| `--detector TYPE` | all | Which detectors to run (cli, review, arc, hook, all) |
| `--dry-run` | false | Report findings without writing to echoes |
| `--project PATH` | CWD | Project directory to scan (implicit) |

## Execution Flow

### Phase 1: Parse Arguments

Read `$ARGUMENTS` and set:
- `SINCE_DAYS` (default 7)
- `DETECTOR` (default all)
- `DRY_RUN` (default false)

Resolve `PROJECT_DIR` = current working directory.

Resolve `SCRIPT_DIR`:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARN_DIR="${SCRIPT_DIR}/../../scripts/learn"
```

### Phase 2: Run Detectors

#### 2a. Session Scanner (always runs)

```bash
SCAN_OUTPUT=$(bash "${LEARN_DIR}/session-scanner.sh" \
  --since "${SINCE_DAYS}" \
  --project "${PROJECT_DIR}" \
  --format json 2>/dev/null)
```

Output: `{"events":[...], "scanned": N, "project": "..."}`

#### 2b. CLI Correction Detector (`--detector cli|all`)

```bash
CLI_OUTPUT=$(printf '%s' "$SCAN_OUTPUT" | \
  bash "${LEARN_DIR}/cli-correction-detector.sh" 2>/dev/null)
```

Output: `{"corrections":[...]}`

Each correction:
```json
{
  "error_type": "UnknownFlag",
  "tool_name": "Bash",
  "failed_input": "...",
  "corrected_input": "...",
  "error_preview": "...",
  "confidence": 0.9,
  "multi_session": false
}
```

#### 2c. Review Recurrence Detector (`--detector review|all`)

```bash
REV_OUTPUT=$(bash "${LEARN_DIR}/review-recurrence-detector.sh" \
  --project "${PROJECT_DIR}" 2>/dev/null)
```

Output: `{"recurrences":[...]}`

Each recurrence:
```json
{
  "finding_id": "SEC-001",
  "tome_paths": ["tmp/reviews/X/TOME.md"],
  "count": 3,
  "severity": "high",
  "description": "..."
}
```

#### 2d. Arc + Hook Detectors (inline, `--detector arc|hook|all`)

These run as inline grep-based scans — no separate detector script:

**Arc failures:**
```bash
# Grep checkpoint.json files for failed phases
find -P "${PROJECT_DIR}/.claude/arc" -name "checkpoint.json" -not -type l 2>/dev/null | \
  xargs grep -l '"status":"failed"' 2>/dev/null | head -10
```
Extract phase name and failure reason from the checkpoint JSON.

**Hook denials:**
```bash
# Grep session JSONL for hook denial events
find -P "${CHOME}/projects/${ENCODED_PATH}" -maxdepth 1 -name "*.jsonl" 2>/dev/null | \
  xargs grep -l '"hookDecision":"deny"' 2>/dev/null | head -5
```
Extract tool name, reason from denial events.

### Phase 3: Consolidate & Report

Merge all detector outputs into a single findings list. Sort by confidence (desc), then severity (high → low).

Display a summary table:

```
/rune:learn — Session Analysis (last 7 days, 12 sessions scanned)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 # │ Type        │ Tool/ID  │ Pattern                    │ Conf
───┼─────────────┼──────────┼────────────────────────────┼──────
 1 │ CLI Fix     │ Bash     │ UnknownFlag: --no-verify   │ 0.90
 2 │ Recurrence  │ SEC-001  │ SQL injection in query()   │ high
 3 │ CLI Fix     │ Bash     │ WrongPath: ./scripts/run   │ 0.75
 4 │ Arc Failure │ Phase 7  │ Test phase timed out       │ n/a
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
4 patterns found. Ready to write to echoes.
```

If no findings, report:
```
No patterns found in last 7 days.
```

### Phase 4: User Confirmation & Write

If `--dry-run`, skip this phase and exit with the report.

Otherwise, use `AskUserQuestion`:
```
Write 4 patterns to .claude/echoes/workers/MEMORY.md? [y/N]
```

On "y": for each pattern, invoke echo-writer.sh:
```bash
printf '%s' "$ENTRY_JSON" | bash "${LEARN_DIR}/echo-writer.sh" \
  --role workers \
  --layer notes \
  --source "learn/session-scanner"
```

Map pattern type to role:
| Pattern Type | Echo Role |
|-------------|-----------|
| CLI Fix | workers |
| Review Recurrence | reviewer |
| Arc Failure | orchestrator |
| Hook Denial | orchestrator |

Map confidence to layer:
| Confidence | Layer |
|-----------|-------|
| >= 0.8 | inscribed |
| >= 0.6 | notes |
| < 0.6 | observations |

On success, report: "N patterns written to .claude/echoes/."

## Entry Format

CLI corrections become echo entries like:

```markdown
## CLI Fix: UnknownFlag for Bash (2026-03-01)
- **layer**: notes
- **source**: `learn/session-scanner`
- **confidence**: HIGH
- **tags**: cli-correction, UnknownFlag, Bash

When using Bash, the flag `--no-verify` caused "unknown flag" error.
Correct usage was `--no-gpg-sign` instead.

Error: unknown flag: --no-verify
Fixed: git commit --no-gpg-sign -m "..."
```

Review recurrences become:

```markdown
## Review Recurrence: SEC-001 — SQL injection (2026-03-01)
- **layer**: inscribed
- **source**: `learn/review-recurrence-detector`
- **confidence**: HIGH
- **tags**: recurrence, SEC-001, security

Finding SEC-001 appeared in 3 separate TOME reviews without echo entry.
Description: SQL injection in query() method — use parameterized queries.
```

## References

- [detectors.md](references/detectors.md) — Detector algorithms and JSONL schema documentation
