#!/bin/bash
# scripts/pre-compact-checkpoint.sh
# Saves team state before context compaction so the post-compact
# SessionStart handler can re-inject critical state into the fresh context.
#
# DESIGN PRINCIPLES:
#   1. Non-blocking — always exit 0 (compaction must never be prevented)
#   2. Atomic writes — temp+mv pattern prevents partial checkpoint files
#   3. rune-*/arc-* prefix filter (never touch foreign plugin teams)
#   4. JSON output via jq --arg (no printf or shell interpolation)
#
# Hook events: PreCompact
# Matcher: manual|auto
# Timeout: 10s
# Exit 0: Always (non-blocking)

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  # VEIL-003/BACK-005: Always emit stderr warning so crash-through-compaction is observable
  printf 'WARN: pre-compact-checkpoint.sh: ERR trap — fail-forward activated (line %s)\n' \
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

# ── PW-002 FIX: Opt-in trace logging (consistent with on-task-completed.sh) ──
_trace() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
    [[ ! -L "$_log" ]] && echo "[pre-compact] $*" >> "$_log" 2>/dev/null
  fi
  return 0
}

# ── Source platform helpers for cross-platform stat ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  # shellcheck source=lib/platform.sh
  source "${SCRIPT_DIR}/lib/platform.sh"
fi
source "${SCRIPT_DIR}/lib/rune-state.sh"

# ── PW-005 FIX: Cross-platform mtime sort helper (DRY — used for team and workflow discovery) ──
# Reads paths from stdin, emits them sorted by mtime descending
_sort_by_mtime() {
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    mtime=$(_stat_mtime "$p"); mtime="${mtime:-0}"
    printf '%s\t%s\n' "$mtime" "$p"
  done | sort -rn | cut -f2
}

# ── QUAL-005 FIX: Shared arc-batch state extractor (DRY — called from both teamless and team-active paths) ──
# Sets arc_batch_state global. Reads BATCH_STATE_FILE path from caller (must be set before calling).
# Fixes: BACK-009 (summary_enabled gate), BACK-008 (numeric sort instead of ls -t)
_capture_arc_batch_state() {
  arc_batch_state="{}"
  # BACK-R1-009 FIX: Guard against CWD not yet initialized (function defined before CWD is set)
  [[ -z "${CWD:-}" ]] && return 0
  [[ ! -f "$BATCH_STATE_FILE" ]] && return 0
  [[ -L "$BATCH_STATE_FILE" ]] && return 0
  local _batch_frontmatter
  _batch_frontmatter=$(sed -n '/^---$/,/^---$/p' "$BATCH_STATE_FILE" 2>/dev/null | sed '1d;$d')
  [[ -z "$_batch_frontmatter" ]] && return 0
  local _batch_iter _batch_total _batch_active _batch_summary_enabled
  _batch_iter=$(echo "$_batch_frontmatter" | grep '^iteration:' | head -1 | sed 's/^iteration:[[:space:]]*//')
  _batch_total=$(echo "$_batch_frontmatter" | grep '^total_plans:' | head -1 | sed 's/^total_plans:[[:space:]]*//')
  _batch_active=$(echo "$_batch_frontmatter" | grep '^active:' | head -1 | sed 's/^active:[[:space:]]*//')
  # BACK-009 FIX: extract summary_enabled from state file; default to true if absent
  _batch_summary_enabled=$(echo "$_batch_frontmatter" | grep '^summary_enabled:' | head -1 | sed 's/^summary_enabled:[[:space:]]*//')
  [[ -z "$_batch_summary_enabled" ]] && _batch_summary_enabled="true"
  if [[ "$_batch_active" == "true" ]] && [[ "$_batch_iter" =~ ^[0-9]+$ ]] && [[ "$_batch_total" =~ ^[0-9]+$ ]]; then
    local _latest_summary=""
    local _batch_summary_dir="${CWD}/tmp/arc-batch/summaries"
    # BACK-009 FIX: only populate latest_summary when enabled AND directory exists
    if [[ "$_batch_summary_enabled" != "false" ]] && [[ -d "$_batch_summary_dir" ]] && [[ ! -L "$_batch_summary_dir" ]]; then
      # BACK-008 FIX: numeric sort (iteration-N.md) instead of ls -t (mtime-prone)
      # BACK-R1-004 FIX: extract iteration number from basename before sorting —
      # sort -t- -k2 -n on full paths fails when directory contains hyphens (e.g. arc-batch)
      local _found
      _found=$(find "$_batch_summary_dir" -maxdepth 1 -name 'iteration-*.md' 2>/dev/null | \
        awk -F/ '{n=$NF; sub(/iteration-/,"",n); sub(/\.md$/,"",n); print n+0, $0}' | \
        sort -k1 -n | tail -1 | cut -d' ' -f2-)
      if [[ -n "$_found" ]]; then
        # BACK-R1-005 FIX: verify strip actually removed CWD prefix (symlink/mount mismatch guard)
        local _rel="${_found#${CWD}/}"
        if [[ "$_rel" != "$_found" ]] && [[ "$_rel" != /* ]]; then
          _latest_summary="$_rel"
        fi
      fi
    fi
    arc_batch_state=$(jq -n \
      --arg iter "$_batch_iter" \
      --arg total "$_batch_total" \
      --arg summary "${_latest_summary:-none}" \
      --arg sdir "tmp/arc-batch/summaries" \
      '{
        iteration: ($iter | tonumber),
        total_plans: ($total | tonumber),
        latest_summary: $summary,
        summary_dir: $sdir
      }' 2>/dev/null || echo '{}')
    _trace "Arc-batch state captured: iter=${_batch_iter} total=${_batch_total} summary_enabled=${_batch_summary_enabled}"
  fi
}

# ── Task 5 (child-1, plan AC-7): Arc state-file content snapshot ──
# Capture the content of `.rune/arc-{kind}-loop.local.md` state files into
# the compact checkpoint so post-compact recovery can re-derive them.
# The snapshot serves as a TRIGGER (we know a state file existed pre-compact)
# rather than as restoration source — restoration uses create --force which
# re-stamps session identity with current post-compact values.
# Additive field (arc_state_files); does NOT bump schema_version.
_capture_arc_state_files() {
  arc_state_files="{}"
  [[ -z "${CWD:-}" ]] && return 0
  local _kinds_json="{}" _kind _sf _content
  for _kind in phase batch hierarchy issues; do
    _sf="${CWD}/${RUNE_STATE}/arc-${_kind}-loop.local.md"
    [[ -L "$_sf" ]] && continue  # reject symlinks
    [[ -f "$_sf" ]] || continue
    # Cap snapshot size to 8 KB per file (defense against huge accidental files)
    _content=$(head -c 8192 "$_sf" 2>/dev/null || true)
    [[ -z "$_content" ]] && continue
    _kinds_json=$(echo "$_kinds_json" | jq --arg k "$_kind" --arg v "$_content" \
      '. + {($k): $v}' 2>/dev/null || echo "$_kinds_json")
  done
  arc_state_files="$_kinds_json"
  # Trace only when we captured something — keeps noise down for teamless paths
  if [[ "$arc_state_files" != "{}" ]]; then
    _trace "Arc state files snapshotted: $(echo "$arc_state_files" | jq -r 'keys | join(",")' 2>/dev/null || true)"
  fi
}

# ── Arc-issues state extractor (parallel to _capture_arc_batch_state) ──
# Sets arc_issues_state global. Reads ISSUES_STATE_FILE path from caller (must be set before calling).
_capture_arc_issues_state() {
  arc_issues_state="{}"
  [[ -z "${CWD:-}" ]] && return 0
  [[ ! -f "$ISSUES_STATE_FILE" ]] && return 0
  [[ -L "$ISSUES_STATE_FILE" ]] && return 0
  local _issues_frontmatter
  _issues_frontmatter=$(sed -n '/^---$/,/^---$/p' "$ISSUES_STATE_FILE" 2>/dev/null | sed '1d;$d')
  [[ -z "$_issues_frontmatter" ]] && return 0
  local _issues_iter _issues_total _issues_active
  _issues_iter=$(echo "$_issues_frontmatter" | grep '^iteration:' | head -1 | sed 's/^iteration:[[:space:]]*//')
  _issues_total=$(echo "$_issues_frontmatter" | grep '^total_plans:' | head -1 | sed 's/^total_plans:[[:space:]]*//')
  _issues_active=$(echo "$_issues_frontmatter" | grep '^active:' | head -1 | sed 's/^active:[[:space:]]*//')
  if [[ "$_issues_active" == "true" ]] && [[ "$_issues_iter" =~ ^[0-9]+$ ]] && [[ "$_issues_total" =~ ^[0-9]+$ ]]; then
    arc_issues_state=$(jq -n \
      --arg iter "$_issues_iter" \
      --arg total "$_issues_total" \
      '{
        iteration: ($iter | tonumber),
        total_plans: ($total | tonumber)
      }' 2>/dev/null || echo '{}')
    _trace "Arc-issues state captured: iter=${_issues_iter} total=${_issues_total}"
  fi
}

# ── GUARD 1: jq dependency ──
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — compact checkpoint will not be written" >&2
  exit 0
fi

# ── GUARD 2: Input size cap (SEC-2: 1MB DoS prevention) ──
# timeout guard prevents blocking on disconnected stdin (macOS may lack timeout)
if command -v timeout &>/dev/null; then
  INPUT=$(timeout 2 head -c 1048576 || true)
else
  INPUT=$(head -c 1048576 2>/dev/null || true)
fi

# ── GUARD 3: CWD extraction and canonicalization ──
# BACK-005 FIX: Use printf instead of echo to avoid flag interpretation if $INPUT starts with '-'
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then exit 0; fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# ── GUARD 4: tmp/ directory must exist ──
if [[ ! -d "${CWD}/tmp" ]]; then exit 0; fi

# ── CHOME resolution ──
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  exit 0
fi

# ── Cleanup trap — remove temp files on exit ──
CHECKPOINT_TMP=""
cleanup() { [[ -n "$CHECKPOINT_TMP" ]] && rm -f "$CHECKPOINT_TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

# ── FIND ACTIVE RUNE TEAM ──
# Look for rune-*/arc-* team dirs (NOT goldmask-*) — pick the most recently modified
active_team=""
if [[ -d "$CHOME/teams/" ]]; then
  while IFS= read -r dir; do
    dirname=$(basename "$dir")
    if [[ "$dirname" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ ! -L "$dir" ]]; then
      active_team="$dirname"
      break  # stat-based mtime sort below picks most recent
    fi
  done < <(find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" \) -not -name "goldmask-*" 2>/dev/null | _sort_by_mtime)
fi

_trace "Team discovery: active_team=${active_team:-<none>}"

# Initialize arc_phase_summaries early — referenced in the teamless branch below
# and reassigned in the team-present path (line ~297). Must be set before the
# if [[ -z "$active_team" ]] branch to satisfy set -euo pipefail.
arc_phase_summaries="{}"

# NOTE: During arc-batch, teams are created/destroyed per-phase — compaction may
# hit when no team is active. Summary files persist independently of team state.
# Arc-batch state is captured regardless of team presence (see section below).

# If no active team, nothing to checkpoint (but still capture arc-batch state below)
if [[ -z "$active_team" ]]; then
  # ── Arc-batch state capture (teamless — C6 accepted limitation) ──
  # Arc-batch teams are ephemeral, but batch state file persists.
  # Capture batch iteration context even when no team is active.
  BATCH_STATE_FILE="${CWD}/${RUNE_STATE}/arc-batch-loop.local.md"
  _capture_arc_batch_state

  # ── Arc-issues state capture (teamless — parallel to arc-batch) ──
  ISSUES_STATE_FILE="${CWD}/${RUNE_STATE}/arc-issues-loop.local.md"
  _capture_arc_issues_state

  # ── Task 5: Arc state-file content snapshot (teamless path) ──
  _capture_arc_state_files

  # If we captured batch or issues state OR any arc state files, write checkpoint
  if [[ "$arc_batch_state" != "{}" ]] || [[ "$arc_issues_state" != "{}" ]] || [[ "${arc_state_files:-{}}" != "{}" ]]; then
    CHECKPOINT_FILE="${CWD}/tmp/.rune-compact-checkpoint.json"
    # SEC-102 FIX: use mktemp instead of PID-based temp file; add symlink guard
    CHECKPOINT_TMP=$(mktemp "${CHECKPOINT_FILE}.XXXXXX" 2>/dev/null) || { exit 0; }
    [[ -L "$CHECKPOINT_TMP" ]] && { rm -f "$CHECKPOINT_TMP" 2>/dev/null; exit 0; }
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if jq -n \
      --arg team "" \
      --arg ts "$TIMESTAMP" \
      --arg cfg "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
      --arg pid "${PPID:-}" \
      --argjson batch "$arc_batch_state" \
      --argjson issues "$arc_issues_state" \
      --argjson phase_summaries "$arc_phase_summaries" \
      --argjson arc_state_files "${arc_state_files:-{}}" \
      '{
        team_name: $team,
        saved_at: $ts,
        config_dir: $cfg,
        owner_pid: $pid,
        team_config: {},
        tasks: [],
        workflow_state: {},
        arc_checkpoint: {},
        arc_batch_state: $batch,
        arc_issues_state: $issues,
        arc_phase_summaries: $phase_summaries,
        arc_state_files: $arc_state_files
      }' > "$CHECKPOINT_TMP" 2>/dev/null; then
      mv -f "$CHECKPOINT_TMP" "$CHECKPOINT_FILE" 2>/dev/null || rm -f "$CHECKPOINT_TMP" 2>/dev/null
      CHECKPOINT_TMP=""
    else
      rm -f "$CHECKPOINT_TMP" 2>/dev/null
    fi
    _context_msg="No active Rune team but loop state captured in compact checkpoint."
    [[ "$arc_batch_state" != "{}" ]] && _context_msg="No active Rune team but arc-batch state captured in compact checkpoint."
    [[ "$arc_issues_state" != "{}" ]] && _context_msg="No active Rune team but arc-issues state captured in compact checkpoint."
    [[ "${arc_state_files:-{}}" != "{}" ]] && _context_msg="No active Rune team but arc state files snapshotted in compact checkpoint."
    jq -n --arg msg "$_context_msg" '{ systemMessage: $msg }'
    exit 0
  fi

  jq -n '{ systemMessage: "No active Rune team found — compact checkpoint skipped." }'
  exit 0
fi

# ── COLLECT TEAM STATE ──

# 1. Team config (members list)
team_config="{}"
config_file="$CHOME/teams/${active_team}/config.json"
if [[ -f "$config_file" ]] && [[ ! -L "$config_file" ]]; then
  team_config=$(jq -c '.' "$config_file" 2>/dev/null || echo '{}')
fi

# 2. Task list — collect from tasks directory
tasks_json="[]"
task_files=()  # Initialize before conditional (set -u safe for _trace on line 175)
tasks_dir="$CHOME/tasks/${active_team}"
if [[ -d "$tasks_dir" ]] && [[ ! -L "$tasks_dir" ]]; then
  # Read all task JSON files, merge into array
  while IFS= read -r tf; do
    if [[ -f "$tf" ]] && [[ ! -L "$tf" ]]; then
      task_files+=("$tf")
    fi
  done < <(find "$tasks_dir" -maxdepth 1 -type f -name "*.json" 2>/dev/null)

  # FW-004 FIX: Cap task file count to prevent ARG_MAX overflow
  if [[ ${#task_files[@]} -gt 200 ]]; then
    echo "WARN: ${#task_files[@]} task files exceeds cap of 200 — truncating" >&2
    task_files=("${task_files[@]:0:200}")
  fi

  if [[ ${#task_files[@]} -gt 0 ]]; then
    tasks_json=$(jq -s '.' "${task_files[@]}" 2>/dev/null || echo '[]')
  fi
fi

# 3. Active workflow state file (tmp/.rune-*.json)
# FW-001 FIX: Use find-based approach instead of glob loop (zsh compat — shopt unavailable on zsh)
workflow_state="{}"
workflow_file=""
workflow_file=$(find "${CWD}/tmp/" -maxdepth 1 -type f \
  \( -name ".rune-review-*.json" -o -name ".rune-audit-*.json" \
     -o -name ".rune-work-*.json" -o -name ".rune-mend-*.json" \
     -o -name ".rune-inspect-*.json" -o -name ".rune-plan-*.json" \
     -o -name ".rune-forge-*.json" -o -name ".rune-goldmask-*.json" \
     -o -name ".rune-brainstorm-*.json" -o -name ".rune-debug-*.json" \
     -o -name ".rune-design-sync-*.json" \
     -o -name ".rune-arc-*.json" \) 2>/dev/null | while read -r f; do
    [[ -L "$f" ]] && continue
    echo "$f"
  done | _sort_by_mtime | head -1)
if [[ -n "$workflow_file" ]] && [[ -f "$workflow_file" ]]; then
  workflow_state=$(jq -c '.' "$workflow_file" 2>/dev/null || echo '{}')
fi

# 4. Arc checkpoint if it exists
# BUG FIX (v1.107.0): Arc checkpoints live at ${RUNE_STATE}/arc/${id}/checkpoint.json,
# NOT tmp/.arc-checkpoint.json (which never existed). Find newest checkpoint
# belonging to current session (owner_pid matches $PPID).
arc_checkpoint="{}"
arc_file=""
_ckpt_dir="${CWD}/${RUNE_STATE}/arc"
if [[ -d "$_ckpt_dir" ]]; then
  _newest_mtime=0
  # BACK-006 FIX: Protect glob with nullglob to prevent literal-path iteration on no match
  shopt -s nullglob 2>/dev/null || true
  for _f in "$_ckpt_dir"/*/checkpoint.json; do
    [[ -f "$_f" ]] && [[ ! -L "$_f" ]] || continue
    _pid=$(jq -r '.owner_pid // empty' "$_f" 2>/dev/null) || continue
    [[ "$_pid" == "$PPID" ]] || continue
    _mt=$(_stat_mtime "$_f"); [[ -n "$_mt" ]] || continue
    if [[ "$_mt" -gt "$_newest_mtime" ]]; then
      _newest_mtime="$_mt"
      arc_file="$_f"
    fi
  done
  shopt -u nullglob 2>/dev/null || true
fi
if [[ -n "$arc_file" ]] && [[ -f "$arc_file" ]] && [[ ! -L "$arc_file" ]]; then
  arc_checkpoint=$(jq -c '.' "$arc_file" 2>/dev/null || echo '{}')
fi

# 4a. Arc phase summary paths from checkpoint.phase_summaries (Feature 5 — phase memory handoff)
# Collects paths to all written phase group summaries so recovery can re-inject them as context.
# phase_summaries is a map: { "forge": "tmp/arc/{id}/phase-summary-forge.md", ... }
# We extract only paths that actually exist on disk (guards against stale checkpoint fields).
arc_phase_summaries="{}"
if [[ "$arc_checkpoint" != "{}" ]]; then
  # BACK-005 FIX: Use printf instead of echo to avoid flag interpretation
  _raw_summaries=$(printf '%s\n' "$arc_checkpoint" | jq -r '.phase_summaries // {} | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null || true)
  if [[ -n "$_raw_summaries" ]]; then
    # SEC-003 FIX: Build JSON via jq --arg instead of shell string interpolation
    _built_summaries="{}"
    while IFS=$'\t' read -r _group _path; do
      # Validate group name and path (SEC: allowlist chars, prevent traversal)
      # NOTE: {1,N} quantifier not supported in Bash 3.2 (macOS) — use + and length check
      [[ ${#_group} -le 32 ]] && [[ "$_group" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
      [[ ${#_path} -le 256 ]] && [[ "$_path" =~ ^[a-zA-Z0-9._/-]+$ ]] || continue
      [[ "$_path" == *".."* ]] && continue
      # Verify file exists on disk
      _full="${CWD}/${_path}"
      [[ -f "$_full" ]] && [[ ! -L "$_full" ]] || continue
      _built_summaries=$(printf '%s\n' "$_built_summaries" | jq -c \
        --arg k "$_group" --arg v "$_path" '. + {($k): $v}' 2>/dev/null || echo "$_built_summaries")
    done <<< "$_raw_summaries"
    # Only use if we got at least one entry
    if [[ "$_built_summaries" != "{}" ]]; then
      arc_phase_summaries="$_built_summaries"
    fi
  fi
fi
_trace "Arc phase summaries: ${arc_phase_summaries}"

# 5. Arc-batch state if active (v1.72.0) — QUAL-005 FIX: shared extractor
BATCH_STATE_FILE="${CWD}/${RUNE_STATE}/arc-batch-loop.local.md"
_capture_arc_batch_state

# 6. Arc-issues state if active (parallel to arc-batch)
ISSUES_STATE_FILE="${CWD}/${RUNE_STATE}/arc-issues-loop.local.md"
_capture_arc_issues_state

# 7. Arc state-file content snapshot (Task 5, plan AC-7)
_capture_arc_state_files

# ── WRITE CHECKPOINT (atomic) ──
CHECKPOINT_FILE="${CWD}/tmp/.rune-compact-checkpoint.json"
# SEC-102 FIX: use mktemp instead of PID-based temp file; add symlink guard
CHECKPOINT_TMP=$(mktemp "${CHECKPOINT_FILE}.XXXXXX" 2>/dev/null) || { exit 0; }
[[ -L "$CHECKPOINT_TMP" ]] && { rm -f "$CHECKPOINT_TMP" 2>/dev/null; exit 0; }
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if ! jq -n \
  --arg team "$active_team" \
  --arg ts "$TIMESTAMP" \
  --arg cfg "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
  --arg pid "${PPID:-}" \
  --argjson config "$team_config" \
  --argjson tasks "$tasks_json" \
  --argjson workflow "$workflow_state" \
  --argjson arc "$arc_checkpoint" \
  --argjson batch "$arc_batch_state" \
  --argjson issues "$arc_issues_state" \
  --argjson phase_summaries "$arc_phase_summaries" \
  --argjson arc_state_files "${arc_state_files:-{}}" \
  '{
    team_name: $team,
    saved_at: $ts,
    config_dir: $cfg,
    owner_pid: $pid,
    team_config: $config,
    tasks: $tasks,
    workflow_state: $workflow,
    arc_checkpoint: $arc,
    arc_batch_state: $batch,
    arc_issues_state: $issues,
    arc_phase_summaries: $phase_summaries,
    arc_state_files: $arc_state_files
  }' > "$CHECKPOINT_TMP" 2>/dev/null; then
  echo "WARN: Failed to write compact checkpoint" >&2
  rm -f "$CHECKPOINT_TMP" 2>/dev/null
  exit 0
fi

# SEC-003: Atomic rename
# FW-002 FIX: Use mv -f (force) instead of mv -n (no-clobber). A stale checkpoint
# with an old team name is worse than a fresh one — always write latest state.
_trace "Writing checkpoint: team=${active_team} tasks=${#task_files[@]}"
mv -f "$CHECKPOINT_TMP" "$CHECKPOINT_FILE" 2>/dev/null || {
  rm -f "$CHECKPOINT_TMP" 2>/dev/null
  exit 0
}
CHECKPOINT_TMP=""  # Clear for cleanup trap — file was moved successfully

# ── OUTPUT: systemMessage (PreCompact does not support hookSpecificOutput) ──
jq -n --arg team "$active_team" '{
  systemMessage: ("Rune compact checkpoint saved for team " + $team + ". State will be restored after compaction via session-compact-recovery.sh.")
}'
exit 0
