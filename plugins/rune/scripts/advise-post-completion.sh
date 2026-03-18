#!/bin/bash
# scripts/advise-post-completion.sh
# POST-COMP-001: Advisory warning when heavy tools are used after arc pipeline completion.
# Advisory only — NEVER blocks. Uses additionalContext to inject a gentle warning.
# Debounced: warns once per session via /tmp flag file.
# Fail-open: any error → exit 0 (allow tool).
#
# Design: advise- prefix = advisory-only PreToolUse hook (vs enforce-* for guards that can deny).
# BD-2 doc: This hook is purely advisory. It will NEVER emit permissionDecision: "deny".

set -euo pipefail
umask 077

# --- Fail-open wrapper ---
_fail_open() { exit 0; }
trap '_fail_open' ERR

# --- Guard: jq dependency ---
command -v jq >/dev/null 2>&1 || exit 0

# --- Guard: Input size cap (SEC-2) ---
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Guard: Teammate bypass (subagents skip) ---
TRANSCRIPT_PATH=$(printf '%s\n' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
if [[ -n "$TRANSCRIPT_PATH" && "$TRANSCRIPT_PATH" == *"/subagents/"* ]]; then
  exit 0
fi

# --- Extract CWD and SESSION_ID ---
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && exit 0

SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[[ -z "$SESSION_ID" ]] && exit 0

# SESSION_ID validation (prevent path injection)
if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

# --- CWD canonicalization ---
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
if [[ -z "$CWD" || "$CWD" != /* ]]; then
  exit 0
fi

# --- Session identity ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=resolve-session-identity.sh
source "${SCRIPT_DIR}/resolve-session-identity.sh"
source "${SCRIPT_DIR}/lib/rune-state.sh"

# --- Debounce: once per session ---
# SEC-P3-005: Use TMPDIR (non-predictable on macOS) + UID-scoped path
FLAG_FILE="${TMPDIR:-/tmp}/rune-postcomp-$(id -u)-${SESSION_ID}.json"

# Symlink guard on flag file
if [[ -L "$FLAG_FILE" ]]; then
  rm -f "$FLAG_FILE" 2>/dev/null
fi

if [[ -f "$FLAG_FILE" ]]; then
  # Already warned this session — skip
  exit 0
fi

# --- Guard: Check for active state files (arc running NOW) ---
# If any rune workflow is active, do NOT advise — let it finish.
shopt -s nullglob
for sf in "${CWD}"/tmp/.rune-*.json; do
  [[ -f "$sf" ]] || continue
  [[ -L "$sf" ]] && continue
  sf_status=$(jq -r '.status // empty' "$sf" 2>/dev/null || true)
  if [[ "$sf_status" == "active" ]]; then
    # Active workflow — do not advise
    exit 0
  fi
done
shopt -u nullglob

# --- Detection: Scan for completed arc checkpoints ---
FOUND_COMPLETED=false

shopt -s nullglob
for f in "${CWD}/${RUNE_STATE}/arc/"*/checkpoint.json; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && continue  # Symlink guard

  # Ownership check (fast-path skip for foreign sessions)
  f_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
  f_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)

  # Layer 1: config dir mismatch → different installation
  [[ -n "$f_cfg" && "$f_cfg" != "$RUNE_CURRENT_CFG" ]] && continue

  # Layer 2: PID mismatch + alive → different session (skip)
  if [[ -n "$f_pid" && "$f_pid" =~ ^[0-9]+$ && "$f_pid" != "$PPID" ]]; then
    rune_pid_alive "$f_pid" && continue
  fi

  # Check if any phase is still active (negative logic per EC-6)
  has_active=$(jq -e '.phases | to_entries | map(.value.status) | any(. == "in_progress" or . == "pending")' "$f" 2>/dev/null || echo "true")
  if [[ "$has_active" == "true" ]]; then
    # Arc still running — NO advisory
    exit 0
  fi

  # Sort by started_at (not mtime) per EC-1 — just need to find ANY completed
  FOUND_COMPLETED=true
done
shopt -u nullglob

# No completed arc found — nothing to advise about
if [[ "$FOUND_COMPLETED" != "true" ]]; then
  exit 0
fi

# --- Write debounce flag (atomic mktemp + mv per EC-H4) ---
TEMP_FLAG=$(mktemp "${TMPDIR:-/tmp}/rune-postcomp-XXXXXX" 2>/dev/null) || exit 0
jq -n --arg cfg "$RUNE_CURRENT_CFG" --arg pid "$PPID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{config_dir: $cfg, owner_pid: $pid, created_at: $ts}' > "$TEMP_FLAG" 2>/dev/null || exit 0
mv "$TEMP_FLAG" "$FLAG_FILE" 2>/dev/null || { rm -f "$TEMP_FLAG" 2>/dev/null; exit 0; }

# --- Read context usage from statusline bridge (same pattern as guard-context-critical.sh) ---
BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}.json"
USED_PCT="?"
if [[ -f "$BRIDGE_FILE" && ! -L "$BRIDGE_FILE" ]]; then
  # FLAW-015: jq '//' treats 0 as falsy. Use explicit null check to handle used_pct=0 correctly.
  USED_PCT=$(jq -r 'if .used_pct == null then "?" else (.used_pct | tostring) end' "$BRIDGE_FILE" 2>/dev/null || echo "?")
fi

# --- Context-aware advisory message (NEVER deny) ---
if [[ "$USED_PCT" =~ ^[0-9]+$ ]] && (( USED_PCT < 50 )); then
  MSG="Arc completed. Context at ${USED_PCT}% — room to continue working."
elif [[ "$USED_PCT" =~ ^[0-9]+$ ]] && (( USED_PCT < 70 )); then
  MSG="Arc completed. Context at ${USED_PCT}%. Consider /rune:rest to free artifacts."
elif [[ "$USED_PCT" =~ ^[0-9]+$ ]]; then
  MSG="Arc completed. Context at ${USED_PCT}% used. Recommend /rune:rest + fresh session."
else
  MSG="Arc completed. Run /rune:rest to free artifacts if starting new work."
fi

jq -n --arg msg "$MSG" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $msg}}' 2>/dev/null || true

exit 0
