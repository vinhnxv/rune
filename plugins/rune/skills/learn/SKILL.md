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
/rune:learn --watch    # Enable real-time correction detection for this session
/rune:learn --unwatch  # Disable real-time detection
```

| Flag | Default | Description |
|------|---------|-------------|
| `--since DAYS` | 7 | Scan session files from last N days |
| `--detector TYPE` | all | Which detectors to run (cli, review, arc, hook, all) |
| `--dry-run` | false | Report findings without writing to echoes |
| `--project PATH` | CWD | Project directory to scan (implicit) |
| `--watch` | false | Enable real-time correction detection (two-hook pipeline) |
| `--unwatch` | false | Disable real-time correction detection |

## Execution Flow

### Phase 0: Parse Arguments

Read `$ARGUMENTS` and handle special flags first:

**--watch flag**:
1. Create `tmp/.rune-learn-watch` marker file with session identity:
   ```json
   {"config_dir": "${CLAUDE_CONFIG_DIR:-$HOME/.claude}", "owner_pid": "$PPID", "session_id": "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()}
   ```
2. Create `tmp/.rune-signals/.learn-edits/` directory
3. Output: "Real-time correction detection enabled for this session."
4. Exit (skip remaining phases)

**--unwatch flag**:
1. Remove `tmp/.rune-learn-watch` marker if it exists
2. Remove `tmp/.rune-signals/.learn-edits/` directory
3. Remove `tmp/.rune-signals/.learn-correction-detected` signal
4. Output: "Real-time correction detection disabled."
5. Exit (skip remaining phases)

**Regular flags**: Set the following:
- `SINCE_DAYS` (default 7)
- `DETECTOR` (default all)
- `DRY_RUN` (default false)

Resolve `PROJECT_DIR` = current working directory.

Resolve `LEARN_DIR`:
```bash
PLUGIN_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)/plugins/rune
LEARN_DIR="${PLUGIN_ROOT}/scripts/learn"
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

On "y": for each pattern, invoke echo-writer.sh with role and layer resolved from the mapping tables below (role varies by pattern type, layer varies by confidence):
```bash
# Simplified example — actual role/layer/source vary per pattern type (see mapping tables)
printf '%s' "$ENTRY_JSON" | bash "${LEARN_DIR}/echo-writer.sh" \
  --role "${ECHO_ROLE}" \
  --layer "${ECHO_LAYER}" \
  --source "learn/${SOURCE_DETECTOR}"
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

## Real-Time Correction Detection (--watch)

The `--watch` flag activates a two-hook pipeline for automatic correction detection:

1. **PostToolUse hook** (`correction-signal-writer.sh`) — Detects file-revert patterns
2. **Stop hook** (`detect-corrections.sh`) — Aggregates signals and suggests Echo persist

### Activation

```bash
/rune:learn --watch    # Creates marker file tmp/.rune-learn-watch
/rune:learn --unwatch  # Removes marker file and signal directory
```

### What Gets Detected

| Signal Type | Description | Source |
|-------------|-------------|--------|
| File revert | Same file edited 2+ times | PostToolUse hook |
| CLI errors | `is_error:true` in JSONL | Stop hook JSONL scan |

### How It Works

1. **Marker file**: `tmp/.rune-learn-watch` contains session identity (`config_dir`, `owner_pid`, `session_id`)
2. **Edit tracking**: `tmp/.rune-signals/.learn-edits/{hash}.log` per-file timestamps
3. **Signal file**: `tmp/.rune-signals/.learn-correction-detected` written on 2+ edits to same file
4. **Debounce**: Max 1 suggestion per session via `.learn-suggested-{PID}` marker
5. **Session isolation**: Only activates when marker owner matches current session

### Guardrails

- Fast-path exit when marker absent (< 1ms overhead)
- Active workflow guard: Skips during arc/strive/batch pipelines
- Fail-forward: Crashes are silent (non-blocking hooks)
- Signal cleanup after suggestion (prevents accumulation)
