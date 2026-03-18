#!/bin/bash
# scripts/learn/review-recurrence-detector.sh
# Scans TOME files and echo entries to find recurring review findings.
#
# USAGE:
#   review-recurrence-detector.sh [--project PATH] [--min-count N]
#
# Options:
#   --project PATH   Project root (default: CWD)
#   --min-count N    Min TOME occurrences to flag (default: 2)
#
# Output (stdout): JSON — { "recurrences": [...] }
# Each recurrence: { "finding_id": "SEC-001", "tome_paths": [...], "count": N, "severity": "..." }
#
# Algorithm:
#   1. Glob TOME files under tmp/reviews/, tmp/audit/, tmp/arc/
#   2. Extract finding prefixes (SEC-001, QUAL-003, etc.) + descriptions
#   3. Cross-reference against .rune/echoes/reviewer/MEMORY.md
#   4. Flag findings in 2+ TOMEs with NO echo entry
#
# EXIT: 0 always (fail-forward). On error, outputs {"recurrences":[]} with "error" field.
# DEPENDENCIES: python3

set -euo pipefail
umask 077

RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] %s: %s\n' "$(date +%H:%M:%S)" "${BASH_SOURCE[0]##*/}" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  echo "WARN: ${BASH_SOURCE[0]##*/} crashed at line $_crash_line — fail-forward." >&2
  printf '{"recurrences":[],"error":"crashed_at_line_%s"}\n' "$_crash_line"
  exit 0
}
trap '_rune_fail_forward' ERR

# ── Dependency guards ──
if ! command -v python3 &>/dev/null; then
  printf '{"recurrences":[],"error":"python3_not_found"}\n'
  exit 0
fi

# ── Argument parsing ──
PROJECT_DIR=""
MIN_COUNT=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      shift
      PROJECT_DIR="${1:-}"
      shift
      ;;
    --min-count)
      shift
      MIN_COUNT="${1:-2}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# ── Resolve project directory ──
if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(pwd -P)"
else
  PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || {
    printf '{"recurrences":[],"error":"invalid_project_path"}\n'
    exit 0
  }
fi

# Validate min_count is numeric
MIN_COUNT=$(( "${MIN_COUNT}" + 0 )) 2>/dev/null || MIN_COUNT=2
[[ "$MIN_COUNT" -lt 1 ]] && MIN_COUNT=2

# ── Step 1: Collect TOME files ──
TOME_DIRS=(
  "${PROJECT_DIR}/tmp/reviews"
  "${PROJECT_DIR}/tmp/audit"
  "${PROJECT_DIR}/tmp/arc"
)

TOME_FILES=()
_nullglob_was_set=0
shopt -q nullglob && _nullglob_was_set=1
shopt -s nullglob
for dir in "${TOME_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  [[ -L "$dir" ]] && continue
  for f in "${dir}"/*/TOME.md; do
    [[ -f "$f" ]] && [[ ! -L "$f" ]] && TOME_FILES+=("$f")
  done
done
[[ "$_nullglob_was_set" -eq 0 ]] && shopt -u nullglob

if [[ ${#TOME_FILES[@]} -eq 0 ]]; then
  printf '{"recurrences":[]}\n'
  exit 0
fi

# ── Steps 2–4: Extract, cross-reference, and output recurrences ──
# Single python3 invocation handles extraction + dedup + output
python3 - "$PROJECT_DIR" "$MIN_COUNT" "${TOME_FILES[@]}" <<'PYEOF'
import sys, re, json, os

project_dir = sys.argv[1]
min_count = int(sys.argv[2])
tome_files = sys.argv[3:]

# ── Pattern: finding prefix like SEC-001, QUAL-003, BACK-007, VEIL-002, etc. ──
FINDING_RE = re.compile(
    r'(?:^|\s|\*\*|###\s+)'            # anchor
    r'([A-Z][A-Z0-9]{1,10}-\d{1,4})'  # prefix (e.g. SEC-001, QUAL-003)
    r'(?:\*\*)?'                         # optional closing **
    r'[\s:*-]+(.*?)$',                   # description
    re.MULTILINE
)

# ── Severity inference from finding prefix ──
SEVERITY_MAP = {
    'SEC': 'high',
    'BACK': 'medium',
    'VEIL': 'medium',
    'QUAL': 'low',
    'DOC': 'low',
    'PERF': 'medium',
    'TEST': 'low',
    'ARCH': 'medium',
}

def infer_severity(finding_id):
    prefix = finding_id.split('-')[0] if '-' in finding_id else finding_id
    return SEVERITY_MAP.get(prefix, 'low')

# ── Jaccard word-overlap for description dedup ──
def word_set(text):
    return set(re.findall(r'\b\w+\b', text.lower()))

def jaccard(a, b):
    sa, sb = word_set(a), word_set(b)
    if not sa and not sb:
        return 1.0
    inter = len(sa & sb)
    union = len(sa | sb)
    return inter / union if union > 0 else 0.0

# ── Step 2: Extract findings from TOME files ──
# Per-finding: { finding_id -> { descriptions: [...], tome_paths: [...] } }
findings = {}

for tome_path in tome_files:
    if os.path.islink(tome_path):
        continue
    try:
        with open(tome_path, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read(524288)  # 512KB cap per file
    except (OSError, IOError):
        continue

    for m in FINDING_RE.finditer(content):
        fid = m.group(1)
        desc = m.group(2).strip()
        # Strip markdown bold/italic syntax from description
        desc = re.sub(r'\*+', '', desc).strip()
        # Truncate to 200 chars
        desc = desc[:200]

        if fid not in findings:
            findings[fid] = {'descriptions': [], 'tome_paths': []}

        if tome_path not in findings[fid]['tome_paths']:
            findings[fid]['tome_paths'].append(tome_path)

        if desc and desc not in findings[fid]['descriptions']:
            findings[fid]['descriptions'].append(desc)

# ── Step 3: Read reviewer echo entries ──
echo_file = os.path.join(project_dir, '.claude', 'echoes', 'reviewer', 'MEMORY.md')
echo_content = ''
if os.path.isfile(echo_file) and not os.path.islink(echo_file):
    try:
        with open(echo_file, 'r', encoding='utf-8', errors='replace') as f:
            echo_content = f.read(524288)
    except (OSError, IOError):
        pass

# Extract finding IDs already mentioned in echo content
ECHO_ID_RE = re.compile(r'\b([A-Z][A-Z0-9]{1,10}-\d{1,4})\b')
echoed_ids = set(ECHO_ID_RE.findall(echo_content))

# ── Step 4: Cross-reference + flag recurring findings with no echo entry ──
recurrences = []

for fid, data in findings.items():
    tome_paths = data.get('tome_paths', [])
    count = len(tome_paths)

    # Only flag findings in min_count+ TOMEs
    if count < min_count:
        continue

    # Skip if already echoed
    if fid in echoed_ids:
        continue

    # Deduplicate descriptions with Jaccard word-overlap (80% threshold)
    descs = data.get('descriptions', [])
    unique_descs = []
    for d in descs:
        is_dup = any(jaccard(d, u) >= 0.8 for u in unique_descs)
        if not is_dup:
            unique_descs.append(d)

    # Best description: longest unique desc
    best_desc = max(unique_descs, key=len) if unique_descs else ""

    MAX_PATHS = 10
    capped_paths = tome_paths[:MAX_PATHS]
    relative_paths = [os.path.relpath(p, project_dir) for p in capped_paths]

    recurrences.append({
        "finding_id": fid,
        "tome_paths": relative_paths,
        "count": count,
        "severity": infer_severity(fid),
        "description": best_desc,
    })

# Sort by severity desc (high first), then count desc
SEVERITY_ORDER = {'high': 0, 'medium': 1, 'low': 2}
recurrences.sort(key=lambda r: (SEVERITY_ORDER.get(r['severity'], 3), -r['count']))

print(json.dumps({"recurrences": recurrences}))
PYEOF

exit 0
