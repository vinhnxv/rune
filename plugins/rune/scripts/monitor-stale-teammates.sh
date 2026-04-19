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

# MON-003 FIX (audit 20260419-150325): resolve SCRIPT_DIR from BASH_SOURCE and
# source platform.sh unconditionally. Prior guarded `CLAUDE_PLUGIN_ROOT` sourcing
# meant that when the env var was unset `_stat_mtime` was undefined, every loop
# iteration short-circuited on `[[ "$mtime" -gt 0 ]]`, and the watcher emitted
# zero alerts with zero warning — a silent invisible-regression path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || SCRIPT_DIR="."
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  # shellcheck source=lib/platform.sh
  source "${SCRIPT_DIR}/lib/platform.sh"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/lib/platform.sh" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/platform.sh"
else
  # Last-resort inline fallback — still better than silent undefined.
  _stat_mtime() {
    case "$(uname -s 2>/dev/null)" in
      Darwin) stat -f '%m' "$1" 2>/dev/null || true ;;
      *)      stat -c '%Y' "$1" 2>/dev/null || true ;;
    esac
  }
fi

STALE_THRESHOLD_SECS="${RUNE_STALE_THRESHOLD_SECS:-180}"  # 3 min — matches detect-stale-lead.sh
POLL_SECS="${RUNE_STALE_POLL_SECS:-30}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# MON-001 FIX (audit 20260419-150325): session isolation anchors.
# Canonicalize CLAUDE_CONFIG_DIR once for comparison vs state-file config_dir.
# OWNER_PID = $PPID — in a harness-spawned monitor, the parent is the Claude
# Code session process, which is also what gets written into state files'
# owner_pid field by skills at workflow start.
RUNE_CURRENT_CFG=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P) || \
  RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
OWNER_PID="$PPID"

# MON-004 FIX (audit 20260419-150325): wall-clock cap on the `while true` loop.
# Combined with MON-001, leaked signal dirs from crashed prior sessions would
# otherwise keep this watcher pinned indefinitely. Default 12h — any arc phase
# exceeding that is a separate incident and human-should-be-alerted territory.
MAX_WATCH_SECS="${RUNE_MAX_WATCH_SECS:-43200}"  # 12h
WATCH_START_EPOCH=$(date +%s 2>/dev/null || printf '0')

# MON-002 FIX (audit 20260419-150325): liveness check helpers.
# Port of detect-stale-lead.sh:399-414 (Method D) — if the owning session still
# has live node/claude teammate child processes, emission is suppressed.
rune_pid_alive() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  local _err
  _err=$(kill -0 "$1" 2>&1) && return 0
  case "$_err" in *ermission*|*[Pp]erm*|*EPERM*) return 0 ;; esac
  return 1
}

count_live_teammates() {
  local _pid="$1"
  local _count=0
  [[ -n "$_pid" && "$_pid" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  command -v pgrep &>/dev/null || { printf '0'; return 0; }
  while IFS= read -r _child; do
    [[ -z "$_child" || ! "$_child" =~ ^[0-9]+$ ]] && continue
    _cmd=$(ps -p "$_child" -o comm= 2>/dev/null || true)
    case "$_cmd" in
      node|claude|claude-*) _count=$((_count + 1)) ;;
    esac
  done < <(pgrep -P "$_pid" 2>/dev/null || true)
  printf '%s' "$_count"
}

# Resolve (config_dir|owner_pid) for a given team name by scanning state files.
# Returns empty string when no matching state file exists (likely an orphan).
# Prefers jq when available; falls back to grep-based extraction for robustness.
resolve_team_owner() {
  local _team="$1"
  [[ -z "$_team" ]] && return 0
  [[ "$_team" =~ ^[a-zA-Z0-9_-]+$ ]] || return 0  # SEC-4
  local _sf _cfg _pid
  while IFS= read -r _sf; do
    [[ -f "$_sf" && ! -L "$_sf" ]] || continue
    local _tn=""
    if command -v jq &>/dev/null; then
      _tn=$(jq -r '.team_name // empty' "$_sf" 2>/dev/null || true)
    else
      _tn=$(grep -E '"team_name"[[:space:]]*:' "$_sf" 2>/dev/null \
            | head -1 | sed -E 's/.*"team_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)
    fi
    [[ "$_tn" != "$_team" ]] && continue
    if command -v jq &>/dev/null; then
      _cfg=$(jq -r '.config_dir // empty' "$_sf" 2>/dev/null || true)
      _pid=$(jq -r '.owner_pid // empty' "$_sf" 2>/dev/null || true)
    else
      _cfg=$(grep -E '"config_dir"[[:space:]]*:' "$_sf" 2>/dev/null \
             | head -1 | sed -E 's/.*"config_dir"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)
      _pid=$(grep -E '"owner_pid"[[:space:]]*:' "$_sf" 2>/dev/null \
             | head -1 | sed -E 's/.*"owner_pid"[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*/\1/' || true)
    fi
    printf '%s|%s' "$_cfg" "$_pid"
    return 0
  done < <(find "${PROJECT_DIR}/tmp" -maxdepth 1 -name '.rune-*.json' -type f 2>/dev/null || true)
  return 0
}

signals_root() {
  printf '%s/tmp/.rune-signals' "$PROJECT_DIR"
}

sentinel_ok() {
  printf '%s/tmp/.rune-monitor-available' "$PROJECT_DIR"
}

# fast-path exit — no Rune team signals.
# Scope: this monitor tracks stale TEAMMATES, which only exist inside an active team.
# We intentionally do NOT check `tmp/.rune-*.json` state files — those persist across
# arc phases and leak from prior sessions, causing the watcher to loop forever and
# block the Stop hook from advancing the phase loop (see v2.57.2 bug fix).
has_active_workflow() {
  local sigs_dir
  sigs_dir="$(signals_root)"

  # Any team signal dir present?
  if [[ -d "$sigs_dir" ]]; then
    if find "$sigs_dir" -maxdepth 1 -mindepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
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
  # MON-004 FIX: wall-clock cap. Exit cleanly past MAX_WATCH_SECS — any
  # legitimate arc phase beyond that is a separate incident.
  _now=$(date +%s 2>/dev/null || printf '0')
  _elapsed=$(( _now - WATCH_START_EPOCH ))
  if [[ "$_elapsed" -ge "$MAX_WATCH_SECS" ]]; then
    exit 0
  fi

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

      # MON-001 FIX: session isolation. Resolve the team's state-file owner
      # before emitting. Skip teams owned by a different installation or a
      # different live Claude Code session.
      _own=$(resolve_team_owner "$team")
      if [[ -z "$_own" ]]; then
        # No state file for this team — likely orphan from crashed prior
        # session. detect-workflow-complete.sh is responsible for that path;
        # we stay silent to avoid phantom wakes.
        continue
      fi
      _sf_cfg="${_own%%|*}"
      _sf_pid="${_own##*|}"
      if [[ -n "$_sf_cfg" && "$_sf_cfg" != "$RUNE_CURRENT_CFG" ]]; then
        continue  # foreign installation
      fi
      if [[ -n "$_sf_pid" && "$_sf_pid" =~ ^[0-9]+$ && "$_sf_pid" != "$OWNER_PID" ]]; then
        if rune_pid_alive "$_sf_pid"; then
          continue  # live foreign session — not our concern
        fi
        # Owner dead → orphan. Defer to detect-workflow-complete.sh.
        continue
      fi

      # MON-002 FIX: liveness probe. mtime alone is NOT a liveness signal —
      # throttled activity writes (15s) + legit long-running tool calls (e.g.,
      # browser tests) can push the file past STALE_THRESHOLD even when the
      # teammate is fully alive. Check for live node|claude child processes
      # of the OWNING session's PID before declaring stale.
      _probe_pid="${_sf_pid:-$OWNER_PID}"
      _alive_count=$(count_live_teammates "$_probe_pid")
      if [[ "$_alive_count" -gt 0 ]]; then
        continue
      fi

      emit "$key" "$age"
    done < <(find "$sigs_dir" -maxdepth 2 -type f -name 'activity-*' 2>/dev/null || true)
  fi

  sleep "$POLL_SECS"
done
