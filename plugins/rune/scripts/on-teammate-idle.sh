#!/bin/bash
# scripts/on-teammate-idle.sh
# Validates teammate work quality before allowing idle.
# Exit 2 + stderr = block idle and send feedback to teammate.
# Exit 0 = allow teammate to go idle normally.
# Exit 0 + {"continue": false} JSON = stop teammate (Claude Code 2.1.69+).

set -euo pipefail
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
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
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
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
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
# Claude Code 2.1.69+: agent_type identifies the calling agent type (diagnostic/trace)
AGENT_TYPE=$(printf '%s\n' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)

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
_trace "PARSED team=$TEAM_NAME teammate=$TEAMMATE_NAME agent_type=$AGENT_TYPE"
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

# --- Guard: Skip output file gate for work teams ---
# Work agents communicate via SendMessage (Seal) and TaskUpdate, not output files.
# Inscription includes output_file entries for signal tracking but work agents
# should NOT be blocked for missing output files. (FIX: stuck rune-smith agents)
# Layer 4 all-tasks-done signal (below) still applies to work teams.
if [[ "$TEAM_NAME" =~ ^(rune|arc)-work- ]]; then
  _trace "SKIP output file gate for work team: $TEAM_NAME"
  # Fall through to Layer 4 all-tasks-done signal below
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
# Use grealpath -m (GNU coreutils on macOS) or realpath -m (Linux), with
# shell-based fallback for environments where neither is available.
# The fallback is safe because .. is already rejected above (lines 72, 92).
resolve_path() {
  grealpath -m "$1" 2>/dev/null || realpath -m "$1" 2>/dev/null || \
    { command -v readlink >/dev/null 2>&1 && readlink -f "$1" 2>/dev/null; } || \
    { echo "WARN: realpath not available, skipping canonicalization" >&2; echo "$1"; }
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

# --- Layer 4: All-Tasks-Done Signal ---
# After quality gates pass, check if ALL tasks in this team are done.
# If so, write a signal file so orchestrators can skip remaining poll cycles.
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
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

# All gates passed — allow idle
exit 0
