#!/bin/bash
# scripts/learn/cli-correction-detector.sh
# Detects error->retry->success sequences in session scanner output.
#
# USAGE:
#   session-scanner.sh | cli-correction-detector.sh [--window N]
#   cli-correction-detector.sh [--window N] < scanner-output.json
#
# Input (stdin): JSON from session-scanner.sh
#   { "events": [...], "scanned": N, "project": "..." }
#   Each event: { tool_name, input_preview, result_preview, is_error, tool_use_id, file }
#
# Options:
#   --window N   Max events between error and retry to count as a pair (default: 5)
#
# Output (stdout): JSON -- { "corrections": [...] }
# Each correction:
#   {
#     "error_type": "UnknownFlag|CommandNotFound|WrongPath|WrongSyntax|PermissionDenied|Timeout",
#     "tool_name": "Bash",
#     "failed_input": "...",
#     "corrected_input": "...",
#     "confidence": 0.0-1.0,
#     "multi_session": false
#   }
#
# EXIT: 0 always (fail-forward). On error, outputs {"corrections":[]} with "error" field.
# DEPENDENCIES: python3

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] %s: %s\n' "$(date +%H:%M:%S)" "${BASH_SOURCE[0]##*/}" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap -- fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  echo "WARN: ${BASH_SOURCE[0]##*/} crashed at line $_crash_line -- fail-forward." >&2
  printf '{"corrections":[],"error":"crashed_at_line_%s"}\n' "$_crash_line"
  exit 0
}
trap '_rune_fail_forward' ERR

_rune_cleanup() {
  rm -f "${PY_TMP:-}" 2>/dev/null
}
trap '_rune_cleanup' EXIT
trap '_rune_cleanup; exit 130' INT
trap '_rune_cleanup; exit 143' TERM

# -- Dependency guards --
if ! command -v python3 &>/dev/null; then
  printf '{"corrections":[],"error":"python3_not_found"}\n'
  exit 0
fi

# -- Argument parsing --
WINDOW=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window)
      shift
      WINDOW="${1:-5}"
      [[ $# -gt 0 ]] && shift
      ;;
    *)
      shift
      ;;
  esac
done

# Validate window is numeric and positive
WINDOW=$(( "${WINDOW}" + 0 )) 2>/dev/null || WINDOW=5
[[ "$WINDOW" -lt 1 ]] && WINDOW=5

# -- Read scanner output from stdin --
INPUT=$(head -c 1048576 2>/dev/null || true)

if [[ -z "$INPUT" ]]; then
  printf '{"corrections":[],"error":"empty_input"}\n'
  exit 0
fi

# -- Write python3 processor to temp file (avoids heredoc+pipe stdin conflict) --
PY_TMP=$(mktemp "${TMPDIR:-/tmp}/rune-ccd-XXXXXX.py" 2>/dev/null) || {
  printf '{"corrections":[],"error":"tmpfile_failed"}\n'
  exit 0
}
cat > "$PY_TMP" << 'PYEOF'
import sys, json, re

window = int(sys.argv[1])
raw = sys.stdin.read()

try:
    scanner_output = json.loads(raw)
except json.JSONDecodeError:
    print(json.dumps({"corrections": [], "error": "invalid_json_input"}))
    sys.exit(0)

events = scanner_output.get("events", [])
if not events:
    print(json.dumps({"corrections": []}))
    sys.exit(0)

# -- Error classification patterns --
ERROR_PATTERNS = [
    ("UnknownFlag",     re.compile(r'unknown (?:flag|option)|unrecognized (?:flag|option|argument)|invalid (?:flag|option)|bad flag', re.IGNORECASE)),
    ("CommandNotFound", re.compile(r'command not found|No such file or directory.*bin|is not recognized as|cannot find the command|zsh: command not found', re.IGNORECASE)),
    ("WrongPath",       re.compile(r'No such file or directory|not a directory|no such file|does not exist|cannot access|Path not found', re.IGNORECASE)),
    ("WrongSyntax",     re.compile(r'syntax error|unexpected token|parse error|invalid syntax|unexpected.*near|SyntaxError|illegal option', re.IGNORECASE)),
    ("PermissionDenied",re.compile(r'permission denied|access denied|Operation not permitted|insufficient permissions', re.IGNORECASE)),
    ("Timeout",         re.compile(r'timed? ?out|timeout|killed.*SIGTERM|Killed: 9|exceeded.*time limit', re.IGNORECASE)),
]

def classify_error(result_preview):
    for error_type, pattern in ERROR_PATTERNS:
        if pattern.search(result_preview):
            return error_type
    return "UnknownError"

def word_set(text):
    return set(re.findall(r'\b\w+\b', text.lower()))

def jaccard(a, b):
    sa, sb = word_set(a), word_set(b)
    if not sa and not sb:
        return 1.0
    inter = len(sa & sb)
    union = len(sa | sb)
    return inter / union if union > 0 else 0.0

def compute_confidence(error_event, success_event):
    base = 0.5
    if error_event.get("tool_name") == success_event.get("tool_name"):
        base += 0.2
    err_input = error_event.get("input_preview", "")
    suc_input = success_event.get("input_preview", "")
    sim = jaccard(err_input, suc_input)
    if 0.3 <= sim < 0.95:
        base += 0.2
    if error_event.get("file") != success_event.get("file"):
        base += 0.1
    return round(min(base, 1.0), 2)

# -- Scan events for error->success pairs within window --
corrections = []
n = len(events)
i = 0

while i < n:
    event = events[i]
    if not event.get("is_error", False):
        i += 1
        continue

    tool_name = event.get("tool_name", "")
    result_preview = event.get("result_preview", "")
    error_type = classify_error(result_preview)

    found = False
    for j in range(i + 1, min(i + window + 1, n)):
        candidate = events[j]
        if candidate.get("is_error", False):
            continue
        if candidate.get("tool_name", "") != tool_name:
            continue

        confidence = compute_confidence(event, candidate)
        corrections.append({
            "error_type": error_type,
            "tool_name": tool_name,
            "failed_input": event.get("input_preview", "")[:500],
            "corrected_input": candidate.get("input_preview", "")[:500],
            "error_preview": result_preview[:200],
            "confidence": confidence,
            "multi_session": event.get("file") != candidate.get("file"),
        })
        i = j
        found = True
        break

    if not found:
        i += 1

# -- Dedup with Jaccard word-overlap (80% threshold) --
unique_corrections = []
for c in corrections:
    key = c["failed_input"] + " " + c["corrected_input"]
    is_dup = any(
        jaccard(key, u["failed_input"] + " " + u["corrected_input"]) >= 0.8
        for u in unique_corrections
    )
    if not is_dup:
        unique_corrections.append(c)

unique_corrections.sort(key=lambda c: -c["confidence"])
print(json.dumps({"corrections": unique_corrections}))
PYEOF

# -- Execute python3 with input piped to its stdin --
printf '%s' "$INPUT" | python3 "$PY_TMP" "$WINDOW"

exit 0
