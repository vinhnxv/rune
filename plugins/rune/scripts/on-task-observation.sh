#!/bin/bash
# scripts/on-task-observation.sh
# Auto-observation recording for Rune workflow tasks.
# Fires on TaskCompleted — appends lightweight observation entries to the
# appropriate role MEMORY.md in ${RUNE_STATE}/echoes/.
#
# Design goals:
# - Non-blocking: exit 0 on all error paths
# - Dedup: ${TEAM_NAME}_${TASK_ID} as dedup key (portable, C2)
# - Role detection from team name pattern
# - Append-only to ${RUNE_STATE}/echoes/{role}/MEMORY.md (Observations tier)
# - Signals echo-search dirty for auto-reindex

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rune-state.sh"

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

# SEC-002 FIX: Strip markdown headers from task data to prevent header injection
TASK_SUBJECT="${TASK_SUBJECT//#/}"
TASK_DESC="${TASK_DESC//#/}"
[[ "$TEAM_NAME" =~ ^(rune-|arc-) ]] || exit 0

# Guard: safe characters only (prevent path traversal)
[[ "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0
[[ ${#TEAM_NAME} -le 128 ]] || exit 0
[[ -n "$TASK_ID" ]] || exit 0
[[ "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

# --- Guard 2: Skip cleanup/shutdown/meta tasks ---
# Bash 3.2 compatible: use tr instead of ${var,,}
case "$(printf '%s' "$TASK_SUBJECT" | tr '[:upper:]' '[:lower:]')" in
  *shutdown*|*cleanup*|*aggregate*|*monitor*|*"shut down"*) exit 0 ;;
esac

# --- Guard 3: Resolve project directory ---
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && exit 0
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
[[ -n "$CWD" && "$CWD" == /* ]] || exit 0

PROJECT_DIR="$CWD"

# --- Guard 4: Check ${RUNE_STATE}/echoes/ directory exists ---
ECHO_DIR="$PROJECT_DIR/${RUNE_STATE}/echoes"
[[ -d "$ECHO_DIR" ]] || exit 0

# --- Guard 4.5: Hard gate — prevent writes to global echoes directory (C5: fail-forward) ---
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GLOBAL_ECHO_DIR="$CHOME/echoes/global"
# If the target echoes dir is under the global echoes path, skip silently.
# Global echoes (doc packs) are curated — auto-observations must not pollute them.
case "$ECHO_DIR" in
  "$GLOBAL_ECHO_DIR"*) exit 0 ;;
esac

# --- Guard 5: Symlink protection on echoes dir ---
[[ -L "$ECHO_DIR" ]] && exit 0

# --- Guard 6: Determine role from team name pattern ---
ROLE="orchestrator"
case "$TEAM_NAME" in
  *self-audit*|*meta-qa*)      ROLE="meta-qa" ;;
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
**Source**: `__TEAM_NAME__/__AGENT_NAME__`
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

# T8 / RUIN-005 FIX: Atomic append via read-modify-mv. Previous implementation
# appended with `cat TMPFILE >> MEMORY_FILE`, which is NOT atomic — a
# TaskCompleted hook killed mid-append left MEMORY.md with a partial
# observation entry, corrupting the echo index on reload. Now we stage the
# full target file in a sibling temp, then atomically rename over it.
_MEMORY_DIR="${MEMORY_FILE%/*}"
[[ -d "$_MEMORY_DIR" ]] || mkdir -p "$_MEMORY_DIR" 2>/dev/null || exit 0
TMPFILE=$(mktemp "${_MEMORY_DIR}/.MEMORY.md.XXXXXX" 2>/dev/null) || exit 0
if [[ -f "$MEMORY_FILE" ]]; then
  cat "$MEMORY_FILE" > "$TMPFILE" 2>/dev/null || { rm -f "$TMPFILE"; exit 0; }
fi
printf '%s\n' "$ENTRY" >> "$TMPFILE" 2>/dev/null || { rm -f "$TMPFILE"; exit 0; }
mv -f "$TMPFILE" "$MEMORY_FILE" 2>/dev/null || { rm -f "$TMPFILE"; exit 0; }

# --- Step 9.5: Assumption echo persistence ---
# If the task's summary.json has assumptions_violated or assumptions_declared,
# write them to .rune/echoes/assumptions/MEMORY.md.
# VIOLATED → inscribed tier. HELD/UNVERIFIED → observations tier.
WORK_SUMMARY=$(find "${CWD}/tmp/work" -maxdepth 4 -path "*/evidence/${TASK_ID}/summary.json" -print -quit 2>/dev/null || true)
if [[ -n "$WORK_SUMMARY" && -f "$WORK_SUMMARY" ]]; then
  # Check if assumptions fields exist
  HAS_ASSUMPTIONS=$(jq -r '(has("assumptions_violated") or has("assumptions_declared")) | tostring' "$WORK_SUMMARY" 2>/dev/null || echo "false")
  if [[ "$HAS_ASSUMPTIONS" == "true" ]]; then
    ASSUMPTION_ECHO_DIR="$ECHO_DIR/assumptions"
    ASSUMPTION_MEMORY="$ASSUMPTION_ECHO_DIR/MEMORY.md"
    ASSUMPTION_DEDUP_KEY="${TEAM_NAME}_${TASK_ID}_assumption"
    ASSUMPTION_DEDUP_FILE="$SIGNAL_DIR/.obs-${ASSUMPTION_DEDUP_KEY}"
    if [[ ! -f "$ASSUMPTION_DEDUP_FILE" ]] && [[ ! -L "$ASSUMPTION_ECHO_DIR" ]]; then
      mkdir -p "$ASSUMPTION_ECHO_DIR" 2>/dev/null || true
      touch "$ASSUMPTION_DEDUP_FILE" 2>/dev/null || true
      # Determine tier from violation count
      VIOLATED_COUNT=$(jq -r '.assumptions_violated // [] | length' "$WORK_SUMMARY" 2>/dev/null || echo "0")
      [[ "$VIOLATED_COUNT" =~ ^[0-9]+$ ]] || VIOLATED_COUNT="0"
      if [[ "$VIOLATED_COUNT" -gt 0 ]]; then
        ASSUMPTION_TIER="inscribed"
        VIOLATED_LIST=$(jq -r '.assumptions_violated // [] | join("; ")' "$WORK_SUMMARY" 2>/dev/null || true)
        # SEC-002: strip markdown header chars from assumption text
        VIOLATED_LIST="${VIOLATED_LIST//#/}"
        ASSUMPTION_DETAIL="Violated (${VIOLATED_COUNT}): ${VIOLATED_LIST}"
      else
        ASSUMPTION_TIER="observations"
        DECLARED_COUNT=$(jq -r '.assumptions_declared // [] | length' "$WORK_SUMMARY" 2>/dev/null || echo "0")
        ASSUMPTION_DETAIL="Declared: ${DECLARED_COUNT} — all HELD or UNVERIFIED"
      fi
      ASSUMPTION_ENTRY=$(cat <<'AEOF'

## Assumption Echo — Task: __TASK_SUBJECT__ (__DATE__)
- **layer**: __TIER__
- **Source**: `__TEAM_NAME__/__AGENT_NAME__`
- **Confidence**: LOW (auto-generated from summary.json)
- __ASSUMPTION_DETAIL__
AEOF
      )
      ASSUMPTION_ENTRY="${ASSUMPTION_ENTRY//__TASK_SUBJECT__/$TASK_SUBJECT}"
      ASSUMPTION_ENTRY="${ASSUMPTION_ENTRY//__DATE__/$DATE}"
      ASSUMPTION_ENTRY="${ASSUMPTION_ENTRY//__TIER__/$ASSUMPTION_TIER}"
      ASSUMPTION_ENTRY="${ASSUMPTION_ENTRY//__TEAM_NAME__/$TEAM_NAME}"
      ASSUMPTION_ENTRY="${ASSUMPTION_ENTRY//__AGENT_NAME__/$AGENT_NAME}"
      ASSUMPTION_ENTRY="${ASSUMPTION_ENTRY//__ASSUMPTION_DETAIL__/$ASSUMPTION_DETAIL}"
      # Atomic write using mktemp+cat+printf+mv pattern
      ATMPFILE=$(mktemp "${ASSUMPTION_ECHO_DIR}/.MEMORY.md.XXXXXX" 2>/dev/null) || true
      if [[ -n "$ATMPFILE" ]]; then
        if [[ -f "$ASSUMPTION_MEMORY" ]]; then
          cat "$ASSUMPTION_MEMORY" > "$ATMPFILE" 2>/dev/null || { rm -f "$ATMPFILE"; ATMPFILE=""; }
        fi
        if [[ -n "$ATMPFILE" ]]; then
          printf '%s\n' "$ASSUMPTION_ENTRY" >> "$ATMPFILE" 2>/dev/null || { rm -f "$ATMPFILE"; ATMPFILE=""; }
          [[ -n "$ATMPFILE" ]] && mv -f "$ATMPFILE" "$ASSUMPTION_MEMORY" 2>/dev/null || { rm -f "$ATMPFILE" 2>/dev/null; true; }
        fi
      fi
    fi
  fi
fi

# --- Step 10: Signal echo-search dirty for auto-reindex ---
touch "$SIGNAL_DIR/.echo-dirty" 2>/dev/null || true

exit 0
