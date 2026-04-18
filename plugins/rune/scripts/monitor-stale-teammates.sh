#!/usr/bin/env bash
# monitor-stale-teammates.sh — plugin monitor companion (Track B.1)
#
# Watches tmp/.rune-signals/{team}/activity-* files (written by track-teammate-activity.sh)
# and emits ONE stdout line per newly-stale teammate detected since the previous emission.
#
# Emission discipline (BP-1 / BP-6): state change only — never heartbeat.
# Fast-path exit (<50ms) when no Rune workflow is active.
# Capability-gate: if the AC-5 sentinel is missing or reports unavailable, exit 0 quietly
# (host does not support plugin monitors — Stop-hook detect-stale-lead.sh handles detection).
# Kill-switch: process_management.monitors.enabled = false in talisman → the session runtime
# is expected to skip starting this monitor at SessionStart. This script also self-gates
# via the sentinel below for defense-in-depth; mid-session flips do NOT take effect here
# (EC-6: requires next SessionStart).

set -euo pipefail

# Cross-platform helpers — guarded
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/lib/platform.sh" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/platform.sh" 2>/dev/null || true
fi

STALE_THRESHOLD_SECS="${RUNE_STALE_THRESHOLD_SECS:-180}"  # 3 min — matches detect-stale-lead.sh
POLL_SECS="${RUNE_STALE_POLL_SECS:-30}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

signals_root() {
  printf '%s/tmp/.rune-signals' "$PROJECT_DIR"
}

state_files_root() {
  printf '%s/tmp' "$PROJECT_DIR"
}

sentinel_ok() {
  printf '%s/tmp/.rune-monitor-available' "$PROJECT_DIR"
}

# fast-path exit — no Rune workflow signals
has_active_workflow() {
  local sigs_dir
  sigs_dir="$(signals_root)"
  local state_dir
  state_dir="$(state_files_root)"

  # Any team signal dir present?
  if [[ -d "$sigs_dir" ]]; then
    if find "$sigs_dir" -maxdepth 1 -mindepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  fi

  # Any Rune state file present?
  if ls "$state_dir"/.rune-*.json >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# AC-5 capability gate — silent skip on unsupported hosts
if [[ ! -f "$(sentinel_ok)" ]]; then
  # fast-path exit: Monitor not available or not yet probed. Stop-hook covers us.
  exit 0
fi

# Fast-path exit when nothing to watch yet
if ! has_active_workflow; then
  exit 0
fi

iso_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ
}

# De-dup cache — emit each stale teammate at most once per watcher lifetime.
# In-memory set via tracked file names; avoids dumping noise on every poll.
declare -a ALREADY_EMITTED=()

is_already_emitted() {
  local key="$1"
  local x
  for x in "${ALREADY_EMITTED[@]:-}"; do
    [[ "$x" == "$key" ]] && return 0
  done
  return 1
}

emit() {
  local key="$1"
  local age="$2"
  ALREADY_EMITTED+=("$key")
  printf '%s STATE_CHANGE stale_teammate team=%s age_secs=%s\n' "$(iso_utc)" "$key" "$age"
}

now_epoch() {
  date +%s 2>/dev/null || printf '0'
}

# Watcher loop — emits only on state change (new stale teammate). Heartbeat silent.
# This monitor is started by the harness with `when: "always"`; the harness is responsible
# for terminating it at SessionEnd. We exit cleanly if signals disappear for > 2 cycles
# (workflow ended).
silent_streak=0
while true; do
  if ! has_active_workflow; then
    silent_streak=$((silent_streak + 1))
    [[ "$silent_streak" -ge 2 ]] && exit 0
  else
    silent_streak=0
  fi

  # Iterate activity signal files across all teams
  sigs_dir="$(signals_root)"
  if [[ -d "$sigs_dir" ]]; then
    # Use find to be portable (zsh nullglob not required)
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -f "$f" ]] || continue
      mtime=$(_stat_mtime "$f" 2>/dev/null || printf '0')
      [[ "$mtime" -gt 0 ]] || continue
      age=$(( $(now_epoch) - mtime ))
      [[ "$age" -lt "$STALE_THRESHOLD_SECS" ]] && continue
      # derive team+member from path
      rel="${f#$sigs_dir/}"
      team="${rel%%/*}"
      fname="${rel##*/}"
      member="${fname#activity-}"
      member="${member%.*}"
      key="${team}:${member}"
      is_already_emitted "$key" && continue
      emit "$key" "$age"
    done < <(find "$sigs_dir" -maxdepth 2 -type f -name 'activity-*' 2>/dev/null || true)
  fi

  sleep "$POLL_SECS"
done
