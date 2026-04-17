#!/bin/bash
# plugins/rune/scripts/rune-arc-init-state.sh
#
# Deterministic writer for arc phase-loop state files. Replaces the LLM-driven
# Write() in skills/arc/references/arc-phase-loop-state.md and closes AC-1 of
# plans/2026-04-17-fix-arc-state-file-reliability-plan.md.
#
# USAGE:
#   rune-arc-init-state.sh create                    [--kind KIND] [--checkpoint PATH] [--force]
#                                                    [--source skill|hook]
#   rune-arc-init-state.sh verify                    [--kind KIND] [--checkpoint PATH]
#   rune-arc-init-state.sh touch                     [--kind KIND]
#   rune-arc-init-state.sh resolve-owned-checkpoint  [--source skill|hook]
#
# SUBCOMMANDS:
#   create                    Write state file atomically. If --checkpoint
#                             omitted, resolve newest .rune/arc/*/checkpoint.json
#                             owned by current session. Without --force, exit 0
#                             without overwrite when the file exists.
#   verify                    test -f on the state file; exit 0 if present,
#                             1 if missing.
#   touch                     Refresh mtime via library helper (throttled 60s).
#   resolve-owned-checkpoint  Print path of the newest owned checkpoint on
#                             stdout. Exit 1 when no owned checkpoint exists.
#                             Used by arc-phase-stop-hook.sh self-heal path.
#
# EXIT CODES:
#   0 success
#   1 state missing AND --force omitted (verify), OR recoverable failure (create)
#   2 unrecoverable failure — checkpoint missing/corrupt, invalid identity
#
# KEY PROPERTIES:
#   - INTEG Layer 1 pre-write assertions (configDir, ownerPid, sessionId, planFile)
#   - Atomic write via mktemp "${STATE_FILE}.XXXXXX" + mv -f (XM-1, R17)
#   - INTEG Layer 2 post-write cross-field verification
#   - owner_pid in HOOK mode sourced from checkpoint.json (XM-2, R19) not $PPID
#   - jq -nc --arg for every string in integrity log (CWE-93 immune)
#   - umask 077; chmod 600 on all writes
#   - Bash 3.2 compatible (no assoc arrays, no `${var,,}`, no sed -i)
#
# See plan §6.1 for full specification.

set -u
# Note: deliberately using set -u without -e / pipefail. This script uses explicit
# || { echo FATAL; return N; } patterns and intentionally-empty jq fields (// empty).
# Adding -e would require defensive `|| true` additions throughout.
umask 077

# ─────────────────────────────────────────────────────────────────────────────
# Locate script directory and source libraries
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
: "${CWD:=$PWD}"

# platform.sh → _stat_mtime, _parse_iso_epoch
if [ -f "${SCRIPT_DIR}/lib/platform.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/lib/platform.sh"
fi
# rune-state.sh → RUNE_STATE variable
if [ -f "${SCRIPT_DIR}/lib/rune-state.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/lib/rune-state.sh"
fi
# arc-loop-state.sh → arc_state_* public functions
if [ -f "${SCRIPT_DIR}/lib/arc-loop-state.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/lib/arc-loop-state.sh"
else
  echo "FATAL: lib/arc-loop-state.sh missing (expected at ${SCRIPT_DIR}/lib/arc-loop-state.sh)" >&2
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Trace helper (used only when RUNE_TRACE=1)
# ─────────────────────────────────────────────────────────────────────────────
_trace() {
  [ "${RUNE_TRACE:-0}" = "1" ] || return 0
  local _msg="$1"
  local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-$PPID.log}"
  [ ! -L "$_log" ] || return 0
  printf '[%s] rune-arc-init-state: %s\n' "$(date +%H:%M:%S)" "$_msg" >> "$_log" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: resolve newest checkpoint owned by current session
# ─────────────────────────────────────────────────────────────────────────────
_resolve_newest_checkpoint() {
  local _src="$1"  # "skill" or "hook"
  local _arc_dir="${CWD}/.rune/arc"
  [ -d "$_arc_dir" ] || return 1
  # Find newest checkpoint.json across all .rune/arc/*/ — mtime-sort via while loop
  # (xargs -I{} fails on macOS with "command line too long" for complex subcommands)
  local _newest="" _newest_mtime=0 _f _m
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    _m=$(_stat_mtime "$_f" 2>/dev/null)
    _m="${_m:-0}"
    case "$_m" in
      ''|*[!0-9]*) _m=0 ;;
    esac
    if [ "$_m" -gt "$_newest_mtime" ] 2>/dev/null; then
      _newest_mtime="$_m"
      _newest="$_f"
    fi
  done < <(find "$_arc_dir" -maxdepth 2 -name checkpoint.json -not -path "*/archived/*" 2>/dev/null)
  [ -z "$_newest" ] && return 1

  # Validate ownership — session_id is the primary match (CLAUDE.md §11).
  # PPID liveness is a secondary signal only: a live foreign PID with a DIFFERENT
  # session_id is a true foreign session; a live foreign PID with the SAME
  # session_id means the current process is a hook/subprocess of the owner
  # (XM-2: plain PPID mismatch in that case is not foreign ownership).
  if [ "$_src" = "skill" ]; then
    local _ckpt_pid _ckpt_sid _cur_sid _ckpt_comm _ownership_ok
    _ckpt_pid=$(jq -r '.owner_pid // empty' "$_newest" 2>/dev/null | tr -d '\r')
    _ckpt_sid=$(jq -r '.session_id // empty' "$_newest" 2>/dev/null | tr -d '\r')
    _cur_sid="${RUNE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    _ownership_ok=0

    # Priority 1: session_id exact match → definitive (non-empty, equal)
    if [ -n "$_ckpt_sid" ] && [ -n "$_cur_sid" ] && [ "$_ckpt_sid" = "$_cur_sid" ]; then
      _ownership_ok=1
    fi

    # Priority 2 (BACK-IDN-002 FIX, v2.53.2): When SID not resolvable in this
    # subprocess env (early-hook timing before RUNE_SESSION_ID bridges, or
    # nested shell where CLAUDE_SESSION_ID was dropped), walk up the process
    # tree and check whether _ckpt_pid is one of our ancestors. If yes, we
    # are the owning session via process ancestry.
    #
    # Before this fix: the old code compared only `$_ckpt_pid != $PPID`.
    # When called through a nested shell (e.g., `bash -c` or an Agent
    # subprocess), $PPID was the intermediate shell, not Claude Code.
    # Checkpoint.owner_pid (Claude Code PID) mismatched $PPID, and the
    # "foreign PID" branch wrongly rejected the same session.
    if [ "$_ownership_ok" = "0" ] && [ -z "$_cur_sid" ] && [ -n "$_ckpt_pid" ]; then
      if [ "$_ckpt_pid" = "$PPID" ]; then
        _ownership_ok=1
      else
        local _walk_pid _i
        _walk_pid="$PPID"
        for _i in 1 2 3 4 5; do
          _walk_pid=$(ps -o ppid= -p "$_walk_pid" 2>/dev/null | tr -d ' ')
          [ -z "$_walk_pid" ] && break
          [ "$_walk_pid" = "1" ] && break
          if [ "$_walk_pid" = "$_ckpt_pid" ]; then
            _trace "SID unresolved but _ckpt_pid $_ckpt_pid is process ancestor (depth=$_i) — trusting"
            _ownership_ok=1
            break
          fi
        done
      fi
    fi

    # Priority 3: PID-based foreign-session rejection (existing logic)
    if [ "$_ownership_ok" = "0" ] && [ -n "$_ckpt_pid" ] && [ "$_ckpt_pid" != "$PPID" ]; then
      if kill -0 "$_ckpt_pid" 2>/dev/null; then
        # Cross-check comm — if PID is alive but not Claude Code, treat as dead
        # (orphan recovery, protects against PID reuse by unrelated processes).
        _ckpt_comm=$(ps -o comm= -p "$_ckpt_pid" 2>/dev/null | awk '{print $1}')
        if [ -z "$_ckpt_comm" ]; then
          _trace "ps lookup failed for pid=$_ckpt_pid — treating as dead"
        else
          case "$_ckpt_comm" in
            claude|claude-code|node|cc)
              _trace "checkpoint owned by live foreign PID $_ckpt_pid (sid=${_ckpt_sid:-n/a}, comm=$_ckpt_comm) — refusing"
              return 1
              ;;
            *)
              _trace "ckpt_pid $_ckpt_pid foreign comm=$_ckpt_comm — treating as dead"
              ;;
          esac
        fi
      fi
      # Dead PID — safe to claim (orphan recovery)
    fi
    if [ -z "$_ckpt_sid" ] && [ -z "$_ckpt_pid" ]; then
      _trace "checkpoint missing both session_id and owner_pid — refusing (fail-closed)"
      return 1
    fi
  fi
  printf '%s\n' "$_newest"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: extract fields from checkpoint
# ─────────────────────────────────────────────────────────────────────────────
_ck_field() {
  local _cp="$1" _field="$2"
  # SEC-004: allowlist field names to letters/digits/dot/underscore only — $_field is
  # interpolated directly into the jq filter (jq paths cannot use --arg), so any
  # future caller passing checkpoint-derived or user-controlled input would be a
  # CWE-93 injection vector. All current callers pass literals, but defense in depth.
  case "$_field" in
    *[!a-zA-Z0-9._]*) echo ""; return 1 ;;
    '') echo ""; return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || { echo ""; return 1; }
  jq -r ".$_field // empty" "$_cp" 2>/dev/null | tr -d '\n\r'
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: create
# ─────────────────────────────────────────────────────────────────────────────
cmd_create() {
  local _kind="phase" _cp="" _force=0 _src="skill" _iteration="" _iteration_explicit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) _kind="$2"; shift 2 ;;
      --checkpoint) _cp="$2"; shift 2 ;;
      --force) _force=1; shift ;;
      --source) _src="$2"; shift 2 ;;
      --iteration) _iteration="$2"; _iteration_explicit=1; shift 2 ;;
      *) echo "FATAL: unknown arg: $1" >&2; return 2 ;;
    esac
  done

  # Validate --iteration if provided (must be non-negative integer); otherwise
  # we compute it below (recovery path) or default to 0 (skill bootstrap).
  if [ "$_iteration_explicit" = "1" ]; then
    case "$_iteration" in
      ''|*[!0-9]*) _iteration=0 ;;
    esac
  fi

  # Validate kind
  case " phase batch hierarchy issues " in
    *" $_kind "*) ;;
    *) echo "FATAL: invalid kind: $_kind" >&2; return 2 ;;
  esac

  # Validate source
  case "$_src" in
    skill|hook) ;;
    *) echo "FATAL: invalid --source: $_src" >&2; return 2 ;;
  esac

  # Flag check (fail-open: even if disabled, create may still run in dry-run
  # mode during canary. For now we honor the flag only for integrity log
  # dry_run tagging — the actual write always proceeds when invoked directly.)
  # The dry_run flag state is stamped into every integrity log entry.

  # Resolve checkpoint
  if [ -z "$_cp" ]; then
    _cp=$(_resolve_newest_checkpoint "$_src" || true)
  fi
  if [ -z "$_cp" ] || [ ! -f "$_cp" ]; then
    _trace "no checkpoint found"
    arc_state_integrity_log "recovery_failed_no_checkpoint" "no_checkpoint_in_arc_dir" ""
    return 2
  fi

  # Path validation: canonical .rune/arc/arc-{ts}/checkpoint.json (SEC — AC-11, §16)
  case "$_cp" in
    *..*)     echo "FATAL: checkpoint path traversal: $_cp" >&2; return 2 ;;
  esac

  # INTEG Layer 1 pre-write assertions
  local _arc_id _plan _branch
  _arc_id=$(_ck_field "$_cp" 'id')
  _plan=$(_ck_field "$_cp" 'plan_file')
  _branch=$(git -C "${CWD}" branch --show-current 2>/dev/null | tr -d '\r')
  [ -z "$_branch" ] && _branch="main"

  # SEC — Issue 2: validate arc_id against canonical pattern before any path construction
  case "$_arc_id" in
    arc-[0-9]*[0-9]) ;;
    *) echo "FATAL (INTEG-INIT-003): arc_id invalid: $_arc_id" >&2; return 2 ;;
  esac
  # Additional strict check
  if ! printf '%s' "$_arc_id" | grep -Eq '^arc-[0-9]+$'; then
    echo "FATAL (INTEG-INIT-003): arc_id fails regex: $_arc_id" >&2
    return 2
  fi

  if [ -z "$_plan" ] || [ "$_plan" = "null" ]; then
    echo "FATAL (INTEG-INIT-005): plan_file empty" >&2
    return 2
  fi

  # Identity resolution
  local _cdir _pid _sid _tmpdir_canonical
  _cdir=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P)
  # FLAW-005: INTEG-INIT-001 originally rejected relative `tmp/*` and `./tmp/*`
  # but missed absolute `/tmp/*` (the most common temp-dir form) — a misconfigured
  # CLAUDE_CONFIG_DIR=/tmp/rune would pass the guard. Add `/tmp/*` and the
  # canonical system-temp-dir prefix so shared-temp cross-user state collisions
  # are blocked.
  _tmpdir_canonical="${TMPDIR:-/tmp}"
  _tmpdir_canonical="${_tmpdir_canonical%/}"
  case "$_cdir" in
    ''|tmp/*|./tmp/*|*/tmp/arc/*|/tmp/*|/private/tmp/*)
      echo "FATAL (INTEG-INIT-001): configDir invalid: $_cdir" >&2
      return 2
      ;;
  esac
  # Also reject the (canonical) $TMPDIR prefix when it differs from /tmp (e.g. macOS `/var/folders/…`).
  case "$_tmpdir_canonical" in
    ''|/tmp|/private/tmp) ;;  # already covered above
    *)
      case "$_cdir" in
        "${_tmpdir_canonical}"/*)
          echo "FATAL (INTEG-INIT-001): configDir under \$TMPDIR: $_cdir" >&2
          return 2
          ;;
      esac
      ;;
  esac

  # SEC — Issue 2: CHOME UID ownership check — reject configDir owned by another
  # user to prevent cross-account state tampering. Graceful fallback when
  # _stat_uid is unavailable (e.g. platform.sh failed to source) — do not block.
  if command -v _stat_uid >/dev/null 2>&1; then
    local _cdir_uid
    _cdir_uid=$(_stat_uid "$_cdir" 2>/dev/null || echo "")
    if [ -n "$_cdir_uid" ] && [ "$_cdir_uid" != "$(id -u)" ]; then
      echo "FATAL: configDir $_cdir not owned by current user (uid=$_cdir_uid, expected=$(id -u))" >&2
      return 2
    fi
  fi

  # Iteration computation — recovery path: when --source hook AND --iteration
  # not provided AND checkpoint is readable, derive from completed phase count.
  # Preserves default 0 on any failure (bootstrap path).
  if [ "$_iteration_explicit" = "0" ]; then
    _iteration=0
    if [ "$_src" = "hook" ] && command -v jq >/dev/null 2>&1 && [ -r "$_cp" ]; then
      local _it
      _it=$(jq -r '[.phases[]? | select(.status == "completed")] | length' "$_cp" 2>/dev/null | tr -d '\r')
      case "$_it" in
        ''|*[!0-9]*) _iteration=0 ;;
        *) _iteration="$_it" ;;
      esac
    fi
  fi

  if [ "$_src" = "hook" ]; then
    # XM-2: use checkpoint's owner_pid in hook context (PPID is hook runner)
    _pid=$(_ck_field "$_cp" 'owner_pid')
  else
    _pid="$PPID"
  fi
  case "$_pid" in
    ''|*[!0-9]*) echo "FATAL (INTEG-INIT-002): ownerPid invalid: $_pid" >&2; return 2 ;;
  esac

  _sid="${RUNE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  if [ -z "$_sid" ]; then
    _sid=$(_ck_field "$_cp" 'session_id')
  fi
  if [ -z "$_sid" ] || [ "$_sid" = "unknown" ]; then
    echo "FATAL (INTEG-INIT-006): sessionId unavailable" >&2
    return 2
  fi
  # SEC — Issue 5: session_id must be non-empty AND regex-clean
  case "$_sid" in
    *[!a-zA-Z0-9_-]*) echo "FATAL (INTEG-INIT-SEC): sessionId has invalid chars" >&2; return 2 ;;
  esac

  # Resolve state file path via lib
  local _state_file
  _state_file=$(arc_state_file_path "$_kind") || {
    echo "FATAL: arc_state_file_path failed for kind=$_kind" >&2
    return 2
  }

  # Symlink reject (SEC CWE-61) — deep walk from target up to repo root / $HOME.
  # Falls back to shallow `-L` check if helper is unavailable (platform.sh missing).
  if command -v reject_symlink_deep >/dev/null 2>&1; then
    if ! reject_symlink_deep "$_state_file"; then
      echo "FATAL (SEC): state file path contains a symlink component: $_state_file" >&2
      return 2
    fi
  elif [ -L "$_state_file" ]; then
    echo "FATAL (SEC): state file is a symlink: $_state_file" >&2
    return 2
  fi

  # Idempotent unless --force
  if [ "$_force" = "0" ] && [ -f "$_state_file" ]; then
    _trace "state file exists, no --force — verified"
    arc_state_integrity_log "verified" "idempotent_skip" "$_state_file"
    return 0
  fi

  # Build state content
  local _ckpt_rel
  _ckpt_rel="${_cp#${CWD}/}"
  local _flags_line=""
  local _flag_no_forge _flag_approve _flag_no_test _flag_bot
  _flag_no_forge=$(_ck_field "$_cp" 'flags.no_forge')
  _flag_approve=$(_ck_field "$_cp" 'flags.approve')
  _flag_no_test=$(_ck_field "$_cp" 'flags.no_test')
  _flag_bot=$(_ck_field "$_cp" 'flags.bot_review')
  [ "$_flag_no_forge" = "true" ] && _flags_line="${_flags_line}--no-forge "
  [ "$_flag_approve" = "true" ]  && _flags_line="${_flags_line}--approve "
  [ "$_flag_no_test" = "true" ]  && _flags_line="${_flags_line}--no-test "
  [ "$_flag_bot" = "true" ]      && _flags_line="${_flags_line}--bot-review "
  _flags_line="${_flags_line% }"

  local _state_dir
  _state_dir=$(dirname "$_state_file")
  mkdir -p "$_state_dir" 2>/dev/null

  # Atomic write via same-dir mktemp (XM-1 / R17)
  local _tmp
  _tmp=$(mktemp "${_state_file}.XXXXXX" 2>/dev/null) || {
    echo "FATAL: mktemp failed in $(dirname "$_state_file")" >&2
    return 1
  }
  # FLAW-003: Cleanup trap MUST survive cmd_create's return frame. The previous
  # pattern captured function-local `$_tmp` — under `set -u`, if a signal (SIGTERM/
  # SIGHUP) arrived after cmd_create returned but before `trap - EXIT` cleared the
  # trap, the EXIT handler saw `_tmp` as unbound and aborted before `rm` ran, leaking
  # the temp file. Using a module-level `_RUNE_INIT_TMP` var keeps the path
  # accessible across frames. Cleared on all normal exit paths.
  _RUNE_INIT_TMP="$_tmp"
  _cleanup_tmp() { [ -n "${_RUNE_INIT_TMP:-}" ] && rm -f -- "$_RUNE_INIT_TMP" 2>/dev/null; _RUNE_INIT_TMP=""; }
  trap _cleanup_tmp EXIT

  # SEC-005: Quote identity fields that are fed into YAML frontmatter. `_branch`
  # comes from `git branch --show-current` and can contain YAML-significant chars
  # (`:` `#` `|` `>`). `_plan` is already neutralized of newlines by _ck_field's
  # `tr -d '\n\r'` but may still contain spaces. Quoting them is the minimal fix.
  # Strip embedded double quotes to prevent escaping the quoted form.
  local _plan_yaml _branch_yaml
  _plan_yaml="$(printf '%s' "$_plan" | tr -d '"')"
  _branch_yaml="$(printf '%s' "$_branch" | tr -d '"')"

  {
    printf -- '---\n'
    printf 'active: true\n'
    printf 'iteration: %d\n' "$_iteration"
    printf 'max_iterations: 66\n'
    printf 'checkpoint_path: %s\n' "$_ckpt_rel"
    printf 'plan_file: "%s"\n' "$_plan_yaml"
    printf 'branch: "%s"\n' "$_branch_yaml"
    printf 'arc_flags: %s\n' "$_flags_line"
    printf 'config_dir: %s\n' "$_cdir"
    printf 'owner_pid: %s\n' "$_pid"
    printf 'session_id: %s\n' "$_sid"
    printf 'compact_pending: false\n'
    printf 'user_cancelled: false\n'
    printf 'cancel_reason: null\n'
    printf 'cancelled_at: null\n'
    printf 'stop_reason: null\n'
    printf 'group_mode: null\n'
    printf 'group_paused: null\n'
    printf -- '---\n'
  } > "$_tmp" 2>/dev/null

  chmod 600 "$_tmp" 2>/dev/null

  if ! mv -f "$_tmp" "$_state_file" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    _RUNE_INIT_TMP=""
    trap - EXIT
    arc_state_integrity_log "failed_write" "mv_f_failed" "$_state_file"
    echo "FATAL: mv -f failed — tmp file removed" >&2
    return 1
  fi
  _RUNE_INIT_TMP=""
  trap - EXIT

  # Layer 2 post-write verification — re-read fields. `plan_file` is now
  # quoted (SEC-005), so strip surrounding double quotes before comparison.
  local _v_cdir _v_pid _v_sid _v_plan
  _v_cdir=$(sed -n 's/^config_dir:[[:space:]]*//p' "$_state_file" | head -1)
  _v_pid=$(sed -n 's/^owner_pid:[[:space:]]*//p' "$_state_file" | head -1)
  _v_sid=$(sed -n 's/^session_id:[[:space:]]*//p' "$_state_file" | head -1)
  _v_plan=$(sed -n 's/^plan_file:[[:space:]]*//p' "$_state_file" | head -1)
  _v_plan="${_v_plan#\"}"; _v_plan="${_v_plan%\"}"
  if [ "$_v_cdir" != "$_cdir" ] || [ "$_v_pid" != "$_pid" ] \
     || [ "$_v_sid" != "$_sid" ] || [ "$_v_plan" != "$_plan_yaml" ]; then
    arc_state_integrity_log "corrupted_write" "layer2_mismatch" "$_state_file"
    echo "FATAL (INTEG-POST): Layer 2 cross-field verification failed" >&2
    # QUAL-FH-003: remove the corrupted file so subsequent cmd_verify sees it as missing
    rm -f -- "$_state_file" 2>/dev/null
    return 1
  fi

  local _action="created"
  [ "$_src" = "hook" ] && _action="recovered_post_checkpoint_write"
  arc_state_integrity_log "$_action" "src=$_src,kind=$_kind" "$_state_file"
  _trace "create ok: $_state_file (src=$_src kind=$_kind)"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: verify
# ─────────────────────────────────────────────────────────────────────────────
cmd_verify() {
  local _kind="phase"
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) _kind="$2"; shift 2 ;;
      --checkpoint) shift 2 ;;  # ignored for verify
      *) shift ;;
    esac
  done
  local _sf
  _sf=$(arc_state_file_path "$_kind") || return 2
  if [ -f "$_sf" ]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: touch
# ─────────────────────────────────────────────────────────────────────────────
cmd_touch() {
  local _kind="phase"
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) _kind="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local _sf
  _sf=$(arc_state_file_path "$_kind") || return 2
  arc_state_touch "$_sf"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: resolve-owned-checkpoint
#
# Thin wrapper around _resolve_newest_checkpoint(). Prints the checkpoint path
# of the most-recent checkpoint owned by the current session to stdout.
# Exit 0 on success, exit 1 when no owned checkpoint is found (covers both
# "no checkpoints at all" and "only foreign checkpoints exist").
#
# Used by arc-phase-stop-hook.sh GUARD 4 self-heal path (Task 2, v2.54.0):
# before re-creating a missing state file, the Stop hook must confirm that
# the current session actually owns an active arc — otherwise a stale
# foreign-session checkpoint could trigger unwanted recovery.
# ─────────────────────────────────────────────────────────────────────────────
cmd_resolve_owned_checkpoint() {
  local _src="skill"
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) _src="$2"; shift 2 ;;
      *) echo "FATAL: unknown arg: $1" >&2; return 2 ;;
    esac
  done
  case "$_src" in
    skill|hook) ;;
    *) echo "FATAL: invalid --source: $_src" >&2; return 2 ;;
  esac
  local _cp
  _cp=$(_resolve_newest_checkpoint "$_src" || true)
  if [ -z "$_cp" ]; then
    return 1
  fi
  printf '%s\n' "$_cp"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatcher
# ─────────────────────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
  cat <<'USAGE' >&2
Usage: rune-arc-init-state.sh <create|verify|touch|resolve-owned-checkpoint> [flags]
  create                    [--kind phase|batch|hierarchy|issues] [--checkpoint PATH]
                            [--force] [--source skill|hook]
  verify                    [--kind KIND]
  touch                     [--kind KIND]
  resolve-owned-checkpoint  [--source skill|hook]
USAGE
  exit 2
fi

_cmd="$1"; shift
case "$_cmd" in
  create) cmd_create "$@"; exit $? ;;
  verify) cmd_verify "$@"; exit $? ;;
  touch)  cmd_touch  "$@"; exit $? ;;
  resolve-owned-checkpoint) cmd_resolve_owned_checkpoint "$@"; exit $? ;;
  *) echo "FATAL: unknown subcommand: $_cmd" >&2; exit 2 ;;
esac
