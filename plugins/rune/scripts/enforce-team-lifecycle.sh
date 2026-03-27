#!/bin/bash
# scripts/enforce-team-lifecycle.sh
# TLC-001: Centralized team lifecycle guard for TeamCreate.
# Runs BEFORE every TeamCreate call. Validates team name, detects stale
# teams, auto-cleans filesystem orphans, and injects advisory context.
#
# DESIGN PRINCIPLES:
#   1. Advisory-only for stale detection (additionalContext, NOT deny)
#   2. Hard-block ONLY for invalid team names (shell injection prevention)
#   3. 30-minute stale threshold (avoids false positives in arc/concurrent)
#   4. rune-*/arc-* prefix filter (never touch foreign plugin teams)
#
# Hook events: PreToolUse:TeamCreate
# Timeout: 5s (fast-path guard)
# Exit 0: Allow (with optional JSON for additionalContext or deny)

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# ── Script directory for library sourcing ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh"

# --- DSEC-005: Cache trace log path before _rune_fail_forward ---
# Avoids $(id -u) subshell fork on every ERR trap invocation.
_RUNE_TRACE_PATH="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
case "$_RUNE_TRACE_PATH" in
  "${TMPDIR:-/tmp}/"*|/tmp/*) ;;
  *) _RUNE_TRACE_PATH="${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log" ;;
esac

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
# BACK-002: Always warn on stderr so crashes are observable in production.
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-?}"
  printf 'WARN: enforce-team-lifecycle.sh ERR trap at line %s — fail-forward activated\n' \
    "$_crash_line" >&2
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "$_RUNE_TRACE_PATH" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# ── GUARD 1: jq dependency ──
# SEC-3 FIX: When jq is missing, perform basic team name validation with pure bash
# instead of silently allowing all names. SDK also validates, so this is defense-in-depth.
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — enforce-team-lifecycle.sh using fallback validation" >&2
  # Best-effort: extract team_name from raw JSON input using grep/sed
  RAW_INPUT=$(head -c 1048576 2>/dev/null || true)
  RAW_NAME=$(printf '%s\n' "$RAW_INPUT" | grep -o '"team_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"team_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  if [[ -n "$RAW_NAME" ]] && [[ ! "$RAW_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "TLC-001: BLOCKED — invalid team name (jq-free fallback validation)" >&2
    # Output deny JSON manually (no jq available)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"TLC-001: Invalid team name (jq-free fallback). Names must match /^[a-zA-Z0-9_-]+$/."}}\n'
  fi
  exit 0
fi

# ── GUARD 2: Input size cap (SEC-2: 1MB DoS prevention) ──
INPUT=$(head -c 1048576 2>/dev/null || true)

# ── GUARD 3: Tool name match (fast path) ──
# SEC-5 NOTE: Exact string match here provides defense-in-depth against any
# SDK matcher ambiguity (hooks.json "TeamCreate" matcher is regex-based).
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "TeamCreate" ]]; then
  exit 0
fi

# ── GUARD 4: CWD canonicalization (QUAL-5) ──
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then exit 0; fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || {
  [[ "${RUNE_TRACE:-}" == "1" ]] && echo "TLC-001: CWD canonicalization failed for original CWD" >> "$_RUNE_TRACE_PATH" 2>/dev/null
  exit 0
}
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# ── EXTRACT: team_name from tool_input (single-pass jq) ──
TEAM_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || true)
# XBUG-002 FIX: Strip null bytes that could bypass regex validation (bash 3.2 edge case)
TEAM_NAME="${TEAM_NAME//$'\0'/}"
if [[ -z "$TEAM_NAME" ]]; then
  exit 0  # No team_name — let SDK handle the error
fi

# ── GATE 1: Team name validation (HARD BLOCK — D-5) ──
# This is the ONLY deny case. Invalid names can cause shell injection.
if [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ "$TEAM_NAME" == *".."* ]]; then
  # Sanitize team name for JSON output — strip chars that break JSON
  # SEC-002 FIX: Dash at end of tr charset to avoid ambiguous range interpretation
  # QUAL-012 FIX: Exclude '.' from sanitization charset — prevents '..' in error messages
  SAFE_NAME=$(printf '%s' "${TEAM_NAME:0:64}" | tr -cd 'a-zA-Z0-9 _-')
  # BACK-004 FIX: Fallback for empty SAFE_NAME (team name was ALL special chars)
  SAFE_NAME="${SAFE_NAME:-<invalid>}"
  # SEC-001 FIX: Use jq --arg for JSON-safe output instead of unquoted heredoc
  jq -n --arg name "$SAFE_NAME" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("TLC-001: Invalid team name \"" + $name + "\". Team names must match /^[a-zA-Z0-9_-]+$/ and must not contain \"..\"."),
      additionalContext: "BLOCKED by enforce-team-lifecycle.sh. Fix the team name to use only alphanumeric characters, hyphens, and underscores. Example: rune-review-abc123."
    }
  }'
  exit 0
fi

# ── GATE 2: Team name length (max 128 chars) ──
if [[ ${#TEAM_NAME} -gt 128 ]]; then
  # SEC-001 FIX: Use jq for JSON-safe output (consistency with GATE 1)
  jq -n --argjson len "${#TEAM_NAME}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("TLC-001: Team name exceeds 128 characters (" + ($len | tostring) + " chars)."),
      additionalContext: "BLOCKED by enforce-team-lifecycle.sh. Shorten the team name to 128 characters or fewer."
    }
  }'
  exit 0
fi

# ── EXTRACT: session_id from hook input (for session-scoped stale scan) ──
HOOK_SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
# SEC-004: Validate session_id format to prevent injection via crafted hook input
if [[ -n "$HOOK_SESSION_ID" ]] && [[ ! "$HOOK_SESSION_ID" =~ ^[a-zA-Z0-9_-]{1,128}$ ]]; then
  [[ "${RUNE_TRACE:-}" == "1" ]] && echo "TLC-001: Invalid session_id format — sanitizing to empty" >> "$_RUNE_TRACE_PATH" 2>/dev/null
  HOOK_SESSION_ID=""
fi

# ── STALE TEAM DETECTION (Advisory — D-1, D-2) ──
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# FIX-1: CHOME absoluteness guard (flaw-hunter EC-A5)
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  exit 0  # CHOME is invalid (not absolute), skip scan
fi

# XVER-001 FIX: Canonicalize CHOME and reject symlinked intermediate roots
# This prevents symlink-based path traversal attacks where an attacker could
# create $CHOME/teams -> /some/sensitive/path and cause rm -rf to follow it.
CHOME_CANONICAL="$(_resolve_path "$CHOME")"
if [[ -z "$CHOME_CANONICAL" ]] || [[ "$CHOME_CANONICAL" != /* ]]; then
  exit 0  # Canonical resolution failed, skip scan
fi

# Reject if teams or tasks directories are symlinks (intermediate root protection)
for _root_dir in "teams" "tasks"; do
  _target_path="${CHOME}/${_root_dir}"
  if [[ -L "$_target_path" ]]; then
    # Symlink detected at intermediate root — abort for safety
    printf 'WARN: TLC-001: Symlink detected at %s — rejecting for security\n' "$_target_path" >&2
    exit 0
  fi
  # If directory exists, verify its canonical path is under CHOME_CANONICAL
  if [[ -d "$_target_path" ]]; then
    _target_canonical="$(_resolve_path "$_target_path")"
    if [[ "$_target_canonical" != "$CHOME_CANONICAL"/${_root_dir}* ]]; then
      printf 'WARN: TLC-001: Path traversal detected at %s — rejecting for security\n' "$_target_path" >&2
      exit 0
    fi
  fi
done
unset _root_dir _target_path _target_canonical

# Find stale rune-*/arc-* team dirs older than 30 min (ORPHAN_STALE_THRESHOLD)
# BACK-004 NOTE: -mmin +30 checks directory mtime (updated on any file write inside),
# not creation time. An active team with FS activity stays fresh. A team idle >30 min
# (e.g., waiting on long LLM call) may be flagged — increase to -mmin +60 if observed.
# Using -mmin +30 for age check (fast, no jq needed per dir)
stale_teams=()
if [[ -d "$CHOME/teams/" ]]; then
  while IFS= read -r dir; do
    dirname=$(basename "$dir")
    # Validate dirname before adding (defense-in-depth)
    if [[ "$dirname" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ ! -L "$dir" ]]; then
      # Session scoping: check .session marker before treating as stale
      if [[ -n "$HOOK_SESSION_ID" ]] && [[ -f "$dir/.session" ]] && [[ ! -L "$dir/.session" ]]; then
        # .session marker exists — read owner session_id (SEC-001 FIX: parse JSON with jq)
        _marker_session=$(jq -r '.session_id // empty' "$dir/.session" 2>/dev/null || true)
        if [[ -n "$_marker_session" ]] && [[ "$_marker_session" != "$HOOK_SESSION_ID" ]]; then
          # Different session owns this team — skip it
          continue
        fi
      fi
      # No .session marker OR same session OR empty HOOK_SESSION_ID → count as stale for reporting.
      # Auto-cleanup eligibility is enforced separately in the cleanup loop below.
      stale_teams+=("$dirname")
    fi
  done < <(find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" -o -name "goldmask-*" \) -mmin +30 2>/dev/null)
fi

# If no stale teams found, allow TeamCreate silently
if [[ ${#stale_teams[@]} -eq 0 ]]; then
  exit 0
fi

# ── AUTO-CLEANUP: Remove stale filesystem dirs (D-3) ──
# NOTE: 30-min age is INFORMATIONAL ONLY for different-session teams (hardened v1.157.0).
# Auto-cleanup is restricted to own-session teams with verified .session ownership.
# BACK-005 NOTE: rm-rf removes dirs without SDK TeamDelete. This clears filesystem
# state but not SDK leadership. Advisory message tells Claude to run TeamDelete()
# if "Already leading" errors occur. SDK TeamDelete can't be called from a hook script.
cleaned_teams=()
for team in "${stale_teams[@]}"; do
  # Double-validate before rm-rf (defense-in-depth)
  # SEC-1 FIX: Re-check symlink immediately before rm-rf (collapses TOCTOU window from scan loop)
  # BACK-P3-012: Check for active state files referencing this team before cleanup
  if [[ "$team" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ "$team" != *".."* ]] && [[ ! -L "$CHOME/teams/${team}" ]]; then
    # Cross-session safety (hardened v1.157.0): only auto-clean own-session teams.
    # Rule: .session file MUST exist AND session_id MUST match current session.
    # Teams without .session may be in race window (TeamCreate → stamp-team-session.sh).
    _team_session_file="$CHOME/teams/${team}/.session"
    if [[ ! -f "$_team_session_file" ]] || [[ -L "$_team_session_file" ]]; then
      continue  # No .session → never auto-clean
    fi
    if [[ -n "$HOOK_SESSION_ID" ]]; then
      _team_marker_session=$(jq -r '.session_id // empty' "$_team_session_file" 2>/dev/null || true)
      if [[ -z "$_team_marker_session" ]] || [[ "$_team_marker_session" != "$HOOK_SESSION_ID" ]]; then
        continue  # Different session or unknown → never auto-clean
      fi
    else
      continue  # Can't verify session ownership without HOOK_SESSION_ID → skip cleanup
    fi
    unset _team_session_file _team_marker_session
    # Skip if an active state file references this team (cross-check with project state)
    _has_active_state=false
    if [[ -n "${CWD:-}" ]]; then
      # SEC-009 FIX: Ensure nullglob is active for glob expansion
      _nullglob_was_set=1
      shopt -q nullglob && _nullglob_was_set=0
      shopt -s nullglob 2>/dev/null || true
      for _sf in "${CWD}"/tmp/.rune-*.json; do
        [[ -f "$_sf" ]] || continue
        [[ -L "$_sf" ]] && continue
        _sf_team=$(jq -r '.team_name // empty' "$_sf" 2>/dev/null || true)
        _sf_status=$(jq -r '.status // empty' "$_sf" 2>/dev/null || true)
        if [[ "$_sf_team" == "$team" && "$_sf_status" == "active" ]]; then
          _has_active_state=true
          break
        fi
      done
    fi
    # SEC-009 FIX: Restore nullglob state (SEC-003: conditional instead of eval)
    [[ "$_nullglob_was_set" -eq 1 ]] && shopt -u nullglob
    unset _nullglob_was_set
    if [[ "$_has_active_state" == "false" ]]; then
      # XVER-003 FIX: TOCTOU verification before rm -rf
      # DSEC-004: A narrow TOCTOU race window exists between the scan (find -mmin +30)
      # and this cleanup point. A new TeamCreate could claim the dir name in between.
      # Defense-in-depth mitigations: (1) re-check mtime freshness below rejects dirs
      # that became active, (2) .session ownership is verified above, (3) symlink and
      # canonical path checks prevent traversal. Residual risk is accepted as negligible.
      # Re-check that the directory is still stale (mtime > 30 min) immediately before deletion
      # This closes the race window between the scan loop and the cleanup loop
      _team_dir="$CHOME/teams/${team}"
      _tasks_dir="$CHOME/tasks/${team}"
      _should_remove=true

      # Re-verify team dir is still stale if it exists
      if [[ -d "$_team_dir" ]] && [[ ! -L "$_team_dir" ]]; then
        # Re-check mtime using platform helper (30 min = 1800 seconds)
        _dir_mtime=$(_stat_mtime "$_team_dir")
        _now_epoch=$(date +%s 2>/dev/null || echo "0")
        if [[ -n "$_dir_mtime" ]] && [[ "$_now_epoch" != "0" ]]; then
          _age_secs=$(( _now_epoch - _dir_mtime ))
          # Reject removal if directory became fresh (< 30 min old)
          if [[ $_age_secs -lt 1800 ]]; then
            _should_remove=false
          fi
        fi
        # Re-verify canonical path is under CHOME_CANONICAL/teams
        _dir_canonical="$(_resolve_path "$_team_dir")"
        if [[ "$_dir_canonical" != "$CHOME_CANONICAL"/teams/* ]]; then
          _should_remove=false
        fi
      fi

      if [[ "$_should_remove" == "true" ]]; then
        rm -rf "$_team_dir/" "$_tasks_dir/" 2>/dev/null
        cleaned_teams+=("$team")
      fi
      unset _team_dir _tasks_dir _should_remove _dir_mtime _now_epoch _age_secs _dir_canonical
    fi
  fi
done

# ── ADVISORY CONTEXT: Tell Claude what was found and cleaned ──
# If stale teams exist but none were eligible for cleanup (all foreign/no .session),
# report as informational advisory and exit.
if [[ ${#cleaned_teams[@]} -eq 0 ]]; then
  jq -n --argjson count "${#stale_teams[@]}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("TLC-001 PRE-FLIGHT: Detected " + ($count | tostring) + " stale team dir(s) older than 30 min from other sessions or without session markers. Not auto-cleaned for cross-session safety. Run /rune:rest --heal to clean up if these are yours.")
    }
  }'
  exit 0
fi
# Build comma-separated list for JSON (truncate to first 5)
cleaned_list=""
count=0
for team in "${cleaned_teams[@]+"${cleaned_teams[@]}"}"; do
  if [[ $count -ge 5 ]]; then
    # EDGE-001/EDGE-006 FIX: Bounds check to prevent negative display
    _remaining=$(( ${#cleaned_teams[@]} - 5 ))
    [[ $_remaining -lt 0 ]] && _remaining=0
    cleaned_list="${cleaned_list}, ... and ${_remaining} more"
    break
  fi
  if [[ -n "$cleaned_list" ]]; then
    cleaned_list="${cleaned_list}, ${team}"
  else
    cleaned_list="${team}"
  fi
  # BACK-006 FIX: ((0++)) returns exit code 1 under set -e, killing the script
  count=$((count + 1))
done

# SEC-003 FIX: Use jq --arg/--argjson for JSON-safe output instead of unquoted heredoc
jq -n --argjson count "${#cleaned_teams[@]}" --arg list "$cleaned_list" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    additionalContext: ("TLC-001 PRE-FLIGHT: Found and cleaned " + ($count | tostring) + " orphaned team dir(s) older than 30 min: [" + $list + "]. Filesystem dirs removed. If you encounter an Already leading team error, the SDK leadership state may still be stale — run TeamDelete() to clear it before retrying TeamCreate.")
  }
}'
exit 0
