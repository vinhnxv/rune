#!/bin/bash
# plugins/rune/scripts/verify-arc-state-integrity.sh
#
# PostToolUse hook: after any Write/Edit to .rune/arc/*/checkpoint.json,
# verify phase-loop state file exists. When missing, auto-create via
# rune-arc-init-state.sh in hook/source mode.
#
# Fast-path: exits immediately when the modified file is NOT an arc checkpoint.
# Re-entrancy guard (R16): refuses to run if the tool_input.file_path IS the
# state file itself. RUNE_ARC_STATE_INIT_IN_PROGRESS guard for nested writes.
#
# DESIGN:
#   - Dry-run mode when arc.state_file.code_enforced_writes == false
#     (hook fires, logs observation, does NOT write the state file)
#   - Active mode when flag == true (creates state file on miss)
#   - Always exit 0 — fail-forward protocol; never block the user's tool call
#   - Budget: <5s total (default hook timeout)
#
# See plan §6.3, §6.4, and Issue 10 in §16.

set -u

# ─── Hook re-entrancy guard ───
if [ -n "${RUNE_ARC_STATE_INIT_IN_PROGRESS:-}" ]; then
  exit 0  # nested invocation — already handling
fi
export RUNE_ARC_STATE_INIT_IN_PROGRESS=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
: "${CWD:=$PWD}"

# ─── Read hook input JSON from stdin ───
# Fail-forward: if input unreadable, emit valid JSON and exit 0
_input=""
if [ -t 0 ]; then
  # Interactive — no stdin; nothing to do
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
  exit 0
fi
_input=$(cat 2>/dev/null || echo "")
[ -z "$_input" ] && {
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
  exit 0
}

# ─── Extract tool name + file_path (fast-path grep BEFORE jq) ───
# Fast-path: skip everything if input doesn't even mention arc or checkpoint
if ! printf '%s' "$_input" | grep -q '\.rune/arc/.*checkpoint\.json'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
  exit 0
fi

# Extract via jq (required from here on — safely fall through if missing)
if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
  exit 0
fi

_tool_name=$(printf '%s' "$_input" | jq -r '.tool_name // .toolName // ""' 2>/dev/null)
_file_path=$(printf '%s' "$_input" | jq -r '.tool_input.file_path // .toolInput.file_path // ""' 2>/dev/null)

# Only react to Write/Edit (MultiEdit/NotebookEdit out of scope)
case "$_tool_name" in
  Write|Edit) ;;
  *)
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
    exit 0
    ;;
esac

# ─── Canonical path gate: only arc checkpoints ───
# Canonical: .rune/arc/arc-{digits}/checkpoint.json (allow absolute or relative)
case "$_file_path" in
  *..*|'')
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
    exit 0
    ;;
esac
# Strict regex
if ! printf '%s' "$_file_path" | grep -Eq '\.rune/arc/arc-[0-9]+/checkpoint\.json$'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
  exit 0
fi

# ─── R16 guard: refuse if file_path IS the state file ───
case "$_file_path" in
  *arc-phase-loop.local.md|*arc-batch-loop.local.md|*arc-hierarchy-loop.local.md|*arc-issues-loop.local.md)
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
    exit 0
    ;;
esac

# ─── Source lib to read flag + log ───
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/rune-state.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/arc-loop-state.sh" 2>/dev/null || {
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
  exit 0
}

# ─── Dry-run vs active decision ───
_mode="dry_run"
if arc_state_flag_enabled; then
  _mode="active"
fi

# Always check and log — even in dry-run
_init="${SCRIPT_DIR}/rune-arc-init-state.sh"
[ -x "$_init" ] || {
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
  exit 0
}

# Verify state file
if "$_init" verify >/dev/null 2>&1; then
  # State file exists — touch to refresh mtime (throttled in lib)
  if [ "$_mode" = "active" ]; then
    "$_init" touch >/dev/null 2>&1 || true
  fi
  arc_state_integrity_log "verified" "posttooluse_hook_${_mode}" "$(arc_state_file_path phase 2>/dev/null)"
else
  # State file missing — auto-recreate in active mode, log-only in dry-run
  if [ "$_mode" = "active" ]; then
    if "$_init" create --source hook --checkpoint "${CWD}/${_file_path#"${CWD}/"}" >/dev/null 2>&1; then
      : # success — init script logs recovery event itself
    else
      arc_state_integrity_log "recovery_failed_no_checkpoint" "posttooluse_auto_create_failed" ""
    fi
  else
    # Dry-run: log what we WOULD have done
    arc_state_integrity_log "recovery_failed_no_checkpoint" "posttooluse_dry_run_would_have_created" ""
  fi
fi

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
exit 0
