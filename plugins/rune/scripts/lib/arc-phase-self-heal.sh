#!/usr/bin/env bash
# lib/arc-phase-self-heal.sh — Artifact-mtime self-heal for in_progress phases
#
# Implements Iron Law ARC-QA-002 "Stop Hook Self-Heal Precedence" (plan AC-4).
#
# WHY THIS EXISTS
# ---------------
# The stop hook picks the next phase by scanning PHASE_ORDER for the first
# status=="pending" entry. If a QA verifier is still initializing while the
# Stop hook fires, the QA phase is `in_progress` (not `pending`), so the
# scanner skips it and picks the next phase — bypassing the retry loop and
# silently accepting a failed verdict that lands on disk moments later.
#
# This helper closes the race by inspecting every `in_progress` phase BEFORE
# the scanner runs. For each one, it checks whether a durable artifact has
# landed on disk with mtime > started_at. If so, it flips the phase to
# `completed` and records `self_healed: true` so qa-gate-check.sh can read
# the late-arriving verdict and run the retry loop.
#
# SCOPE (v1 — matches plan AC-4 evidence set)
# -------------------------------------------
# Covers QA phases only: forge_qa, work_qa, gap_analysis_qa, code_review_qa,
# mend_qa, test_qa, design_verification_qa. Non-QA phase self-heal (sentinel
# discovery in .done/*.done) is future work — the qa-gate-check.sh feedback
# loop is the critical protection surface.
#
# USAGE
# -----
# Sourced by arc-phase-stop-hook.sh before _phase_find_next:
#   source "${SCRIPT_DIR}/lib/arc-phase-self-heal.sh"
#   CKPT_CONTENT=$(_arc_phase_self_heal "$CKPT_CONTENT" \
#     "${CWD}/tmp/arc/${_ARC_ID_FOR_LOG}" \
#     "$_ARC_ID_FOR_LOG" \
#     "$CHECKPOINT_PATH")
#
# CONTRACT
# --------
# Input (positional): ckpt_json arc_dir arc_id ckpt_path
# Output: possibly-modified checkpoint JSON on stdout; if any heals occurred,
#         the checkpoint file is also rewritten atomically on disk.
# Failure mode: fail-forward — any internal error returns the ORIGINAL ckpt_json
#               unchanged so the caller never breaks. Warnings go to _trace.
#
# SAFETY RAILS
# ------------
# - artifact mtime MUST be greater than phases[X].started_at (defeats pre-existing
#   files from prior runs — ARC-QA-001 verify-before-skip discipline).
# - verdict JSON MUST parse as valid JSON before healing (prevents healing from
#   a truncated mid-write file — see plan Risk #1).
# - If jq is missing, returns original content unchanged (fail-forward).
# - If arc_id/arc_dir fail SEC validation, returns original content unchanged.

# Guard against double-source
if [[ -n "${_ARC_PHASE_SELF_HEAL_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_ARC_PHASE_SELF_HEAL_LOADED=1

# Platform helpers (for _stat_mtime, _parse_iso_epoch)
if [[ -z "${_RUNE_PLATFORM:-}" ]]; then
  _SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  [[ -f "${_SH_DIR}/platform.sh" ]] && source "${_SH_DIR}/platform.sh"
fi

# Private trace — reuses parent _trace if available, otherwise no-op
_ash_trace() {
  if declare -F _trace >/dev/null 2>&1; then
    _trace "self-heal: $*"
  fi
}

# Map a phase name to the expected artifact path within an arc directory.
# Returns empty string for unsupported phases (caller skips them).
_ash_phase_artifact_path() {
  local _phase="$1" _arc_dir="$2"
  case "$_phase" in
    forge_qa|work_qa|gap_analysis_qa|code_review_qa|mend_qa|test_qa|design_verification_qa)
      # QA phases write to tmp/arc/{id}/qa/{parent}-verdict.json
      local _parent="${_phase%_qa}"
      printf '%s/qa/%s-verdict.json' "$_arc_dir" "$_parent"
      ;;
    *)
      printf ''
      ;;
  esac
}

# Validate that a verdict JSON file is well-formed enough to heal from.
# Returns 0 if valid, 1 otherwise. Quiet — errors logged via _ash_trace.
_ash_verdict_valid() {
  local _path="$1"
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  # Empty file → invalid
  [[ -s "$_path" ]] || return 1
  # Must parse as JSON object (not array, not scalar — a verdict is always {...})
  local _type
  _type=$(jq -r 'type' "$_path" 2>/dev/null || echo "error")
  [[ "$_type" == "object" ]] || return 1
  return 0
}

# Core self-heal function.
# Emits updated checkpoint JSON to stdout. On any internal failure, emits the
# original ckpt_json unchanged (fail-forward).
_arc_phase_self_heal() {
  local _ckpt_json="$1" _arc_dir="$2" _arc_id="$3" _ckpt_path="$4"

  # Short-circuit — bail out cleanly on missing inputs
  if [[ -z "$_ckpt_json" || -z "$_arc_dir" || -z "$_arc_id" || -z "$_ckpt_path" ]]; then
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # SEC: arc_id format must match the same regex used elsewhere in the hook
  if [[ ! "$_arc_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    _ash_trace "SKIP: arc_id failed SEC validation: ${_arc_id}"
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # SEC: arc_dir must exist and be a real directory (reject symlinks)
  if [[ ! -d "$_arc_dir" || -L "$_arc_dir" ]]; then
    _ash_trace "SKIP: arc_dir missing or symlink: ${_arc_dir}"
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # Tool gate — jq is required for checkpoint manipulation
  if ! command -v jq >/dev/null 2>&1; then
    _ash_trace "SKIP: jq unavailable"
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # Enumerate in_progress phases with their started_at timestamps.
  # TSV output: phase\tstarted_at per line. jq failure → no phases to heal.
  local _phases_tsv
  _phases_tsv=$(printf '%s' "$_ckpt_json" | jq -r '
    .phases // {} | to_entries
    | map(select(.value.status == "in_progress"))
    | map("\(.key)\t\(.value.started_at // "")")
    | .[]
  ' 2>/dev/null || true)

  if [[ -z "$_phases_tsv" ]]; then
    # Nothing to heal — fast path
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # Iterate candidates. Healed phases accumulate as TSV: phase\tartifact\tmtime.
  local _heals=""
  local _line _phase _started_at _artifact _started_epoch _artifact_mtime
  while IFS=$'\t' read -r _phase _started_at; do
    [[ -z "$_phase" ]] && continue

    _artifact=$(_ash_phase_artifact_path "$_phase" "$_arc_dir")
    if [[ -z "$_artifact" ]]; then
      _ash_trace "skip ${_phase}: no artifact mapping (non-QA phase)"
      continue
    fi

    # Verdict file must exist and parse as JSON object
    if ! _ash_verdict_valid "$_artifact"; then
      _ash_trace "skip ${_phase}: verdict missing or invalid at ${_artifact}"
      continue
    fi

    # Parse started_at to epoch. Missing/unparseable → cannot safely heal
    # (the mtime>started_at guard is what defeats stale files from prior runs).
    _started_epoch=$(_parse_iso_epoch "$_started_at" 2>/dev/null || echo "0")
    if [[ -z "$_started_epoch" || "$_started_epoch" == "0" ]]; then
      _ash_trace "skip ${_phase}: unparseable started_at='${_started_at}'"
      continue
    fi

    _artifact_mtime=$(_stat_mtime "$_artifact" 2>/dev/null || echo "")
    if [[ -z "$_artifact_mtime" || ! "$_artifact_mtime" =~ ^[0-9]+$ ]]; then
      _ash_trace "skip ${_phase}: mtime unreadable at ${_artifact}"
      continue
    fi

    if (( _artifact_mtime <= _started_epoch )); then
      _ash_trace "skip ${_phase}: artifact mtime ${_artifact_mtime} <= started ${_started_epoch} (stale)"
      continue
    fi

    _ash_trace "HEAL ${_phase}: artifact ${_artifact} mtime=${_artifact_mtime} > started=${_started_epoch}"
    # SEC: artifact path escapes will be quoted by jq --arg; no shell interpolation
    _heals+="${_phase}"$'\t'"${_artifact}"$'\t'"${_artifact_mtime}"$'\n'
  done <<< "$_phases_tsv"

  # No heals? Return unchanged
  if [[ -z "$_heals" ]]; then
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # Build a heals JSON array for jq reduction
  local _heals_json
  _heals_json=$(printf '%s' "$_heals" | jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({phase: .[0], artifact: .[1], mtime: (.[2] | tonumber)})
  ' 2>/dev/null || echo "[]")

  if [[ -z "$_heals_json" || "$_heals_json" == "[]" ]]; then
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # Apply heals: for each, set phases[X].status=completed, self_healed=true,
  # artifact=<path>, completed_at=<ISO8601 from mtime>. Also append a log entry
  # so operators can audit the heal decision later.
  local _now_iso
  _now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

  local _merged
  _merged=$(printf '%s' "$_ckpt_json" | jq --argjson heals "$_heals_json" --arg now "$_now_iso" '
    . as $ckpt
    | reduce $heals[] as $h ($ckpt;
        .phases[$h.phase].status = "completed"
        | .phases[$h.phase].self_healed = true
        | .phases[$h.phase].artifact = $h.artifact
        | .phases[$h.phase].completed_at = (
            ($h.mtime | todate)
          )
        | .phases[$h.phase].self_heal_reason = "artifact_mtime_greater_than_started_at"
      )
    | .self_heal_log = ((.self_heal_log // []) + ($heals | map({
        phase: .phase,
        artifact: .artifact,
        artifact_mtime: .mtime,
        healed_at: $now,
        reason: "artifact_mtime_greater_than_started_at"
      })))
  ' 2>/dev/null || true)

  if [[ -z "$_merged" ]]; then
    _ash_trace "merge failed — returning original checkpoint"
    printf '%s' "$_ckpt_json"
    return 0
  fi

  # Atomic write to disk: tmp + mv. Preserves file mode implicitly (new file
  # inherits umask; same as checkpoint-update.sh behaviour).
  local _ckpt_dir _tmp
  _ckpt_dir=$(dirname "$_ckpt_path")
  if [[ ! -d "$_ckpt_dir" ]]; then
    _ash_trace "checkpoint dir missing (${_ckpt_dir}) — returning in-memory only"
    printf '%s' "$_merged"
    return 0
  fi

  _tmp=$(mktemp "${_ckpt_dir}/.self-heal-XXXXXX" 2>/dev/null || true)
  if [[ -z "$_tmp" ]]; then
    _ash_trace "mktemp failed — returning in-memory only"
    printf '%s' "$_merged"
    return 0
  fi

  if ! printf '%s\n' "$_merged" > "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    _ash_trace "tmp write failed — returning in-memory only"
    printf '%s' "$_merged"
    return 0
  fi

  if ! mv -f "$_tmp" "$_ckpt_path" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    _ash_trace "atomic rename failed — returning in-memory only"
    printf '%s' "$_merged"
    return 0
  fi

  _ash_trace "wrote self-healed checkpoint to ${_ckpt_path}"
  printf '%s' "$_merged"
  return 0
}
