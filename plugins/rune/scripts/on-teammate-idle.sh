#!/bin/bash
# scripts/on-teammate-idle.sh
# Validates teammate work quality before allowing idle.
# Exit 2 + stderr = block idle and send feedback to teammate.
# Exit 0 = allow teammate to go idle normally.
# Exit 0 + {"continue": false} JSON = stop teammate (Claude Code 2.1.69+).

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  # VEIL-003: Always emit stderr warning so quality-gate bypasses are observable
  printf 'WARN: on-teammate-idle.sh: ERR trap — fail-forward activated (line %s)\n' \
    "${BASH_LINENO[0]:-?}" >&2 2>/dev/null || true
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Session isolation — source resolve-session-identity.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  # shellcheck source=resolve-session-identity.sh
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
fi

# RUNE_TRACE: opt-in trace logging (off by default, zero overhead in production)
# NOTE(QUAL-007): _trace() is intentionally duplicated in on-task-completed.sh — each script
# must be self-contained for hook execution. Sharing via source would add a dependency.
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
# SEC-004: Restrict trace log to expected TMPDIR location to prevent env-var redirect attacks
case "$RUNE_TRACE_LOG" in
  "${TMPDIR:-/tmp}/"*) ;;  # allowed
  *) RUNE_TRACE_LOG="${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log" ;;  # reset to safe default
esac
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] on-teammate-idle: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# Pre-flight: jq is required for parsing inscription and hook input.
# If missing, exit 0 (non-blocking) — skip quality gate rather than crash.
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — quality gate skipped. Install jq for Phase 2 event-driven sync." >&2
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read
_trace "ENTER"

TEAM_NAME=$(printf '%s\n' "$INPUT" | jq -r '.team_name // empty' 2>/dev/null || true)
TEAMMATE_NAME=$(printf '%s\n' "$INPUT" | jq -r '.teammate_name // empty' 2>/dev/null || true)
# Claude Code 2.1.69+: agent_type/agent_id identify the calling agent (diagnostic/trace)
AGENT_TYPE=$(printf '%s\n' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)
AGENT_ID=$(printf '%s\n' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)

# Validate TEAMMATE_NAME characters
if [[ -n "$TEAMMATE_NAME" && ! "$TEAMMATE_NAME" =~ ^[a-zA-Z0-9_:-]+$ ]]; then
  exit 0
fi

# Guard: validate names (char-set and length before prefix check)
if [[ -z "$TEAM_NAME" ]] || [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi
if [[ ${#TEAM_NAME} -gt 128 ]]; then
  exit 0
fi

# Guard: only process Rune and Arc teams
# QUAL-001: Guard includes arc-* for arc pipeline support
_trace "PARSED team=$TEAM_NAME teammate=$TEAMMATE_NAME agent_type=$AGENT_TYPE agent_id=$AGENT_ID"
if [[ "$TEAM_NAME" != rune-* && "$TEAM_NAME" != arc-* ]]; then
  _trace "SKIP non-rune team: $TEAM_NAME"
  exit 0
fi

# Derive absolute path from hook input CWD (not relative — CWD is not guaranteed)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  echo "WARN: TeammateIdle hook input missing 'cwd' field" >&2
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { echo "WARN: Cannot canonicalize CWD: $CWD" >&2; exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then
  exit 0
fi

# --- Layer 0: Force-Stop Orphaned Teammates (Claude Code 2.1.69+) ---
# When team dir no longer exists (TeamDelete already ran) or workflow state is
# "completed"/"failed"/"cancelled", the teammate is orphaned — force stop it.
# This catches in-process teammates that acknowledged shutdown_request but whose
# process didn't exit (they go idle → TeammateIdle fires → we stop them here).
# Runs BEFORE quality gates — no point checking output if team is already gone.
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TEAM_CONFIG_DIR="$CHOME/teams/$TEAM_NAME"
if [[ ! -d "$TEAM_CONFIG_DIR" ]]; then
  _trace "STOP orphaned teammate (team dir gone): $TEAMMATE_NAME in $TEAM_NAME"
  jq -n --arg reason "Team directory no longer exists — teammate orphaned after cleanup" \
    '{"continue": false, "stopReason": $reason}' 2>/dev/null || \
    printf '{"continue":false,"stopReason":"Team directory gone — orphaned teammate"}\n'
  exit 0
fi

# --- Layer 0.5: Session Ownership Check (GAP-1 fix) ---
# Verify this teammate belongs to the current session before applying quality gates.
# stamp-team-session.sh (TLC-004) writes .session file with session_id at TeamCreate time.
# If hook's session_id differs from team's session_id, skip — another session owns this team.
HOOK_SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
if [[ -n "$HOOK_SESSION_ID" ]]; then
  TEAM_SESSION_FILE="$TEAM_CONFIG_DIR/.session"
  if [[ -f "$TEAM_SESSION_FILE" && ! -L "$TEAM_SESSION_FILE" ]]; then
    TEAM_SESSION_ID=$(jq -r '.session_id // empty' "$TEAM_SESSION_FILE" 2>/dev/null)
    if [[ -n "$TEAM_SESSION_ID" && "$TEAM_SESSION_ID" != "$HOOK_SESSION_ID" ]]; then
      _trace "SKIP session mismatch: hook=$HOOK_SESSION_ID team=$TEAM_SESSION_ID — another session owns this team"
      exit 0
    fi
  fi
fi

# Check workflow state files — if workflow completed, stop lingering teammates
# Use find instead of glob to avoid zsh NOMATCH when no state files exist
while IFS= read -r state_file; do
  [[ -f "$state_file" && ! -L "$state_file" ]] || continue
  state_team=$(jq -r '.team_name // empty' "$state_file" 2>/dev/null || true)
  if [[ "$state_team" == "$TEAM_NAME" ]]; then
    state_status=$(jq -r '.status // empty' "$state_file" 2>/dev/null || true)
    if [[ "$state_status" == "completed" || "$state_status" == "failed" || "$state_status" == "cancelled" ]]; then
      _trace "STOP orphaned teammate (workflow $state_status): $TEAMMATE_NAME in $TEAM_NAME"
      jq -n --arg reason "Workflow status is ${state_status} — teammate should have exited" \
        '{"continue": false, "stopReason": $reason}' 2>/dev/null || \
        printf '{"continue":false,"stopReason":"Workflow %s — orphaned teammate"}\n' "$state_status"
      exit 0
    fi
    break
  fi
done < <(find "${CWD}/tmp" -maxdepth 1 -name '.rune-*.json' -type f 2>/dev/null)

# --- Time-based force-stop (cumulative idle duration) ---
# If teammate has been idling for >MAX_IDLE_DURATION_SECS cumulative,
# force-stop regardless of retry count. Catches teammates that idle
# infrequently but persistently (e.g., once per 3 min, never hitting MAX_IDLE_RETRIES).
# Team-specific idle tolerance defaults (AC-7)
# Test agents need more idle tolerance — waiting between batch executions
# can exceed the default 300s threshold during legitimate batch transitions.
_DEFAULT_IDLE_SECS=300
case "${TEAM_NAME:-}" in
  arc-test-*|rune-test-*) _DEFAULT_IDLE_SECS=600 ;;  # Test agents: longer batch transitions
esac
# Configurable via RUNE_MAX_IDLE_DURATION env var (overrides team-specific defaults).
MAX_IDLE_DURATION_SECS="${RUNE_MAX_IDLE_DURATION:-$_DEFAULT_IDLE_SECS}"

FIRST_IDLE_FILE="${CWD}/tmp/.rune-signals/${TEAM_NAME}/${TEAMMATE_NAME}.first-idle"
if [[ ! -f "$FIRST_IDLE_FILE" ]] || [[ -L "$FIRST_IDLE_FILE" ]]; then
  # First idle event (or symlink — recreate safely) — record timestamp atomically
  # FLAW-001 FIX: Ensure signal directory exists before writing (may not exist yet if
  # on-task-completed.sh hasn't run). Without this, printf silently fails and the time-gate
  # is permanently disabled for this teammate.
  mkdir -p "${CWD}/tmp/.rune-signals/${TEAM_NAME}" 2>/dev/null || true
  if [[ -L "$FIRST_IDLE_FILE" ]]; then
    rm -f "$FIRST_IDLE_FILE" 2>/dev/null
  fi
  printf '%s' "$(date +%s)" > "${FIRST_IDLE_FILE}.tmp.$$" 2>/dev/null && \
    mv -f "${FIRST_IDLE_FILE}.tmp.$$" "$FIRST_IDLE_FILE" 2>/dev/null || true
else
  # Subsequent idle — check elapsed time since first idle
  first_idle_epoch=$(head -c 20 "$FIRST_IDLE_FILE" 2>/dev/null | tr -dc '0-9')
  now_epoch=$(date +%s)
  # FLAW-002 FIX: Validate first_idle_epoch is a reasonable value (within last 24h).
  # If empty/corrupt (epoch=0), the elapsed calculation would be ~1.7 billion seconds,
  # triggering an immediate false-positive force-stop. Reset the file instead.
  if [[ -z "$first_idle_epoch" ]] || (( first_idle_epoch < now_epoch - 86400 )); then
    # Corrupt or stale — reset timer to now
    _trace "TIME-GATE: Reset stale/corrupt first-idle for ${TEAMMATE_NAME} (was: ${first_idle_epoch:-empty})"
    printf '%s' "$now_epoch" > "${FIRST_IDLE_FILE}.tmp.$$" 2>/dev/null && \
      mv -f "${FIRST_IDLE_FILE}.tmp.$$" "$FIRST_IDLE_FILE" 2>/dev/null || true
    first_idle_epoch=$now_epoch
  fi
  elapsed=$(( now_epoch - first_idle_epoch ))
  if (( elapsed > MAX_IDLE_DURATION_SECS )); then
    # ── Semantic activity check (before force-stop) ──
    # If teammate is actually productive (JSONL shows WORKING), extend timer
    # instead of force-stopping. Prevents false positives from stale activity files.
    if [[ -f "${SCRIPT_DIR}/lib/find-teammate-session.sh" ]] && \
       [[ -f "${SCRIPT_DIR}/lib/detect-activity-state.sh" ]]; then
      source "${SCRIPT_DIR}/lib/find-teammate-session.sh"
      _sem_session=$(_find_teammate_session "${TEAMMATE_NAME}" "${TEAM_NAME}" 2>/dev/null) || true
      if [[ -n "$_sem_session" ]]; then
        _sem_state=$(bash "${SCRIPT_DIR}/lib/detect-activity-state.sh" "$_sem_session" 2>/dev/null) || true
        _sem_activity=$(echo "$_sem_state" | jq -r '.state // empty' 2>/dev/null) || true
        if [[ "$_sem_activity" == "WORKING" ]]; then
          # Agent is productive — reset timer, don't force-stop
          _trace "SEMANTIC-OVERRIDE: ${TEAMMATE_NAME} idle but JSONL shows WORKING — resetting timer"
          printf '%s' "$now_epoch" > "${FIRST_IDLE_FILE}.tmp.$$" 2>/dev/null && \
            mv -f "${FIRST_IDLE_FILE}.tmp.$$" "$FIRST_IDLE_FILE" 2>/dev/null || true
          echo "Teammate idle but JSONL shows productive work — extending timer" >&2
          exit 0
        fi
        _trace "SEMANTIC-CHECK: ${TEAMMATE_NAME} activity state: ${_sem_activity:-unknown}"
      fi
    fi
    # Time-gated force stop
    _trace "TIME-GATE: ${TEAMMATE_NAME} idle for ${elapsed}s (>${MAX_IDLE_DURATION_SECS}s) — force-stopping"
    jq -n --arg reason "Teammate idle for ${elapsed}s (>${MAX_IDLE_DURATION_SECS}s cumulative threshold)" \
      '{"continue": false, "stopReason": $reason}' 2>/dev/null || \
      printf '{"continue":false,"stopReason":"Teammate idle for %ds (>%ds cumulative threshold)"}\n' "$elapsed" "$MAX_IDLE_DURATION_SECS"
    exit 0
  fi
fi

# --- Retry-based quality gate with teammate stop (Claude Code 2.1.69+) ---
# After MAX_IDLE_RETRIES consecutive quality gate failures, stop the teammate
# via {"continue": false} instead of blocking indefinitely with exit 2.
# Uses file-based counter in signal dir. Security exits (path traversal) bypass this.
MAX_IDLE_RETRIES=3

_block_or_stop() {
  local msg="$1"
  local sig_dir="${CWD}/tmp/.rune-signals/${TEAM_NAME}"
  local retry_file="${sig_dir}/${TEAMMATE_NAME}.idle-retries"
  local retries=0

  # Read current retry count (fail-safe: default to 0)
  if [[ -f "$retry_file" && ! -L "$retry_file" ]]; then
    retries=$(head -c 4 "$retry_file" 2>/dev/null | tr -dc '0-9')
    [[ -z "$retries" ]] && retries=0
  fi
  retries=$((retries + 1))

  # Write updated count atomically
  if [[ -d "$sig_dir" ]]; then
    printf '%d' "$retries" > "${retry_file}.tmp.$$" 2>/dev/null && \
      mv -f "${retry_file}.tmp.$$" "$retry_file" 2>/dev/null || true
  fi

  if [[ "$retries" -ge "$MAX_IDLE_RETRIES" ]]; then
    _trace "STOP teammate after $retries retries: $TEAMMATE_NAME"
    # Claude Code 2.1.69+: {"continue": false} stops the teammate cleanly
    jq -n --arg reason "${msg} (stopped after ${retries} quality gate failures)" \
      '{"continue": false, "stopReason": $reason}' 2>/dev/null || \
      printf '{"continue":false,"stopReason":"Quality gate failed %d times"}\n' "$retries"
    exit 0
  fi

  _trace "BLOCK retry $retries/$MAX_IDLE_RETRIES: $msg"
  # Write to stderr: >&2 sends stdout→real stderr, 2>/dev/null silences printf's own errors.
  # || true prevents ERR trap if stderr is broken (replaces SEC-003 group pattern).
  printf '%s\n' "$msg" >&2 2>/dev/null || true
  exit 2
}

# --- Guard: Worker Completion Evidence Check ---
# Work agents communicate via SendMessage (Seal) and TaskUpdate, not output files.
# Instead of blanket bypass, verify completion evidence before allowing idle.
# Evidence 1: TaskCompletion signals (.done files per assigned task)
# Evidence 2: No assigned tasks (worker spawned but pool was empty)
# Evidence 3: Block if worker has assigned tasks but no completion signal
if [[ "$TEAM_NAME" =~ ^(rune|arc)-work- ]]; then
  _trace "WORKER evidence check for: $TEAMMATE_NAME in $TEAM_NAME"

  # Get tasks assigned to this teammate from task files
  TASK_DIR="$CHOME/tasks/$TEAM_NAME"
  ASSIGNED_TASKS=()
  IN_PROGRESS_TASKS=()

  if [[ -d "$TASK_DIR" ]]; then
    # Build file list with symlink pre-filter
    task_files=()
    shopt -s nullglob
    for f in "$TASK_DIR"/*.json; do
      [[ -L "$f" || ! -f "$f" ]] && continue
      task_files+=("$f")
    done
    shopt -u nullglob

    if [[ ${#task_files[@]} -gt 0 ]]; then
      # Batch extract with per-file error isolation (BACK-001 fix)
      # Each file processed independently — corrupt file N doesn't skip file N+1
      # Field order: id, status, owner — must match read variable order
      # Uses // "" (not // empty) to preserve TSV column positions
      # See also: on-task-completed.sh:92 for proven @tsv pattern
      while IFS=$'\t' read -r task_id task_status task_owner; do
        [[ -z "$task_id" ]] && continue
        if [[ "$task_owner" == "$TEAMMATE_NAME" && "$task_status" != "completed" && "$task_status" != "deleted" ]]; then
          ASSIGNED_TASKS+=("$task_id")
          [[ "$task_status" == "in_progress" ]] && IN_PROGRESS_TASKS+=("$task_id")
        fi
      done < <(for _tf in "${task_files[@]}"; do jq -r '[.id // "", .status // "", .owner // ""] | @tsv' "$_tf" 2>/dev/null || true; done)
    fi
  fi

  # Evidence 2: No assigned tasks → allow idle (worker spawned but pool empty)
  if [[ ${#ASSIGNED_TASKS[@]} -eq 0 ]]; then
    _trace "WORKER no assigned tasks: $TEAMMATE_NAME — allow idle"
    # Fall through to Layer 4 all-tasks-done signal below
  else
    # Evidence 1: Check for .done signal files for each assigned task
    SIG_DIR="${CWD}/tmp/.rune-signals/${TEAM_NAME}"
    MISSING_SIGNALS=()

    for task_id in "${ASSIGNED_TASKS[@]}"; do
      [[ -z "$task_id" ]] && continue
      done_signal="${SIG_DIR}/${task_id}.done"
      if [[ ! -f "$done_signal" ]]; then
        MISSING_SIGNALS+=("$task_id")
      fi
    done

    # Evidence 3: Block if assigned tasks missing completion signals
    if [[ ${#MISSING_SIGNALS[@]} -gt 0 ]]; then
      _trace "BLOCK worker missing completion signals: $TEAMMATE_NAME tasks=${MISSING_SIGNALS[*]}"
      missing_list=$(IFS=', '; echo "${MISSING_SIGNALS[*]:0:3}")
      [[ ${#MISSING_SIGNALS[@]} -gt 3 ]] && missing_list="${missing_list}, and $(( ${#MISSING_SIGNALS[@]} - 3 )) more"
      _block_or_stop "Worker ${TEAMMATE_NAME} has ${#ASSIGNED_TASKS[@]} assigned task(s) but no completion signal for: ${missing_list}. Complete the task(s) or report blockers."
    fi

    # All assigned tasks have .done signals → allow idle
    _trace "WORKER all tasks signaled done: $TEAMMATE_NAME (${#ASSIGNED_TASKS[@]} tasks)"
    # Fall through to Layer 4 all-tasks-done signal below
  fi
else

# --- Quality Gate: Check if teammate wrote its output file ---
# Rune teammates are expected to write output files before going idle.
# The expected output path is stored in the inscription.

# NOTE: inscription.json is write-once by orchestrator. Teammates cannot modify it if signal dir has correct permissions (umask 077 in on-task-completed.sh).
INSCRIPTION="${CWD}/tmp/.rune-signals/${TEAM_NAME}/inscription.json"
if [[ ! -f "$INSCRIPTION" ]]; then
  _trace "SKIP no inscription: $INSCRIPTION"
  # No inscription = no quality gate to enforce
  exit 0
fi
_trace "INSCRIPTION found: $INSCRIPTION"

# Find this teammate's expected output file from inscription
# Note: inscription teammate uniqueness is validated during orchestrator setup, not here
EXPECTED_OUTPUT=$(jq -r --arg name "$TEAMMATE_NAME" \
  '.teammates[] | select(.name == $name) | .output_file // empty' \
  "$INSCRIPTION" 2>/dev/null || true)

# SEC-003: Path traversal check for EXPECTED_OUTPUT
# SEC-C01: Fast-fail heuristic only — rejects obvious traversal patterns early.
# The real security boundary is the realpath+prefix canonicalization at lines 104-110.
if [[ "$EXPECTED_OUTPUT" == *".."* || "$EXPECTED_OUTPUT" == /* ]]; then
  # SEC-003: >&2 sends to real stderr, 2>/dev/null silences printf errors, || true prevents ERR trap
  printf 'ERROR: inscription output_file contains path traversal: %s\n' "${EXPECTED_OUTPUT}" >&2 2>/dev/null || true; exit 2
fi

if [[ -z "$EXPECTED_OUTPUT" ]]; then
  # Teammate not in inscription (e.g., dynamically spawned utility agent)
  exit 0
fi

# Resolve output path relative to the inscription's output_dir
# Note: output_dir in inscription must end with "/" (enforced by orchestrator setup)
OUTPUT_DIR=$(jq -r '.output_dir // empty' "$INSCRIPTION" 2>/dev/null || true)

# Validate OUTPUT_DIR
if [[ -z "$OUTPUT_DIR" ]]; then
  echo "WARN: inscription missing output_dir. Skipping quality gate." >&2
  exit 0
fi
# SEC-003: Path traversal check for OUTPUT_DIR
if [[ "$OUTPUT_DIR" == *".."* ]]; then
  # SEC-003: exit 2 before echo — prevents ERR trap preemption on broken stderr
  printf 'ERROR: inscription output_dir contains path traversal: %s\n' "${OUTPUT_DIR}" >&2 2>/dev/null || true; exit 2
fi
if [[ "$OUTPUT_DIR" != tmp/* ]]; then
  # SEC-003: exit 2 before echo — prevents ERR trap preemption on broken stderr
  printf 'ERROR: inscription output_dir outside tmp/: %s\n' "${OUTPUT_DIR}" >&2 2>/dev/null || true; exit 2
fi

# Normalize trailing slash
[[ -n "$OUTPUT_DIR" && "${OUTPUT_DIR: -1}" != "/" ]] && OUTPUT_DIR="${OUTPUT_DIR}/"

FULL_OUTPUT_PATH="${CWD}/${OUTPUT_DIR}${EXPECTED_OUTPUT}"

# SEC-004: Canonicalize and verify output path stays within output_dir
# QUAL-005 AUDIT FIX: Use lib/platform.sh _resolve_path() instead of inline duplicate.
# The fallback is safe because .. is already rejected above (lines 72, 92).
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  source "${SCRIPT_DIR}/lib/platform.sh"
fi
resolve_path() {
  if type _resolve_path &>/dev/null; then
    _resolve_path "$1"
  else
    # Fallback if platform.sh unavailable (same chain as before)
    grealpath -m "$1" 2>/dev/null || realpath -m "$1" 2>/dev/null || \
      { command -v readlink >/dev/null 2>&1 && readlink -f "$1" 2>/dev/null; } || \
      { echo "WARN: realpath not available, skipping canonicalization" >&2; echo "$1"; }
  fi
}
RESOLVED_OUTPUT=$(resolve_path "$FULL_OUTPUT_PATH")
RESOLVED_OUTDIR=$(resolve_path "${CWD}/${OUTPUT_DIR}")
if [[ "$RESOLVED_OUTPUT" != "$RESOLVED_OUTDIR"* ]]; then
  # SEC-003: exit 2 before echo — prevents ERR trap preemption on broken stderr
  printf 'ERROR: output_file resolves outside output_dir\n' >&2 2>/dev/null || true; exit 2
fi

if [[ ! -f "$FULL_OUTPUT_PATH" ]]; then
  _trace "BLOCK output missing: $FULL_OUTPUT_PATH"
  _block_or_stop "Output file not found: ${OUTPUT_DIR}${EXPECTED_OUTPUT}. Please complete your review and write findings before stopping."
fi

# BACK-007: Minimum output size gate
MIN_OUTPUT_SIZE=50  # Minimum bytes for meaningful output
FILE_SIZE=$(wc -c < "$FULL_OUTPUT_PATH" 2>/dev/null | tr -dc '0-9')
[[ -z "$FILE_SIZE" ]] && FILE_SIZE=0
if [[ "$FILE_SIZE" -lt "$MIN_OUTPUT_SIZE" ]]; then
  _trace "BLOCK output too small: ${FILE_SIZE} bytes < ${MIN_OUTPUT_SIZE}"
  _block_or_stop "Output file is empty or too small (${FILE_SIZE} bytes). Please write your findings."
fi

# --- Quality Gate: Check for SEAL marker (Roundtable Circle only) ---
# BACK-004: SEAL enforcement for review/audit workflows
# Ash agents include a SEAL YAML block in their output.
# If no SEAL, block idle — output is incomplete.
if [[ "$TEAM_NAME" =~ ^(rune|arc)-(review|audit)- ]]; then
  # SEC-009: Simple string match — this is a quality gate, not a security boundary.
  # BACK-102: ^SEAL: requires column-0 positioning by design — partial or indented
  # SEAL lines are treated as incomplete output (fail-safe).
  # Check for SEAL in output file: YAML format (^SEAL:), XML tag (<seal>), or Inner Flame self-review marker
  if ! grep -q "^SEAL:" "$FULL_OUTPUT_PATH" 2>/dev/null && ! grep -q "<seal>" "$FULL_OUTPUT_PATH" 2>/dev/null && ! grep -q "^Inner Flame:" "$FULL_OUTPUT_PATH" 2>/dev/null; then
    _trace "BLOCK SEAL missing: $FULL_OUTPUT_PATH"
    _block_or_stop "SEAL marker missing. Review output incomplete — add SEAL block."
  fi
fi

# --- Layer 3.5: Semantic Content Depth Validation ---
# Validates output has meaningful content depth beyond structural markers.
# Three checks: (1) Minimum line count, (2) Finding density, (3) File grounding.
# Runs after SEAL check, before required_sections.
if [[ "$TEAM_NAME" =~ ^(rune|arc)-(review|audit)- ]]; then
  # GAP-3 fix: removed dead OUTPUT_CONTENT variable (was set but never referenced)
  OUTPUT_LINES=$(wc -l < "$FULL_OUTPUT_PATH" 2>/dev/null | tr -dc '0-9')
  [[ -z "$OUTPUT_LINES" ]] && OUTPUT_LINES=0

  # --- Check 1: Minimum Content Depth ---
  # Skip for very large outputs (>500 lines) — already substantive
  if [[ "$OUTPUT_LINES" -lt 500 ]]; then
    # Calibrated thresholds: 50 lines (review), 80 lines (audit)
    # Based on empirical data: P25=111 lines, P10=78 lines from 522 historical outputs
    BASE_MIN_LINES=50
    if [[ "$TEAM_NAME" =~ -audit- ]]; then
      BASE_MIN_LINES=80
    fi

    # Scale down for small scopes
    # Get scope files from inscription
    SCOPE_FILES_COUNT=$(jq -r '.scope_files // [] | length' "$INSCRIPTION" 2>/dev/null || echo "0")
    [[ -z "$SCOPE_FILES_COUNT" || "$SCOPE_FILES_COUNT" == "null" ]] && SCOPE_FILES_COUNT=0

    # Calculate scaled minimum: max(20, base * files / 5)
    # For 1-2 files: ~20-32 lines. For 5+ files: full threshold.
    SCALED_MIN_LINES=20
    if [[ "$SCOPE_FILES_COUNT" -gt 0 ]]; then
      SCALED_MIN_LINES=$((BASE_MIN_LINES * SCOPE_FILES_COUNT / 5))
      [[ "$SCALED_MIN_LINES" -lt 20 ]] && SCALED_MIN_LINES=20
      [[ "$SCALED_MIN_LINES" -gt "$BASE_MIN_LINES" ]] && SCALED_MIN_LINES=$BASE_MIN_LINES
    fi

    if [[ "$OUTPUT_LINES" -lt "$SCALED_MIN_LINES" ]]; then
      _trace "BLOCK content too shallow: ${OUTPUT_LINES} lines < ${SCALED_MIN_LINES} (scaled from ${BASE_MIN_LINES}, scope=${SCOPE_FILES_COUNT} files)"
      _block_or_stop "Output is too shallow (${OUTPUT_LINES} lines, expected ${SCALED_MIN_LINES}+ for ${SCOPE_FILES_COUNT} scope files). Please provide substantive analysis."
    fi
  fi

  # --- Check 2: Finding Density ---
  # Count P1/P2/P3 finding markers in output
  # Patterns: "P1:", "P2:", "P3:", "Priority 1:", "Priority 2:", "Priority 3:"
  # Also check for domain-specific findings: vulnerability, issue, problem, finding
  # BUG FIX: grep -c outputs "0" AND returns non-zero when no matches.
  # Using `|| echo "0"` appends a second "0" (captured as "0\n0"), breaking arithmetic.
  # Fix: separate assignment from fallback so grep's stdout is captured without duplication.
  FINDING_COUNT=$(grep -cE '(P[123]:|Priority [123]:|Finding #|VULN-|SEC-|BUG-|CRITICAL|HIGH|MEDIUM|LOW):?' "$FULL_OUTPUT_PATH" 2>/dev/null) || true
  [[ -z "$FINDING_COUNT" || "$FINDING_COUNT" == "null" ]] && FINDING_COUNT=0

  # If no findings found, require explicit "no issues found" declaration
  if [[ "$FINDING_COUNT" -eq 0 ]]; then
    # Enhanced regex for domain-specific "no findings" declarations
    # Matches: "no issues found", "no findings", "no problems detected", "no vulnerabilities"
    if ! grep -qiE '(no\s+(issues?|findings?|problems?|vulnerabilities?|concerns?|defects?)(\s+(found|detected|identified|observed))?)' "$FULL_OUTPUT_PATH" 2>/dev/null; then
      _trace "BLOCK no findings and no explicit declaration: $FULL_OUTPUT_PATH"
      _block_or_stop "No findings detected in output. If no issues were found, please explicitly state 'No issues found' or similar declaration."
    fi
  fi

  # --- Check 3: File Reference Grounding (advisory only) ---
  # Warn if output references <20% of scope files
  # Get scope files list from inscription
  SCOPE_FILES=$(jq -r '.scope_files // [] | .[]' "$INSCRIPTION" 2>/dev/null || true)
  if [[ -n "$SCOPE_FILES" ]]; then
    TOTAL_SCOPE=0
    REFERENCED=0
    BINARY_EXCLUDED=0

    while IFS= read -r scope_file; do
      [[ -z "$scope_file" ]] && continue
      TOTAL_SCOPE=$((TOTAL_SCOPE + 1))

      # Skip binary files from grounding ratio
      # Common binary extensions: .png, .jpg, .jpeg, .gif, .ico, .woff, .woff2, .ttf, .eot, .pdf, .zip, .gz, .tar
      if [[ "$scope_file" =~ \.(png|jpg|jpeg|gif|ico|woff|woff2|ttf|eot|pdf|zip|gz|tar|bin|exe|so|dylib)$ ]]; then
        BINARY_EXCLUDED=$((BINARY_EXCLUDED + 1))
        continue
      fi

      # Check if file is referenced in output (basename match)
      FILE_BASENAME=$(basename "$scope_file" 2>/dev/null || true)
      if [[ -n "$FILE_BASENAME" ]] && grep -qiF "$FILE_BASENAME" "$FULL_OUTPUT_PATH" 2>/dev/null; then
        REFERENCED=$((REFERENCED + 1))
      fi
    done <<< "$SCOPE_FILES"

    # Calculate grounding ratio (excluding binaries)
    ELIGIBLE_SCOPE=$((TOTAL_SCOPE - BINARY_EXCLUDED))
    if [[ "$ELIGIBLE_SCOPE" -gt 0 ]]; then
      GROUNDING_RATIO=$((REFERENCED * 100 / ELIGIBLE_SCOPE))

      # Advisory warning at <20% grounding (do not block)
      if [[ "$GROUNDING_RATIO" -lt 20 ]]; then
        _trace "WARN low file grounding: ${REFERENCED}/${ELIGIBLE_SCOPE} files (${GROUNDING_RATIO}%)"
        # Advisory only — output to stderr but do not block
        echo "Warning: Output references only ${REFERENCED} of ${ELIGIBLE_SCOPE} scope files (${GROUNDING_RATIO}%). Consider reviewing more files." >&2
      fi
    fi
  fi
fi

# --- Quality Gate: Required sections check (inscription-driven) ---
# If the inscription contract specifies required_sections for this Ash,
# verify those section headings appear in the output file.
# Advisory only — warns but does NOT block (exit 0, not exit 2).
if [[ "$TEAM_NAME" =~ ^(rune|arc)-(review|audit)- ]]; then
  SECTIONS_INSCRIPTION_PATH=""
  # Discover inscription.json from team output directory
  # Fix: Use ${CWD} prefix — hook cwd may differ from project root (P1 fix)
  for candidate in "${CWD}/tmp/reviews/"*/inscription.json "${CWD}/tmp/audit/"*/inscription.json; do
    [[ -f "$candidate" ]] || continue
    [[ -L "$candidate" ]] && continue
    # Match team name via structured jq lookup (not substring grep — P2 fix)
    if jq -e --arg tn "$TEAM_NAME" '.team_name == $tn' "$candidate" >/dev/null 2>/dev/null; then
      SECTIONS_INSCRIPTION_PATH="$candidate"
      break
    fi
  done

  if [[ -n "$SECTIONS_INSCRIPTION_PATH" ]]; then
    # Extract required_sections for this teammate (simplified jq per EC-2)
    # Fix: Use .teammates[] to match inscription schema (not .ashes[] — P2 fix)
    REQ_SECTIONS=$(jq -r --arg name "$TEAMMATE_NAME" \
      '.teammates[]? | select(.name == $name) | .required_sections // [] | .[]' \
      "$SECTIONS_INSCRIPTION_PATH" 2>/dev/null || true)

    if [[ -n "$REQ_SECTIONS" ]]; then
      MISSING_SECTIONS=""
      MISSING_COUNT=0
      TOTAL_COUNT=0

      while IFS= read -r section; do
        [[ -z "$section" ]] && continue
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        # Sanity check: skip if inscription has >20 required sections (likely corrupted)
        [[ "$TOTAL_COUNT" -gt 20 ]] && break
        # EC-1: Use grep -qiF for fixed-string case-insensitive matching
        if ! grep -qiF "$section" "$FULL_OUTPUT_PATH" 2>/dev/null; then
          MISSING_COUNT=$((MISSING_COUNT + 1))
          # Truncate to first 5 missing sections for readable warnings
          if [[ "$MISSING_COUNT" -le 5 ]]; then
            MISSING_SECTIONS="${MISSING_SECTIONS}  - ${section}\n"
          fi
        fi
      done <<< "$REQ_SECTIONS"

      if [[ "$MISSING_COUNT" -gt 0 ]]; then
        EXTRA=""
        [[ "$MISSING_COUNT" -gt 5 ]] && EXTRA=" (and $((MISSING_COUNT - 5)) more)"
        _trace "WARN missing ${MISSING_COUNT} required sections for $TEAMMATE_NAME"
        # Advisory only — output to stderr but exit 0 (do not block)
        echo "Warning: ${MISSING_COUNT} required section(s) missing from ${TEAMMATE_NAME} output${EXTRA}:" >&2
        printf '%b' "$MISSING_SECTIONS" >&2
      fi
    fi
  fi
fi

fi  # end: skip output file gate for work teams

_trace "PASS all gates for $TEAMMATE_NAME"

# Reset time-gate and retry counter on successful quality gate pass — measures cumulative
# FAILED idle time and failures, not total lifetime. A teammate that works productively
# between idles gets both timers reset. Without retry reset, transient failures accumulate
# across the teammate's lifetime and eventually trigger premature force-stop (GAP-2 fix).
rm -f "${CWD}/tmp/.rune-signals/${TEAM_NAME}/${TEAMMATE_NAME}.first-idle" 2>/dev/null
rm -f "${CWD}/tmp/.rune-signals/${TEAM_NAME}/${TEAMMATE_NAME}.idle-retries" 2>/dev/null

# --- Layer 4: All-Tasks-Done Signal ---
# After quality gates pass, check if ALL tasks in this team are done.
# If so, write a signal file so orchestrators can skip remaining poll cycles.
# NOTE: CHOME already set in Layer 0 above
TASK_DIR="$CHOME/tasks/$TEAM_NAME"
if [[ -d "$TASK_DIR" ]]; then
  ALL_DONE=true
  found_any_task=false
  shopt -s nullglob
  for task_file in "$TASK_DIR"/*.json; do
    [[ -L "$task_file" ]] && continue
    [[ -f "$task_file" ]] || continue
    found_any_task=true
    task_status=$(jq -r '.status // empty' "$task_file" 2>/dev/null || true)
    if [[ "$task_status" != "completed" && "$task_status" != "deleted" ]]; then
      ALL_DONE=false
      break
    fi
  done
  shopt -u nullglob

  if [[ "$ALL_DONE" == "true" && "$found_any_task" == "true" ]]; then
    sig="${CWD}/tmp/.rune-signals/${TEAM_NAME}/all-tasks-done"
    mkdir -p "$(dirname "$sig")" 2>/dev/null
    # SEC-002 FIX: Use jq for JSON-safe construction instead of printf interpolation
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg cfg "${RUNE_CURRENT_CFG:-unknown}" \
      --arg pid "${PPID:-0}" \
      '{timestamp: $ts, config_dir: $cfg, owner_pid: $pid}' \
      > "${sig}.tmp.$$" 2>/dev/null && mv "${sig}.tmp.$$" "${sig}" 2>/dev/null || \
      { printf 'WARN: on-teammate-idle.sh: all-tasks-done signal write failed for team %s\n' "$TEAM_NAME" >&2 2>/dev/null || true; }
    _trace "SIGNAL all-tasks-done for team $TEAM_NAME"
  fi
fi

# ── Layer 5: Per-teammate status signal (STALE-LEAD-001) ──
# Write status JSON so detect-stale-lead.sh can assess team health.
# Fail-forward: mkdir/jq/mv failures must not affect idle gate decision.
if [[ -n "${TEAM_NAME:-}" && -n "${TEAMMATE_NAME:-}" ]]; then
  _sl_status_dir="${CWD}/tmp/.rune-signals/${TEAM_NAME}/status"
  mkdir -p "$_sl_status_dir" 2>/dev/null || true
  _sl_outcome="idle"
  # Check if teammate produced output (heuristic: task file exists with completed status)
  if [[ -n "${TASK_DIR:-}" && -d "${TASK_DIR:-}" ]]; then
    _sl_done_count=$(find "$TASK_DIR" -maxdepth 1 -name "*.json" -newer "${CWD}/tmp/.rune-signals/${TEAM_NAME}/.expected" 2>/dev/null | wc -l)
    [[ "$_sl_done_count" -gt 0 ]] && _sl_outcome="done" 2>/dev/null || true
  fi
  jq -n \
    --arg name "${TEAMMATE_NAME}" \
    --arg outcome "$_sl_outcome" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{teammate: $name, outcome: $outcome, timestamp: $ts}' \
    > "${_sl_status_dir}/${TEAMMATE_NAME}.json.tmp.$$" 2>/dev/null && \
    mv -f "${_sl_status_dir}/${TEAMMATE_NAME}.json.tmp.$$" \
          "${_sl_status_dir}/${TEAMMATE_NAME}.json" 2>/dev/null || true
  _trace "STATUS signal written for $TEAMMATE_NAME: $_sl_outcome"
fi

# All gates passed — allow idle
exit 0
