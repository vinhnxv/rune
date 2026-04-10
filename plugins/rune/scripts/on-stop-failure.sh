#!/bin/bash
# scripts/on-stop-failure.sh
# STOP-FAILURE-001: Handle API errors during arc pipeline and standalone workflows.
# Hook event: StopFailure
# Exit 0: No active workflow — allow failure (stdout/stderr discarded by Claude Code)
# Exit 2 + stderr: Re-inject recovery prompt (with backoff for rate limits)
#
# OPERATIONAL: Fail-forward (crash -> exit 0, allow failure, don't make worse)

set -euo pipefail
umask 077  # PAT-003 FIX
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source ordering (verified from arc-phase-stop-hook.sh) ──
# shellcheck source=lib/arc-stop-hook-common.sh
if [[ ! -f "${SCRIPT_DIR}/lib/arc-stop-hook-common.sh" ]]; then
  exit 0  # fail-forward: allow failure rather than crash with undefined functions
fi
source "${SCRIPT_DIR}/lib/arc-stop-hook-common.sh"  # 1st: ERR trap + jq guard
arc_setup_err_trap                                    # NOT verbose (lightweight)
arc_init_trace_log
arc_guard_jq_required                                 # exit 0 if jq missing

# shellcheck source=lib/stop-hook-common.sh
source "${SCRIPT_DIR}/lib/stop-hook-common.sh"        # 2nd: parse_input, resolve_cwd

# ── Define _trace after arc_init_trace_log ──
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] on-stop-failure: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

_trace "ENTER on-stop-failure.sh"

# ── Guard 1: Parse input (stdin) ──
parse_input

# ── Guard 2: Resolve CWD ──
resolve_cwd

# ── Standalone handler for non-arc workflows ──
_handle_standalone_stop_failure() {
  local error_type="$1"
  local wait_seconds="$2"
  case "$error_type" in
    RATE_LIMIT)
      local has_active=false
      local sf
      # ERR-017 FIX: Use while-read to avoid word-splitting on paths with spaces
      while IFS= read -r sf; do
        [[ -z "$sf" || -L "$sf" ]] && continue
        local sf_status
        sf_status=$(jq -r '.status // empty' "$sf" 2>/dev/null || true)
        [[ "$sf_status" == "active" ]] && has_active=true && break
      done < <(find "${CWD}/tmp" -maxdepth 1 -name '.rune-*.json' -type f 2>/dev/null)
      if [[ "$has_active" == "true" ]]; then
        printf '[STOP-FAILURE] API rate limit during active Rune workflow. Wait %d seconds then retry.\n' "$wait_seconds" >&2
        exit 2
      fi
      printf '[STOP-FAILURE] API rate limit. Wait and retry your request.\n' >&2
      exit 0
      ;;
    AUTH)
      printf '[STOP-FAILURE] Authentication error. Check your API key and billing status.\n' >&2
      exit 0
      ;;
    *)
      printf '[STOP-FAILURE] API error (%s). Retry your request.\n' "$error_type" >&2
      exit 0
      ;;
  esac
}

# ── Guard 3: Check for active arc OR handle standalone ──
STATE_FILE="${CWD}/${RUNE_STATE}/arc-phase-loop.local.md"
if [[ ! -f "$STATE_FILE" ]]; then
  # No arc state — handle standalone workflows
  source "${SCRIPT_DIR}/lib/stop-failure-common.sh"
  classify_stop_failure
  _handle_standalone_stop_failure "$ERROR_TYPE" "$WAIT_SECONDS"
  # _handle_standalone_stop_failure exits internally
fi
check_state_file "$STATE_FILE"

# ── Guard 4: Reject symlinks on state file ──
reject_symlink "$STATE_FILE"

# ── Guard 5: Parse frontmatter from state file ──
parse_frontmatter "$STATE_FILE"

# ── Guard 6: Get hook session ID ──
arc_get_hook_session_id

# ── Guard 7: Validate session ownership (exit 0 if different session) ──
# FLAW-002 FIX: Use if-guard instead of bare call (avoids ERR trap as control flow)
if ! validate_session_ownership_strict "$STATE_FILE"; then
  _trace "EXIT: session ownership strict check failed"
  exit 0
fi

_trace "Guards passed — classifying stop failure"

# ── Classification ──
# shellcheck source=lib/stop-failure-common.sh
source "${SCRIPT_DIR}/lib/stop-failure-common.sh"
classify_stop_failure

_trace "ERROR_TYPE=${ERROR_TYPE} WAIT_SECONDS=${WAIT_SECONDS} ERROR_ACTION=${ERROR_ACTION}"

# ── Read checkpoint info from state file frontmatter ──
checkpoint_path=$(get_field "checkpoint_path")
_trace "checkpoint_path=${checkpoint_path}"

# SEC-001: Validate checkpoint_path before use (path traversal + metachar rejection)
if [[ -n "$checkpoint_path" ]] && ! validate_paths "$checkpoint_path"; then
  _trace "WARN: checkpoint_path failed validation, clearing"
  checkpoint_path=""
fi

# Determine current phase from checkpoint (if readable)
current_phase=""
next_phase=""
if [[ -n "$checkpoint_path" ]] && [[ -f "${CWD}/${checkpoint_path}" ]] && [[ ! -L "${CWD}/${checkpoint_path}" ]]; then
  current_phase=$(jq -r '.current_phase // empty' "${CWD}/${checkpoint_path}" 2>/dev/null || true)
  # Find next pending phase
  # FLAW-011 FIX: checkpoint .phases is an object (keys=phase names), not an array
  next_phase=$(jq -r '
    .phases // {} | to_entries | map(select(.value.status == "pending")) | .[0].key // empty
  ' "${CWD}/${checkpoint_path}" 2>/dev/null || true)
fi

# Fallback: read phase from state file frontmatter
if [[ -z "$current_phase" ]]; then
  current_phase=$(get_field "current_phase")
fi

_trace "current_phase=${current_phase} next_phase=${next_phase}"

# ── Build phase context string ──
phase_info=""
if [[ -n "$current_phase" ]]; then
  phase_info=" at phase '${current_phase}'"
fi
resume_phase=""
if [[ -n "$next_phase" ]]; then
  resume_phase=" from phase '${next_phase}'"
elif [[ -n "$current_phase" ]]; then
  resume_phase=" from phase '${current_phase}'"
fi

# ── Resolve talisman shard for retry config ──
talisman_shard=""
if type _rune_resolve_talisman_shard &>/dev/null; then
  talisman_shard=$(_rune_resolve_talisman_shard "arc" "${CWD:-}" 2>/dev/null || true)
fi
[[ -z "$talisman_shard" ]] && talisman_shard="${CWD}/tmp/.talisman-resolved/arc.json"

# ── Actions by error type (all via stderr + exit 2) ──
case "$ERROR_TYPE" in
  RATE_LIMIT)
    # ── Retry counter with exponential backoff ──
    api_retries=0
    if [[ -n "$checkpoint_path" ]] && [[ -f "${CWD}/${checkpoint_path}" ]] && [[ ! -L "${CWD}/${checkpoint_path}" ]]; then
      api_retries=$(jq -r '.api_error_retries // 0' "${CWD}/${checkpoint_path}" 2>/dev/null || echo "0")
    fi
    [[ "$api_retries" =~ ^[0-9]+$ ]] || api_retries=0

    # Read max_retries from talisman (default: 3)
    max_retries=3
    if [[ -f "$talisman_shard" ]] && [[ ! -L "$talisman_shard" ]]; then
      _mr=$(jq -r '.rate_limit.max_retries // 3' "$talisman_shard" 2>/dev/null || echo "3")
      [[ "$_mr" =~ ^[0-9]+$ ]] && max_retries="$_mr"
    fi

    # Check if retries exceeded — halt if so
    if [[ "$api_retries" -ge "$max_retries" ]]; then
      _trace "RATE_LIMIT — retries exhausted (${api_retries}/${max_retries}), halting"
      cat >&2 <<EOF
API rate limit hit${phase_info}. Retry limit reached (${api_retries}/${max_retries}). Arc paused.

Checkpoint preserved at: ${checkpoint_path:-<unknown>}
To resume later: /rune:arc --resume
EOF
      exit 0
    fi

    # Calculate exponential backoff: base_wait * 2^retries, capped at max_wait
    backoff=$((1 << api_retries))
    WAIT_SECONDS=$((WAIT_SECONDS * backoff))
    # Cap at max_wait from talisman
    max_wait=300
    if [[ -f "$talisman_shard" ]] && [[ ! -L "$talisman_shard" ]]; then
      _mw=$(jq -r '.rate_limit.max_wait_seconds // 300' "$talisman_shard" 2>/dev/null || echo "300")
      [[ "$_mw" =~ ^[0-9]+$ ]] && max_wait="$_mw"
    fi
    [[ "$WAIT_SECONDS" -gt "$max_wait" ]] && WAIT_SECONDS="$max_wait"

    # Increment retry counter atomically in checkpoint
    if [[ -n "$checkpoint_path" ]] && [[ -f "${CWD}/${checkpoint_path}" ]] && [[ ! -L "${CWD}/${checkpoint_path}" ]]; then
      # FLAW-003 FIX: Create temp file on same filesystem for atomic rename
      _tmp=$(mktemp "${CWD}/${checkpoint_path}.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/rune-cp-XXXXXX")
      if jq ".api_error_retries = $((api_retries + 1))" "${CWD}/${checkpoint_path}" > "$_tmp" 2>/dev/null; then
        mv -f "$_tmp" "${CWD}/${checkpoint_path}"
      else
        rm -f "$_tmp"
      fi
    fi

    _trace "RATE_LIMIT — retry ${api_retries}/${max_retries}, backoff=${backoff}x, wait=${WAIT_SECONDS}s"
    cat >&2 <<EOF
API rate limit hit${phase_info}. Retry ${api_retries}/${max_retries} — wait ${WAIT_SECONDS} seconds (${backoff}x backoff).

After waiting, continue arc${resume_phase}. Checkpoint preserved at: ${checkpoint_path:-<unknown>}

Run: sleep ${WAIT_SECONDS} && then continue the arc pipeline.
EOF
    exit 2
    ;;

  SERVER)
    # ── Retry counter for server errors ──
    server_retries=0
    if [[ -n "$checkpoint_path" ]] && [[ -f "${CWD}/${checkpoint_path}" ]] && [[ ! -L "${CWD}/${checkpoint_path}" ]]; then
      server_retries=$(jq -r '.server_error_retries // 0' "${CWD}/${checkpoint_path}" 2>/dev/null || echo "0")
    fi
    [[ "$server_retries" =~ ^[0-9]+$ ]] || server_retries=0

    # Read max_server_retries from talisman (default: 2)
    max_server_retries=2
    if [[ -f "$talisman_shard" ]] && [[ ! -L "$talisman_shard" ]]; then
      _msr=$(jq -r '.rate_limit.max_server_retries // 2' "$talisman_shard" 2>/dev/null || echo "2")
      [[ "$_msr" =~ ^[0-9]+$ ]] && max_server_retries="$_msr"
    fi

    # Check if retries exceeded — halt if so
    if [[ "$server_retries" -ge "$max_server_retries" ]]; then
      _trace "SERVER — retries exhausted (${server_retries}/${max_server_retries}), halting"
      cat >&2 <<EOF
API server error${phase_info}. Retry limit reached (${server_retries}/${max_server_retries}). Arc paused.

Checkpoint preserved at: ${checkpoint_path:-<unknown>}
To resume later: /rune:arc --resume
EOF
      exit 0
    fi

    # Calculate exponential backoff for server errors
    backoff=$((1 << server_retries))
    WAIT_SECONDS=$((WAIT_SECONDS * backoff))
    max_wait=300
    if [[ -f "$talisman_shard" ]] && [[ ! -L "$talisman_shard" ]]; then
      _mw=$(jq -r '.rate_limit.max_wait_seconds // 300' "$talisman_shard" 2>/dev/null || echo "300")
      [[ "$_mw" =~ ^[0-9]+$ ]] && max_wait="$_mw"
    fi
    [[ "$WAIT_SECONDS" -gt "$max_wait" ]] && WAIT_SECONDS="$max_wait"

    # Increment retry counter atomically in checkpoint
    if [[ -n "$checkpoint_path" ]] && [[ -f "${CWD}/${checkpoint_path}" ]] && [[ ! -L "${CWD}/${checkpoint_path}" ]]; then
      # FLAW-003 FIX: Create temp file on same filesystem for atomic rename
      _tmp=$(mktemp "${CWD}/${checkpoint_path}.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/rune-cp-XXXXXX")
      if jq ".server_error_retries = $((server_retries + 1))" "${CWD}/${checkpoint_path}" > "$_tmp" 2>/dev/null; then
        mv -f "$_tmp" "${CWD}/${checkpoint_path}"
      else
        rm -f "$_tmp"
      fi
    fi

    _trace "SERVER — retry ${server_retries}/${max_server_retries}, backoff=${backoff}x, wait=${WAIT_SECONDS}s"
    cat >&2 <<EOF
API server error${phase_info}. Retry ${server_retries}/${max_server_retries} — wait ${WAIT_SECONDS} seconds (${backoff}x backoff).

After waiting, continue arc${resume_phase}. Checkpoint preserved at: ${checkpoint_path:-<unknown>}

Run: sleep ${WAIT_SECONDS} && then continue the arc pipeline.
EOF
    exit 2
    ;;

  AUTH)
    _trace "AUTH — halting arc, preserving checkpoint"
    cat >&2 <<EOF
API authentication error${phase_info}. Arc paused. Checkpoint preserved at: ${checkpoint_path:-<unknown>}

Fix credentials, then resume with: /rune:arc --resume
EOF
    exit 2
    ;;

  UNKNOWN|*)
    _trace "UNKNOWN — preserving checkpoint for manual resume"
    cat >&2 <<EOF
API error during arc${phase_info}. Checkpoint preserved at: ${checkpoint_path:-<unknown>}

To resume: /rune:arc --resume
EOF
    exit 2
    ;;
esac
