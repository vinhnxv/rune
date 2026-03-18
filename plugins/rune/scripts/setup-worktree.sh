#!/bin/bash
# setup-worktree.sh — WorktreeCreate hook: copy .claude/ + .rune/ contents to worktree
# Workaround for anthropics/claude-code#28041 (worktrees don't include .claude/ subdirs).
#
# Receives JSON on stdin: { "name": "...", "cwd": "...", "worktree_path": "..." }
# Copies Claude Code platform files (.claude/settings.json) and Rune state
# (.rune/talisman.yml, .rune/echoes/, .rune/arc/) to worktree.
# Writes .rune/.rune-worktree-source marker for downstream scripts.
#
# Hook event: WorktreeCreate
# Timeout budget: <5 seconds (10s hard limit)
# Fail-forward: exits 0 on all errors — worktree still usable without Rune config.

set -euo pipefail
umask 077

# ── Fail-forward guard (OPERATIONAL hook) ──
# Crash before validation → allow operation (don't stall worktree creation).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# ── Opt-in trace logging ──
_trace() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ ! -L "$_log" ]] && echo "[setup-worktree] $*" >> "$_log" 2>/dev/null
  fi
  return 0
}

# ── Guard: jq dependency ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rune-state.sh"

if ! command -v jq &>/dev/null; then
  _trace "SKIP: jq not available"
  exit 0
fi

# ── Read hook input JSON from stdin (SEC-003: 1MB cap) ──
INPUT=$(head -c 1048576 2>/dev/null || true)

if [[ -z "$INPUT" ]]; then
  _trace "SKIP: empty stdin"
  exit 0
fi

# ── Parse hook input fields ──
# WorktreeCreate hook input: { "name": "...", "cwd": "..." }
# worktree_path may or may not be present — derive from cwd + name if absent.
WT_NAME=$(printf '%s\n' "$INPUT" | jq -r '.name // empty' 2>/dev/null || true)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
WT_PATH=$(printf '%s\n' "$INPUT" | jq -r '.worktree_path // empty' 2>/dev/null || true)

# SEC-001: Validate WT_NAME charset (branch-like identifiers only)
if [[ -n "$WT_NAME" && ! "$WT_NAME" =~ ^[a-zA-Z0-9_/.-]+$ ]]; then
  _trace "DENY: WT_NAME contains invalid characters"
  exit 0
fi
# SEC-001b: Reject traversal and absolute paths in WT_NAME
if [[ "$WT_NAME" == *".."* || "$WT_NAME" == /* ]]; then
  _trace "DENY: path traversal or absolute path in WT_NAME"
  exit 0
fi

_trace "Parsed input — name=$WT_NAME cwd=$CWD worktree_path=$WT_PATH"

# ── Validate CWD (main repo root) ──
if [[ -z "$CWD" ]]; then
  _trace "SKIP: no cwd in hook input"
  exit 0
fi

# SEC-002: Reject CWD if it is a symlink before canonicalizing
if [[ -L "$CWD" ]]; then
  _trace "DENY: CWD is a symlink: $CWD"
  exit 0
fi

# Canonicalize CWD — resolve symlinks
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { _trace "SKIP: cannot canonicalize CWD"; exit 0; }

# SEC-001: CWD must be absolute
if [[ "$CWD" != /* ]]; then
  _trace "SKIP: CWD not absolute: $CWD"
  exit 0
fi

# ── Derive worktree_path if not provided ──
# Claude Code creates worktrees at ${RUNE_STATE}/worktrees/<name>/
if [[ -z "$WT_PATH" && -n "$WT_NAME" ]]; then
  WT_PATH="${CWD}/${RUNE_STATE}/worktrees/${WT_NAME}"
fi

if [[ -z "$WT_PATH" ]]; then
  _trace "SKIP: cannot determine worktree path"
  exit 0
fi

# SEC-002: Validate worktree path — must be absolute, no traversal
if [[ "$WT_PATH" != /* ]]; then
  _trace "SKIP: worktree_path not absolute: $WT_PATH"
  exit 0
fi
if [[ "$WT_PATH" == *".."* ]]; then
  _trace "DENY: path traversal detected in worktree_path: $WT_PATH"
  exit 0
fi

# SEC-003: Symlink guard — worktree_path must not be or contain a symlink
# Check the path itself (if it exists)
if [[ -L "$WT_PATH" ]]; then
  _trace "DENY: worktree_path is a symlink: $WT_PATH"
  exit 0
fi
# Check .claude and .rune subdirs (if they exist)
if [[ -L "$WT_PATH/.claude" ]]; then
  _trace "DENY: worktree .claude/ is a symlink"
  exit 0
fi
if [[ -L "$WT_PATH/.rune" ]]; then
  _trace "DENY: worktree .rune/ is a symlink"
  exit 0
fi

# ── Verify source directories exist ──
SRC_CLAUDE="${CWD}/.claude"
SRC_RUNE="${CWD}/.rune"

if [[ ! -d "$SRC_CLAUDE" && ! -d "$SRC_RUNE" ]]; then
  _trace "SKIP: neither .claude/ nor .rune/ found at $CWD"
  exit 0
fi

# ── Re-entry detection ──
# If worktree already has the marker file, setup was already done (idempotent).
# Use the marker (always written) instead of talisman.yml (may not exist in all projects).
DST_CLAUDE="${WT_PATH}/.claude"
DST_RUNE="${WT_PATH}/.rune"
if [[ -f "$DST_RUNE/.rune-worktree-source" ]]; then
  _trace "SKIP: re-entry — .rune-worktree-source marker already exists in worktree"
  exit 0
fi

_trace "Setting up Rune config in worktree: $WT_PATH"

# ── Create target directories ──
mkdir -p "$DST_CLAUDE"
mkdir -p "$DST_RUNE"

# ── Copy Claude Code platform files (.claude/) ──
if [[ -d "$SRC_CLAUDE" ]]; then
  for file in settings.json; do
    if [[ -f "$SRC_CLAUDE/$file" && ! -L "$SRC_CLAUDE/$file" ]]; then
      cp -f "$SRC_CLAUDE/$file" "$DST_CLAUDE/$file" 2>/dev/null || true
      _trace "Copied .claude/$file"
    fi
  done
fi

# ── Copy Rune state files (.rune/) ──
if [[ -d "$SRC_RUNE" ]]; then
  # Individual files
  for file in talisman.yml; do
    if [[ -f "$SRC_RUNE/$file" && ! -L "$SRC_RUNE/$file" ]]; then
      cp -f "$SRC_RUNE/$file" "$DST_RUNE/$file" 2>/dev/null || true
      _trace "Copied .rune/$file"
    fi
  done

  # Directories (echoes, arc)
  # Use cp -R (not cp -r): -R copies symlinks as symlinks (POSIX), -r may dereference them.
  # EXCLUDE: worktrees/ (prevent recursion), audit-state/ (session-specific)
  for dir in echoes arc; do
    if [[ -d "$SRC_RUNE/$dir" && ! -L "$SRC_RUNE/$dir" ]]; then
      mkdir -p "$DST_RUNE/$dir"
      if ! cp -R "$SRC_RUNE/$dir/." "$DST_RUNE/$dir/" 2>/dev/null; then
        _trace "WARN: cp -R failed for .rune/$dir/ — partial copy may exist"
      else
        _trace "Copied .rune/$dir/"
      fi
    fi
  done
fi

# ── Create tmp/ directory in worktree ──
mkdir -p "$WT_PATH/tmp" 2>/dev/null || true

# ── Write worktree source marker ──
# Downstream scripts (workflow-lock.sh, stop-hook-common.sh) read this
# to resolve the main repo root for shared resources.
MARKER="$DST_RUNE/.rune-worktree-source"

# SEC-004: Marker must not be a symlink
if [[ -L "$MARKER" ]]; then
  rm -f "$MARKER" 2>/dev/null || true
fi

# Write canonicalized main repo path (atomic via tmp+mv)
_marker_tmp="${MARKER}.tmp.$$"
if printf '%s\n' "$CWD" > "$_marker_tmp" && mv -f "$_marker_tmp" "$MARKER"; then
  _trace "Wrote marker: $MARKER → $CWD"
else
  rm -f "$_marker_tmp" 2>/dev/null || true
  _trace "WARN: failed to write marker atomically"
fi

_trace "Worktree setup complete"
exit 0
