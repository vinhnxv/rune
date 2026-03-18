#!/bin/bash
# scripts/lib/stop-hook-common.sh
# Shared guard library for Stop hook loop drivers (arc-batch, arc-hierarchy, arc-issues).
#
# USAGE: Source this file AFTER set -euo pipefail and trap declarations.
#   source "${SCRIPT_DIR}/lib/stop-hook-common.sh"
#
# This library implements Guards 1-3 (common input guards) plus shared helper functions:
#   parse_input()                — Guard 2: read stdin with 1MB cap, sets INPUT
#   resolve_cwd()                — Guard 3: extract and canonicalize CWD from INPUT, sets CWD
#   check_state_file()           — Guard 4: state file existence check
#   reject_symlink()             — Guard 5: symlink rejection on state file
#   parse_frontmatter()          — Parse YAML frontmatter from state file, sets FRONTMATTER
#   get_field()                  — Extract field from FRONTMATTER
#   validate_session_ownership()        — Guards 5.7/10: config_dir + owner_pid isolation check (with orphan cleanup)
#   validate_session_ownership_strict() — Guards 5.7/10: strict isolation (no orphan cleanup, returns 1 on mismatch)
#   _iso_to_epoch()              — Cross-platform ISO-8601 to Unix epoch (macOS + Linux)
#   _check_context_critical()    — Check context level via statusline bridge (GUARD 11)
#   validate_paths()             — Path traversal + metachar rejection for relative file paths
#
# EXPORTED VARIABLES (set by functions):
#   INPUT          — raw stdin (1MB cap)
#   CWD            — canonicalized working directory (absolute path)
#   FRONTMATTER    — YAML frontmatter content (between first --- ... ---)
#   RUNE_CURRENT_CFG — resolved CLAUDE_CONFIG_DIR (set by resolve-session-identity.sh)
#
# EXIT BEHAVIOR:
#   All guard functions call `exit 0` on failure (fail-open — allow stop, do not block).
#   Callers should NOT have `set -e` active when calling guards that may clean up and exit.
#   (The `trap 'exit 0' ERR` in callers handles unexpected failures.)
#
# DEPENDENCIES: jq (Guard 1 check must be in caller before sourcing)

source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"
# Source rune-state if not already loaded
[[ -n "${RUNE_STATE:-}" ]] || source "$(dirname "${BASH_SOURCE[0]}")/rune-state.sh"

# ── GUARD 1: jq dependency ──
# NOTE: Callers must check for jq BEFORE sourcing this library, because `source` itself
# may call functions. Standard pattern:
#   if ! command -v jq &>/dev/null; then exit 0; fi

# ── parse_input(): Guard 2 — stdin read with 1MB DoS cap ──
# Sets: INPUT
parse_input() {
  INPUT=$(head -c 1048576 2>/dev/null || true)
}

# ── resolve_cwd(): Guard 3 — CWD extraction and canonicalization ──
# Sets: CWD
# Exits 0 if CWD is empty (after fallback), non-absolute, or unresolvable.
# BUG FIX (v1.144.12, fixed in Claude Code ~2.1.50): Added CLAUDE_PROJECT_DIR fallback.
# Previously exited silently when .cwd was missing from Stop hook input, while
# detect-workflow-complete.sh (which works correctly) had this fallback. Parity fix.
resolve_cwd() {
  local _raw_cwd
  _raw_cwd=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  CWD="$_raw_cwd"
  if [[ -z "$CWD" ]]; then
    CWD="${CLAUDE_PROJECT_DIR:-}"
  fi
  if [[ -z "$CWD" ]]; then
    exit 0
  fi
  CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
  if [[ -z "$CWD" || "$CWD" != /* ]]; then
    exit 0
  fi
  # WORKTREE-FIX: If CWD came from CLAUDE_PROJECT_DIR (not .cwd), and we can
  # detect a worktree, prefer the worktree path. This handles Stop hooks
  # where .cwd may be absent in older Claude Code versions.
  if [[ -z "$_raw_cwd" ]]; then
    local actual_cwd
    actual_cwd="$(pwd -P)"
    # Check .rune/ first, then .claude/ fallback (RUNE_LEGACY_SUPPORT_UNTIL=3.0.0)
    if [[ -f "$actual_cwd/.git" ]]; then
      if [[ -f "$actual_cwd/.rune/.rune-worktree-source" && ! -L "$actual_cwd/.rune/.rune-worktree-source" ]] \
        || [[ -f "$actual_cwd/.claude/.rune-worktree-source" && ! -L "$actual_cwd/.claude/.rune-worktree-source" ]]; then
        CWD="$actual_cwd"
      fi
    fi
  fi
}

# ── check_state_file(): Guard 4 — state file existence ──
# Args: $1 = state file path (absolute)
# Exits 0 if state file does not exist.
check_state_file() {
  local state_file="$1"
  if [[ ! -f "$state_file" ]]; then
    exit 0
  fi
}

# ── reject_symlink(): Guard 5 — symlink rejection ──
# Args: $1 = state file path (absolute)
# Exits 0 (after cleanup) if state file is a symlink.
reject_symlink() {
  local state_file="$1"
  if [[ -L "$state_file" ]]; then
    rm -f "$state_file" 2>/dev/null
    exit 0
  fi
}

# ── parse_frontmatter(): Parse YAML frontmatter from state file ──
# Args: $1 = state file path (absolute)
# Sets: FRONTMATTER
# Exits 0 (after cleanup) if frontmatter is empty (corrupted state file).
parse_frontmatter() {
  local state_file="$1"
  FRONTMATTER=$(sed -n '/^---$/,/^---$/p' "$state_file" 2>/dev/null | sed '1d;$d')
  if [[ -z "$FRONTMATTER" ]]; then
    # Corrupted state file — fail-safe: remove and allow stop
    rm -f "$state_file" 2>/dev/null
    exit 0
  fi
}

# ── get_field(): Extract named field from FRONTMATTER ──
# Args: $1 = field name (must match ^[a-z_]+$)
# Returns: field value (stripped of surrounding quotes), or empty string
# SEC-2: Validates field name to prevent regex metachar injection via grep/sed.
get_field() {
  local field="$1"
  [[ "$field" =~ ^[a-z_]+$ ]] || return 1
  # BACK-B4-004 FIX: `|| true` prevents grep exit code 1 (no match) from propagating
  # through pipefail → set -e → ERR trap → script exit. Missing fields return empty string.
  echo "$FRONTMATTER" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true
}

# ── _validate_session_ownership_core(): Shared session isolation logic ──
# Internal core for validate_session_ownership() and validate_session_ownership_strict().
# DO NOT call directly — use the public wrappers.
#
# Args:
#   $1 = mode: "normal" (exits on mismatch, cleans orphans) or "strict" (returns 1, no cleanup)
#   $2 = state file path (absolute)
#   $3 = progress file path (relative to CWD), may be empty (normal mode only)
#   $4 = orphan handler mode: "batch" or "skip" (normal mode only)
# Sources: resolve-session-identity.sh (sets RUNE_CURRENT_CFG)
# Normal mode: exits 0 on mismatch/orphan (fail-open). Strict mode: returns 1 on mismatch.
_validate_session_ownership_core() {
  local mode="$1"
  local state_file="$2"
  local progress_file="${3:-}"
  local orphan_mode="${4:-skip}"

  # Parameterized trace prefix per mode (QUAL-002)
  local _tp="ownership"
  [[ "$mode" == "strict" ]] && _tp="ownership-strict"

  # Ownership bypass: RUNE_SKIP_OWNERSHIP defaults to "0" (ownership checks enabled).
  # Set RUNE_SKIP_OWNERSHIP=1 in settings.local.json env to bypass ownership checks.
  # Ownership checks were previously unreliable due to PPID/session_id mismatch between
  # Bash tool context and hook subprocess context (see v1.144.16 notes), now fixed.
  if [[ "${RUNE_SKIP_OWNERSHIP:-0}" == "1" ]]; then
    if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
      _trace "${_tp}: BYPASSED (RUNE_SKIP_OWNERSHIP=1)"
    fi
    return 0
  fi

  # Source session identity resolver (idempotent — checks RUNE_CURRENT_CFG)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=../resolve-session-identity.sh
  source "${script_dir}/../resolve-session-identity.sh"

  local stored_config_dir stored_pid stored_session_id
  stored_config_dir=$(get_field "config_dir")
  stored_pid=$(get_field "owner_pid")
  stored_session_id=$(get_field "session_id")

  # Extract session_id from hook input JSON (injected by Claude Code — always reliable)
  # DSEC-001: Sanitize hook_session_id before use in sed substitution to prevent injection.
  local hook_session_id=""
  if [[ -n "${INPUT:-}" ]]; then
    hook_session_id=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  fi
  # Validate: alphanumeric, hyphens, underscores only, max 128 chars. Reject invalid values.
  if [[ -n "$hook_session_id" ]] && ! [[ "$hook_session_id" =~ ^[a-zA-Z0-9_-]{1,128}$ ]]; then
    hook_session_id=""
  fi

  # Trace: log ownership check details for debugging (uses caller's _trace if available)
  if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
    _trace "${_tp}: stored_cfg='${stored_config_dir}' RUNE_CURRENT_CFG='${RUNE_CURRENT_CFG}'"
    _trace "${_tp}: stored_sid='${stored_session_id}' hook_sid='${hook_session_id}' stored_pid='${stored_pid}' PPID='${PPID}'"
  fi

  # Mode-specific rejection helper: normal mode exits 0, strict mode returns 1.
  # shellcheck disable=SC2317
  _ownership_reject() {
    if [[ "$mode" == "strict" ]]; then return 1; else exit 0; fi
  }

  # Layer 1: Config-dir isolation (different Claude Code installations)
  if [[ -n "$stored_config_dir" && "$stored_config_dir" != "$RUNE_CURRENT_CFG" ]]; then
    if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
      _trace "${_tp}: REJECTED — config_dir mismatch"
    fi
    _ownership_reject; return $?
  fi

  # Layer 2: Session isolation (same config dir, different session)
  # BUG FIX (v1.144.16): $PPID in hook context differs from $PPID in Bash tool context
  # because Claude Code spawns hooks via a hook runner subprocess. Use session_id from
  # hook input JSON instead — it's always consistent with the session that wrote the state file.
  #
  # Priority: session_id (reliable) > owner_pid (unreliable in hooks)
  # Fallback to PID check only when session_id is unavailable in BOTH state file and hook input.
  #
  # "Claim on first touch" (VEIL-002: defensive fallback for session_id bootstrapping):
  # CLAUDE_SESSION_ID is not available in Bash tool context, so the skill writes
  # session_id: unknown. On the first Stop hook execution, we claim ownership by writing
  # the hook's session_id into the state file. This is safe because:
  # 1. The state file is created by the skill in the SAME session
  # 2. The first Stop hook fires in the SAME session (immediately after the skill's turn)
  # 3. Config-dir isolation (Layer 1) already passed at this point
  # This path is a defensive fallback — if Claude Code ever makes CLAUDE_SESSION_ID
  # available in Bash tool context, this code becomes unreachable but harmless.
  #
  # GUARD: Process tree verification (v1.152.1 — cross-session claiming prevention)
  # When session_id is "unknown", ANY session's Stop hook could fire first.
  # Verify this hook belongs to the same Claude Code session that created the state file
  # by walking the process tree: hook script → hook runner → Claude Code session PID.
  # If the hook's ancestor chain does NOT include stored_pid, this is a DIFFERENT session.
  if [[ -n "$hook_session_id" && ( -z "$stored_session_id" || "$stored_session_id" == "unknown" ) ]]; then
    # Process tree guard: verify hook is descendant of the owning session
    if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ ]]; then
      local _ancestor="$PPID" _is_descendant=false
      # VEIL-001: Walk up to 4 levels of the process tree. Observed chain depth as of
      # Claude Code 2.1.63: hook script (bash) → hook runner (node) → node worker → Claude Code
      # session PID. 4 is sufficient for current architecture; increase if Claude Code adds
      # intermediate processes (e.g., sandbox wrappers).
      local _walk
      for _walk in 1 2 3 4; do
        _ancestor=$(ps -o ppid= -p "$_ancestor" 2>/dev/null | tr -d ' ')
        [[ -n "$_ancestor" && "$_ancestor" =~ ^[0-9]+$ ]] || break
        [[ "$_ancestor" == "1" || "$_ancestor" == "0" ]] && break  # hit init/launchd
        if [[ "$_ancestor" == "$stored_pid" ]]; then
          _is_descendant=true
          break
        fi
      done
      if [[ "$_is_descendant" != "true" ]]; then
        # Hook is NOT a descendant of stored_pid → different session → reject claim
        if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
          _trace "${_tp}: claim-on-first-touch REJECTED — hook not descendant of stored_pid=${stored_pid} (last ancestor=${_ancestor})"
        fi
        _ownership_reject; return $?
      fi
    else
      # R1-010 FIX: No valid stored_pid — cannot verify process ancestry, reject claim
      if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
        _trace "${_tp}: claim-on-first-touch REJECTED — no valid stored_pid for ancestry verification"
      fi
      _ownership_reject; return $?
    fi
    if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
      _trace "${_tp}: claim-on-first-touch — writing hook_sid='${hook_session_id}' owner_pid='${PPID}' to state file"
    fi
    # Write session_id AND owner_pid into state file YAML frontmatter (atomic write)
    # BUG FIX (v1.156.0): Previously only updated session_id, leaving owner_pid stale.
    # This caused session-team-hygiene.sh to misdetect active arcs as orphaned (dead PID).
    # R1-001 FIX: Only update in-memory state after successful atomic write
    local _tmp_state _claim_write_ok=false
    _tmp_state=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || true
    if [[ -n "$_tmp_state" ]]; then
      if sed -e "s/^session_id:.*/session_id: ${hook_session_id}/" \
             -e "s/^owner_pid:.*/owner_pid: ${PPID}/" \
             "$state_file" > "$_tmp_state" 2>/dev/null && \
         mv -f "$_tmp_state" "$state_file" 2>/dev/null; then
        _claim_write_ok=true
      else
        rm -f "$_tmp_state" 2>/dev/null
      fi
    fi
    if [[ "$_claim_write_ok" == "true" ]]; then
      stored_session_id="$hook_session_id"
      stored_pid="$PPID"
    else
      # Disk write failed — reject claim to prevent in-memory/disk divergence
      if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
        _trace "${_tp}: claim-on-first-touch REJECTED — atomic write failed"
      fi
      _ownership_reject; return $?
    fi
  fi

  local _session_match=""
  if [[ -n "$stored_session_id" && "$stored_session_id" != "unknown" && -n "$hook_session_id" ]]; then
    # Both session IDs available — use session_id comparison (reliable)
    if [[ "$stored_session_id" == "$hook_session_id" ]]; then
      _session_match="yes"
    else
      _session_match="no"
    fi
    if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
      _trace "${_tp}: session_id comparison — match=${_session_match}"
    fi
  fi

  if [[ "$_session_match" == "yes" ]]; then
    # Same session — proceed, but update owner_pid if stale (e.g., claude --resume creates
    # a new process with a different PID but the same session_id).
    # BUG FIX (v1.156.0): Previously returned immediately without updating owner_pid,
    # leaving it pointing to a dead PID. This caused session-team-hygiene.sh to
    # misdetect active arcs as orphaned and other PID-based checks to use stale data.
    if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
      if ! rune_pid_alive "$stored_pid"; then
        local _tmp_state
        _tmp_state=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || true
        if [[ -n "$_tmp_state" ]]; then
          sed "s/^owner_pid:.*/owner_pid: ${PPID}/" "$state_file" > "$_tmp_state" 2>/dev/null && \
            mv -f "$_tmp_state" "$state_file" 2>/dev/null || rm -f "$_tmp_state" 2>/dev/null
        fi
        if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
          _trace "${_tp}: session_id match — updated stale owner_pid ${stored_pid} → ${PPID}"
        fi
      fi
    fi
    return 0
  elif [[ "$_session_match" == "no" ]]; then
    if [[ "$mode" == "normal" ]]; then
      # Different session — check if owner is still alive for orphan handling
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ ]]; then
        if rune_pid_alive "$stored_pid"; then
          if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
            _trace "${_tp}: REJECTED — different session_id, owner alive (pid=${stored_pid})"
          fi
          exit 0
        fi
        # Owner dead — fall through to orphan handling below
      else
        # R1-002 FIX: No valid PID to verify owner death — cannot confirm orphan, fail-safe: reject
        if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
          _trace "${_tp}: REJECTED — different session_id, no valid stored_pid to verify orphan (fail-safe)"
        fi
        exit 0
      fi
    else
      # Strict mode: just reject, no orphan cleanup
      if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
        _trace "${_tp}: REJECTED — different session_id (no orphan cleanup)"
      fi
      return 1
    fi
  fi

  # Fallback: PID-based check (when session_id unavailable — legacy state files)
  if [[ -z "$_session_match" && -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ ]]; then
    if [[ "$stored_pid" != "$PPID" ]]; then
      if [[ "$mode" == "normal" ]]; then
        local _pid_alive=false
        if rune_pid_alive "$stored_pid"; then
          _pid_alive=true
        fi
        if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
          _trace "${_tp}: PID fallback — stored=${stored_pid} hook_PPID=${PPID} owner_alive=${_pid_alive}"
        fi
        if [[ "$_pid_alive" == "true" ]]; then
          exit 0
        fi
        # Owner died — fall through to orphan handling
      else
        # BACK-006: Only compute _pid_alive when trace is active (avoid unnecessary work)
        if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
          local _pid_alive=false
          rune_pid_alive "$stored_pid" && _pid_alive=true
          _trace "${_tp}: PID fallback — stored=${stored_pid} hook_PPID=${PPID} owner_alive=${_pid_alive}"
        fi
        # Strict mode: reject on any PID mismatch (no orphan cleanup)
        return 1
      fi
    else
      # PID matches — same session
      return 0
    fi
  fi

  # Normal mode orphan handling: clean up dead owner's state
  if [[ "$mode" == "normal" ]]; then
    if [[ "$_session_match" == "no" ]] || [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
      # DSEC-003: Validate progress_file path before constructing filesystem paths
      if [[ "$orphan_mode" == "batch" && -n "$progress_file" ]]; then
        if [[ "$progress_file" == *".."* ]] || [[ "$progress_file" == /* ]] || [[ "$progress_file" =~ [^a-zA-Z0-9._/-] ]]; then
          if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
            _trace "${_tp}: orphan cleanup — progress_file path rejected (traversal/metachar)"
          fi
        elif [[ -f "${CWD}/${progress_file}" ]]; then
          local orphan_progress
          orphan_progress=$(jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            (.plans[] | select(.status == "in_progress")) |= (
              .status = "failed" |
              .failed_at = $ts |
              .failure_reason = "orphaned: owner session died"
            )
          ' "${CWD}/${progress_file}" 2>/dev/null || true)
          if [[ -n "$orphan_progress" ]]; then
            local tmpfile
            tmpfile=$(mktemp "${CWD}/${progress_file}.XXXXXX" 2>/dev/null) || true
            if [[ -n "$tmpfile" ]]; then
              printf '%s\n' "$orphan_progress" > "$tmpfile" && mv -f "$tmpfile" "${CWD}/${progress_file}" 2>/dev/null || rm -f "$tmpfile" 2>/dev/null
            fi
          fi
        fi
      fi
      rm -f "$state_file" 2>/dev/null
      if [[ "${RUNE_TRACE:-}" == "1" ]] && declare -f _trace &>/dev/null; then
        _trace "${_tp}: orphan cleanup — removed state file"
      fi
      exit 0
    fi
  fi

  # No stored PID and no session_id match — accept (legacy/minimal state files)
  return 0
}

# ── validate_session_ownership(): Guards 5.7/10 — session isolation ──
# Args:
#   $1 = state file path (absolute) — used for cleanup on orphan detection
#   $2 = progress file path (relative to CWD), may be empty
#   $3 = orphan handler mode: "batch" (update plans[]) or "skip" (just remove state)
# Sources: resolve-session-identity.sh (sets RUNE_CURRENT_CFG)
# Exits 0 if: config_dir mismatch (different installation) or
#             PID alive and different (different session).
# Cleans up and exits 0 if: owner PID is dead (orphan).
validate_session_ownership() {
  _validate_session_ownership_core "normal" "$1" "${2:-}" "${3:-skip}"
}

# ── validate_session_ownership_strict(): Strict session isolation (no orphan cleanup) ──
# Like validate_session_ownership but does NOT clean up orphans.
# Designed for arc-phase-stop-hook.sh where orphan cleanup is dangerous
# (could destroy another session's active work).
#
# Args:
#   $1 = state file path (absolute) — used for claim-on-first-touch updates only
# Sources: resolve-session-identity.sh (sets RUNE_CURRENT_CFG)
# Returns: 0 if ownership confirmed, 1 if mismatch (caller should exit 0).
# NEVER calls exit — always returns to caller.
# NEVER deletes state files or modifies progress files.
# NOTE: Legacy state files (pre-v1.144.16) may lack session_id — these fall through
# to PID-based ownership check which returns 1 on any mismatch (no orphan recovery).
validate_session_ownership_strict() {
  _validate_session_ownership_core "strict" "$1"
}

# ── _find_arc_checkpoint(): Find the most recent arc checkpoint for current session ──
# Searches ${CWD}/.rune/arc/*/checkpoint.json, ${CWD}/.claude/arc/*/checkpoint.json (legacy),
# AND ${CWD}/tmp/arc/*/checkpoint.json for the newest checkpoint belonging to the current
# session (owner_pid matches $PPID).
#
# BUG FIX (v1.108.2): After session compaction, the arc pipeline may resume and
# write its checkpoint to tmp/arc/ instead of .rune/arc/. Searching only .rune/arc/
# would find a stale pre-compaction checkpoint (e.g., ship=pending) while the actual
# completed checkpoint lives at tmp/arc/ (ship=completed, PR merged). This caused
# arc-batch to misdetect successful arcs as "failed" and break the batch chain.
#
# Args: none (uses CWD and PPID globals)
# Returns: absolute path to checkpoint.json on stdout, or empty string if not found.
# Exit code: 0 if found, 1 if not found.
_find_arc_checkpoint() {
  local newest="" newest_mtime=0

  # Search .rune/arc/ (primary), .claude/arc/ (legacy fallback), and tmp/arc/ (post-compaction).
  local ckpt_dir
  for ckpt_dir in "${CWD}/${RUNE_STATE}/arc" "${CWD}/.claude/arc" "${CWD}/tmp/arc"; do
    [[ -d "$ckpt_dir" ]] || continue

    # PERF FIX (v1.108.1): Use grep for fast PID matching instead of jq per file.
    # With 100+ checkpoint dirs, individual jq calls exceeded the 15s hook timeout,
    # causing the stop hook to silently exit and breaking the batch loop.
    # grep is ~100x faster than jq for simple string matching.
    #
    # Scan only the 20 most recently modified files per location to bound worst-case time.
    local candidates
    candidates=$(ls -dt "$ckpt_dir"/*/checkpoint.json 2>/dev/null | head -20) || true
    [[ -n "$candidates" ]] || continue

    while IFS= read -r f; do
      [[ -f "$f" ]] && [[ ! -L "$f" ]] || continue
      # Session isolation: prefer session_id match (reliable in hooks), fallback to owner_pid
      # BUG FIX (v1.144.16): $PPID in hooks differs from $PPID in Bash tool.
      local _ckpt_matched=false
      # Try session_id first (from hook input JSON — set by caller or extracted from INPUT)
      if [[ -n "${HOOK_SESSION_ID:-}" ]]; then
        if grep -q "\"session_id\"[[:space:]]*:[[:space:]]*\"${HOOK_SESSION_ID:-}\"" "$f" 2>/dev/null; then
          _ckpt_matched=true
        fi
      fi
      # Fallback to owner_pid (works when session_id unavailable)
      if [[ "$_ckpt_matched" != "true" ]]; then
        if ! grep -q "\"owner_pid\"[[:space:]]*:[[:space:]]*\"${PPID}\"" "$f" 2>/dev/null; then
          grep -qE "\"owner_pid\"[[:space:]]*:[[:space:]]*${PPID}([^0-9]|$)" "$f" 2>/dev/null || continue
        fi
      fi
      # Get mtime via cross-platform helper
      local mtime
      mtime=$(_stat_mtime "$f"); [[ -n "$mtime" ]] || continue
      if [[ "$mtime" -gt "$newest_mtime" ]]; then
        newest_mtime="$mtime"
        newest="$f"
      fi
    done <<< "$candidates"
  done

  if [[ -n "$newest" ]]; then
    echo "$newest"
    return 0
  fi
  return 1
}

# ── _iso_to_epoch(): Cross-platform ISO-8601 to Unix epoch (macOS + Linux) ──
# Args: $1 = ISO-8601 timestamp (must match YYYY-MM-DDTHH:MM:SSZ exactly)
# Returns: epoch seconds via stdout, exit 1 on failure.
# SEC-GUARD10: Validates format to prevent shell injection via crafted timestamps.
# Delegates to _parse_iso_epoch from lib/platform.sh for cross-platform date parsing.
_iso_to_epoch() {
  local ts="$1"
  # Strip optional fractional seconds (.NNN) before terminal Z
  if [[ "$ts" =~ \.[0-9]+Z$ ]]; then
    ts="${ts%%.*}Z"
  fi
  # Validate strict format: YYYY-MM-DDTHH:MM:SSZ (no other chars allowed)
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  local result
  result=$(_parse_iso_epoch "$ts")
  # R1-009 FIX: Use empty-string check — "0" is valid (Unix epoch 0 = 1970-01-01T00:00:00Z)
  [[ -n "$result" ]] && echo "$result" && return 0
  return 1
}

# ── _check_context_at_threshold(): Parameterized context threshold check ──
# Reads the statusline bridge file to determine remaining context percentage.
# Args: $1 = threshold (integer, 0-100). Returns 0 when remaining% <= threshold.
# Fail-open: returns 1 on any error (missing file, stale data, parse failure).
# Callers: _check_context_critical (25%), _check_context_compact_needed (50%).
_check_context_at_threshold() {
  local threshold="${1:-25}"
  [[ "$threshold" =~ ^[0-9]+$ ]] || return 1

  local session_id
  session_id=$(echo "${INPUT:-}" | jq -r '.session_id // empty' 2>/dev/null || true)
  [[ -n "$session_id" && "$session_id" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1

  local bridge_file="${TMPDIR:-/tmp}/rune-ctx-${session_id}.json"
  [[ -f "$bridge_file" && ! -L "$bridge_file" ]] || return 1

  # UID ownership check (prevent reading other users' bridge files)
  local bridge_uid=""
  bridge_uid=$(_stat_uid "$bridge_file")
  [[ -n "$bridge_uid" && "$bridge_uid" != "$(id -u)" ]] && return 1

  # Freshness check (180s — more lenient than PreToolUse's 30s because
  # Stop hooks fire after Claude responds and may chain through multiple hooks.
  # In phase-isolated arc, the statusline updates after each phase turn, but
  # by the time the batch hook fires after the phase completion + summary turn,
  # the bridge file can be 60-120s old. 180s provides safe margin.)
  local file_mtime now age
  file_mtime=$(_stat_mtime "$bridge_file"); file_mtime="${file_mtime:-0}"
  now=$(date +%s)
  age=$(( now - file_mtime ))
  [[ "$age" -ge 0 && "$age" -lt 180 ]] || return 1

  # Parse remaining percentage
  local rem_int
  rem_int=$(jq -r '(.remaining_percentage // -1) | floor | tostring' "$bridge_file" 2>/dev/null || echo "-1")
  [[ "$rem_int" =~ ^[0-9]+$ ]] || return 1
  [[ "$rem_int" -le 100 ]] || return 1

  [[ "$rem_int" -le "$threshold" ]] && return 0
  return 1
}

# ── _check_context_critical(): Check if context is at critical level (GUARD 11) ──
# Returns: 0 if context is critical (<= 25% remaining), 1 if OK or unknown.
# Used by GUARD 10 extension in Stop hooks to prevent prompt injection at critical context.
_check_context_critical() {
  _check_context_at_threshold 25
}

# ── _check_context_compact_needed(): Check if context needs compaction ──
# Returns: 0 if context remaining <= 50% (compaction beneficial), 1 if OK or unknown.
# Used by arc-phase-stop-hook.sh adaptive compact interlude to trigger compaction
# based on actual context pressure rather than only before heavy phases.
# Fail-open: returns 1 when bridge file is unavailable (caller should use fallback).
_check_context_compact_needed() {
  _check_context_at_threshold 50
}

# ── _read_arc_result_signal(): Read explicit arc result signal (v1.109.2) ──
# Primary arc completion detection method. Arc writes tmp/arc-result-current.json
# at a deterministic path after each pipeline run. This decouples stop hooks from
# checkpoint internals (location, field names, nesting).
#
# Args: none (uses CWD and PPID globals)
# Sets: ARC_SIGNAL_STATUS ("completed"|"partial"), ARC_SIGNAL_PR_URL ("none"|url),
#        ARC_SIGNAL_ARC_ID (arc session ID from signal, or "" if unavailable)
# Returns: 0 if valid signal found for this session, 1 if not found/stale/wrong-session.
# BACK-008: Only "completed" and "partial" are accepted (SEC-005 allowlist). Any other
# status (including manually-crafted "failed") causes return 1, forcing callers to
# fall back to _find_arc_checkpoint(). This is intentional — signal should only represent
# positive completion evidence. Callers should NOT check ARC_SIGNAL_STATUS independently
# of the return code; return 0 guarantees a valid, allowlisted status.
# Fail-open: returns 1 on any error — callers fall back to _find_arc_checkpoint().
_read_arc_result_signal() {
  ARC_SIGNAL_STATUS=""
  ARC_SIGNAL_PR_URL=""
  ARC_SIGNAL_ARC_ID=""

  local signal_file="${CWD}/tmp/arc-result-current.json"
  [[ -f "$signal_file" ]] && [[ ! -L "$signal_file" ]] || return 1

  # BACK-003: Single jq call extracts all 6 fields at once (tab-separated)
  # Fields: schema_version, owner_pid, config_dir, status, pr_url, arc_id
  local jq_out
  jq_out=$(jq -r '[(.schema_version // "" | tostring), (.owner_pid // ""), (.config_dir // ""), (.status // ""), (.pr_url // "none"), (.arc_id // "")] | join("\t")' "$signal_file" 2>/dev/null) || return 1

  local signal_schema signal_pid signal_config signal_status signal_pr_url signal_arc_id
  IFS=$'\t' read -r signal_schema signal_pid signal_config signal_status signal_pr_url signal_arc_id <<< "$jq_out"

  # QUAL-001-SCHEMA: Validate schema version (forward-compat guard)
  [[ "$signal_schema" == "1" ]] || return 1

  # SEC-010: Numeric PID validation (parity with validate_session_ownership)
  [[ -n "$signal_pid" && "$signal_pid" =~ ^[0-9]+$ ]] || return 1
  # Session isolation: prefer session_id match (reliable in hooks), fallback to owner_pid
  # BUG FIX (v1.144.16): $PPID in hooks differs from $PPID in Bash tool.
  local signal_session_id
  signal_session_id=$(jq -r '.session_id // empty' "$signal_file" 2>/dev/null || true)
  if [[ -n "${HOOK_SESSION_ID:-}" && -n "$signal_session_id" ]]; then
    [[ "$signal_session_id" == "${HOOK_SESSION_ID:-}" ]] || return 1
  else
    [[ "$signal_pid" == "$PPID" ]] || return 1
  fi

  # Config-dir isolation: verify same Claude Code installation
  if [[ -n "${RUNE_CURRENT_CFG:-}" && -n "$signal_config" && "$signal_config" != "$RUNE_CURRENT_CFG" ]]; then
    return 1
  fi

  # SEC-005: Allowlist validation — only accept known status values
  case "$signal_status" in
    completed|partial) ;;
    *) return 1 ;;
  esac

  ARC_SIGNAL_STATUS="$signal_status"
  ARC_SIGNAL_PR_URL="$signal_pr_url"
  ARC_SIGNAL_ARC_ID="$signal_arc_id"
  # Belt-and-suspenders: handles edge case where pr_url is the literal string "null"
  [[ "$ARC_SIGNAL_PR_URL" == "null" ]] && ARC_SIGNAL_PR_URL="none"

  # BACK-003: Validate PR URL format (defense-in-depth, parity with consumer regex)
  if [[ "$ARC_SIGNAL_PR_URL" != "none" ]]; then
    [[ "$ARC_SIGNAL_PR_URL" =~ ^https://[a-zA-Z0-9._/-]+$ ]] || ARC_SIGNAL_PR_URL="none"
  fi

  return 0
}

# ── _rune_detect_rate_limit(): Check for rate limit in recent context ──
# Reads talisman arc shard for config, then checks transcript tail for rate limit patterns.
# Returns: 0 if rate limit detected (wait seconds printed to stdout), 1 if no rate limit.
# Fail-open: returns 1 on any read/parse error — callers proceed normally.
#
# Args:
#   $1 = session_id (validated: alphanumeric/hyphens/underscores)
#   $2 = cwd (absolute path to project root)
# Integration: Called by arc-phase-stop-hook.sh and arc-batch-stop-hook.sh BEFORE
# constructing the re-injection prompt. If rate limit detected, prepend wait instruction.
_rune_detect_rate_limit() {
  local session_id="$1"
  local cwd="$2"

  # Guard: require non-empty validated inputs
  [[ -n "$session_id" && "$session_id" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  [[ -n "$cwd" && "$cwd" == /* ]] || return 1

  # Talisman config defaults
  local default_wait=60
  local max_wait=300
  # Resolve talisman shard (project → system fallback)
  local talisman_shard=""
  if type _rune_resolve_talisman_shard &>/dev/null; then
    talisman_shard=$(_rune_resolve_talisman_shard "arc" "${cwd:-}")
  fi
  [[ -z "$talisman_shard" ]] && talisman_shard="${cwd}/tmp/.talisman-resolved/arc.json"
  if [[ -f "$talisman_shard" && ! -L "$talisman_shard" ]]; then
    local enabled
    enabled=$(jq -r '.rate_limit.enabled // true' "$talisman_shard" 2>/dev/null || echo "true")
    [[ "$enabled" == "false" ]] && return 1
    local _dw _mw
    _dw=$(jq -r '.rate_limit.default_wait_seconds // 60' "$talisman_shard" 2>/dev/null || echo "60")
    _mw=$(jq -r '.rate_limit.max_wait_seconds // 300' "$talisman_shard" 2>/dev/null || echo "300")
    [[ "$_dw" =~ ^[0-9]+$ ]] && default_wait="$_dw"
    [[ "$_mw" =~ ^[0-9]+$ ]] && max_wait="$_mw"
  fi

  # Extract transcript_path from hook input JSON
  local transcript_path
  transcript_path=$(printf '%s\n' "${INPUT:-}" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  [[ -z "$transcript_path" || ! -f "$transcript_path" || -L "$transcript_path" ]] && return 1

  # Read last 2KB of transcript for rate limit patterns
  local tail_content
  tail_content=$(tail -c 2048 "$transcript_path" 2>/dev/null || true)
  [[ -z "$tail_content" ]] && return 1

  # Pattern match: rate_limit, 429, too many requests, retry-after, overloaded_error
  if printf '%s' "$tail_content" | grep -qiE '(rate.?limit|429|too many requests|retry.?after|overloaded_error)'; then
    # Try to extract retry-after seconds from the content
    local retry_after
    retry_after=$(printf '%s' "$tail_content" | grep -oiE 'retry.?after[":= ]+([0-9]+)' | grep -oE '[0-9]+' | tail -1 2>/dev/null || true)

    local wait_seconds="${retry_after:-$default_wait}"
    [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds="$default_wait"
    # Cap at max_wait to prevent indefinite waits
    (( wait_seconds > max_wait )) && wait_seconds="$max_wait"

    printf '%d' "$wait_seconds"
    return 0
  fi

  return 1
}

# ── validate_paths(): Path traversal + metachar rejection for relative paths ──
# Args: One or more relative path values to validate.
# Returns: 0 if all paths are safe, 1 if any path is unsafe.
# Checks: no "..", not absolute (/), no shell metacharacters.
# NOTE: Callers are responsible for removing state file and exiting on failure.
validate_paths() {
  local path
  for path in "$@"; do
    if [[ "$path" == *".."* ]]; then
      return 1
    fi
    if [[ "$path" == /* ]]; then
      return 1
    fi
    if [[ "$path" =~ [^a-zA-Z0-9._/-] ]]; then
      return 1
    fi
  done
  return 0
}
