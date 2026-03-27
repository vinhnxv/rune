#!/bin/bash
# cleanup-worktree.sh — WorktreeRemove hook: salvage uncommitted changes
# Saves any uncommitted diff from the worktree as a patch file before removal.
#
# Receives JSON on stdin: { "worktree_path": "...", ... }
# Writes patch to tmp/.rune-salvaged-patches/<worktree-basename>-<timestamp>.patch
#
# Hook event: WorktreeRemove
# Timeout budget: <5 seconds (10s hard limit)
# Fail-forward: exits 0 on all errors — worktree removal proceeds even if salvage fails.

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# ── Fail-forward guard (OPERATIONAL hook) ──
# Crash before validation → allow operation (don't block worktree removal).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
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
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
    [[ ! -L "$_log" ]] && echo "[cleanup-worktree] $*" >> "$_log" 2>/dev/null
  fi
  return 0
}

# ── Source shared libs (optional — fail-forward on missing) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rune-state.sh" 2>/dev/null || true

# ── Guard: jq dependency ──
if ! command -v jq >/dev/null 2>&1; then
  _trace "SKIP: jq not available"
  exit 0
fi

# ── Read hook input JSON from stdin (SEC-003: 1MB cap) ──
INPUT=$(head -c 1048576 2>/dev/null || true)
WORKTREE_PATH=$(printf '%s\n' "$INPUT" | jq -r '.worktree_path // empty')
[[ -z "$WORKTREE_PATH" ]] && exit 0

# ── SEC-002: Validate WORKTREE_PATH ──
[[ "$WORKTREE_PATH" != /* ]] && { _trace "DENY: WORKTREE_PATH not absolute"; exit 0; }
[[ "$WORKTREE_PATH" == *".."* ]] && { _trace "DENY: WORKTREE_PATH contains traversal"; exit 0; }
[[ "$WORKTREE_PATH" == *$'\0'* ]] && { _trace "DENY: WORKTREE_PATH contains null byte"; exit 0; }
[[ -L "$WORKTREE_PATH" ]] && { _trace "DENY: WORKTREE_PATH is symlink"; exit 0; }

# ── CRITICAL: Check filesystem existence BEFORE git ops ──
# Timing race — worktree may be partially removed by the time this hook fires.
if [[ ! -d "$WORKTREE_PATH" ]] || [[ ! -e "$WORKTREE_PATH/.git" ]]; then
  exit 0
fi

# ── Check for uncommitted changes ──
if git -C "$WORKTREE_PATH" diff --quiet 2>/dev/null; then
  # No uncommitted changes — nothing to salvage
  exit 0
fi

# ── Resolve salvage directory ──
source "${SCRIPT_DIR}/lib/worktree-resolve.sh" 2>/dev/null || true
rune_resolve_project_dir "" >/dev/null 2>&1 || true
SALVAGE_BASE="${RUNE_MAIN_REPO_ROOT:-${RUNE_PROJECT_DIR:-$(pwd)}}"
SALVAGE_DIR="${SALVAGE_BASE}/tmp/.rune-salvaged-patches"
mkdir -p "$SALVAGE_DIR"

# ── Generate patch file ──
PATCH_FILE="${SALVAGE_DIR}/$(basename "$WORKTREE_PATH")-$(date +%Y%m%d-%H%M%S).patch"
git -C "$WORKTREE_PATH" diff > "$PATCH_FILE" 2>/dev/null || true

if [[ -s "$PATCH_FILE" ]]; then
  echo "Salvaged uncommitted changes to: $PATCH_FILE" >&2
else
  rm -f "$PATCH_FILE" 2>/dev/null
fi

exit 0
