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
#   rune-arc-init-state.sh doctor                    [--kind KIND] [--json]
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
#   doctor                    Report per-loop-kind health (phase/batch/hierarchy/
#                             issues): checkpoint existence, state file existence,
#                             ownership match, pending phases. Exit 0 when all
#                             invariants hold, exit 1 with actionable fix hint
#                             when violated. --json toggles structured output.
#
# EXIT CODES:
#   0 success (or, for doctor: all invariants hold — 0 issues found)
#   1 state missing AND --force omitted (verify), OR recoverable failure
#     (create), OR doctor found 1+ issues (checkpoint without state file,
#     orphan state file with dead owner_pid, etc. — see "Recommended fix")
#   2 unrecoverable failure — checkpoint missing/corrupt, invalid identity,
#     OR invalid argument (e.g., doctor --kind not in {phase,batch,hierarchy,issues})
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
    # BACK-IDN-004 + BACK-IDN-005 (v2.65.5) FIX: Three-tier session_id priority
    # matches the writer (cmd_create) at line ~398. HOOK_SESSION_ID is the hook
    # stdin session_id, parsed by the caller (e.g., verify-arc-state-integrity.sh)
    # and passed into this subprocess. It is always fresh per-hook-fire and must
    # rank above the bridged RUNE_SESSION_ID which can lag on resume.
    _cur_sid="${CLAUDE_SESSION_ID:-${HOOK_SESSION_ID:-${RUNE_SESSION_ID:-}}}"
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
    skill|hook|session-start|worktree) ;;
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

  # ── TERMINAL-CHECKPOINT GUARD (v2.62.1) ──
  # Skip state-file (re)creation when the target checkpoint has reached terminal
  # state (all phases completed/skipped AND completed_at stamped). Without this
  # guard the Stop hook's self-heal path (arc-phase-stop-hook.sh:148) and the
  # PostToolUse verify-arc-state-integrity.sh hook keep recreating the phase
  # loop state file after post-arc completion, causing the stop hook to
  # re-inject the "MANDATORY post-arc steps" prompt on every Stop event.
  #
  # --force bypasses this guard so explicit operator intent (e.g.,
  # `/rune:arc --resume` on a terminal arc that needs rehydration) still works.
  #
  # QUAL-002 (v2.63.0): Sibling guard in arc-phase-stop-hook.sh:152 uses the
  # same predicate. Both files are bash shebang, so both now use `[[ ]]` for
  # consistency. If this guard is refactored, update the sibling in lockstep
  # (or extract to lib/arc-stop-hook-common.sh in a future change).
  # BACK-003 (v2.63.0): warn-loud when jq is absent so v2.62.1 regressions
  # are observable in minimal images.
  if [[ "$_force" = "0" ]] && [[ "$_kind" = "phase" ]]; then
    if command -v jq >/dev/null 2>&1; then
      local _cp_completed _cp_non_terminal
      _cp_completed=$(jq -r '.completed_at // empty' "$_cp" 2>/dev/null | tr -d '\r')
      _cp_non_terminal=$(jq -r '[.phases[]? | select(.status == "pending" or .status == "in_progress")] | length' "$_cp" 2>/dev/null | tr -d '\r')
      case "$_cp_non_terminal" in ''|*[!0-9]*) _cp_non_terminal=0 ;; esac
      if [[ -n "$_cp_completed" ]] && [[ "$_cp_non_terminal" = "0" ]]; then
        _trace "skip state file create: checkpoint terminal (completed_at=${_cp_completed}, non_terminal=0)"
        arc_state_integrity_log "skipped_terminal_checkpoint" "post_arc_finalized" "$_cp"
        return 0
      fi
    else
      _trace "WARN: jq absent — terminal-checkpoint guard degraded (v2.62.1 regression risk). Install jq to restore guard."
    fi
  fi

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

  # BACK-IDN-004 + BACK-IDN-005 (v2.65.5) FIX: Three-tier session_id priority.
  # Priority order (most-authoritative first):
  #   1. CLAUDE_SESSION_ID — native harness env var (authoritative when set)
  #   2. HOOK_SESSION_ID   — parsed from hook stdin JSON per-fire (always fresh;
  #                          passed as env var by verify-arc-state-integrity.sh
  #                          and other hook-side callers)
  #   3. RUNE_SESSION_ID   — bridged by SessionStart hook into CLAUDE_ENV_FILE;
  #                          can lag on resume (session-start.sh skips the update
  #                          when hook stdin lacks session_id, leaving the old
  #                          value stamped into state files). Keep as last-resort
  #                          fallback only — prefer hook-fresh sources above.
  # When only RUNE_SESSION_ID is set and differs from the checkpoint's own
  # session_id, we prefer the checkpoint's recorded session_id (same session
  # that created the checkpoint) to avoid imprinting a stale bridge value.
  _sid="${CLAUDE_SESSION_ID:-${HOOK_SESSION_ID:-${RUNE_SESSION_ID:-}}}"
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
  case "$_src" in
    hook) _action="recovered_post_checkpoint_write" ;;
    session-start) _action="hydrated_at_session_start" ;;
    worktree) _action="hydrated_at_worktree_create" ;;
  esac
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
  # _resolve_newest_checkpoint only enforces ownership validation when invoked
  # with "skill". The "hook" branch skips the validation entirely — which is
  # correct for cmd_create (hook has separate checkpoint-derived identity) but
  # WRONG for cmd_resolve_owned_checkpoint where the CALLER (Stop hook GUARD 4)
  # depends on the ownership gate to prevent hydrating foreign-owned state.
  # Hardcode "skill" regardless of caller's --source flag — the --source flag
  # stays in the CLI contract for future use, but ownership check is mandatory.
  local _cp
  _cp=$(_resolve_newest_checkpoint "skill" || true)
  if [ -z "$_cp" ]; then
    return 1
  fi
  printf '%s\n' "$_cp"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: doctor
#
# Report health of the 4 arc loop kinds (phase/batch/hierarchy/issues):
#   - checkpoint: presence + pending-phase count (for `phase` kind only)
#   - state_file: presence + size
#   - ownership:  OWNED (state file session_id matches current subshell) /
#                 HELD_BY_OTHER (different live session owns it; v2.65.5 — was
#                 "FOREIGN" pre-v2.65.5 but renamed to make POV explicit) /
#                 ORPHAN (state file present but its owner_pid is dead) /
#                 N/A (state file absent) / UNKNOWN (cannot determine)
#   - integrity:  brief status line
#
# Exit 0 when all invariants hold (owned checkpoint + matching state file, OR
# clean slate with no checkpoint and no state file). Exit 1 with an actionable
# "Recommended fix" hint when any invariant is violated.
#
# Text output is the default; --json produces structured output for automation.
# ─────────────────────────────────────────────────────────────────────────────
_doctor_kind_checkpoint_path() {
  # Return newest checkpoint path for the given kind.
  # Only `phase` has a canonical checkpoint under .rune/arc/*/checkpoint.json.
  # batch/hierarchy/issues are loop state files — no checkpoint counterpart.
  case "$1" in
    phase)
      local _arc_dir="${CWD}/.rune/arc"
      [ -d "$_arc_dir" ] || return 1
      local _newest="" _newest_mtime=0 _f _m
      while IFS= read -r _f; do
        [ -z "$_f" ] && continue
        _m=$(_stat_mtime "$_f" 2>/dev/null)
        _m="${_m:-0}"
        case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
        if [ "$_m" -gt "$_newest_mtime" ] 2>/dev/null; then
          _newest_mtime="$_m"
          _newest="$_f"
        fi
      done < <(find "$_arc_dir" -maxdepth 2 -name checkpoint.json -not -path "*/archived/*" 2>/dev/null)
      [ -z "$_newest" ] && return 1
      printf '%s\n' "$_newest"
      ;;
    *)
      # No checkpoint concept for batch/hierarchy/issues
      return 1
      ;;
  esac
}

_doctor_report_kind() {
  # $1 kind, $2 json_flag (0|1)
  local _kind="$1" _json="$2"
  local _cp="" _sf=""
  local _cp_status="none" _cp_detail=""
  local _sf_status="absent" _sf_detail="OK"
  local _own_status="N/A" _own_detail=""
  local _integ_status="N/A" _integ_detail=""
  local _issue_count=0 _fix_hint=""

  # Resolve state file path via library
  _sf=$(arc_state_file_path "$_kind" 2>/dev/null) || _sf=""

  # Resolve checkpoint (phase kind only)
  _cp=$(_doctor_kind_checkpoint_path "$_kind" 2>/dev/null) || _cp=""

  # Checkpoint block
  if [ -n "$_cp" ] && [ -f "$_cp" ]; then
    _cp_status="present"
    if [ "$_kind" = "phase" ] && command -v jq >/dev/null 2>&1; then
      local _pending
      _pending=$(jq -r '[.phases[]? | select(.status == "pending")] | length' "$_cp" 2>/dev/null | tr -d '\r')
      case "$_pending" in ''|*[!0-9]*) _pending=0 ;; esac
      _cp_detail="$_pending pending phases"
    fi
  fi

  # State file block
  if [ -n "$_sf" ] && [ -f "$_sf" ]; then
    _sf_status="present"
    local _size
    _size=$(wc -c < "$_sf" 2>/dev/null | tr -d ' ')
    case "$_size" in ''|*[!0-9]*) _size=0 ;; esac
    _sf_detail="${_size}B"
  elif [ "$_cp_status" = "present" ]; then
    _sf_status="MISSING"
    _sf_detail="run: create --source skill"
    _issue_count=$((_issue_count + 1))
    [ -z "$_fix_hint" ] && _fix_hint="run 'bash $(basename "${BASH_SOURCE[0]}") create --source skill --kind $_kind' to hydrate the missing state file"
  fi

  # Ownership block
  if [ "$_sf_status" = "present" ]; then
    local _sf_sid _sf_pid _cur_sid
    _sf_sid=$(sed -n 's/^session_id:[[:space:]]*//p' "$_sf" 2>/dev/null | head -1 | tr -d '\r')
    _sf_pid=$(sed -n 's/^owner_pid:[[:space:]]*//p' "$_sf" 2>/dev/null | head -1 | tr -d '\r')
    # BACK-IDN-004 + BACK-IDN-005 (v2.65.5): three-tier priority, matching the
    # writer (cmd_create) and _resolve_newest_checkpoint above.
    _cur_sid="${CLAUDE_SESSION_ID:-${HOOK_SESSION_ID:-${RUNE_SESSION_ID:-}}}"

    if [ -n "$_sf_sid" ] && [ -n "$_cur_sid" ] && [ "$_sf_sid" = "$_cur_sid" ]; then
      _own_status="OWNED"
      _own_detail="session_id match"
    elif [ -n "$_sf_pid" ] && ! kill -0 "$_sf_pid" 2>/dev/null; then
      _own_status="ORPHAN"
      _own_detail="owner_pid=$_sf_pid dead"
      _issue_count=$((_issue_count + 1))
      [ -z "$_fix_hint" ] && _fix_hint="remove stale state file '$_sf' (dead owner PID $_sf_pid)"
    elif [ -n "$_sf_sid" ] && [ -n "$_cur_sid" ] && [ "$_sf_sid" != "$_cur_sid" ]; then
      # v2.65.5 (BACK-IDN-005): rename from "FOREIGN" to "HELD_BY_OTHER".
      # "FOREIGN" was misleading when the doctor subshell had a stale self-identity
      # (CLAUDE_SESSION_ID scrubbed + RUNE_SESSION_ID lagging) — it accused the
      # user's own session of being foreign. The new label makes the POV explicit:
      # the state file IS held, but not by THIS subshell. Pair with P1 three-tier
      # session_id priority so false positives become rare.
      _own_status="HELD_BY_OTHER"
      _own_detail="held by session ${_sf_sid:0:16}... (pid=${_sf_pid:-?}); this subshell resolves as ${_cur_sid:0:16}..."
    else
      _own_status="UNKNOWN"
      _own_detail="cannot determine ownership"
    fi
  else
    _own_detail="no state file"
  fi

  # Integrity line
  if [ "$_sf_status" = "present" ]; then
    _integ_status="OK"
    _integ_detail="state file readable"
  else
    _integ_detail="state file absent"
  fi

  # Checkpoint-without-state = the most actionable issue for `phase` kind
  if [ "$_kind" = "phase" ] && [ "$_cp_status" = "present" ] && [ "$_sf_status" = "MISSING" ]; then
    _integ_status="DEGRADED"
    _integ_detail="checkpoint owned but state file absent — stop hook will stall at GUARD 4"
  fi

  if [ "$_json" = "1" ]; then
    # JSON object per kind (comma handled by caller via index)
    printf '  "%s": {\n' "$_kind"
    printf '    "checkpoint": { "path": %s, "status": "%s", "detail": "%s" },\n' \
      "$(printf '%s' "${_cp:-null}" | jq -R . 2>/dev/null || printf '"%s"' "${_cp:-}")" \
      "$_cp_status" "$_cp_detail"
    printf '    "state_file": { "path": %s, "status": "%s", "detail": "%s" },\n' \
      "$(printf '%s' "${_sf:-null}" | jq -R . 2>/dev/null || printf '"%s"' "${_sf:-}")" \
      "$_sf_status" "$_sf_detail"
    printf '    "ownership": { "status": "%s", "detail": "%s" },\n' "$_own_status" "$_own_detail"
    printf '    "integrity": { "status": "%s", "detail": "%s" },\n' "$_integ_status" "$_integ_detail"
    printf '    "issues": %d\n' "$_issue_count"
    printf '  }'
  else
    printf 'Loop kind: %s\n' "$_kind"
    if [ -n "$_cp" ]; then
      printf '  checkpoint:    %s (%s%s)\n' "$_cp" "$_cp_status" "${_cp_detail:+, $_cp_detail}"
    else
      printf '  checkpoint:    none\n'
    fi
    if [ -n "$_sf" ]; then
      if [ "$_sf_status" = "MISSING" ]; then
        printf '  state_file:    %s (MISSING — %s)\n' "$_sf" "$_sf_detail"
      elif [ "$_sf_status" = "absent" ]; then
        printf '  state_file:    %s (absent — %s)\n' "$_sf" "$_sf_detail"
      else
        printf '  state_file:    %s (%s, %s)\n' "$_sf" "$_sf_status" "$_sf_detail"
      fi
    fi
    if [ "$_own_status" = "N/A" ]; then
      printf '  ownership:     N/A (%s)\n' "$_own_detail"
    else
      printf '  ownership:     %s (%s)\n' "$_own_status" "$_own_detail"
    fi
    printf '  integrity:     %s (%s)\n' "$_integ_status" "$_integ_detail"
  fi

  # Emit fix hint to global aggregator via stderr (captured by caller)
  if [ -n "$_fix_hint" ]; then
    printf '%s\n' "$_fix_hint" >&3
  fi
  return "$_issue_count"
}

cmd_doctor() {
  local _kind="" _json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) _kind="$2"; shift 2 ;;
      --json) _json=1; shift ;;
      *) echo "FATAL: unknown arg: $1" >&2; return 2 ;;
    esac
  done

  local _kinds=""
  if [ -n "$_kind" ]; then
    case " phase batch hierarchy issues " in
      *" $_kind "*) _kinds="$_kind" ;;
      *) echo "FATAL: invalid kind: $_kind" >&2; return 2 ;;
    esac
  else
    _kinds="phase batch hierarchy issues"
  fi

  # Collect fix hints via fd 3
  local _hints_file
  _hints_file=$(mktemp "${TMPDIR:-/tmp}/rune-arc-doctor-hints.XXXXXX") || {
    echo "FATAL: mktemp failed for hint capture" >&2
    return 2
  }
  trap 'rm -f "$_hints_file" 2>/dev/null' EXIT

  local _total_issues=0 _first=1 _k _k_rc
  if [ "$_json" = "1" ]; then
    printf '{\n'
    printf '  "arc_doctor_version": 1,\n'
    printf '  "checked_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    printf '  "session_id": "%s",\n' "${RUNE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    printf '  "kinds": {\n'
  fi

  for _k in $_kinds; do
    if [ "$_json" = "1" ] && [ "$_first" = "0" ]; then
      printf ',\n'
    fi
    _doctor_report_kind "$_k" "$_json" 3>>"$_hints_file"
    _k_rc=$?
    _total_issues=$((_total_issues + _k_rc))
    _first=0
    [ "$_json" = "0" ] && printf '\n'
  done

  if [ "$_json" = "1" ]; then
    printf '\n  },\n'
    printf '  "total_issues": %d,\n' "$_total_issues"
    printf '  "fix_hints": [\n'
    local _first_hint=1 _hint
    while IFS= read -r _hint; do
      [ -z "$_hint" ] && continue
      [ "$_first_hint" = "0" ] && printf ',\n'
      printf '    %s' "$(printf '%s' "$_hint" | jq -R . 2>/dev/null || printf '"%s"' "$_hint")"
      _first_hint=0
    done < "$_hints_file"
    printf '\n  ]\n'
    printf '}\n'
  else
    if [ "$_total_issues" -eq 0 ]; then
      printf 'Overall: 0 issues found. All invariants hold.\n'
    else
      printf 'Overall: %d issue(s) found.\n' "$_total_issues"
      local _hint
      while IFS= read -r _hint; do
        [ -z "$_hint" ] && continue
        printf 'Recommended fix: %s\n' "$_hint"
      done < "$_hints_file"
    fi
  fi

  rm -f "$_hints_file" 2>/dev/null
  trap - EXIT

  [ "$_total_issues" -eq 0 ] && return 0
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatcher
# ─────────────────────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
  cat <<'USAGE' >&2
Usage: rune-arc-init-state.sh <create|verify|touch|resolve-owned-checkpoint|doctor> [flags]
  create                    [--kind phase|batch|hierarchy|issues] [--checkpoint PATH]
                            [--force] [--source skill|hook]
  verify                    [--kind KIND]
  touch                     [--kind KIND]
  resolve-owned-checkpoint  [--source skill|hook]
  doctor                    [--kind KIND] [--json]
USAGE
  exit 2
fi

_cmd="$1"; shift
case "$_cmd" in
  create) cmd_create "$@"; exit $? ;;
  verify) cmd_verify "$@"; exit $? ;;
  touch)  cmd_touch  "$@"; exit $? ;;
  resolve-owned-checkpoint) cmd_resolve_owned_checkpoint "$@"; exit $? ;;
  doctor) cmd_doctor "$@"; exit $? ;;
  *) echo "FATAL: unknown subcommand: $_cmd" >&2; exit 2 ;;
esac
