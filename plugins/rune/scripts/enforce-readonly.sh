#!/bin/bash
# scripts/enforce-readonly.sh
# SEC-001: Enforce read-only for review/audit Ashes at platform level.
# Blocks Write/Edit/Bash/NotebookEdit when a review/audit team is active
# and the caller is a subagent (not the team lead).
#
# Detection strategy (PreToolUse does NOT receive team_name):
#   1. Check transcript_path for /subagents/ — team leads are never blocked
#   2. Check for .readonly-active marker in review/audit signal directories
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
# Exit 2 = hook error, stderr fed to Claude (not used by this script).

set -euo pipefail
trap 'exit 2' ERR  # XVER-SEC-002 FIX: fail-closed from start for SECURITY hook
umask 077

# --- SECURITY hook (fail-closed from start, XVER-SEC-002) ---
# Initial trap is fail-closed (exit 2) to eliminate bypass window.
# Phase 2 (subagent detected): upgrades to detailed fail-closed handler.
# See CLAUDE.md "Hook Crash Classification" for the SECURITY vs OPERATIONAL distinction.
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Pre-flight: jq is required for JSON parsing.
# If missing, exit 2 (blocking) — deny rather than silently disable enforcement.
# This is a SECURITY-CRITICAL hook: failing open would bypass SEC-001 protection.
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found — enforce-readonly.sh requires jq. Install jq to enable SEC-001 protection." >&2
  exit 2
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read

# Fast path: if not a subagent, allow immediately.
# Team leads and direct user sessions have transcript paths at root level,
# not in the /subagents/ subdirectory.
# transcript_path: documented common field (all hook events). Subagent detection
# via /subagents/ path segment. If absent or format changes, check fails open.
# The .readonly-active marker provides the primary enforcement;
# this check determines WHO is subject to it (subagents only, not team leads).
TRANSCRIPT_PATH=$(printf '%s\n' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
if [[ -z "$TRANSCRIPT_PATH" ]] || [[ "$TRANSCRIPT_PATH" != */subagents/* ]]; then
  exit 0
fi

# ── Phase 2: Subagent detected — switch to fail-closed ──
# From this point, any crash should BLOCK the tool (exit 2) to enforce SEC-001.
_rune_fail_closed() {
  printf 'ERROR: %s: unexpected crash at line %s — blocking for safety (SEC-001)\n' \
    "${BASH_SOURCE[0]##*/}" "${BASH_LINENO[0]:-?}" >&2 2>/dev/null || true
  exit 2
}
trap '_rune_fail_closed' ERR

# Subagent detected — check if any review/audit team has a readonly marker.
# Detection differs from enforce-teams.sh: this script checks transcript_path
# (subagent vs team-lead) while enforce-teams checks tool_name (Agent/Task calls only).
# QUAL-5: Canonicalize CWD to resolve symlinks (matches on-task-completed.sh pattern)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

SIGNAL_BASE="${CWD}/tmp/.rune-signals"
if [[ ! -d "$SIGNAL_BASE" ]]; then
  exit 0
fi

# Scan for .readonly-active marker in review/audit signal directories.
# Only rune-review-*, arc-review-*, rune-audit-*, arc-audit-* teams create this marker.
# Work teams (rune-work-*) and mend teams (rune-mend-*) do NOT have this marker.
# NOTE: .readonly-active is created by the orchestrator in roundtable-circle Phase 2
# (see skills/roundtable-circle/SKILL.md "Forge Team" step 3). The review/audit command
# must write this marker BEFORE spawning Ashes for enforcement to take effect.
# SEC-4 FIX: nullglob prevents literal glob strings when no directories match
# Save/restore nullglob state (FLAW-007 fix)
_prev_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob")
shopt -s nullglob
for dir in "$SIGNAL_BASE"/rune-review-* "$SIGNAL_BASE"/arc-review-* \
           "$SIGNAL_BASE"/rune-audit-* "$SIGNAL_BASE"/arc-audit-* \
           "$SIGNAL_BASE"/rune-inspect-*; do
  # Validate directory name contains only safe characters
  [[ "$(basename "$dir")" =~ ^(rune|arc)-(review|audit|inspect)-[a-zA-Z0-9_-]+$ ]] || continue
  # DSEC-003 FIX: Reject symlinks to prevent TOCTOU race (attacker could symlink signal dir)
  [[ -L "$dir" ]] && continue
  [[ -L "${dir}/.readonly-active" ]] && continue
  if [[ -f "${dir}/.readonly-active" ]]; then
    # Active review/audit team found + caller is a subagent → deny
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"SEC-001: review/audit Ashes are read-only. Use Read, Glob, Grep only."}}'
    exit 0
  fi
done
# CLD-SEC-001: Restore nullglob without eval (safe pattern)
if [[ "$_prev_nullglob" == *"-s"* ]]; then shopt -s nullglob; else shopt -u nullglob; fi

# No active review/audit team with readonly marker — allow
exit 0
