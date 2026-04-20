#!/bin/bash
# scripts/validate-phase-order-sync.sh
# AC-1 (BUG-N-01, P1): Runtime assertion that arc-phase-constants.md PHASE_ORDER (JS)
# stays in sync with arc-phase-stop-hook.sh PHASE_ORDER (Bash).
#
# Without this check, adding a phase to one array but not the other causes silent
# skip/stall behavior in the arc pipeline (the LLM dispatcher and Stop hook use
# different source arrays).
#
# Exit codes:
#   0 = arrays in sync (no drift)
#   1 = drift detected (arrays differ)
#   2 = script error (source files missing or unparseable)
#
# Usage:
#   bash scripts/validate-phase-order-sync.sh           # from repo root
#   bash scripts/validate-phase-order-sync.sh --verbose # show both arrays even on success
#
# Intended call sites:
#   - Pre-commit hook (via lefthook/husky or manual)
#   - CI (part of the plugin-wiring validation suite)
#   - Ad-hoc: after any edit to PHASE_ORDER in either source
#
# Sibling scripts: validate-plugin-wiring.sh, validate-task-contract.sh (same style).

set -euo pipefail

# --- Paths (resolved relative to this script) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
JS_SOURCE="${PLUGIN_ROOT}/skills/arc/references/arc-phase-constants.md"
BASH_SOURCE_FILE="${PLUGIN_ROOT}/scripts/arc-phase-stop-hook.sh"

# --- Flags ---
VERBOSE=0
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then
  VERBOSE=1
fi

# --- Pre-flight: both source files must exist ---
if [[ ! -f "$JS_SOURCE" ]]; then
  echo "ERROR: arc-phase-constants.md not found at: $JS_SOURCE" >&2
  echo "       (script error — not a drift)" >&2
  exit 2
fi
if [[ ! -f "$BASH_SOURCE_FILE" ]]; then
  echo "ERROR: arc-phase-stop-hook.sh not found at: $BASH_SOURCE_FILE" >&2
  echo "       (script error — not a drift)" >&2
  exit 2
fi

# --- Extract JS PHASE_ORDER from arc-phase-constants.md ---
# Pattern: `const PHASE_ORDER = ['a', 'b', 'c', ...]` on a single line.
# Tolerates single or double quotes, spacing.
JS_LINE=$(grep -E "^const PHASE_ORDER = \[" "$JS_SOURCE" 2>/dev/null | head -1)
if [[ -z "$JS_LINE" ]]; then
  echo "ERROR: could not find 'const PHASE_ORDER = [...]' in $JS_SOURCE" >&2
  exit 2
fi

# Extract quoted strings inside the brackets. Both single- and double-quoted.
# Output: one phase name per line, preserving order.
JS_ORDER=$(printf '%s\n' "$JS_LINE" \
  | sed -E "s/.*\[//; s/\].*//" \
  | tr ',' '\n' \
  | sed -E "s/['\"]//g; s/^ +//; s/ +\$//" \
  | grep -v '^$')

if [[ -z "$JS_ORDER" ]]; then
  echo "ERROR: JS PHASE_ORDER parsed empty from: $JS_LINE" >&2
  exit 2
fi

# --- Extract Bash PHASE_ORDER from arc-phase-stop-hook.sh ---
# Pattern: `PHASE_ORDER=( ... )` — may span multiple lines.
# Strategy: use awk to capture everything between `PHASE_ORDER=(` and the closing `)`.
BASH_ORDER=$(awk '
  /^PHASE_ORDER=\(/ { in_array = 1; sub(/^PHASE_ORDER=\(/, ""); }
  in_array {
    if (match($0, /\)/)) {
      sub(/\).*/, "");
      print;
      exit;
    }
    print;
  }
' "$BASH_SOURCE_FILE" \
  | sed -E 's/#.*$//' \
  | tr -s ' \t\n' '\n' \
  | grep -v '^$')

if [[ -z "$BASH_ORDER" ]]; then
  echo "ERROR: Bash PHASE_ORDER parsed empty from $BASH_SOURCE_FILE" >&2
  exit 2
fi

# --- Compare ---
# Use file-based diff to get a side-by-side view. Temp files are auto-cleaned.
TMPDIR_BASE="${TMPDIR:-/tmp}"
JS_FILE=$(mktemp "${TMPDIR_BASE}/phase-order-js-XXXXXX")
BASH_FILE=$(mktemp "${TMPDIR_BASE}/phase-order-bash-XXXXXX")
trap 'rm -f "$JS_FILE" "$BASH_FILE"' EXIT

printf '%s\n' "$JS_ORDER" > "$JS_FILE"
printf '%s\n' "$BASH_ORDER" > "$BASH_FILE"

JS_COUNT=$(wc -l < "$JS_FILE" | tr -d ' ')
BASH_COUNT=$(wc -l < "$BASH_FILE" | tr -d ' ')

if diff -q "$JS_FILE" "$BASH_FILE" >/dev/null 2>&1; then
  # In sync
  if [[ "$VERBOSE" == "1" ]]; then
    echo "OK: PHASE_ORDER in sync ($JS_COUNT phases)"
    echo "Source (JS):   $JS_SOURCE"
    echo "Source (Bash): $BASH_SOURCE_FILE"
    echo ""
    echo "Phases (in order):"
    nl -ba "$JS_FILE" | sed 's/^/  /'
  else
    echo "OK: arc PHASE_ORDER in sync ($JS_COUNT phases)"
  fi
  exit 0
fi

# Drift detected — print actionable diff
echo "FAIL: arc PHASE_ORDER drift detected between JS and Bash arrays" >&2
echo "" >&2
echo "  JS source   ($JS_COUNT entries): $JS_SOURCE" >&2
echo "  Bash source ($BASH_COUNT entries): $BASH_SOURCE_FILE" >&2
echo "" >&2
echo "--- Diff (< JS only, > Bash only) ---" >&2
diff "$JS_FILE" "$BASH_FILE" >&2 || true
echo "" >&2
echo "Fix: update BOTH arrays atomically. See CLAUDE.md Pre-Commit Checklist." >&2
exit 1
