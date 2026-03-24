#!/bin/bash
# scripts/on-stop-failure.sh
# STOP-FAILURE-001: Handle API errors during arc pipeline execution.
# Hook event: StopFailure
# Exit 0: No active arc — allow failure (stdout/stderr discarded by Claude Code)
# Exit 2 + stderr: Re-inject recovery prompt (with backoff for rate limits)
#
# OPERATIONAL: Fail-forward (crash -> exit 0, allow failure, don't make worse)

set -euo pipefail
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

# ── Guard 3: Check for active arc (state file must exist) ──
STATE_FILE="${CWD}/${RUNE_STATE}/arc-phase-loop.local.md"
check_state_file "$STATE_FILE"

# ── Guard 4: Reject symlinks on state file ──
reject_symlink "$STATE_FILE"

# ── Guard 5: Parse frontmatter from state file ──
parse_frontmatter "$STATE_FILE"

# ── Guard 6: Get hook session ID ──
arc_get_hook_session_id

# ── Guard 7: Validate session ownership (exit 0 if different session) ──
validate_session_ownership_strict "$STATE_FILE"

_trace "Guards passed — classifying stop failure"

# ── Classification ──
# shellcheck source=lib/stop-failure-common.sh
source "${SCRIPT_DIR}/lib/stop-failure-common.sh"
classify_stop_failure

_trace "ERROR_TYPE=${ERROR_TYPE} WAIT_SECONDS=${WAIT_SECONDS} ERROR_ACTION=${ERROR_ACTION}"

# ── Read checkpoint info from state file frontmatter ──
checkpoint_path=$(get_field "checkpoint_path")
_trace "checkpoint_path=${checkpoint_path}"

# Determine current phase from checkpoint (if readable)
current_phase=""
next_phase=""
if [[ -n "$checkpoint_path" ]] && [[ -f "${CWD}/${checkpoint_path}" ]] && [[ ! -L "${CWD}/${checkpoint_path}" ]]; then
  current_phase=$(jq -r '.current_phase // empty' "${CWD}/${checkpoint_path}" 2>/dev/null || true)
  # Find next pending phase
  next_phase=$(jq -r '
    .phases // [] | map(select(.status == "pending")) | .[0].name // empty
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

# ── Actions by error type (all via stderr + exit 2) ──
case "$ERROR_TYPE" in
  RATE_LIMIT)
    _trace "RATE_LIMIT — injecting backoff wait of ${WAIT_SECONDS}s"
    cat >&2 <<EOF
API rate limit hit${phase_info}. Wait ${WAIT_SECONDS} seconds before continuing.

After waiting, continue arc${resume_phase}. Checkpoint preserved at: ${checkpoint_path:-<unknown>}

Run: sleep ${WAIT_SECONDS} && then continue the arc pipeline.
EOF
    exit 2
    ;;

  SERVER)
    _trace "SERVER — injecting backoff wait of ${WAIT_SECONDS}s"
    cat >&2 <<EOF
API server error${phase_info}. Wait ${WAIT_SECONDS} seconds before retrying.

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
