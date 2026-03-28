#!/bin/bash
# scripts/codex-exec.sh
# Canonical Codex CLI wrapper — SEC-009 enforcement, model allowlist,
# timeout clamping, error classification.
#
# Replaces raw `codex exec` Bash calls throughout Rune skills/agents.
# All Rune workflows that invoke Codex SHOULD use this script instead
# of crafting raw shell commands.
#
# Usage: codex-exec.sh [OPTIONS] PROMPT_FILE
#
# Options:
#   -m MODEL          Model (default: gpt-5.3-codex, validated against allowlist)
#   -r REASONING      xhigh|high|medium|low (default: xhigh)
#   -t TIMEOUT        Seconds, clamped to [300, 900] (default: 600)
#   -s STREAM_IDLE    Stream idle timeout ms (default: 540000)
#   -j                Enable --json + jq JSONL parsing
#   -g                Pass --skip-git-repo-check
#   -k KILL_AFTER     Kill-after grace period seconds (default: 30, 0=disable)
#   -o OUTPUT_FILE    Redirect Codex stdout to file (atomic write via tmp+mv)
#
# Exit codes:
#   0   — success
#   1   — missing dependency (codex CLI not found)
#   2   — pre-flight failure (.codexignore missing, invalid prompt file)
#   124 — timeout (from GNU/coreutils timeout)
#   137 — killed (SIGKILL from --kill-after)
#   *   — passthrough from codex exec
#
# Environment:
#   RUNE_TRACE=1        Enable trace logging
#   CLAUDE_PLUGIN_ROOT  Plugin root (auto-detected if unset)

set -euo pipefail
umask 077

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ─── Trace logging ────────────────────────────────────────────────────────────
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() {
  [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && \
    printf '[%s] codex-exec: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"
  return 0
}

# ─── Defaults ─────────────────────────────────────────────────────────────────
MODEL="gpt-5.3-codex"
REASONING="xhigh"
TIMEOUT=600
STREAM_IDLE=540000
JSON_MODE=0
SKIP_GIT_CHECK=0
KILL_AFTER=30
OUTPUT_FILE=""

# ─── Parse options ────────────────────────────────────────────────────────────
while getopts "m:r:t:s:k:o:jg" opt; do
  case "$opt" in
    m) MODEL="$OPTARG" ;;
    r) REASONING="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    s) STREAM_IDLE="$OPTARG" ;;
    k) KILL_AFTER="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    j) JSON_MODE=1 ;;
    g) SKIP_GIT_CHECK=1 ;;
    *)
      echo "Usage: codex-exec.sh [OPTIONS] PROMPT_FILE" >&2
      echo "Options: -m MODEL -r REASONING -t TIMEOUT -s STREAM_IDLE -j -g -k KILL_AFTER -o OUTPUT_FILE" >&2
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))

# ─── Prompt file argument ─────────────────────────────────────────────────────
PROMPT_FILE="${1:-}"
if [[ -z "$PROMPT_FILE" ]]; then
  echo "ERROR: PROMPT_FILE argument required" >&2
  echo "Usage: codex-exec.sh [OPTIONS] PROMPT_FILE" >&2
  exit 2
fi

# ─── Validation: prompt file security ─────────────────────────────────────────
# SEC-009: Reject symlinks (prevent reading unintended files)
if [[ -L "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file is a symlink — rejected for security" >&2
  exit 2
fi

# SEC-009: Reject path traversal
case "$PROMPT_FILE" in
  *..*)
    echo "ERROR: Prompt file path contains '..' — rejected for security" >&2
    exit 2
    ;;
esac

# SEC-002 FIX: Allowlist validation — reject special characters that could be exploited in shell contexts
if [[ ! "$PROMPT_FILE" =~ ^[a-zA-Z0-9_/.\-]+$ ]]; then
  echo "ERROR: Prompt file path contains invalid characters — rejected for security" >&2
  exit 2
fi

# Check prompt file exists and is readable
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

if [[ ! -r "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not readable: $PROMPT_FILE" >&2
  exit 2
fi

# SEC-2: Cap prompt file at 1MB (DoS prevention)
PROMPT_SIZE=$(wc -c < "$PROMPT_FILE" 2>/dev/null || echo 0)
if [[ "$PROMPT_SIZE" -gt 1048576 ]]; then
  echo "ERROR: Prompt file exceeds 1MB limit (${PROMPT_SIZE} bytes)" >&2
  exit 2
fi

# ─── Validation: output file security (SEC-010) ─────────────────────────────
if [[ -n "$OUTPUT_FILE" ]]; then
  # SEC-010: Reject symlinks (prevent writing to unintended locations)
  if [[ -L "$OUTPUT_FILE" ]]; then
    echo "ERROR: Output file path is a symlink — rejected for security" >&2
    exit 2
  fi

  # SEC-010: Reject path traversal
  case "$OUTPUT_FILE" in
    *..*)
      echo "ERROR: Output file path contains '..' — rejected for security" >&2
      exit 2
      ;;
  esac

  # SEC-010: Allowlist validation — reject special characters
  if [[ ! "$OUTPUT_FILE" =~ ^[a-zA-Z0-9_/.\-]+$ ]]; then
    echo "ERROR: Output file path contains invalid characters — rejected for security" >&2
    exit 2
  fi

  # Ensure parent directory exists
  OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
  if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "ERROR: Output directory does not exist: $OUTPUT_DIR" >&2
    exit 2
  fi
fi

# ─── Validation: model allowlist ──────────────────────────────────────────────
MODEL=$(echo "$MODEL" | tr '[:upper:]' '[:lower:]')
CODEX_MODEL_ALLOWLIST='^gpt-5(\.[0-9]{1,3})?-codex(-spark)?$'
if [[ ! "$MODEL" =~ $CODEX_MODEL_ALLOWLIST ]]; then
  _trace "WARN: Model '$MODEL' rejected by allowlist — falling back to gpt-5.3-codex"
  echo "WARN: Model '$MODEL' not in allowlist — using gpt-5.3-codex" >&2
  MODEL="gpt-5.3-codex"
fi

# ─── Validation: reasoning allowlist ──────────────────────────────────────────
case "$REASONING" in
  xhigh|high|medium|low) ;;
  *)
    _trace "WARN: Reasoning '$REASONING' invalid — falling back to xhigh"
    echo "WARN: Reasoning '$REASONING' not in [xhigh, high, medium, low] — using xhigh" >&2
    REASONING="xhigh"
    ;;
esac

# ─── Validation: timeout clamping [300, 900] ─────────────────────────────────
# Strip non-numeric characters first
# Minimum 300s (5 min) ensures xhigh reasoning has sufficient time.
# Maximum 900s (15 min) prevents runaway Codex sessions.
TIMEOUT=$(echo "$TIMEOUT" | tr -cd '0-9')
TIMEOUT=${TIMEOUT:-600}
if [[ "$TIMEOUT" -lt 300 ]]; then
  TIMEOUT=300
elif [[ "$TIMEOUT" -gt 900 ]]; then
  TIMEOUT=900
fi

# ─── Validation: stream idle (numeric) ────────────────────────────────────────
STREAM_IDLE=$(echo "$STREAM_IDLE" | tr -cd '0-9')
STREAM_IDLE=${STREAM_IDLE:-540000}

# ─── Validation: kill-after (numeric, 0=disable) ─────────────────────────────
KILL_AFTER=$(echo "$KILL_AFTER" | tr -cd '0-9')
KILL_AFTER=${KILL_AFTER:-30}

# ─── Pre-flight: codex CLI ────────────────────────────────────────────────────
if ! command -v codex &>/dev/null; then
  echo "ERROR: codex CLI not found — install via: npm install -g @openai/codex" >&2
  exit 1
fi

# ─── Pre-flight: .codexignore (required for --full-auto) ─────────────────────
if [[ ! -f .codexignore ]]; then
  echo "ERROR: .codexignore not found — required for --full-auto mode" >&2
  echo "Create .codexignore at repo root before running codex exec" >&2
  exit 2
fi

# ─── Pre-flight: timeout command ──────────────────────────────────────────────
HAS_TIMEOUT=0
KILL_AFTER_FLAG=""
if command -v timeout &>/dev/null; then
  HAS_TIMEOUT=1
  # Probe --kill-after support (macOS coreutils may not have it)
  if [[ "$KILL_AFTER" -gt 0 ]]; then
    if timeout --kill-after=1 0.1 true &>/dev/null; then
      KILL_AFTER_FLAG="--kill-after=${KILL_AFTER}"
    else
      _trace "WARN: timeout --kill-after not supported on this system"
    fi
  fi
else
  echo "WARN: timeout command not found — using background watchdog for timeout" >&2
fi

# ─── Background watchdog (when timeout command unavailable) ──────────────────
# RUIN-001 FIX: Prevent indefinite hangs on macOS without GNU coreutils.
# Spawns a background subshell that kills the codex process after TIMEOUT seconds.
_watchdog_pid=""
_start_watchdog() {
  if [[ "$HAS_TIMEOUT" -eq 0 && "$TIMEOUT" -gt 0 ]]; then
    (
      sleep "$TIMEOUT" 2>/dev/null
      # Signal the main process group — codex is a child of this script
      kill -TERM $$ 2>/dev/null || true
      sleep 3
      kill -KILL $$ 2>/dev/null || true
    ) &
    _watchdog_pid=$!
    _trace "Watchdog PID=$_watchdog_pid will enforce ${TIMEOUT}s timeout"
  fi
}
_stop_watchdog() {
  if [[ -n "$_watchdog_pid" ]]; then
    kill "$_watchdog_pid" 2>/dev/null || true
    wait "$_watchdog_pid" 2>/dev/null || true
    _watchdog_pid=""
  fi
}
trap '_stop_watchdog' EXIT

# ─── Pre-flight: jq (for JSON mode) ──────────────────────────────────────────
if [[ "$JSON_MODE" -eq 1 ]]; then
  if ! command -v jq &>/dev/null; then
    echo "WARN: jq not found — falling back to non-JSON mode" >&2
    JSON_MODE=0
  fi
fi

# ─── Build command ────────────────────────────────────────────────────────────
_trace "EXEC model=$MODEL reasoning=$REASONING timeout=$TIMEOUT json=$JSON_MODE git_skip=$SKIP_GIT_CHECK file=$PROMPT_FILE output=$OUTPUT_FILE"

# Capture stderr to temp file for error classification
# QUAL-001 + FLAW-005 FIX: Compose traps instead of overwriting — capture existing EXIT trap
_existing_exit_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
_CLEANUP_FILES=()
_cleanup() {
  rm -f "${_CLEANUP_FILES[@]}" 2>/dev/null || true
  # FLAW-005: Run the previously registered EXIT trap (watchdog cleanup)
  if [[ -n "$_existing_exit_trap" ]]; then
    eval "$_existing_exit_trap" 2>/dev/null || true
  fi
}
trap '_rc=$?; _cleanup; exit $_rc' EXIT

# Start watchdog before execution (only activates when timeout cmd unavailable)
_start_watchdog
STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-stderr-XXXXXX")
_CLEANUP_FILES+=("$STDERR_FILE")

# Build codex exec flags array
CODEX_FLAGS=()
CODEX_FLAGS+=(-m "$MODEL")
CODEX_FLAGS+=(--config "model_reasoning_effort=$REASONING")
CODEX_FLAGS+=(--config "stream_idle_timeout_ms=$STREAM_IDLE")
CODEX_FLAGS+=(--sandbox read-only)
CODEX_FLAGS+=(--full-auto)

if [[ "$SKIP_GIT_CHECK" -eq 1 ]]; then
  CODEX_FLAGS+=(--skip-git-repo-check)
fi

if [[ "$JSON_MODE" -eq 1 ]]; then
  CODEX_FLAGS+=(--json)
fi

# The `-` at the end tells codex to read prompt from stdin (SEC-009)
CODEX_FLAGS+=(-)

# ─── Execute ──────────────────────────────────────────────────────────────────
CODEX_EXIT=0

if [[ -n "$OUTPUT_FILE" ]]; then
  # File-write mode: redirect stdout to output file via atomic tmp+mv
  OUTPUT_TMP="${OUTPUT_FILE}.tmp"
  _CLEANUP_FILES+=("$OUTPUT_TMP")

  if [[ "$JSON_MODE" -eq 1 ]]; then
    # JSON mode + file output: jq filter BEFORE redirect (SEC-010a)
    if [[ "$HAS_TIMEOUT" -eq 1 ]]; then
      set +o pipefail
      cat "$PROMPT_FILE" | timeout ${KILL_AFTER_FLAG:+"$KILL_AFTER_FLAG"} "$TIMEOUT" codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" | \
        jq -r 'select(.type == "item.completed" and .item.type == "agent_message") | .item.text' > "$OUTPUT_TMP"
      _ps=("${PIPESTATUS[@]}"); CODEX_EXIT="${_ps[1]}"
      set -o pipefail
    else
      set +o pipefail
      cat "$PROMPT_FILE" | codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" | \
        jq -r 'select(.type == "item.completed" and .item.type == "agent_message") | .item.text' > "$OUTPUT_TMP"
      _ps=("${PIPESTATUS[@]}"); CODEX_EXIT="${_ps[1]}"
      set -o pipefail
    fi
  else
    # Raw mode + file output
    if [[ "$HAS_TIMEOUT" -eq 1 ]]; then
      cat "$PROMPT_FILE" | timeout ${KILL_AFTER_FLAG:+"$KILL_AFTER_FLAG"} "$TIMEOUT" codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" > "$OUTPUT_TMP" || CODEX_EXIT=$?
    else
      cat "$PROMPT_FILE" | codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" > "$OUTPUT_TMP" || CODEX_EXIT=$?
    fi
  fi

  # Atomic move on success (prevents partial file reads by downstream consumers)
  if [[ "$CODEX_EXIT" -eq 0 ]] && [[ -s "$OUTPUT_TMP" ]]; then
    mv "$OUTPUT_TMP" "$OUTPUT_FILE"
  elif [[ "$CODEX_EXIT" -eq 0 ]] && [[ ! -s "$OUTPUT_TMP" ]]; then
    # Codex succeeded but produced empty output — write marker so downstream exists() checks pass
    echo "(No output from Codex)" > "$OUTPUT_FILE"
    rm -f "$OUTPUT_TMP"
  elif [[ "$CODEX_EXIT" -eq 124 ]] && [[ -s "$OUTPUT_TMP" ]]; then
    # Timeout with partial output — move for debugging
    mv "$OUTPUT_TMP" "$OUTPUT_FILE"
  else
    # Other error — remove tmp, don't create output file (let caller handle skip path)
    rm -f "$OUTPUT_TMP"
  fi
else
  # Current behavior — stdout passthrough (unchanged)
  if [[ "$JSON_MODE" -eq 1 ]]; then
    # JSON mode: pipe through jq to extract agent message text
    if [[ "$HAS_TIMEOUT" -eq 1 ]]; then
      set +o pipefail
      cat "$PROMPT_FILE" | timeout ${KILL_AFTER_FLAG:+"$KILL_AFTER_FLAG"} "$TIMEOUT" codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" | \
        jq -r 'select(.type == "item.completed" and .item.type == "agent_message") | .item.text'
      _ps=("${PIPESTATUS[@]}"); CODEX_EXIT="${_ps[1]}"
      set -o pipefail
    else
      set +o pipefail
      cat "$PROMPT_FILE" | codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" | \
        jq -r 'select(.type == "item.completed" and .item.type == "agent_message") | .item.text'
      _ps=("${PIPESTATUS[@]}"); CODEX_EXIT="${_ps[1]}"
      set -o pipefail
    fi
  else
    # Raw mode: direct output
    if [[ "$HAS_TIMEOUT" -eq 1 ]]; then
      cat "$PROMPT_FILE" | timeout ${KILL_AFTER_FLAG:+"$KILL_AFTER_FLAG"} "$TIMEOUT" codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" || CODEX_EXIT=$?
    else
      cat "$PROMPT_FILE" | codex exec "${CODEX_FLAGS[@]}" 2>"$STDERR_FILE" || CODEX_EXIT=$?
    fi
  fi
fi

# ─── Error classification ────────────────────────────────────────────────────
if [[ "$CODEX_EXIT" -ne 0 ]]; then
  STDERR_CONTENT=""
  if [[ -f "$STDERR_FILE" ]]; then
    STDERR_CONTENT=$(head -c 2048 "$STDERR_FILE" 2>/dev/null || true)
  fi

  _trace "FAIL exit=$CODEX_EXIT stderr=$(echo "$STDERR_CONTENT" | head -c 200)"

  # Classify error based on exit code and stderr content
  case "$CODEX_EXIT" in
    124)
      echo "CODEX_ERROR[OUTER_TIMEOUT]: Codex timed out after ${TIMEOUT}s — increase timeout or reduce context" >&2
      ;;
    137)
      echo "CODEX_ERROR[KILL_TIMEOUT]: Codex killed after grace period — process hung" >&2
      ;;
    134)
      # BACK-P3-009: Distinguish abort (SIGABRT) from timeout
      echo "CODEX_ERROR[CRASH_ABORT]: Codex process aborted (SIGABRT) — possible runtime panic" >&2
      ;;
    139)
      # BACK-P3-009: Distinguish segfault (SIGSEGV) from timeout
      echo "CODEX_ERROR[CRASH_SEGFAULT]: Codex process crashed (SIGSEGV)" >&2
      ;;
    *)
      # Pattern-match stderr content for known errors
      if echo "$STDERR_CONTENT" | grep -qiE 'not authenticated|auth'; then
        echo "CODEX_ERROR[AUTH]: Authentication required — run \`codex login\`" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'rate limit|429'; then
        echo "CODEX_ERROR[RATE_LIMIT]: API rate limit — try again later" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'model not found|invalid model'; then
        echo "CODEX_ERROR[MODEL]: Model unavailable — check talisman.codex.model" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'network|connection|ECON'; then
        echo "CODEX_ERROR[NETWORK]: Network error — check internet connection" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'stream idle|stream_idle_timeout'; then
        echo "CODEX_ERROR[STREAM_IDLE]: No output for stream idle period — increase stream_idle_timeout" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'quota|insufficient_quota|402'; then
        echo "CODEX_ERROR[QUOTA]: Quota exceeded — check OpenAI billing" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'context_length|too many tokens'; then
        echo "CODEX_ERROR[CONTEXT_LENGTH]: Context too large — reduce content" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'sandbox|permission denied'; then
        echo "CODEX_ERROR[SANDBOX]: Sandbox restriction — check .codexignore" >&2
      elif echo "$STDERR_CONTENT" | grep -qiE 'version|upgrade|deprecated'; then
        echo "CODEX_ERROR[VERSION]: CLI version issue — run \`npm update -g @openai/codex\`" >&2
      else
        echo "CODEX_ERROR[UNKNOWN]: codex exec failed (exit $CODEX_EXIT) — run manually to debug" >&2
      fi
      ;;
  esac
fi

exit "$CODEX_EXIT"
