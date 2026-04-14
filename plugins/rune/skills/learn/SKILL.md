---
name: learn
description: |
  Use /rune:learn to extract and persist CLI correction patterns and review
  recurrence findings from session history into Rune Echoes memory. Runs detectors
  over recent session JSONL files and TOME findings, then writes high-confidence
  patterns to .rune/echoes/ for future workflow improvement.

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
  user: "/rune:learn --detector meta-qa"
  assistant: "Scanning last 7 days of arc checkpoints... Found 2 meta-QA patterns (code_review retried in 3/4 arcs, high convergence in 2/4 arcs). Write 2 patterns? [y/N]"
  </example>

  <example>
  user: "/rune:learn --dry-run"
  assistant: "Dry run: 5 patterns found. No entries written."
  </example>
user-invocable: true
argument-hint: "[--since DAYS] [--detector cli|review|arc|hook|meta-qa|skill-promotion|all] [--dry-run]"
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
/rune:learn [--since DAYS] [--detector cli|review|arc|hook|meta-qa|skill-promotion|all] [--dry-run]
/rune:learn --watch    # Enable real-time correction detection for this session
/rune:learn --unwatch  # Disable real-time detection
```

| Flag | Default | Description |
|------|---------|-------------|
| `--since DAYS` | 7 | Scan session files from last N days |
| `--detector TYPE` | all | Which detectors to run (cli, review, arc, hook, meta-qa, skill-promotion, all) |
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

#### 2e. Meta-QA Detector (`--detector meta-qa|all`)

```bash
MQA_OUTPUT=$(bash "${LEARN_DIR}/meta-qa-detector.sh" \
  --since "${SINCE_DAYS}" \
  --project "${PROJECT_DIR}" 2>/dev/null)
```

Output: `{"patterns":[...], "total_arcs_scanned": N}`

Each pattern:
```json
{
  "type": "meta-qa",
  "pattern_key": "retry_rate:code_review",
  "description": "code_review phase retried in 3/4 recent arcs (75%)",
  "affected_phase": "code_review",
  "arc_count": 3,
  "total_arcs": 4,
  "confidence": 0.8,
  "evidence": [".rune/arc/arc-123/checkpoint.json"],
  "category": "retry_rate|convergence|qa_score"
}
```

See [detectors.md](references/detectors.md) for algorithm details and pattern categories.

#### 2f. Skill Promotion Detector (`--detector skill-promotion|all`)

Scans Etched and Notes tier echoes for procedural patterns that would benefit from being promoted to project-level Agent Skills (`.claude/skills/`). Gated by `echoes.skill_promotion.enabled` in talisman (default: true).

**Algorithm** — see [references/skill-promotion.md](references/skill-promotion.md) for full pseudocode.

Detection heuristics for promotion candidates:
- **Layer filter**: Etched OR Notes (weight=1.0, user-explicit, never auto-pruned). Observations and Traced excluded.
- **Action keywords**: `always|never|must|should|before.*do` — constraint or procedural language
- **Code patterns**: backtick blocks, file paths, function names
- **Access count** (from `echo_access_log` via existing `_get_access_counts()` at `scripts/echo-search/server.py:78`): `>= min_access_count` (default 5; configurable via talisman `echoes.skill_promotion.min_access_count`)
- **Content length**: `> 100 chars AND < 1500 chars` (substantial but not context-bomb)

**Scoring formula** (clamped to [0, 1]):
```
promotion_score = min(1.0, (action_keywords * 0.3)
                         + (code_patterns * 0.3)
                         + (access_count / 10 * 0.2)
                         + (content_length / 500 * 0.2))
```

Threshold: `promotion_score >= min_score` (default 0.6; configurable via talisman `echoes.skill_promotion.min_score`) → candidate.

Each candidate emits a pattern:
```json
{
  "type": "skill-promotion",
  "pattern_key": "promote:<echo-id>",
  "description": "<echo title>",
  "echo_id": "<MEM-...>",
  "echo_layer": "etched|notes",
  "access_count": N,
  "promotion_score": 0.87,
  "suggested_invocable": true|false,
  "confidence": 0.9,
  "source_file": ".rune/echoes/<role>/MEMORY.md"
}
```

Skill-promotion patterns use a dedicated confirmation flow (Phase 4.1) separate from the general echo-writer path — a promotion produces a new `.claude/skills/<slug>/SKILL.md` file, not an echo entry.

#### 2d. Arc + Hook Detectors (inline, `--detector arc|hook|all`)

These run as inline grep-based scans — no separate detector script:

**Arc failures:**
```bash
# Grep checkpoint.json files for failed phases
find -P "${PROJECT_DIR}/.rune/arc" -name "checkpoint.json" -not -type l -not -path "*/archived/*" 2>/dev/null | \
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
 5 │ Meta-QA     │ code_review │ Phase retried in 3/4 arcs │ 0.80
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
Write 4 patterns to .rune/echoes/workers/MEMORY.md? [y/N]
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
| Meta-QA Pattern | meta-qa |

Map confidence to layer:
| Confidence | Layer |
|-----------|-------|
| >= 0.8 | inscribed |
| >= 0.6 | notes |
| < 0.6 | observations |

On success, report: "N patterns written to .rune/echoes/."

### Phase 4.1: Skill Promotion Confirmation Gate (Task 3)

Runs when `skill-promotion` patterns are present in the findings list. Each candidate triggers a dedicated `AskUserQuestion` flow — promotion creates a `.claude/skills/<slug>/SKILL.md` file, NOT an echo entry.

**First-run banner** (once per session, tracked via `tmp/.rune-signals/skill-promotion-banner-shown-${CLAUDE_SESSION_ID}`):
```
→ New feature: Rune can promote this echo to a .claude/skills/ skill.
  Disable with `echoes.skill_promotion.enabled: false` in talisman.yml.
```

**Session-wide skip flag**: If the user selects "Skip all" for any candidate, set `tmp/.rune-signals/skill-promotion-skip-${CLAUDE_SESSION_ID}` and suppress all remaining skill-promotion prompts this session.

**Per-candidate flow** (see [references/skill-promotion.md](references/skill-promotion.md) for full pseudocode):

```javascript
for (const candidate of skillPromotionCandidates) {
  if (existsSignal("skill-promotion-skip-")) break
  // Dedup: check .claude/skills/*/SKILL.md for similar existing skills
  const dup = findExistingSimilarSkill(candidate)
  const primaryLabel = dup ? "Update existing skill" : "Create skill (Recommended)"
  const primaryDescription = dup
    ? `Merge new content into .claude/skills/${dup.slug}/SKILL.md`
    : `Saves to .claude/skills/${candidate.slug}/SKILL.md — loaded every session`

  AskUserQuestion({
    questions: [{
      question: `Promote echo "${candidate.description}" to a skill?`,
      header: "Skill Promotion",
      options: [
        { label: primaryLabel, description: primaryDescription },
        { label: "Preview first", description: "Show the generated SKILL.md content, then re-ask" },
        { label: "Skip", description: "Keep as echo only — don't promote this one" },
        { label: "Skip all", description: "Suppress future promotion suggestions this session" }
      ],
      multiSelect: false
    }]
  })
}
```

On "Create skill" / "Update existing": write to `.claude/skills/<slug>/SKILL.md` (project target) or `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/<slug>/SKILL.md` (user target, controlled by `echoes.skill_promotion.target`).

**Post-create activation reminder**: Always print after a successful create/update:
```
✓ Skill written to .claude/skills/<slug>/SKILL.md
  Run `/reload-plugins` or restart Claude Code to activate this skill in the current session.
```

On "Preview first": render the generated SKILL.md content, then re-render the same 4-option prompt (omitting "Preview first" to avoid loops).

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
