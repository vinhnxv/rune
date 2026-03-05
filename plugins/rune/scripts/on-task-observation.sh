#!/bin/bash
# scripts/on-task-observation.sh
# Auto-observation recording for Rune workflow tasks.
# Fires on TaskCompleted — appends lightweight observation entries to the
# appropriate role MEMORY.md in .claude/echoes/.
#
# Design goals:
# - Non-blocking: exit 0 on all error paths
# - Dedup: ${TEAM_NAME}_${TASK_ID} as dedup key (portable, C2)
# - Role detection from team name pattern
# - Append-only to .claude/echoes/{role}/MEMORY.md (Observations tier)
# - Signals echo-search dirty for auto-reindex

set -euo pipefail
umask 077  # PAT-005 FIX: Consistent secure file creation

# PAT-001 FIX: Use canonical _rune_fail_forward instead of _fail_open
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  echo "WARN: ${BASH_SOURCE[0]##*/} crashed at line $_crash_line — fail-forward." >&2
  exit 0
}
trap '_rune_fail_forward' ERR

# PAT-009 FIX: Add _trace() for observability
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] on-task-observation: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# Guard: jq required for safe JSON parsing
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — observation recording skipped." >&2  # PAT-008 FIX
  exit 0
fi

# Read hook input from stdin (max 1MB — PAT-002 FIX: standardized cap)
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Guard 1: Only process Rune workflow tasks ---
IFS=$'\t' read -r TEAM_NAME TASK_ID TASK_SUBJECT TASK_DESC AGENT_NAME < <(
  printf '%s\n' "$INPUT" | jq -r '
    [
      .team_name // "",
      .task_id // "",
      .task_subject // "",
      (.task_description // "" | .[0:500]),
      .teammate_name // "unknown"
    ] | @tsv' 2>/dev/null || echo ""
) || true

[[ -z "$TEAM_NAME" ]] && exit 0
[[ "$TEAM_NAME" =~ ^(rune-|arc-) ]] || exit 0

# Guard: safe characters only (prevent path traversal)
[[ "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0
[[ ${#TEAM_NAME} -le 128 ]] || exit 0
[[ -n "$TASK_ID" ]] || exit 0
[[ "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

# --- Guard 2: Skip cleanup/shutdown/meta tasks ---
case "${TASK_SUBJECT,,}" in
  *shutdown*|*cleanup*|*aggregate*|*monitor*|*"shut down"*) exit 0 ;;
esac

# --- Guard 3: Resolve project directory ---
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && exit 0
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
[[ -n "$CWD" && "$CWD" == /* ]] || exit 0

PROJECT_DIR="$CWD"

# --- Guard 4: Check .claude/echoes/ directory exists ---
ECHO_DIR="$PROJECT_DIR/.claude/echoes"
[[ -d "$ECHO_DIR" ]] || exit 0

# --- Guard 5: Symlink protection on echoes dir ---
[[ -L "$ECHO_DIR" ]] && exit 0

# --- Guard 6: Determine role from team name pattern ---
ROLE="orchestrator"
case "$TEAM_NAME" in
  *review*|*appraise*|*audit*) ROLE="reviewer" ;;
  *plan*|*devise*)             ROLE="planner" ;;
  *work*|*strive*|*arc*)       ROLE="workers" ;;
esac

# --- Guard 7: Check role MEMORY.md exists ---
MEMORY_FILE="$ECHO_DIR/$ROLE/MEMORY.md"
[[ -f "$MEMORY_FILE" ]] || exit 0

# Symlink guard on MEMORY.md
[[ -L "$MEMORY_FILE" ]] && exit 0

# --- Guard 8: Dedup by ${TEAM_NAME}_${TASK_ID} (Concern C2 — portable, no md5) ---
SIGNAL_DIR="$PROJECT_DIR/tmp/.rune-signals"
mkdir -p "$SIGNAL_DIR" 2>/dev/null || exit 0
DEDUP_KEY="${TEAM_NAME}_${TASK_ID}"
DEDUP_FILE="$SIGNAL_DIR/.obs-${DEDUP_KEY}"
[[ -f "$DEDUP_FILE" ]] && exit 0
touch "$DEDUP_FILE" 2>/dev/null || exit 0

# --- Step 9: Generate and append observation entry ---
DATE=$(date +%Y-%m-%d)

ENTRY=$(cat <<'ENTRY_EOF'

## Observations — Task: __TASK_SUBJECT__ (__DATE__)
- **layer**: observations
- **source**: `__TEAM_NAME__/__AGENT_NAME__`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: __TASK_SUBJECT__
- Context: __TASK_DESC__
ENTRY_EOF
)
# Inject actual values via variable replacement (safe — no shell expansion in heredoc body)
ENTRY="${ENTRY//__TASK_SUBJECT__/$TASK_SUBJECT}"
ENTRY="${ENTRY//__DATE__/$DATE}"
ENTRY="${ENTRY//__TEAM_NAME__/$TEAM_NAME}"
ENTRY="${ENTRY//__AGENT_NAME__/$AGENT_NAME}"
ENTRY="${ENTRY//__TASK_DESC__/$TASK_DESC}"

# Atomic append via temp file (prevent partial writes)
TMPFILE=$(mktemp 2>/dev/null) || exit 0
printf '%s\n' "$ENTRY" > "$TMPFILE"
cat "$TMPFILE" >> "$MEMORY_FILE" 2>/dev/null || { rm -f "$TMPFILE"; exit 0; }
rm -f "$TMPFILE"

# --- Step 10: Signal echo-search dirty for auto-reindex ---
touch "$SIGNAL_DIR/.echo-dirty" 2>/dev/null || true

exit 0
