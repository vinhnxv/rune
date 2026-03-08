#!/bin/bash
# scripts/enforce-zsh-compat.sh
# ZSH-001: Block zsh-incompatible patterns in Bash commands.
# macOS uses zsh as the default shell. Two common zsh pitfalls:
#
# (A) Read-only variable assignment:
#     zsh has read-only special variables (status, pipestatus, ERRNO, signals).
#     `status=$(...)` fails with: (eval):N: read-only variable: status
#
# (B) Unprotected glob in for-loops:
#     In bash, `for f in *.nothing; do` silently loops with literal string.
#     In zsh, it throws: no matches found: *.nothing (NOMATCH option, on by default).
#     Fix: use `(N)` qualifier or `setopt nullglob` before the glob.
#
# (C) History expansion of `!` before `[[`:
#     In zsh, `! [[ ... ]]` can trigger history expansion (`!` prefix).
#     Causes: (eval):N: command not found: !
#     Fix: move negation inside: `[[ ! ... ]]`
#
# (D) Escaped not-equal operator `\!=` in [[ ]] conditions:
#     In bash, `[[ "$a" \!= "$b" ]]` is valid (backslash is a no-op).
#     In zsh, `[[ ]]` rejects `\!=` with: condition expected: \!=
#     Fix: strip the backslash → `!=`
#
# (E) Unprotected globs in command arguments (non-for contexts):
#     In zsh, unmatched globs in ANY position cause NOMATCH fatal error.
#     `rm -rf path/rune-*` fails if no files match — 2>/dev/null doesn't help.
#     Fix: prepend `setopt nullglob;` (same strategy as Check B).
#
# Detection strategy:
#   1. Shell detection: skip if user's shell is not zsh
#   2. Fast-path: skip if command doesn't contain any target patterns
#   3. Check A: bare `status=` assignment (not `task_status=`, etc.)
#   4. Check B: `for VAR in GLOB; do` without nullglob protection
#   5. Check C: `! [[ ... ]]` history expansion
#   6. Check D: `\!=` inside conditions
#   7. Check E: unprotected globs in command arguments (rm, ls, cp, mv, etc.)
#   8. Check A: block with actionable fix suggestion
#      Checks B-E: ACCUMULATED AUTO-FIX (BACK-016) — all applicable fixes are
#      applied in a single pass, then a combined JSON response is emitted.
#      This prevents partial fixes when multiple issues coexist (e.g., glob + \!=).
#      - Check B: prepend `setopt nullglob;` for for-loop globs
#      - Check C: rewrite `! [[` → `[[ !`
#      - Check D: rewrite `\!=` → `!=`
#      - Check E: prepend `setopt nullglob;` for argument globs
#
# Only active when user's shell is zsh — these are valid patterns in bash.
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 with hookSpecificOutput.permissionDecision="allow" + updatedInput = auto-fix.
# Exit 0 without JSON = tool call allowed as-is.

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Shell detection: only enforce when zsh is the user's shell.
# Claude Code's Bash tool inherits $SHELL, so commands execute under the user's default shell.
# Logic:
#   - $SHELL contains "zsh"  → enforce (user uses zsh)
#   - $SHELL set, not "zsh"  → skip (user explicitly chose bash/fish/etc.)
#   - $SHELL unset + macOS   → enforce (zsh is macOS default since Catalina)
#   - $SHELL unset + Linux   → skip (bash is typical default)
if [[ -n "${SHELL:-}" ]]; then
  # $SHELL is set — check if it's zsh
  case "$SHELL" in *zsh*) ;; *) exit 0 ;; esac
else
  # $SHELL is unset — only enforce on macOS where zsh is the default
  if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
    exit 0
  fi
fi

# Pre-flight: jq is required for JSON parsing.
# If missing, exit 0 (non-blocking) — allow rather than crash.
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — enforce-zsh-compat.sh hook is inactive" >&2
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read

TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Normalize multiline commands BEFORE fast-path (BACK-005: multiline for-loops missed)
NORMALIZED=$(printf '%s\n' "$COMMAND" | tr '\n' ' ')

# Fast-path: skip if none of the target patterns appear (operates on normalized input)
has_status_assign=""
has_for_glob=""
has_bang_bracket=""
has_escaped_neq=""
has_arg_glob=""
case "$NORMALIZED" in *status=*) has_status_assign=1 ;; esac
# BACK-005: Also detect `?` glob character (zsh NOMATCH-triggering)
case "$NORMALIZED" in *for*in*[*?]*do*) has_for_glob=1 ;; esac
# ZSH-001C: Detect `! [[` pattern (history expansion trigger in zsh)
case "$NORMALIZED" in *'! [['*) has_bang_bracket=1 ;; esac
# ZSH-001D: Detect `\!=` pattern (escaped not-equal, invalid in zsh [[ ]])
case "$NORMALIZED" in *'\!='*) has_escaped_neq=1 ;; esac
# ZSH-001E: Detect glob characters outside for-loops and outside quotes
# Fast-path: only trigger if * or ? appears AND a common file command is present
case "$NORMALIZED" in *[*?]*)
  case "$NORMALIZED" in *rm*|*ls*|*cp*|*mv*|*cat*|*wc*|*head*|*tail*|*chmod*|*chown*)
    has_arg_glob=1 ;;
  esac ;;
esac

if [[ -z "$has_status_assign" && -z "$has_for_glob" && -z "$has_bang_bracket" && -z "$has_escaped_neq" && -z "$has_arg_glob" ]]; then
  exit 0
fi

# ─── Check A: bare `status=` assignment ───────────────────────────────────────
# Anchored to: start of string, whitespace, semicolon, pipe, ampersand, parenthesis,
# or shell keywords (local, export, declare, readonly, typeset)
#
# The boundary anchor (^|[[:space:];|&(]) ensures that `task_status=`, `exit_status=`,
# `http_status=` etc. do NOT match — the character before `status` in those cases is
# `_` which is not in the boundary set. Only bare `status=` at a shell word boundary matches.
#
# Matches: status=$(...) | local status= | export status= | ;status= | &&status=
# Skips:   task_status= | exit_status= | http_status= | diff_status=
if [[ -n "$has_status_assign" ]]; then
  if printf '%s\n' "$NORMALIZED" | grep -qE '(^|[[:space:];|&(])(local[[:space:]]+|export[[:space:]]+|declare[[:space:]]+|readonly[[:space:]]+|typeset[[:space:]]+)?status='; then
    cat << 'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "ZSH-001: Blocked assignment to `status` — this is a read-only built-in variable in zsh (macOS default shell). The command will fail with '(eval):N: read-only variable: status'.",
    "additionalContext": "FIX: Rename the variable. Use `task_status`, `tstat`, `wf_status`, or `completion_status` instead of `status`. Example: task_status=$(jq -r '.status' \"$f\") instead of status=$(jq -r '.status' \"$f\"). Other zsh read-only variables to avoid: pipestatus, ERRNO, signals."
  }
}
DENY_JSON
    exit 0
  fi
fi

# ─── Accumulated auto-fix strategy ────────────────────────────────────────────
# BACK-016: Checks B-E now accumulate fixes on COMMAND instead of exiting after
# the first match. This prevents partial fixes when a command has multiple issues
# (e.g., unprotected glob AND \!= — previously only the glob was fixed).
# Check A remains a hard deny (exits immediately).
# After all checks, if any fix was applied, output a single combined JSON response.
needs_nullglob=""       # Flag: prepend setopt nullglob
fix_applied=""          # Flag: any auto-fix was applied
fix_descriptions=""     # Accumulated fix descriptions for additionalContext

# ─── Check B: unprotected glob in for-loop ────────────────────────────────────
# In zsh, `for f in path/*.ext; do` throws "no matches found" if no files match.
# Bash silently expands to the literal string — zsh aborts with NOMATCH (default on).
#
# Detection: `for VAR in <something-with-*>; do` or `for VAR in <something-with-?>; do`
# without nullglob protection.
#
# Nullglob protection patterns (any of these = safe):
#   - `(N)` glob qualifier: `for f in *.md(N); do`
#   - `setopt nullglob` or `setopt NULL_GLOB` before the for-loop
#   - `shopt -s nullglob` (bash compat, also works in zsh with emulation)
if [[ -n "$has_for_glob" ]]; then
  # FLAW-007: Use greedy match up to last '; do' to handle multi-statement for-loops
  glob_text=$(printf '%s\n' "$NORMALIZED" | grep -oE 'for[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+in[[:space:]]+.*;[[:space:]]*do' | head -1 || true)
  if [[ -n "$glob_text" ]]; then
    in_portion=$(printf '%s\n' "$glob_text" | sed 's/.*[[:space:]]in[[:space:]]//' | sed 's/;[[:space:]]*do$//')
    if printf '%s\n' "$in_portion" | grep -qE '[*?]'; then
      has_protection=""
      if printf '%s\n' "$in_portion" | grep -qE '\(N\)'; then
        has_protection=1
      fi
      if printf '%s\n' "$NORMALIZED" | grep -qiE 'setopt[[:space:]]+(nullglob|null_glob)'; then
        has_protection=1
      fi
      if printf '%s\n' "$NORMALIZED" | grep -qE 'shopt[[:space:]]+-s[[:space:]]+nullglob'; then
        has_protection=1
      fi

      if [[ -z "$has_protection" ]]; then
        needs_nullglob=1
        fix_applied=1
        fix_descriptions="prepended 'setopt nullglob;' to protect unguarded glob(s) from zsh NOMATCH"
      fi
    fi
  fi
fi

# ─── Check C: `! [[` history expansion ────────────────────────────────────────
# In zsh, `! [[ ... ]]` triggers history expansion — the `!` is interpreted as
# `!command` (re-run last command starting with...) rather than logical negation.
# Result: (eval):N: command not found: !
#
# Strategy: AUTO-FIX by rewriting `! [[` → `[[ !` in the command.
if [[ -n "$has_bang_bracket" ]]; then
  if printf '%s\n' "$NORMALIZED" | grep -qE '(^|[[:space:];|&])!\s*\[\['; then
    COMMAND=$(printf '%s' "$COMMAND" | sed 's/! \[\[/[[ !/g')
    fix_applied=1
    fix_descriptions="${fix_descriptions:+${fix_descriptions}; }rewrote '! [[' to '[[ !' to avoid zsh history expansion"
  fi
fi

# ─── Check D: `\!=` escaped not-equal in [[ ]] conditions ───────────────────
# In bash, `[[ "$a" \!= "$b" ]]` is valid — the backslash is a no-op before `!=`.
# In zsh, `[[ ]]` rejects `\!=` with: (eval):N: condition expected: \!=
#
# This is a common LLM generation artifact — bash-trained models sometimes emit
# the escaped form. Auto-fix: strip the backslash.
if [[ -n "$has_escaped_neq" ]]; then
  if printf '%s\n' "$NORMALIZED" | grep -qF '\!='; then
    COMMAND=$(printf '%s' "$COMMAND" | sed 's/\\!=/!=/g')
    fix_applied=1
    fix_descriptions="${fix_descriptions:+${fix_descriptions}; }rewrote '\\!=' to '!=' — zsh's [[ ]] rejects the escaped form"
  fi
fi

# ─── Check E: unprotected globs in command arguments ────────────────────────
# In zsh, unmatched globs in ANY position cause NOMATCH fatal error — not just
# in for-loops. `rm -rf path/rune-*` fails if no files match, and `2>/dev/null`
# does NOT suppress it (the error is at parse time, before the command runs).
#
# Detection: glob characters (* or ?) in arguments to common file commands
# (rm, ls, cp, mv, cat, wc, head, tail, chmod, chown) that are NOT inside
# quotes and NOT already protected by nullglob/setopt.
#
# Strategy: AUTO-FIX by prepending `setopt nullglob;` (same as Check B).
# Skip if Check B already set needs_nullglob (avoid duplicate prepend).
if [[ -n "$has_arg_glob" && -z "$needs_nullglob" ]]; then
  has_protection=""
  if printf '%s\n' "$NORMALIZED" | grep -qiE 'setopt[[:space:]]+(nullglob|null_glob)'; then
    has_protection=1
  fi
  if printf '%s\n' "$NORMALIZED" | grep -qE 'shopt[[:space:]]+-s[[:space:]]+nullglob'; then
    has_protection=1
  fi

  if [[ -z "$has_protection" ]]; then
    stripped=$(printf '%s\n' "$NORMALIZED" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
    if printf '%s\n' "$stripped" | grep -qE '[*?]'; then
      needs_nullglob=1
      fix_applied=1
      fix_descriptions="${fix_descriptions:+${fix_descriptions}; }prepended 'setopt nullglob;' to protect unquoted glob(s) from zsh NOMATCH"
    fi
  fi
fi

# ─── Emit combined auto-fix JSON if any fixes were applied ───────────────────
if [[ -n "$fix_applied" ]]; then
  # Apply nullglob prepend last (after in-place sed fixes on COMMAND)
  if [[ -n "$needs_nullglob" ]]; then
    COMMAND="setopt nullglob; ${COMMAND}"
  fi
  # Use jq to build valid JSON — prevents broken output from unescaped variables
  # or partial jq output. If jq fails, exit 0 (fail-forward: allow the command as-is).
  jq -n \
    --arg command "$COMMAND" \
    --arg context "ZSH-001 auto-fix: ${fix_descriptions}." \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: { command: $command },
        additionalContext: $context
      }
    }' 2>/dev/null || true
  exit 0
fi

exit 0
