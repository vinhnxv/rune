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

# ── Fail-forward guard (OPERATIONAL hook) ──
# Crash before validation → allow operation (don't block worktree removal).
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

# ── Source shared libs (optional — fail-forward on missing) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rune-state.sh" 2>/dev/null || true

# ── Parse hook input ──
INPUT=$(cat)
WORKTREE_PATH=$(printf '%s\n' "$INPUT" | jq -r '.worktree_path // empty')
[[ -z "$WORKTREE_PATH" ]] && exit 0

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
SALVAGE_BASE="${RUNE_PROJECT_DIR:-$(pwd)}"
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
