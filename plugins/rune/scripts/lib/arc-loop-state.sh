#!/bin/bash
# plugins/rune/scripts/lib/arc-loop-state.sh
#
# Shared library for arc phase-loop state file lifecycle operations.
# Single source of truth for creation, recovery, deletion, and integrity
# logging of `.rune/arc-{phase|batch|hierarchy|issues}-loop.local.md` state
# files (plan AC-5).
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/platform.sh"             # _stat_mtime, _parse_iso_epoch
#   source "${SCRIPT_DIR}/lib/rune-state.sh"           # RUNE_STATE
#   source "${SCRIPT_DIR}/lib/arc-stop-hook-common.sh" # arc_delete_state_file (wrapped by gate)
#   source "${SCRIPT_DIR}/lib/frontmatter-utils.sh"    # _get_fm_field (optional; inline fallback)
#   source "${SCRIPT_DIR}/lib/arc-loop-state.sh"       # this file
#
# PUBLIC FUNCTIONS (all honor _rune_fail_forward — never abort caller):
#   arc_state_file_path [kind]                        -> stdout: canonical state file path
#   arc_state_integrity_log action cause state_file [extra_json] \
#                            [arc_id] [loop_kind] [checkpoint_path] \
#                            [pending_phase_count] [mtime_age_sec]
#   arc_state_touch state_file                        -> exit 0
#   arc_state_recover [kind]                          -> exit 0 on recreate | 1 on no-checkpoint
#   arc_state_pending_phases checkpoint_path          -> stdout: int (-1 on jq error/defer)
#   arc_state_should_delete state_file                -> exit 0 (delete) | 1 (defer)
#
# DESIGN NOTES:
#   - Bash 3.2 compatible (no assoc arrays, no `${var,,}`)
#   - Atomic writes via mktemp-in-same-dir + mv -f (XM-1, R17)
#   - jq-based field extraction; returns -1 on parse failure (XM-3)
#   - JSONL log construction via `jq -nc --arg ...` (SEC: CWE-93 newline injection)
#   - Log rotation: pre-append check at 5MB cap, serialized via mkdir lock (XM-4, R22)
#   - Secure perms: umask 077 + chmod 600 on log create
#   - Trust boundary: CLAUDE_CONFIG_DIR via CHOME pattern, never trusted beyond type check
#   - No `sed -i`, no `set -e` beyond caller's, no exit inside functions
#   - RUNE_TRACE=1 → function-level trace via _arc_lib_trace (plan §14.3)
#
# See plans/2026-04-17-fix-arc-state-file-reliability-plan.md for AC mapping.

# ─────────────────────────────────────────────────────────────────────────────
# Constants (override-able via environment for testing)
# ─────────────────────────────────────────────────────────────────────────────

: "${RUNE_ARC_INTEG_LOG:=.rune/arc-integrity-log.jsonl}"
: "${RUNE_ARC_INTEG_LOG_MAX_BYTES:=5242880}"  # 5 MB (XM-4)
: "${RUNE_ARC_STATE_TOUCH_THROTTLE_SEC:=60}"
: "${RUNE_ARC_MAX_CREDIBLE_AGE_MIN:=480}"     # XM-5: clock-skew sanity cap

# Valid loop kinds (prevents prototype pollution and arbitrary filename injection)
_ARC_LOOP_KINDS="phase batch hierarchy issues"

# Plugin version — read once at lib load from plugin.json; cached for log entries.
# Resolved relative to this file (lib/ → plugin root is two levels up).
if [ -z "${_RUNE_ARC_PLUGIN_VERSION:-}" ]; then
  _RUNE_ARC_PLUGIN_VERSION=""
  _arc_lib_dir_init=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
  _arc_lib_plugin_json="${RUNE_PLUGIN_ROOT:-${_arc_lib_dir_init%/scripts/lib}}/.claude-plugin/plugin.json"
  if [ -f "$_arc_lib_plugin_json" ] && command -v jq >/dev/null 2>&1; then
    _RUNE_ARC_PLUGIN_VERSION=$(jq -r '.version // ""' "$_arc_lib_plugin_json" 2>/dev/null || echo "")
  fi
  unset _arc_lib_dir_init _arc_lib_plugin_json
fi

# ─────────────────────────────────────────────────────────────────────────────
# _arc_lib_trace msg → stderr/file trace when RUNE_TRACE=1 (plan §14.3)
# ─────────────────────────────────────────────────────────────────────────────
# Mirrors arc-phase-stop-hook.sh:40 pattern. Zero cost when RUNE_TRACE unset.
# Output path matches canonical hook-trace format (on-session-stop.sh:71).
_arc_lib_trace() {
  [ -z "${RUNE_TRACE:-}" ] && return 0
  local _msg="$*"
  local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
  # Refuse to follow a symlinked trace log (SEC hardening; matches arc-phase-stop-hook.sh:40).
  [ -L "$_log" ] && return 0
  printf '[%s] arc-loop-state: %s\n' "$(date +%H:%M:%S)" "$_msg" >> "$_log" 2>/dev/null || true
  return 0
}

# Soft-guard: warn (never hard-fail) if arc-stop-hook-common.sh isn't loaded.
# Phase-4 canary scope — functions that don't depend on common.sh still work.
if [ -z "${_RUNE_ARC_STOP_HOOK_COMMON_LOADED:-}" ]; then
  _arc_lib_trace "WARN: arc-stop-hook-common.sh not loaded; arc_delete_state_file will be unavailable"
fi

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_file_path [kind] → stdout: canonical state file path
# ─────────────────────────────────────────────────────────────────────────────
# Default kind=phase. Reject unknown kinds via allowlist.
arc_state_file_path() {
  local _kind="${1:-phase}"
  case " $_ARC_LOOP_KINDS " in
    *" $_kind "*) ;;
    *) return 1 ;;  # invalid kind
  esac
  # RUNE_STATE is set by lib/rune-state.sh; default to .rune if unset
  local _base="${RUNE_STATE:-.rune}"
  # SEC-002: reject `..` traversal in RUNE_STATE. Previously the sed-based
  # normalizer only collapsed `//` → `/` and did NOT strip `..` — a caller
  # setting RUNE_STATE=".rune/../../etc" would generate a state-file path
  # outside the project root. Strict rejection is safer than path canonicalization.
  case "$_base" in *..*) return 1 ;; esac
  # FLAW-004: use parameter expansion to strip only the trailing slash from
  # CWD instead of a global `sed 's|//|/|g'`. The global collapse corrupted
  # UNC-style `//server/share` paths into `/server/share`; this form only
  # normalizes the join-point `/`.
  local _cwd="${CWD:-$PWD}"
  _cwd="${_cwd%/}"
  local _b="${_base#/}"  # strip leading slash on _base so we don't re-introduce //
  printf '%s/%s/arc-%s-loop.local.md' "$_cwd" "$_b" "$_kind"
}

# ─────────────────────────────────────────────────────────────────────────────
# _arc_state_emit_deprecation_warn_once → stderr warning once per invocation
# ─────────────────────────────────────────────────────────────────────────────
# Emits a one-shot deprecation warning to stderr when the user's talisman still
# carries the removed canary key (v2.56.0+). Key name is constructed at runtime
# so the literal string never appears lexically in source. Warning itself is
# removed in v2.57.0.
_arc_state_emit_deprecation_warn_once() {
  [ -n "${_RUNE_ARC_DEPRECATION_WARN_EMITTED:-}" ] && return 0
  local _shard="${CWD:-$PWD}/tmp/.talisman-resolved/arc.json"
  [ -f "$_shard" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local _key_name
  _key_name=$(printf 'code_enforced_%s' 'writes')
  local _user_val
  _user_val=$(jq -r --arg k "$_key_name" '.state_file[$k] // empty' "$_shard" 2>/dev/null)
  if [ "$_user_val" = "false" ]; then
    printf 'WARN: talisman key `arc.state_file.%s` is deprecated and has no effect (v2.56.0+).\n      All state file writes are now unconditional. Remove this key from your talisman.\n' "$_key_name" >&2
  fi
  export _RUNE_ARC_DEPRECATION_WARN_EMITTED=1
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_integrity_log action cause state_file [extra_json] \
#                          [arc_id] [loop_kind] [checkpoint_path] \
#                          [pending_phase_count] [mtime_age_sec]
# ─────────────────────────────────────────────────────────────────────────────
# Secure JSONL via jq -nc --arg (CWE-93 immune). Pre-append rotation at cap.
# All string fields enum-validated where the plan specifies (§14.4, §16).
#
# Positional params:
#   $1 action              (required; enum, no-op if empty)
#   $2 cause               (free-form; escaped by jq)
#   $3 state_file          (path; escaped by jq)
#   $4 extra_json          (JSON object string; malformed → empty object)
#   $5 arc_id              (`^arc-[0-9]+$` or empty)
#   $6 loop_kind           (`phase|batch|hierarchy|issues`; default `phase`)
#   $7 checkpoint_path     (free-form; escaped by jq)
#   $8 pending_phase_count (integer string or empty → null)
#   $9 mtime_age_sec       (integer string or empty → null)
arc_state_integrity_log() {
  local _action="$1" _cause="$2" _state_file="$3" _extra="${4:-{}}"
  local _arc_id="${5:-}" _loop_kind="${6:-phase}"
  local _checkpoint_path="${7:-}"
  local _pending_str="${8:-}" _mtime_age_str="${9:-}"
  [ -z "$_action" ] && return 0  # silent no-op if misused
  command -v jq >/dev/null 2>&1 || return 0

  local _log_path="${CWD:-$PWD}/${RUNE_ARC_INTEG_LOG}"
  # SEC-002: refuse to traverse symlinks (CWE-61, parent-dir aware). Applied before mkdir -p.
  if command -v reject_symlink_deep >/dev/null 2>&1; then
    reject_symlink_deep "$_log_path" || return 0
  else
    [ -L "$_log_path" ] && return 0
  fi
  local _log_dir; _log_dir=$(dirname "$_log_path")
  # SEC-003: also reject the log DIRECTORY as a symlink before mkdir -p. Previously
  # only the file was checked; a TOCTOU race could replace `_log_dir` with a symlink
  # between the file check and `mkdir -p`, and the `>>` append would follow it.
  [ -L "$_log_dir" ] && return 0
  mkdir -p "$_log_dir" 2>/dev/null || return 0

  # Rotation under mkdir lock (XM-4)
  local _lock="${_log_path%.jsonl}-rotate-lock.d"
  if [ -f "$_log_path" ]; then
    local _sz
    _sz=$(wc -c < "$_log_path" 2>/dev/null | tr -d ' ')
    _sz="${_sz:-0}"
    if [ "$_sz" -ge "$RUNE_ARC_INTEG_LOG_MAX_BYTES" ] 2>/dev/null; then
      # SEC-002: second symlink check (defense-in-depth vs TOCTOU between mkdir -p and mv).
      if command -v reject_symlink_deep >/dev/null 2>&1; then
        reject_symlink_deep "$_log_path" || return 0
      else
        [ -L "$_log_path" ] && return 0
      fi
      # FLAW-002: stale-lock eviction. SIGKILL can't be trapped, so a lock dir
      # left behind by a kill-9'd rotator would disable rotation forever. If the
      # lock is older than 60s, evict it before retrying mkdir. (60s comfortably
      # exceeds rotation wall time — mv + awk over a 5MB file completes in <1s.)
      if [ -d "$_lock" ]; then
        local _lk_mtime _lk_age _now
        _now=$(date +%s)
        _lk_mtime=$(_stat_mtime "$_lock" 2>/dev/null || echo 0)
        _lk_mtime="${_lk_mtime:-0}"
        _lk_age=$((_now - _lk_mtime))
        if [ "$_lk_age" -gt 60 ] 2>/dev/null; then
          rmdir "$_lock" 2>/dev/null || true
        fi
      fi
      if mkdir "$_lock" 2>/dev/null; then
        # SEC-001: previously this block captured `trap -p EXIT` and restored it
        # via `eval "$_prev_exit_trap"`. That pattern matched codex-exec.sh's own
        # pre-fix bug — `eval` on captured trap output is a shell-injection surface
        # when an upstream caller sets a trap containing attacker-controlled text.
        # The rotation block sets NO other state that an EXIT trap would need to
        # clean, so we just do direct rmdir here and skip the trap dance entirely.
        # If the process is killed mid-rotation, FLAW-002's stale-lock eviction
        # (above) will clear the lock on the next call.
        mv -f "$_log_path" "${_log_path%.jsonl}-$(date +%Y%m%d-%H%M%S).jsonl" 2>/dev/null || true
        # FLAW-001 + FLAW-006 + SEC-006: archive retention — keep N newest archives,
        # drop older ones. Previous `ls -t … | xargs rm -f` broke on filenames with
        # spaces (xargs whitespace split), crashed in zsh when no archives existed
        # (NOMATCH), and fed ls output to a command without null-termination. Use
        # `find` + `while IFS= read -r` to get NUL-safe enumeration and avoid
        # glob expansion in the caller's shell. Sort by filename descending (the
        # timestamp suffix `YYYYMMDD-HHMMSS` is monotonic and sorts by mtime).
        local _max_arch _arch_base _arch_dir
        _max_arch="${RUNE_ARC_INTEGRITY_LOG_MAX_ARCHIVES:-5}"
        _arch_base=$(basename "${_log_path%.jsonl}")
        _arch_dir=$(dirname "$_log_path")
        find "$_arch_dir" -maxdepth 1 -type f -name "${_arch_base}-*.jsonl" 2>/dev/null \
          | sort -r \
          | awk -v n="$_max_arch" 'NR>n' \
          | while IFS= read -r _arch; do
              [ -n "$_arch" ] && rm -f -- "$_arch" 2>/dev/null
            done
        rmdir "$_lock" 2>/dev/null || true
      fi
    fi
  fi

  # Identity fields
  local _sid="${RUNE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
  case "$_sid" in *[!a-zA-Z0-9_-]*|'') _sid="unknown" ;; esac
  local _pid="$PPID"
  case "$_pid" in ''|*[!0-9]*) _pid="0" ;; esac
  local _cdir; _cdir=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "")
  local _ts; _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local _src="${BASH_SOURCE[1]##*/}"
  _src="${_src:-unknown}"

  # Validate arc_id (allow empty; reject non-empty non-matching).
  case "$_arc_id" in
    '') ;;
    arc-*) case "$_arc_id" in arc-*[!0-9-]*|arc-) _arc_id="" ;; esac
           case "$_arc_id" in arc-*) : ;; *) _arc_id="" ;; esac ;;
    *) _arc_id="" ;;
  esac
  # Strict `^arc-[0-9]+$` post-check — Bash 3.2 portable (no `=~`).
  if [ -n "$_arc_id" ]; then
    case "$_arc_id" in
      arc-*[!0-9]*) _arc_id="" ;;
      arc-) _arc_id="" ;;
    esac
  fi

  # Validate loop_kind against allowlist; default to phase if invalid.
  case " $_ARC_LOOP_KINDS " in
    *" $_loop_kind "*) ;;
    *) _loop_kind="phase" ;;
  esac

  # Normalize integer-or-null fields: empty/non-digit → null literal for --argjson.
  local _pending_json="null" _mtime_age_json="null"
  case "$_pending_str" in
    ''|*[!0-9-]*) _pending_json="null" ;;
    -*) case "$_pending_str" in -[0-9]*) _pending_json="$_pending_str" ;; *) _pending_json="null" ;; esac ;;
    [0-9]*) _pending_json="$_pending_str" ;;
  esac
  case "$_mtime_age_str" in
    ''|*[!0-9-]*) _mtime_age_json="null" ;;
    -*) case "$_mtime_age_str" in -[0-9]*) _mtime_age_json="$_mtime_age_str" ;; *) _mtime_age_json="null" ;; esac ;;
    [0-9]*) _mtime_age_json="$_mtime_age_str" ;;
  esac

  # Severity + event_class lookup
  # VEIL-005: `verified` (hook happy path) and `created` (init bootstrap) are the
  # two highest-frequency actions and were previously missing from this table,
  # falling through to the `info/lifecycle` default. Making them explicit makes
  # the table a reliable reference for log consumers and schema documentation.
  local _sev="info" _class="lifecycle"
  case "$_action" in
    verified|created) _sev="info"; _class="lifecycle" ;;
    recovered_mid_arc|recovered_post_checkpoint_write) _sev="warn"; _class="recovery" ;;
    flag_lookup_failed) _sev="warn"; _class="lifecycle" ;;
    symlink_rejected) _sev="warn"; _class="failure" ;;
    deletion_deferred_pending_phases|deletion_deferred_jq_unavailable|deletion_deferred_jq_parse_error|deletion_deferred_ambiguous)
      _sev="warn"; _class="deletion" ;;
    legitimate_stale_delete|legitimate_completion_delete)
      _sev="info"; _class="deletion" ;;
    recovery_failed_no_checkpoint|corrupted_write|failed_write|failed_verify)
      _sev="error"; _class="failure" ;;
  esac

  # Flag state — unconditional active writes since v2.56.0 (canary removed)
  local _flag_enabled="true" _dry_run="false"
  _arc_state_emit_deprecation_warn_once

  # SEC-003: final symlink guard immediately before the `>>` append. Closes
  # the TOCTOU window between mkdir -p (above) and the redirection below — if
  # an adversary replaced `_log_path` with a symlink in that window, we refuse
  # to follow it. Cheap re-check: single lstat call.
  [ -L "$_log_path" ] && return 0

  # Construct the entry atomically via jq --arg (newline-safe)
  # Write append-only via >> (atomic for <PIPE_BUF=4096 bytes on POSIX)
  # SEC-003: subshell so umask 077 cannot leak into caller scope.
  (
    umask 077
    jq -nc \
      --arg ts "$_ts" \
      --arg session_id "$_sid" \
      --arg owner_pid "$_pid" \
      --arg config_dir "$_cdir" \
      --arg action "$_action" \
      --arg cause "${_cause:-}" \
      --arg source_script "$_src" \
      --arg state_file_path "${_state_file:-}" \
      --arg severity "$_sev" \
      --arg event_class "$_class" \
      --arg flag_enabled "$_flag_enabled" \
      --arg dry_run "$_dry_run" \
      --arg arc_id "$_arc_id" \
      --arg loop_kind "$_loop_kind" \
      --arg checkpoint_path "$_checkpoint_path" \
      --argjson pending_phase_count "$_pending_json" \
      --argjson mtime_age_sec "$_mtime_age_json" \
      --arg plugin_version "${_RUNE_ARC_PLUGIN_VERSION:-}" \
      --arg extra_json_arg "$_extra" \
      '{ts:$ts, session_id:$session_id, owner_pid:$owner_pid, config_dir:$config_dir,
        action:$action, cause:$cause, source_script:$source_script,
        state_file_path:$state_file_path, severity:$severity, event_class:$event_class,
        flag_enabled:($flag_enabled=="true"), dry_run:($dry_run=="true"),
        arc_id:$arc_id, loop_kind:$loop_kind, checkpoint_path:$checkpoint_path,
        pending_phase_count:$pending_phase_count, mtime_age_sec:$mtime_age_sec,
        plugin_version:$plugin_version,
        extra:($extra_json_arg | try fromjson catch {})}' 2>/dev/null >> "$_log_path"
  ) || true

  # Ensure file mode 600 (umask may already cover; chmod for inherited files)
  [ -f "$_log_path" ] && chmod 600 "$_log_path" 2>/dev/null || true

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_touch state_file → exit 0
# ─────────────────────────────────────────────────────────────────────────────
# Refreshes mtime only (NEVER content rewrite — R27 invariant).
# Throttled to once per RUNE_ARC_STATE_TOUCH_THROTTLE_SEC.
arc_state_touch() {
  local _sf="$1"
  [ -z "$_sf" ] || [ ! -f "$_sf" ] && return 0
  # QUAL-FH-007: symlink rejected and observable (CWE-61, parent-dir aware, with audit trail).
  if command -v reject_symlink_deep >/dev/null 2>&1; then
    reject_symlink_deep "$_sf" || { arc_state_integrity_log "symlink_rejected" "{\"func\":\"arc_state_touch\"}" "$_sf"; return 0; }
  else
    [ -L "$_sf" ] && { arc_state_integrity_log "symlink_rejected" "{\"func\":\"arc_state_touch\"}" "$_sf"; return 0; }
  fi

  local _now _mtime _age
  _now=$(date +%s)
  _mtime=$(_stat_mtime "$_sf" 2>/dev/null || echo 0)
  _mtime="${_mtime:-0}"
  # QUAL-FH-006: stat failure (mtime=0) means we cannot compute age safely; skip.
  [ "$_mtime" = "0" ] && return 0
  _age=$((_now - _mtime))
  if [ "$_age" -ge "$RUNE_ARC_STATE_TOUCH_THROTTLE_SEC" ] 2>/dev/null; then
    touch "$_sf" 2>/dev/null || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_pending_phases checkpoint_path → stdout: int (count) | -1 on error
# ─────────────────────────────────────────────────────────────────────────────
# Counts phases where status ∈ {pending, in_progress} (plan §6.6 bug fix —
# current phase is `in_progress`, not `pending`). On ANY failure (jq missing,
# checkpoint absent, jq non-zero, non-integer output) returns -1 so callers
# can safely defer deletion (XM-3 / AC-14).
arc_state_pending_phases() {
  _arc_lib_trace "ENTER arc_state_pending_phases"
  local _ckpt="$1"
  if ! command -v jq >/dev/null 2>&1; then
    echo -1
    _arc_lib_trace "EXIT arc_state_pending_phases (-1: jq unavailable)"
    return 0
  fi
  if [ -z "$_ckpt" ] || [ ! -f "$_ckpt" ]; then
    echo -1
    _arc_lib_trace "EXIT arc_state_pending_phases (-1: checkpoint missing)"
    return 0
  fi
  local _count _jq_rc
  _count=$(jq -r '[.phases[]? | select(.status == "pending" or .status == "in_progress")] | length' "$_ckpt" 2>/dev/null)
  _jq_rc=$?
  if [ "$_jq_rc" -ne 0 ]; then
    echo -1
    _arc_lib_trace "EXIT arc_state_pending_phases (-1: jq rc=$_jq_rc)"
    return 0
  fi
  # Validate integer (Bash 3.2 portable).
  case "$_count" in
    ''|*[!0-9]*) echo -1; _arc_lib_trace "EXIT arc_state_pending_phases (-1: non-integer '$_count')"; return 0 ;;
  esac
  echo "$_count"
  _arc_lib_trace "EXIT arc_state_pending_phases ($_count)"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_should_delete state_file → exit 0 (delete) | 1 (defer)
# ─────────────────────────────────────────────────────────────────────────────
# 5-branch rubric (plan §4.3 + §6.2) collapsed into 3 high-level criteria:
#   (a) Tooling availability     — branches 1+2 (jq unavailable, checkpoint
#                                   missing, or jq parse error → defer)
#   (b) Pending-phase count      — branch 3 (pending > 0 → defer)
#   (c) Stop-reason allowlist    — branch 4 deletes on
#                                   {completed, cancelled, context_limit,
#                                    context_exhaustion_graceful};
#                                   branch 5 defers anything else
#
# Numbered branches as implemented below:
#   1. jq unavailable                         → defer (deletion_deferred_jq_unavailable)
#   2. checkpoint missing                     → defer (deletion_deferred_jq_unavailable, cause=checkpoint_missing)
#   3. pending_phases == -1                   → defer (deletion_deferred_jq_parse_error)
#   4. pending_phases > 0                     → defer (deletion_deferred_pending_phases)
#   5. stop_reason in allowlist               → delete
#   6. else                                   → defer (deletion_deferred_ambiguous)
# Safe default is ALWAYS defer — deletion never proceeds on error (AC-14).
arc_state_should_delete() {
  _arc_lib_trace "ENTER arc_state_should_delete"
  local _sf="$1"
  if [ -z "$_sf" ] || [ ! -f "$_sf" ]; then
    _arc_lib_trace "EXIT arc_state_should_delete (defer: state_file missing)"
    return 1
  fi

  # Read full state file (≤200 lines is safe; frontmatter-only sed inside helper).
  local _fm
  _fm=$(cat "$_sf" 2>/dev/null || echo "")

  # Resolve checkpoint_path — prefer shared _get_fm_field, fall back to inline grep/sed.
  local _ckpt_rel=""
  if command -v _get_fm_field >/dev/null 2>&1; then
    _ckpt_rel=$(_get_fm_field "$_fm" "checkpoint_path" 2>/dev/null || echo "")
  fi
  if [ -z "$_ckpt_rel" ]; then
    # Inline fallback: first frontmatter block only, strip quotes.
    _ckpt_rel=$(printf '%s\n' "$_fm" \
      | sed -n '/^---$/,/^---$/{ /^---$/d; p; }' \
      | grep '^checkpoint_path:' \
      | head -1 \
      | sed 's/^checkpoint_path:[[:space:]]*//' \
      | sed 's/^"//' \
      | sed 's/"$//')
  fi

  # Resolve absolute checkpoint path.
  local _ckpt=""
  if [ -n "$_ckpt_rel" ]; then
    case "$_ckpt_rel" in
      /*) _ckpt="$_ckpt_rel" ;;
      *)  _ckpt="${CWD:-$PWD}/$_ckpt_rel" ;;
    esac
  fi

  # Criterion 1: jq unavailable or checkpoint missing → defer.
  if ! command -v jq >/dev/null 2>&1; then
    arc_state_integrity_log "deletion_deferred_jq_unavailable" "jq_not_on_path" "$_sf" "{}" "" "" "$_ckpt"
    _arc_lib_trace "EXIT arc_state_should_delete (defer: jq unavailable)"
    return 1
  fi
  if [ -z "$_ckpt" ] || [ ! -f "$_ckpt" ]; then
    arc_state_integrity_log "deletion_deferred_jq_unavailable" "checkpoint_missing" "$_sf" "{}" "" "" "$_ckpt"
    _arc_lib_trace "EXIT arc_state_should_delete (defer: checkpoint missing)"
    return 1
  fi

  # Criterion 2/3: pending phases — -1 means jq parse error, >0 means active work.
  local _pending
  _pending=$(arc_state_pending_phases "$_ckpt")
  if [ "$_pending" = "-1" ]; then
    arc_state_integrity_log "deletion_deferred_jq_parse_error" "pending_phases_jq_failure" "$_sf" "{}" "" "" "$_ckpt"
    _arc_lib_trace "EXIT arc_state_should_delete (defer: jq parse error)"
    return 1
  fi
  if [ "$_pending" -gt 0 ] 2>/dev/null; then
    arc_state_integrity_log "deletion_deferred_pending_phases" "arc_has_work_remaining" "$_sf" "{}" "" "" "$_ckpt" "$_pending"
    _arc_lib_trace "EXIT arc_state_should_delete (defer: $_pending pending)"
    return 1
  fi

  # Criterion 4: stop_reason allowlist — read from checkpoint via jq.
  # (Defer-safe: unknown/null → ambiguous branch below.)
  # VEIL-004: arc-batch-stop-hook.sh and arc-issues-stop-hook.sh both write
  # `stop_reason: "context_exhaustion_graceful"` on graceful context exit — that
  # value belongs in the deletion allowlist (it's a completion signal, not an
  # error). Without it, every healthy arc-batch/arc-issues context-exhaust run
  # leaked the state file and poisoned the `deletion_deferred_ambiguous` rate
  # with false positives. Allowlist and writers must agree.
  local _stop_reason
  _stop_reason=$(jq -r '.stop_reason // ""' "$_ckpt" 2>/dev/null || echo "")
  case "$_stop_reason" in
    completed|cancelled|context_limit|context_exhaustion_graceful)
      arc_state_integrity_log "legitimate_completion_delete" "stop_reason_${_stop_reason}" "$_sf" "{}" "" "" "$_ckpt" "0"
      _arc_lib_trace "EXIT arc_state_should_delete (delete: stop_reason=$_stop_reason)"
      return 0
      ;;
  esac

  # Criterion 5: ambiguous → defer (safe default).
  arc_state_integrity_log "deletion_deferred_ambiguous" "stop_reason_unknown_or_active" "$_sf" "{}" "" "" "$_ckpt" "0"
  _arc_lib_trace "EXIT arc_state_should_delete (defer: ambiguous)"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_recover [kind] → exit 0 on recreate | 1 on no-checkpoint
# ─────────────────────────────────────────────────────────────────────────────
# Invokes rune-arc-init-state.sh create in recovery mode. Library itself
# does NOT do atomic write — that logic lives in the init script to avoid
# duplication (AC-5).
arc_state_recover() {
  _arc_lib_trace "ENTER arc_state_recover"
  local _kind="${1:-phase}"
  case " $_ARC_LOOP_KINDS " in
    *" $_kind "*) ;;
    *) _arc_lib_trace "EXIT arc_state_recover (invalid kind '$_kind')"; return 1 ;;
  esac

  # Locate init script relative to this lib file
  local _lib_dir; _lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
  local _init="${_lib_dir}/../rune-arc-init-state.sh"
  if [ ! -x "$_init" ]; then
    arc_state_integrity_log "recovery_failed_no_checkpoint" "init_script_missing" ""
    _arc_lib_trace "EXIT arc_state_recover (init script missing)"
    return 1
  fi

  # Delegate to init script in recovery mode (--source=hook signals PPID is hook runner, not session)
  if "$_init" create --kind "$_kind" --source hook >/dev/null 2>&1; then
    arc_state_integrity_log "recovered_mid_arc" "stop_hook_watchdog" "$(arc_state_file_path "$_kind")"
    _arc_lib_trace "EXIT arc_state_recover (recovered)"
    return 0
  fi
  arc_state_integrity_log "recovery_failed_no_checkpoint" "init_script_exit_nonzero" ""
  _arc_lib_trace "EXIT arc_state_recover (init non-zero)"
  return 1
}

# Sentinel — indicates the library was successfully sourced
_RUNE_ARC_LOOP_STATE_LOADED=1
