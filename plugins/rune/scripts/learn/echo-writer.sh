#!/bin/bash
# scripts/learn/echo-writer.sh
# Writes detected patterns as echo entries to .claude/echoes/{role}/MEMORY.md
#
# USAGE:
#   echo-writer.sh --role ROLE --layer LAYER --source SOURCE < entry.json
#
# Input (stdin): JSON object with fields:
#   title     — entry title (required)
#   content   — entry body text (required)
#   confidence — HIGH|MEDIUM|LOW (default: MEDIUM)
#   tags      — optional array of strings
#
# Options:
#   --role ROLE      Echo role directory (e.g., orchestrator, reviewer, workers)
#   --layer LAYER    Echo layer (e.g., inscribed, notes, observations)
#   --source SOURCE  Source identifier (e.g., learn/session-scanner)
#
# Exit codes:
#   0 — success (or skipped due to dedup/guard)
#   1 — fatal validation failure
#
# Security:
#   - Symlink guard on MEMORY.md
#   - Role name validated: /^[a-zA-Z0-9_-]+$/
#   - mkdir-based locking (portable, no flock)
#   - Sensitive data filtered via sensitive-patterns.sh
#   - Dedup via fuzzy word-overlap (Jaccard >= 80%)
#   - 150-line pre-flight warning on MEMORY.md

set -euo pipefail
umask 077

RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] %s: %s\n' "$(date +%H:%M:%S)" "${BASH_SOURCE[0]##*/}" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# ── Fail-forward trap (OPERATIONAL) ──
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  echo "WARN: ${BASH_SOURCE[0]##*/} crashed at line $_crash_line — fail-forward." >&2
  exit 0
}
trap '_rune_fail_forward' ERR

# ── Guard: jq required ──
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — echo-writer skipped." >&2
  exit 0
fi

# ── Resolve script directory ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../lib" && pwd)"

# ── Source sensitive-patterns library ──
if [[ -f "${LIB_DIR}/sensitive-patterns.sh" ]]; then
  # shellcheck source=../lib/sensitive-patterns.sh
  source "${LIB_DIR}/sensitive-patterns.sh"
fi
source "${LIB_DIR}/platform.sh"

# ── Default parameters ──
ROLE=""
LAYER="notes"
SOURCE="learn/unknown"

# ── Named flag parsing ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      shift
      [[ -z "${1:-}" ]] && { echo "ERROR: --role requires a value" >&2; exit 1; }
      ROLE="$1"
      shift
      ;;
    --layer)
      shift
      [[ -z "${1:-}" ]] && { echo "ERROR: --layer requires a value" >&2; exit 1; }
      LAYER="$1"
      shift
      ;;
    --source)
      shift
      [[ -z "${1:-}" ]] && { echo "ERROR: --source requires a value" >&2; exit 1; }
      SOURCE="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# ── Validate role name: /^[a-zA-Z0-9_-]+$/ ──
if [[ -z "$ROLE" ]]; then
  echo "ERROR: --role is required" >&2
  exit 1
fi
if [[ ! "$ROLE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: invalid role name (must match [a-zA-Z0-9_-]+): ${ROLE}" >&2
  exit 1
fi

# ── Read input JSON from stdin ──
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && { echo "WARN: empty stdin — nothing to write." >&2; exit 0; }

# ── Parse input fields ──
IFS=$'\t' read -r ENTRY_TITLE ENTRY_CONTENT ENTRY_CONFIDENCE < <(
  printf '%s' "$INPUT" | jq -r '
    [
      (.title // "" | .[0:200]),
      (.content // "" | .[0:2000]),
      (.confidence // "MEDIUM" | ascii_upcase)
    ] | @tsv
  ' 2>/dev/null
) || { echo "WARN: JSON parse failed — skipping." >&2; exit 0; }

[[ -z "$ENTRY_TITLE" ]] && { echo "WARN: entry title is empty — skipping." >&2; exit 0; }
[[ -z "$ENTRY_CONTENT" ]] && { echo "WARN: entry content is empty — skipping." >&2; exit 0; }

# Validate confidence
case "$ENTRY_CONFIDENCE" in
  HIGH|MEDIUM|LOW) ;;
  *) ENTRY_CONFIDENCE="MEDIUM" ;;
esac

# Parse optional tags
ENTRY_TAGS=$(printf '%s' "$INPUT" | jq -r '(.tags // []) | map(tostring | .[0:50]) | join(", ")' 2>/dev/null || echo "")

# ── Apply sensitive data filter ──
if declare -f rune_strip_sensitive &>/dev/null; then
  ENTRY_CONTENT=$(printf '%s' "$ENTRY_CONTENT" | rune_strip_sensitive 2000 2>/dev/null) || true
  ENTRY_TITLE=$(printf '%s' "$ENTRY_TITLE" | rune_strip_sensitive 200 2>/dev/null) || true
fi

# ── Resolve project directory ──
# Look for .claude/echoes/ in current directory and parent dirs
PROJECT_DIR=""
_check_dir="$(pwd -P)"
for _depth in 1 2 3 4 5; do
  if [[ -d "${_check_dir}/.claude/echoes" ]]; then
    PROJECT_DIR="$_check_dir"
    break
  fi
  _parent="$(dirname "$_check_dir")"
  [[ "$_parent" == "$_check_dir" ]] && break
  _check_dir="$_parent"
done

if [[ -z "$PROJECT_DIR" ]]; then
  echo "WARN: .claude/echoes/ directory not found from $(pwd)" >&2
  exit 0
fi

# ── Verify echo role directory exists ──
ECHO_DIR="${PROJECT_DIR}/.claude/echoes/${ROLE}"
if [[ ! -d "$ECHO_DIR" ]]; then
  echo "WARN: echo role directory does not exist: ${ECHO_DIR}" >&2
  exit 0
fi

# ── Resolve MEMORY.md path ──
MEMORY_FILE="${ECHO_DIR}/MEMORY.md"

# ── Symlink guard ──
if [[ -L "$MEMORY_FILE" ]]; then
  echo "WARN: MEMORY.md is a symlink — skipping (security guard)." >&2
  exit 0
fi

# ── Create MEMORY.md if it doesn't exist (with schema header) ──
if [[ ! -f "$MEMORY_FILE" ]]; then
  printf '<!-- echo-schema: v1 -->\n' > "$MEMORY_FILE" 2>/dev/null || {
    echo "WARN: cannot create MEMORY.md" >&2
    exit 0
  }
fi

# ── 150-line pre-flight check ──
LINE_COUNT=$(wc -l < "$MEMORY_FILE" 2>/dev/null || echo 0)
if [[ "$LINE_COUNT" -gt 150 ]]; then
  echo "WARN: ${MEMORY_FILE} has ${LINE_COUNT} lines (> 150). Consider pruning with /rune:echoes prune." >&2
fi

# ── Dedup check: fuzzy word-overlap (Jaccard >= 80%) ──
# Extract existing entry titles from MEMORY.md
EXISTING_TITLES=$(grep -E '^## ' "$MEMORY_FILE" 2>/dev/null | sed 's/^## //' || true)

# Compute Jaccard similarity with python3
_is_duplicate() {
  local new_title="$1"
  local existing_titles="$2"
  [[ -z "$existing_titles" ]] && { echo "UNIQUE"; return 0; }

  python3 -c '
import sys

def jaccard(a, b):
    wa = set(a.lower().split())
    wb = set(b.lower().split())
    if not wa and not wb:
        return 1.0
    if not wa or not wb:
        return 0.0
    inter = wa & wb
    union = wa | wb
    return len(inter) / len(union)

new_title = sys.argv[1]
threshold = 0.8
lines = sys.stdin.read().strip().splitlines()
for existing in lines:
    existing = existing.strip()
    if not existing:
        continue
    score = jaccard(new_title, existing)
    if score >= threshold:
        print("DUPLICATE")
        sys.exit(0)
print("UNIQUE")
' "$new_title" <<< "$existing_titles" 2>/dev/null || echo "UNIQUE"
}

DEDUP_RESULT=$(_is_duplicate "$ENTRY_TITLE" "$EXISTING_TITLES")
if [[ "$DEDUP_RESULT" == "DUPLICATE" ]]; then
  echo "INFO: duplicate entry detected (Jaccard >= 80%) — skipping: ${ENTRY_TITLE}" >&2

  # Write dedup signal
  SIGNAL_DIR="${PROJECT_DIR}/tmp/.rune-signals"
  mkdir -p "$SIGNAL_DIR" 2>/dev/null || true
  DEDUP_HASH=$(printf '%s' "${ENTRY_TITLE}${ENTRY_CONTENT}" | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])' 2>/dev/null || date +%s%N 2>/dev/null || date +%s)
  touch "${SIGNAL_DIR}/.learn-${DEDUP_HASH}" 2>/dev/null || true
  exit 0
fi

# ── mkdir-based locking (portable, no flock) ──
LOCK_DIR="${PROJECT_DIR}/tmp/.rune-echo-lock-${ROLE}"
LOCK_ACQUIRED=0

for _lock_attempt in 1 2 3 4 5; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    break
  fi
  # Check if lock is stale (> 30s old)
  if [[ -d "$LOCK_DIR" ]]; then
    _lock_mtime=$(_stat_mtime "$LOCK_DIR"); _lock_mtime="${_lock_mtime:-0}"
    _now=$(date +%s)
    _age=$(( _now - _lock_mtime ))
    if [[ "$_age" -gt 30 ]]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
  fi
  sleep 1
done

if [[ "$LOCK_ACQUIRED" -eq 0 ]]; then
  echo "WARN: could not acquire lock after 5 attempts — skipping." >&2
  exit 0
fi

# Ensure lock is released on exit and signals
_release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap '_release_lock; exit 0' EXIT INT TERM

# ── Format and write entry ──
DATE=$(date +%Y-%m-%d)

ENTRY="
## ${ENTRY_TITLE}
- **layer**: ${LAYER}
- **source**: \`${SOURCE}\`
- **confidence**: ${ENTRY_CONFIDENCE}
- **date**: ${DATE}"

if [[ -n "$ENTRY_TAGS" ]]; then
  ENTRY="${ENTRY}
- **tags**: ${ENTRY_TAGS}"
fi

ENTRY="${ENTRY}

${ENTRY_CONTENT}
"

# Atomic append via temp file
TMPFILE=$(mktemp 2>/dev/null) || { echo "WARN: mktemp failed" >&2; exit 0; }
printf '%s\n' "$ENTRY" > "$TMPFILE"
cat "$TMPFILE" >> "$MEMORY_FILE" 2>/dev/null || { rm -f "$TMPFILE"; exit 0; }
rm -f "$TMPFILE"

# ── Write dirty signal for echo-search auto-reindex ──
SIGNAL_DIR="${PROJECT_DIR}/tmp/.rune-signals"
mkdir -p "$SIGNAL_DIR" 2>/dev/null || true
touch "${SIGNAL_DIR}/.echo-dirty" 2>/dev/null || true

echo "INFO: entry written to ${MEMORY_FILE}" >&2
exit 0
