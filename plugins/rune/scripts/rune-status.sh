#!/usr/bin/env bash
# scripts/rune-status.sh
# Diagnostic script — show arc pipeline status for the current session.
#
# Usage: rune-status.sh [--json] [--arc-id <id>]
#   --json       Output structured JSON instead of human-readable box output
#   --arc-id ID  Target a specific arc checkpoint by ID
#
# Reads: ${RUNE_STATE}/arc/*/checkpoint.json (session-owned only)
# Shows: phase summary, per-phase timing (v19+), team roster, context metrics,
#        convergence status (mend/verify_mend)
#
# Falls back to grep/sed output when jq is unavailable (basic info only).

set -euo pipefail
trap 'exit 0' ERR
umask 077

# ── Parse args ──
JSON_MODE=false
TARGET_ARC_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)       JSON_MODE=true; shift ;;
    --arc-id)     TARGET_ARC_ID="${2:-}"; shift 2 ;;
    --arc-id=*)   TARGET_ARC_ID="${1#--arc-id=}"; shift ;;
    *)            shift ;;
  esac
done

# ── Source session identity (RUNE_CURRENT_CFG + rune_pid_alive) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/resolve-session-identity.sh"
source "${SCRIPT_DIR}/lib/platform.sh"
source "${SCRIPT_DIR}/lib/rune-state.sh"

# ── CWD (script is run from project root) ──
CWD="$(pwd -P)"

# ── Trace logging (opt-in via RUNE_TRACE=1) ──
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() {
  [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && \
    printf '[%s] rune-status: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"
  return 0
}

# ── jq availability ──
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# ── No-jq fallback: basic grep/sed output ──
_basic_output() {
  local ckpt="$1" arc_id="$2"
  echo "Arc: ${arc_id}"
  grep -oE '"plan_file": ?"[^"]+"' "$ckpt" 2>/dev/null | head -1 | \
    sed 's/.*: *"/  Plan: /; s/"$//' || true
  grep -oE '"status": ?"[^"]+"' "$ckpt" 2>/dev/null | \
    sed 's/.*: *"//; s/"//' | sort | uniq -c | sort -rn | \
    awk '{printf "  %s: %d\n", $2, $1}' || true
  echo "  (Install jq for full output)"
}

# ── Format duration from milliseconds ──
_fmt_ms() {
  local ms="${1:-0}"
  [[ ! "$ms" =~ ^[0-9]+$ ]] && echo "?" && return
  local s=$(( ms / 1000 ))
  if [[ $s -lt 60 ]]; then
    echo "${s}s"
  elif [[ $s -lt 3600 ]]; then
    printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

# ── Format ISO timestamp → elapsed-ago string ──
_fmt_ago() {
  local ts="${1:-}"
  [[ -z "$ts" || "$ts" == "null" ]] && echo "" && return
  local epoch_ts
  epoch_ts=$(_parse_iso_epoch "$ts")
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - epoch_ts ))
  [[ $elapsed -lt 0 ]] && elapsed=0
  _fmt_ms $(( elapsed * 1000 ))
}

# ── Status symbol for human output ──
_status_sym() {
  case "${1:-}" in
    completed)   printf '✓' ;;
    in_progress) printf '▶' ;;
    skipped)     printf '○' ;;
    cancelled)   printf '✗' ;;
    pending)     printf '·' ;;
    *)           printf '?' ;;
  esac
}

# ── Phase order (must match arc-phase-stop-hook.sh PHASE_ORDER exactly) ──
PHASE_ORDER=(
  forge forge_qa
  plan_review plan_refine verification semantic_verification
  design_extraction design_prototype task_decomposition work work_qa
  drift_review storybook_verification design_verification
  ux_verification gap_analysis gap_analysis_qa
  codex_gap_analysis gap_remediation
  inspect inspect_fix verify_inspect goldmask_verification
  code_review code_review_qa
  goldmask_correlation mend mend_qa
  verify_mend design_iteration
  test test_qa
  test_coverage_critique deploy_verify pre_ship_validation release_quality_check
  ship bot_review_wait pr_comment_resolution merge
)

# ── Find session-owned checkpoint files ──
CHECKPOINT_FILES=()
ARC_DIR="${CWD}/${RUNE_STATE}/arc"
# Legacy fallback (RUNE_LEGACY_SUPPORT_UNTIL=3.0.0)
ARC_DIR_LEGACY="${CWD}/.claude/arc"

if [[ -d "$ARC_DIR" ]] || [[ -d "$ARC_DIR_LEGACY" ]]; then
  shopt -s nullglob
  # Scan both .rune/arc/ and legacy .claude/arc/ for checkpoints
  for ckpt in "${ARC_DIR}"/*/checkpoint.json "${ARC_DIR_LEGACY}"/*/checkpoint.json; do
    [[ -f "$ckpt" ]] || continue
    [[ -L "$ckpt" ]] && continue

    arc_id="${ckpt%/checkpoint.json}"
    arc_id="${arc_id##*/}"

    # Validate arc_id format (SEC: path traversal prevention)
    [[ "$arc_id" =~ ^[a-zA-Z0-9_-]+$ ]] || continue

    # If --arc-id specified, filter to that arc only
    if [[ -n "$TARGET_ARC_ID" && "$arc_id" != "$TARGET_ARC_ID" ]]; then
      continue
    fi

    # Session ownership check (requires jq)
    if [[ "$HAS_JQ" == "true" ]]; then
      stored_cfg=$(jq -r '.config_dir // empty' "$ckpt" 2>/dev/null || true)
      stored_pid=$(jq -r '.owner_pid // empty' "$ckpt" 2>/dev/null || true)

      # Layer 1: config_dir check
      if [[ -n "$stored_cfg" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then
        _trace "Skipping ${arc_id}: config_dir mismatch"
        continue
      fi

      # Layer 2: owner_pid check
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
        if rune_pid_alive "$stored_pid"; then
          _trace "Skipping ${arc_id}: different live session (pid ${stored_pid})"
          continue
        fi
        _trace "Skipping ${arc_id}: orphaned checkpoint (pid ${stored_pid} dead) — skipping"
        if [[ "$JSON_MODE" != "true" ]]; then
          echo "  [orphaned arc ${arc_id} from dead session ${stored_pid} — run /rune:rest to clean]"
        fi
        continue
      fi
    fi

    CHECKPOINT_FILES+=("$ckpt")
  done
  shopt -u nullglob
fi

# ── No active arc ──
if [[ ${#CHECKPOINT_FILES[@]} -eq 0 ]]; then
  if [[ "$JSON_MODE" == "true" ]]; then
    jq -n '{"status":"no_active_arc","message":"No active arc found for this session."}' 2>/dev/null || \
      echo '{"status":"no_active_arc","message":"No active arc found for this session."}'
  else
    echo "No active arc found for this session."
    if [[ -n "$TARGET_ARC_ID" ]]; then
      echo "(arc-id '${TARGET_ARC_ID}' not found or belongs to another session)"
    fi
  fi
  exit 0
fi

# ── JSON output: wrap all results in array ──
if [[ "$JSON_MODE" == "true" ]]; then
  printf '['
fi

FIRST=true
for ckpt in "${CHECKPOINT_FILES[@]}"; do
  arc_id="${ckpt%/checkpoint.json}"
  arc_id="${arc_id##*/}"
  _trace "Processing checkpoint: ${arc_id}"

  # ── No-jq fallback ──
  if [[ "$HAS_JQ" == "false" ]]; then
    _basic_output "$ckpt" "$arc_id"
    continue
  fi

  # ── BACK-001 FIX: Single jq call with @tsv output (was 15+ individual subprocess calls) ──
  IFS=$'\t' read -r SCHEMA_VER PLAN_FILE SESSION_ID STARTED_AT COMPLETED_AT \
    CONV_ROUND CONV_MAX ARC_STATUS CNT_COMPLETED CNT_IN_PROGRESS CNT_PENDING \
    CNT_SKIPPED CNT_CANCELLED ACTIVE_PHASE ACTIVE_TEAM <<< "$(jq -r '[
      (.schema_version // 0),
      (.plan_file // "unknown"),
      (.session_id // ""),
      (.started_at // ""),
      (.completed_at // "null"),
      (.convergence.round // 0),
      (.convergence.max_rounds // 0),
      (if .phases | to_entries | map(select(.value.status == "in_progress")) | length > 0
       then "in_progress"
       elif .phases | to_entries | map(select(.value.status == "pending")) | length > 0
       then "active"
       else "completed" end),
      (.phases | to_entries | map(select(.value.status == "completed")) | length),
      (.phases | to_entries | map(select(.value.status == "in_progress")) | length),
      (.phases | to_entries | map(select(.value.status == "pending")) | length),
      (.phases | to_entries | map(select(.value.status == "skipped")) | length),
      (.phases | to_entries | map(select(.value.status == "cancelled")) | length),
      ((.phases | to_entries | map(select(.value.status == "in_progress")) | first | .key) // ""),
      ((.phases | to_entries | map(select(.value.status == "in_progress")) | first | .value.team_name) // "")
    ] | @tsv' "$ckpt" 2>/dev/null || echo "0	unknown				null	0	0	unknown	0	0	0	0	0		")"

  # Ensure numeric fields are actually numeric
  [[ "$SCHEMA_VER" =~ ^[0-9]+$ ]] || SCHEMA_VER="0"
  [[ "$CNT_COMPLETED" =~ ^[0-9]+$ ]] || CNT_COMPLETED="0"
  [[ "$CNT_IN_PROGRESS" =~ ^[0-9]+$ ]] || CNT_IN_PROGRESS="0"
  [[ "$CNT_PENDING" =~ ^[0-9]+$ ]] || CNT_PENDING="0"
  [[ "$CNT_SKIPPED" =~ ^[0-9]+$ ]] || CNT_SKIPPED="0"
  [[ "$CNT_CANCELLED" =~ ^[0-9]+$ ]] || CNT_CANCELLED="0"
  [[ "$CONV_ROUND" =~ ^[0-9]+$ ]] || CONV_ROUND="0"
  [[ "$CONV_MAX" =~ ^[0-9]+$ ]] || CONV_MAX="0"

  # ── Read bridge file for context metrics ──
  CTX_USED=""
  CTX_REM=""
  CTX_COST=""
  if [[ -n "$SESSION_ID" && "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}.json"
    if [[ -f "$BRIDGE_FILE" && ! -L "$BRIDGE_FILE" ]]; then
      B_MTIME=$(_stat_mtime "$BRIDGE_FILE"); B_MTIME="${B_MTIME:-0}"
      B_NOW=$(date +%s)
      B_AGE=$(( B_NOW - B_MTIME ))
      if [[ $B_AGE -lt 120 ]]; then
        bridge_raw=$(jq -r '[
          (.used_pct // "" | tostring),
          (.remaining_percentage // "" | tostring),
          (.cost // 0 | tostring)
        ] | @tsv' "$BRIDGE_FILE" 2>/dev/null || true)
        if [[ -n "$bridge_raw" ]]; then
          while IFS=$'\t' read -r b1 b2 b3; do
            CTX_USED="${b1:-}"
            CTX_REM="${b2:-}"
            CTX_COST="${b3:-}"
          done <<< "$bridge_raw"
        fi
      fi
    fi
  fi

  # ── Read heartbeat file for last activity ──
  HB_FILE="${CWD}/tmp/arc/${arc_id}/heartbeat.json"
  HB_PHASE=""
  HB_TOOL=""
  HB_ACTIVITY=""
  HB_AGO=""
  if [[ "$HAS_JQ" == "true" && -f "$HB_FILE" && ! -L "$HB_FILE" ]]; then
    HB_PHASE=$(jq -r '.phase // ""' "$HB_FILE" 2>/dev/null || true)
    HB_TOOL=$(jq -r '.last_tool // ""' "$HB_FILE" 2>/dev/null || true)
    HB_ACTIVITY=$(jq -r '.last_activity // ""' "$HB_FILE" 2>/dev/null || true)
    if [[ -n "$HB_ACTIVITY" && "$HB_ACTIVITY" != "null" ]]; then
      HB_AGO=$(_fmt_ago "$HB_ACTIVITY")
    fi
  fi

  # ── JSON output mode ──
  if [[ "$JSON_MODE" == "true" ]]; then
    [[ "$FIRST" == "false" ]] && printf ','
    FIRST=false

    # Build context sub-object
    if [[ "$CTX_USED" =~ ^[0-9]+(\.[0-9]+)?$ && "$CTX_REM" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      ctx_obj="{\"used_pct\":${CTX_USED},\"remaining_pct\":${CTX_REM}}"
    else
      ctx_obj="null"
    fi

    # Build heartbeat sub-object (for JSON output)
    if [[ -n "$HB_ACTIVITY" && "$HB_ACTIVITY" != "null" && -n "$HB_PHASE" ]]; then
      hb_obj="{\"phase\":\"${HB_PHASE}\",\"last_tool\":\"${HB_TOOL}\",\"last_activity\":\"${HB_ACTIVITY}\"}"
    else
      hb_obj="null"
    fi

    jq -n \
      --arg id "$arc_id" \
      --arg plan "$PLAN_FILE" \
      --arg arc_status "$ARC_STATUS" \
      --argjson completed "${CNT_COMPLETED}" \
      --argjson in_progress "${CNT_IN_PROGRESS}" \
      --argjson pending "${CNT_PENDING}" \
      --argjson skipped "${CNT_SKIPPED}" \
      --argjson cancelled "${CNT_CANCELLED}" \
      --arg active_phase "$ACTIVE_PHASE" \
      --arg active_team "$ACTIVE_TEAM" \
      --arg started_at "$STARTED_AT" \
      --argjson schema_ver "${SCHEMA_VER}" \
      --arg conv_round "$CONV_ROUND" \
      --arg conv_max "$CONV_MAX" \
      --argjson ctx "$ctx_obj" \
      --argjson heartbeat "$hb_obj" \
      '{
        arc_id: $id,
        plan_file: $plan,
        status: $arc_status,
        schema_version: $schema_ver,
        started_at: $started_at,
        phase_counts: {
          completed: $completed,
          in_progress: $in_progress,
          pending: $pending,
          skipped: $skipped,
          cancelled: $cancelled
        },
        active_phase: (if $active_phase != "" then $active_phase else null end),
        active_team: (if $active_team != "" then $active_team else null end),
        convergence: {
          round: ($conv_round | tonumber),
          max_rounds: ($conv_max | tonumber)
        },
        context: $ctx,
        heartbeat: $heartbeat
      }' 2>/dev/null
    continue
  fi

  # ── Human-readable output ──
  [[ "$FIRST" == "false" ]] && echo ""
  FIRST=false

  # Header
  echo "┌─ Arc: ${arc_id}"
  echo "│  Plan: ${PLAN_FILE}"
  if [[ -n "$STARTED_AT" && "$STARTED_AT" != "null" ]]; then
    ELAPSED=$(_fmt_ago "$STARTED_AT")
    echo "│  Started: ${STARTED_AT} (${ELAPSED} ago)"
  fi
  if [[ -n "$COMPLETED_AT" && "$COMPLETED_AT" != "null" ]]; then
    echo "│  Completed: ${COMPLETED_AT}"
  fi
  echo "│  Schema: v${SCHEMA_VER}"
  echo "│"

  # Phase counts summary
  echo "│  Phases: ${CNT_COMPLETED} completed / ${CNT_IN_PROGRESS} in-progress / ${CNT_PENDING} pending / ${CNT_SKIPPED} skipped"
  if [[ "$CNT_CANCELLED" -gt 0 ]]; then
    echo "│  Cancelled: ${CNT_CANCELLED}"
  fi
  echo "│"

  # Active phase + team
  if [[ -n "$ACTIVE_PHASE" ]]; then
    echo "│  Active Phase: ${ACTIVE_PHASE}"
    if [[ -n "$ACTIVE_TEAM" ]]; then
      echo "│  Active Team:  ${ACTIVE_TEAM}"
    fi
    echo "│"
  fi

  # Heartbeat (last activity)
  if [[ -n "$HB_AGO" && -n "$HB_PHASE" ]]; then
    echo "│  Last Activity: ${HB_AGO} ago (${HB_PHASE}: ${HB_TOOL})"
    echo "│"
  fi

  # Per-phase timeline (schema v19+ has started_at/completed_at per phase)
  if [[ "$SCHEMA_VER" -ge 19 ]]; then
    echo "│  Phase Timeline:"
    for phase in "${PHASE_ORDER[@]}"; do
      phase_raw=$(jq -r --arg p "$phase" '
        .phases[$p] |
        [(.status // "pending"), (.started_at // ""), (.completed_at // ""), (.team_name // "")] | @tsv
      ' "$ckpt" 2>/dev/null) || continue

      ph_status="pending"
      ph_started=""
      ph_completed=""
      ph_team=""
      while IFS=$'\t' read -r s1 s2 s3 s4; do
        ph_status="${s1:-pending}"
        ph_started="${s2:-}"
        ph_completed="${s3:-}"
        ph_team="${s4:-}"
      done <<< "$phase_raw"

      # Only show non-pending phases (completed/in_progress/skipped/cancelled)
      [[ "$ph_status" == "pending" ]] && continue

      sym=$(_status_sym "$ph_status")
      timing=""
      if [[ -n "$ph_started" ]]; then
        # Calculate duration using cross-platform helpers from lib/platform.sh
        ep_s=$(_parse_iso_epoch_ms "$ph_started")
        if [[ -n "$ph_completed" && "$ph_completed" != "null" && "$ph_completed" =~ ^[0-9] ]]; then
          ep_e=$(_parse_iso_epoch_ms "$ph_completed")
        else
          ep_e=$(_now_epoch_ms)
        fi
        dur_ms=$(( ep_e - ep_s ))
        [[ $dur_ms -lt 0 ]] && dur_ms=0
        if [[ $dur_ms -gt 0 ]]; then
          timing=" ($(_fmt_ms "$dur_ms"))"
        fi
      fi

      team_note=""
      [[ -n "$ph_team" && "$ph_team" != "null" ]] && team_note=" [${ph_team}]"

      printf '│    %s %-30s %s%s%s\n' "$sym" "$phase" "$ph_status" "$timing" "$team_note"
    done
    echo "│"
  fi

  # Convergence status (mend/verify_mend phases)
  if [[ "$CONV_MAX" -gt 0 && "$CONV_ROUND" != "0" ]]; then
    echo "│  Convergence: round ${CONV_ROUND}/${CONV_MAX}"
    vm_status=$(jq -r '.phases.verify_mend.status // "pending"' "$ckpt" 2>/dev/null || echo "pending")
    echo "│  Verify-Mend: ${vm_status}"
    echo "│"
  fi

  # Context metrics (from bridge file)
  if [[ -n "$CTX_USED" && "$CTX_USED" =~ ^[0-9] ]]; then
    USED_INT="${CTX_USED%%.*}"
    [[ "$USED_INT" =~ ^[0-9]+$ ]] || USED_INT="0"
    FILLED=$(( USED_INT * 10 / 100 ))
    [[ $FILLED -gt 10 ]] && FILLED=10
    EMPTY=$(( 10 - FILLED ))
    BAR=""
    _i=0; while [[ $_i -lt "$FILLED" ]]; do BAR="${BAR}█"; _i=$((_i+1)); done
    _i=0; while [[ $_i -lt "$EMPTY" ]]; do BAR="${BAR}░"; _i=$((_i+1)); done
    echo "│  Context: [${BAR}] ${CTX_USED}% used (${CTX_REM}% remaining)"
    if [[ -n "$CTX_COST" && "$CTX_COST" != "0" && "$CTX_COST" != "" ]]; then
      printf '│  Cost:    $%s\n' "$CTX_COST"
    fi
    echo "│"
  fi

  echo "└──────────────────────────────────────────────"
done

# ── Close JSON array ──
if [[ "$JSON_MODE" == "true" ]]; then
  printf ']\n'
fi

exit 0
