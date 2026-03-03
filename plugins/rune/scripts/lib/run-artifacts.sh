#!/bin/bash
# scripts/lib/run-artifacts.sh
# Per-agent structured artifact writer for Rune workflows.
# Source this file — do not execute directly.
#
# Exports:
#   rune_artifact_init(workflow, timestamp, agent_name)     — Create run dir, write initial meta.json
#   rune_artifact_init_at(output_dir, agent_name, workflow) — Create run dir under existing output dir
#   rune_artifact_write_input(run_dir, prompt_content)      — Write input.md (agent prompt/input)
#   rune_artifact_finalize(run_dir, status, output_file)    — Update meta.json with completion data
#   rune_artifact_index_append(index_file, run_dir)         — Append JSONL row from meta.json to index
#
# Run dir: tmp/{workflow}/{timestamp}/runs/{agent-name}/
# Artifacts: meta.json, input.md
# Index: run-index.jsonl (JSONL, one row per agent per status change)
#
# Uses: resolve-session-identity.sh (RUNE_CURRENT_CFG, rune_pid_alive) — soft dep
# Requires: jq (fail-open stubs if missing)

# Source guard — only load once
[[ -n "${_RUNE_ARTIFACTS_LOADED:-}" ]] && return 0
_RUNE_ARTIFACTS_LOADED=1

# zsh-compat: BASH_SOURCE is empty in zsh; fall back to $0 for sourced scripts
if [[ -n "${BASH_VERSION:-}" ]]; then
  _RUNE_ART_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _RUNE_ART_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Soft dep: resolve-session-identity.sh provides RUNE_CURRENT_CFG + rune_pid_alive
if [[ -f "${_RUNE_ART_SCRIPT_DIR}/../resolve-session-identity.sh" ]]; then
  source "${_RUNE_ART_SCRIPT_DIR}/../resolve-session-identity.sh"
fi

# Resolve project root (git root or CWD)
if command -v git &>/dev/null; then
  _RUNE_ART_ROOT="$(git -C "$_RUNE_ART_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\n' || true)"
fi
_RUNE_ART_PATTERN='^/[a-zA-Z0-9_./ -]+$'
if [[ -z "${_RUNE_ART_ROOT:-}" ]] || [[ ! "$_RUNE_ART_ROOT" =~ $_RUNE_ART_PATTERN ]]; then
  _RUNE_ART_ROOT="$(pwd)"
fi

# jq dependency guard — fail-open stubs if jq missing
if ! command -v jq &>/dev/null; then
  echo "[rune-artifacts] WARNING: jq not found — artifact tracking disabled" >&2
  rune_artifact_init() { echo ""; return 0; }
  rune_artifact_init_at() { echo ""; return 0; }
  rune_artifact_write_input() { return 0; }
  rune_artifact_finalize() { return 0; }
  rune_artifact_index_append() { return 0; }
  return 0 2>/dev/null || exit 0
fi

# ── Input validation ──

# Validate workflow name: alphanumeric, hyphens, underscores
_rune_artifact_validate_workflow() {
  local name="$1"
  [[ -n "$name" && "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
}

# Validate agent name: alphanumeric, hyphens, underscores
_rune_artifact_validate_agent() {
  local name="$1"
  [[ -n "$name" && "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
}

# Validate timestamp: digits only
_rune_artifact_validate_timestamp() {
  local ts="$1"
  [[ -n "$ts" && "$ts" =~ ^[0-9]+$ ]] || return 1
}

# SEC: Reject path traversal in any component
_rune_artifact_reject_traversal() {
  local val="$1"
  [[ "$val" != *".."* ]] || return 1
}

# SEC: Symlink guard — refuse to operate on symlinked paths
_rune_artifact_safe_path() {
  [[ ! -L "$1" ]] || return 1
}

# ── Public functions ──

# rune_artifact_init <workflow> <timestamp> <agent-name> [team-name]
# Creates run directory and writes initial meta.json with status "running".
# Run directory: tmp/{workflow}/{timestamp}/runs/{agent-name}/
# Prints the run directory path to stdout. Returns 0 on success, 1 on failure.
rune_artifact_init() {
  local workflow="$1" timestamp="$2" agent_name="$3" team_name="${4:-}"

  # Validate inputs
  _rune_artifact_validate_workflow "$workflow" || {
    echo "[rune-artifacts] ERROR: invalid workflow name: $workflow" >&2
    return 1
  }
  _rune_artifact_validate_timestamp "$timestamp" || {
    echo "[rune-artifacts] ERROR: invalid timestamp: $timestamp" >&2
    return 1
  }
  _rune_artifact_validate_agent "$agent_name" || {
    echo "[rune-artifacts] ERROR: invalid agent name: $agent_name" >&2
    return 1
  }

  # Reject path traversal
  _rune_artifact_reject_traversal "$workflow" || return 1
  _rune_artifact_reject_traversal "$timestamp" || return 1
  _rune_artifact_reject_traversal "$agent_name" || return 1

  local run_dir="${_RUNE_ART_ROOT}/tmp/${workflow}/${timestamp}/runs/${agent_name}"

  _rune_artifact_create_run "$run_dir" "$agent_name" "$workflow" "$team_name"
}

# rune_artifact_init_at <output-dir> <agent-name> <workflow> [team-name]
# Creates run directory under an existing output directory.
# Run directory: {output-dir}/runs/{agent-name}/
# Use this when outputDir is already known (e.g., roundtable circle, strive).
# Prints the run directory path to stdout. Returns 0 on success, 1 on failure.
rune_artifact_init_at() {
  local output_dir="$1" agent_name="$2" workflow="$3" team_name="${4:-}"

  # Validate agent name
  _rune_artifact_validate_agent "$agent_name" || {
    echo "[rune-artifacts] ERROR: invalid agent name: $agent_name" >&2
    return 1
  }

  # Reject path traversal
  _rune_artifact_reject_traversal "$output_dir" || return 1
  _rune_artifact_reject_traversal "$agent_name" || return 1

  # Validate output_dir exists
  [[ -d "$output_dir" ]] || {
    echo "[rune-artifacts] ERROR: output dir does not exist: $output_dir" >&2
    return 1
  }
  _rune_artifact_safe_path "$output_dir" || {
    echo "[rune-artifacts] ERROR: output dir is a symlink: $output_dir" >&2
    return 1
  }

  # Strip trailing slash for consistency
  output_dir="${output_dir%/}"
  local run_dir="${output_dir}/runs/${agent_name}"

  _rune_artifact_create_run "$run_dir" "$agent_name" "${workflow:-unknown}" "$team_name"
}

# _rune_artifact_create_run <run-dir> <agent-name> <workflow> <team-name>
# Internal helper — creates run directory and writes initial meta.json.
_rune_artifact_create_run() {
  local run_dir="$1" agent_name="$2" workflow="$3" team_name="${4:-}"

  # Create run directory
  if ! mkdir -p "$run_dir" 2>/dev/null; then
    echo "[rune-artifacts] ERROR: failed to create run dir: $run_dir" >&2
    return 1
  fi

  # Symlink guard on created directory
  _rune_artifact_safe_path "$run_dir" || {
    echo "[rune-artifacts] ERROR: run dir is a symlink: $run_dir" >&2
    return 1
  }

  # Session identity
  local _cfg="${RUNE_CURRENT_CFG:-$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")}"

  # Write initial meta.json atomically
  jq -n \
    --arg agent "$agent_name" \
    --arg wf "$workflow" \
    --arg team "${team_name}" \
    --arg tstat "running" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cfg "$_cfg" \
    --argjson pid "$PPID" \
    --arg sid "${CLAUDE_SESSION_ID:-unknown}" \
    '{
      agent_name: $agent,
      workflow: $wf,
      team_name: $team,
      status: $tstat,
      started_at: $started,
      completed_at: null,
      duration_seconds: null,
      output_bytes: null,
      config_dir: $cfg,
      owner_pid: $pid,
      session_id: $sid
    }' \
    > "$run_dir/meta.json.tmp" 2>/dev/null \
    && mv -f "$run_dir/meta.json.tmp" "$run_dir/meta.json" 2>/dev/null

  # Verify meta.json was written
  if [[ ! -f "$run_dir/meta.json" ]]; then
    echo "[rune-artifacts] ERROR: failed to write meta.json" >&2
    rm -rf "$run_dir" 2>/dev/null
    return 1
  fi

  # Append start row to run-index.jsonl (best-effort)
  _rune_artifact_append_index "$run_dir"

  # Output run directory path
  echo "$run_dir"
  return 0
}

# _rune_artifact_resolve_index_path <run_dir>
# Resolves the run-index.jsonl path from a run directory.
# run_dir is .../runs/{agent}/ — index lives two levels up at .../run-index.jsonl
_rune_artifact_resolve_index_path() {
  local run_dir="$1"
  # Go up from runs/{agent}/ to the workflow output directory
  local base_dir
  base_dir="$(cd "$run_dir/../.." 2>/dev/null && pwd -P || true)"
  [[ -n "$base_dir" ]] && echo "$base_dir/run-index.jsonl"
}

# _rune_artifact_append_index <run_dir>
# Internal helper — appends a JSONL row from meta.json to run-index.jsonl.
# Best-effort: failures are silently ignored.
_rune_artifact_append_index() {
  local run_dir="$1"
  local meta_file="$run_dir/meta.json"
  [[ -f "$meta_file" ]] || return 0

  local index_file
  index_file="$(_rune_artifact_resolve_index_path "$run_dir")"
  [[ -n "$index_file" ]] || return 0

  # Extract compact JSONL row from meta.json
  local row
  row=$(jq -c '{agent_name, status, started_at, completed_at, duration_seconds, output_bytes}' "$meta_file" 2>/dev/null || true)
  [[ -n "$row" ]] || return 0

  # Append with flock if available, else best-effort
  if command -v flock &>/dev/null; then
    (flock -w 2 200 && printf '%s\n' "$row" >> "$index_file") 200>"$index_file.lock" 2>/dev/null || \
      printf '%s\n' "$row" >> "$index_file" 2>/dev/null
  else
    printf '%s\n' "$row" >> "$index_file" 2>/dev/null
  fi
  return 0
}

# rune_artifact_index_append <index_file> <run_dir>
# Public API — appends a JSONL row from run_dir/meta.json to the given index file.
# Returns 0 on success, 1 on failure.
rune_artifact_index_append() {
  local index_file="$1" run_dir="$2"
  local meta_file="$run_dir/meta.json"

  [[ -f "$meta_file" ]] || {
    echo "[rune-artifacts] ERROR: meta.json not found in: $run_dir" >&2
    return 1
  }
  _rune_artifact_reject_traversal "$index_file" || return 1
  _rune_artifact_reject_traversal "$run_dir" || return 1

  local row
  row=$(jq -c '{agent_name, status, started_at, completed_at, duration_seconds, output_bytes}' "$meta_file" 2>/dev/null || true)
  [[ -n "$row" ]] || {
    echo "[rune-artifacts] ERROR: failed to read meta.json" >&2
    return 1
  }

  # Append with flock if available, else best-effort
  if command -v flock &>/dev/null; then
    (flock -w 2 200 && printf '%s\n' "$row" >> "$index_file") 200>"$index_file.lock" 2>/dev/null || \
      printf '%s\n' "$row" >> "$index_file" 2>/dev/null
  else
    printf '%s\n' "$row" >> "$index_file" 2>/dev/null
  fi
  return 0
}

# rune_artifact_write_input <run_dir> <prompt_content>
# Writes input.md containing the agent's prompt/input text.
# Returns 0 on success, 1 on failure.
rune_artifact_write_input() {
  local run_dir="$1" prompt_content="$2"

  # Validate run_dir exists and is not a symlink
  [[ -d "$run_dir" ]] || {
    echo "[rune-artifacts] ERROR: run dir does not exist: $run_dir" >&2
    return 1
  }
  _rune_artifact_safe_path "$run_dir" || {
    echo "[rune-artifacts] ERROR: run dir is a symlink: $run_dir" >&2
    return 1
  }

  # Reject path traversal
  _rune_artifact_reject_traversal "$run_dir" || return 1

  # Write input.md atomically
  printf '%s\n' "$prompt_content" > "$run_dir/input.md.tmp" 2>/dev/null \
    && mv -f "$run_dir/input.md.tmp" "$run_dir/input.md" 2>/dev/null

  if [[ ! -f "$run_dir/input.md" ]]; then
    echo "[rune-artifacts] ERROR: failed to write input.md" >&2
    return 1
  fi

  return 0
}

# rune_artifact_finalize <run_dir> <status> [output_file]
# Updates meta.json with completion status, timestamp, duration, and output size.
# <status> must be one of: completed, failed, crashed
# [output_file] is optional — if provided, its byte size is recorded.
# Returns 0 on success, 1 on failure.
rune_artifact_finalize() {
  local run_dir="$1" completion_status="$2" output_file="${3:-}"

  # Validate run_dir exists and is not a symlink
  [[ -d "$run_dir" ]] || {
    echo "[rune-artifacts] ERROR: run dir does not exist: $run_dir" >&2
    return 1
  }
  _rune_artifact_safe_path "$run_dir" || {
    echo "[rune-artifacts] ERROR: run dir is a symlink: $run_dir" >&2
    return 1
  }

  # Reject path traversal
  _rune_artifact_reject_traversal "$run_dir" || return 1

  # Validate status
  case "$completion_status" in
    completed|failed|crashed) ;;
    *)
      echo "[rune-artifacts] ERROR: invalid status: $completion_status (must be completed|failed|crashed)" >&2
      return 1
      ;;
  esac

  # Read existing meta.json
  local meta_file="$run_dir/meta.json"
  [[ -f "$meta_file" ]] || {
    echo "[rune-artifacts] ERROR: meta.json not found in: $run_dir" >&2
    return 1
  }
  _rune_artifact_safe_path "$meta_file" || return 1

  # Calculate duration from started_at
  local started_at duration_seconds=0
  started_at=$(jq -r '.started_at // empty' "$meta_file" 2>/dev/null || true)
  if [[ -n "$started_at" ]]; then
    local start_epoch now_epoch
    # macOS date vs GNU date: try both formats
    # TZ=UTC ensures macOS date -jf interprets the ISO-8601 UTC timestamp correctly
    start_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || \
                  date -d "$started_at" +%s 2>/dev/null || echo "0")
    now_epoch=$(date -u +%s 2>/dev/null || echo "0")
    if [[ "$start_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ && "$start_epoch" -gt 0 ]]; then
      duration_seconds=$(( now_epoch - start_epoch ))
      [[ "$duration_seconds" -lt 0 ]] && duration_seconds=0
    fi
  fi

  # Calculate output bytes if output_file provided
  local output_bytes="null"
  if [[ -n "$output_file" && -f "$output_file" ]]; then
    _rune_artifact_safe_path "$output_file" || true
    # wc -c works on both macOS and Linux
    local byte_count
    byte_count=$(wc -c < "$output_file" 2>/dev/null | tr -d ' ' || echo "0")
    if [[ "$byte_count" =~ ^[0-9]+$ ]]; then
      output_bytes="$byte_count"
    fi
  fi

  # Update meta.json atomically via jq
  local completed_at
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq \
    --arg tstat "$completion_status" \
    --arg completed "$completed_at" \
    --argjson dur "$duration_seconds" \
    --argjson obytes "$output_bytes" \
    '.status = $tstat | .completed_at = $completed | .duration_seconds = $dur | .output_bytes = $obytes' \
    "$meta_file" \
    > "$meta_file.tmp" 2>/dev/null \
    && mv -f "$meta_file.tmp" "$meta_file" 2>/dev/null

  if [[ ! -f "$meta_file" ]]; then
    echo "[rune-artifacts] ERROR: failed to update meta.json" >&2
    return 1
  fi

  # Append completion row to run-index.jsonl (best-effort)
  _rune_artifact_append_index "$run_dir"

  return 0
}
