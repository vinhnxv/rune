# /rune:learn — Detector Algorithms and JSONL Schema

## Session JSONL Schema

Claude Code stores session history as JSONL files under:
```
${CLAUDE_CONFIG_DIR:-~/.claude}/projects/{encoded-project-path}/*.jsonl
```

Where `{encoded-project-path}` = the absolute project path with `/` replaced by `-`, leading `-` stripped.

### JSONL Event Types

Each line in a session JSONL is a JSON object:

```json
{ "type": "message", "role": "assistant", "content": [...] }
{ "type": "message", "role": "user", "content": [...] }
{ "type": "isCompactSummary", ... }
```

**Tool use events** (inside `assistant` message content array):
```json
{
  "type": "tool_use",
  "id": "toolu_01Abc...",
  "name": "Bash",
  "input": { "command": "git push origin main" }
}
```

**Tool result events** (inside `user` message content array):
```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01Abc...",
  "content": "Error: command not found: psuh",
  "is_error": true
}
```

### Filtering Rules

- `isCompactSummary` events MUST be skipped (`select(.type != "isCompactSummary")`)
- Files modified within 60 seconds of scan time are skipped (current session exclusion)
- `find -P` is required (no symlink following)

## session-scanner.sh Output Schema

```json
{
  "events": [
    {
      "tool_name": "Bash",
      "input_preview": "git push origin main",
      "result_preview": "Branch updated",
      "is_error": false,
      "soft_error": false,
      "tool_use_id": "toolu_01Abc",
      "file": "session-stem"
    }
  ],
  "scanned": 3,
  "project": "/path/to/project"
}
```

Events are joined pairs: each `tool_use` matched with its `tool_result` via `tool_use_id`.
Content is truncated to 500 characters.

## cli-correction-detector.sh

### Algorithm

```
INPUT: session-scanner.sh JSON output
OUTPUT: { "corrections": [...] }

1. Parse events[] array from scanner output
2. Walk events with index i:
   a. If events[i].is_error == false → skip (i++)
   b. If events[i].is_error == true:
      - classify_error(events[i].result_preview) → error_type
      - Look ahead in window [i+1 .. i+window]:
        - Find first j where events[j].tool_name == events[i].tool_name
          AND events[j].is_error == false
        - If found: record correction pair, advance i = j
        - If not found: advance i++
3. Dedup pairs with Jaccard word-overlap >= 0.8 on (failed_input + corrected_input)
4. Sort by confidence desc
```

### Error Classification

| Error Type | Pattern (case-insensitive) |
|------------|---------------------------|
| `UnknownFlag` | `unknown flag`, `unrecognized option`, `invalid flag`, `bad flag` |
| `CommandNotFound` | `command not found`, `zsh: command not found`, `is not recognized` |
| `WrongPath` | `No such file or directory`, `not a directory`, `does not exist` |
| `WrongSyntax` | `syntax error`, `unexpected token`, `parse error`, `SyntaxError` |
| `PermissionDenied` | `permission denied`, `access denied`, `Operation not permitted` |
| `Timeout` | `timed out`, `timeout`, `killed.*SIGTERM`, `exceeded.*time limit` |
| `UnknownError` | (fallback — none of the above matched) |

### Confidence Calculation

```
base     = 0.5
+0.2     if same tool_name in error and success events
+0.2     if Jaccard(failed_input, corrected_input) in [0.3, 0.95)  (similar but changed)
+0.1     if events come from different session files (multi_session)
max      = 1.0
```

### Output Schema

```json
{
  "corrections": [
    {
      "error_type": "CommandNotFound",
      "tool_name": "Bash",
      "failed_input": "git psuh origin main",
      "corrected_input": "git push origin main",
      "error_preview": "command not found: psuh",
      "confidence": 0.9,
      "multi_session": false
    }
  ]
}
```

## review-recurrence-detector.sh

### Algorithm

```
INPUT: TOME files from tmp/reviews/*/TOME.md, tmp/audit/*/TOME.md, tmp/arc/*/TOME.md
       .rune/echoes/reviewer/MEMORY.md (for cross-reference)
OUTPUT: { "recurrences": [...] }

1. Glob TOME files (find -P, no symlinks, nullglob)
2. For each TOME:
   a. Extract all finding IDs matching /[A-Z][A-Z0-9]{1,10}-\d{1,4}/
   b. Extract description text following the finding ID
   c. Record: finding_id -> { descriptions: [...], tome_paths: [...] }
3. Read reviewer MEMORY.md, extract all finding IDs mentioned
4. For each finding_id:
   a. Skip if count < min_count (default: 2)
   b. Skip if finding_id already in echoed_ids (already captured)
   c. Deduplicate descriptions with Jaccard >= 0.8
   d. Record recurrence with best_desc = longest unique description
5. Sort: high severity first, then count desc
```

### Finding ID Pattern

Matches: `SEC-001`, `QUAL-003`, `BACK-007`, `VEIL-002`, `PERF-012`, `TEST-004`, `ARCH-002`

Pattern: `/[A-Z][A-Z0-9]{1,10}-\d{1,4}/` (2–11 uppercase alphanum prefix, dash, 1–4 digits)

### Severity Inference

| Prefix | Severity |
|--------|----------|
| `SEC` | high |
| `BACK` | medium |
| `VEIL` | medium |
| `PERF` | medium |
| `ARCH` | medium |
| `QUAL` | low |
| `DOC` | low |
| `TEST` | low |
| (other) | low |

### Output Schema

```json
{
  "recurrences": [
    {
      "finding_id": "SEC-003",
      "tome_paths": [
        "tmp/reviews/abc/TOME.md",
        "tmp/reviews/def/TOME.md"
      ],
      "count": 2,
      "severity": "high",
      "description": "SQL injection in query builder via raw string interpolation"
    }
  ]
}
```

## Arc + Hook Detectors (Inline)

These run as inline Bash/grep scans within the skill — no separate detector script.

### Arc Failure Detector

Targets: `.rune/arc/*/checkpoint.json`

```bash
find -P "${PROJECT_DIR}/.rune/arc" -name "checkpoint.json" -not -type l 2>/dev/null | \
  while IFS= read -r f; do
    jq -r --arg f "$f" '
      .phases | to_entries[] |
      select(.value.status == "failed") |
      {phase: .key, checkpoint: $f, status: "failed"}
    ' "$f" 2>/dev/null
  done
```

Reports: phase name + checkpoint path. Groups by phase name to count occurrences.

### Hook Denial Detector

Targets: Session JSONL files in `${CHOME}/projects/${ENCODED_PATH}/`

```bash
find -P "${CHOME}/projects/${ENCODED_PATH}" -maxdepth 1 -name "*.jsonl" -not -type l 2>/dev/null | \
  xargs grep -h '"permissionDecision":"deny"' 2>/dev/null | \
  jq -r '.tool_input.command // .tool_name // "unknown"' 2>/dev/null | \
  sort | uniq -c | sort -rn | head -10
```

Reports: top N denied tool invocations with counts.

## echo-writer.sh Input Schema

```json
{
  "title": "CLI Fix: CommandNotFound for Bash",
  "content": "When using Bash, `git psuh` caused command not found.\nCorrected: `git push`",
  "confidence": "HIGH",
  "tags": ["cli-correction", "CommandNotFound", "Bash"]
}
```

Fields:
- `title` (required) — used as echo header and dedup key
- `content` (required) — body text, filtered through sensitive-patterns.sh
- `confidence` — `HIGH`, `MEDIUM`, or `LOW` (default: `MEDIUM`)
- `tags` — optional string array for metadata

## Privacy and Security

- All content is truncated to 500 chars before processing
- `isCompactSummary` events are always skipped
- Files modified within 60s are excluded (current session)
- No symlink following (`find -P`, explicit `[[ -L ]]` guards)
- echo-writer.sh strips sensitive data via `sensitive-patterns.sh` before writing
- Role names validated against `/^[a-zA-Z0-9_-]+$/`
