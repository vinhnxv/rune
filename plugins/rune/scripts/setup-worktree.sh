#!/bin/bash
# setup-worktree.sh — WorktreeCreate hook: copy .claude/ contents to worktree
# Workaround for anthropics/claude-code#28041 (worktrees don't include .claude/ subdirs).
#
# Receives JSON on stdin: { "name": "...", "cwd": "...", "worktree_path": "..." }
# Copies essential Rune config from main repo .claude/ to worktree .claude/.
# Writes .rune-worktree-source marker for downstream scripts.
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
# Claude Code creates worktrees at .claude/worktrees/<name>/
if [[ -z "$WT_PATH" && -n "$WT_NAME" ]]; then
  WT_PATH="${CWD}/.claude/worktrees/${WT_NAME}"
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
# Check .claude subdir (if it exists)
if [[ -L "$WT_PATH/.claude" ]]; then
  _trace "DENY: worktree .claude/ is a symlink"
  exit 0
fi

# ── Verify source .claude/ directory exists ──
SRC_CLAUDE="${CWD}/.claude"
if [[ ! -d "$SRC_CLAUDE" ]]; then
  _trace "SKIP: source .claude/ not found at $SRC_CLAUDE"
  exit 0
fi

# ── Re-entry detection ──
# If worktree already has talisman.yml, setup was already done (idempotent).
DST_CLAUDE="${WT_PATH}/.claude"
if [[ -f "$DST_CLAUDE/talisman.yml" ]]; then
  _trace "SKIP: re-entry — talisman.yml already exists in worktree"
  exit 0
fi

_trace "Setting up Rune config in worktree: $WT_PATH"

# ── Create target .claude/ directory ──
mkdir -p "$DST_CLAUDE"

# ── Copy essential files ──
# Individual files (skip if absent)
for file in talisman.yml settings.json; do
  if [[ -f "$SRC_CLAUDE/$file" && ! -L "$SRC_CLAUDE/$file" ]]; then
    cp -f "$SRC_CLAUDE/$file" "$DST_CLAUDE/$file" 2>/dev/null || true
    _trace "Copied $file"
  fi
done

# ── Copy essential directories ──
# Use cp -R (not cp -r): -R copies symlinks as symlinks (POSIX), -r may dereference them.
# EXCLUDE: worktrees/ (prevent recursion), settings.local.json (handled by Claude Code),
#          agent-memory/ and agent-memory-local/ (per-agent persistent memory)
for dir in echoes arc; do
  if [[ -d "$SRC_CLAUDE/$dir" && ! -L "$SRC_CLAUDE/$dir" ]]; then
    # Create parent and copy recursively
    mkdir -p "$DST_CLAUDE/$dir"
    if ! cp -R "$SRC_CLAUDE/$dir/." "$DST_CLAUDE/$dir/" 2>/dev/null; then
      _trace "WARN: cp -R failed for $dir/ — partial copy may exist"
    else
      _trace "Copied $dir/"
    fi
  fi
done

# ── Create tmp/ directory in worktree ──
mkdir -p "$WT_PATH/tmp" 2>/dev/null || true

# ── Write worktree source marker ──
# Downstream scripts (workflow-lock.sh, stop-hook-common.sh) read this
# to resolve the main repo root for shared resources.
MARKER="$DST_CLAUDE/.rune-worktree-source"

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
