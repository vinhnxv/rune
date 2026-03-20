#!/bin/bash
# scripts/learn/meta-qa-detector.sh
# Detects meta-QA patterns from arc checkpoint.json files.
#
# USAGE:
#   meta-qa-detector.sh [--since DAYS] [--project PATH]
#
# Options:
#   --since DAYS   Only scan arcs completed within last N days (default: 7)
#   --project PATH Project root (default: CWD)
#
# Output (stdout): JSON -- { "patterns": [...] }
# Each pattern:
#   {
#     "type": "meta-qa",
#     "pattern_key": "retry_rate:code_review",
#     "description": "code_review phase retried in 3/4 recent arcs",
#     "affected_phase": "code_review",
#     "arc_count": 3,
#     "total_arcs": 4,
#     "confidence": 0.8,
#     "evidence": [".rune/arc/arc-123/checkpoint.json"],
#     "category": "retry_rate|convergence|qa_score"
#   }
#
# EXIT: 0 always (fail-forward). On error, outputs {"patterns":[]} with "error" field.
# DEPENDENCIES: python3

set -euo pipefail
umask 077

RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
[[ "$RUNE_TRACE_LOG" =~ ^/tmp/ ]] || RUNE_TRACE_LOG=""
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
  printf '{"patterns":[],"error":"crashed_at_line_%s"}\n' "$_crash_line"
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
  printf '{"patterns":[],"error":"python3_not_found"}\n'
  exit 0
fi

# -- Argument parsing --
SINCE_DAYS=7
PROJECT_DIR="${PWD}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      shift
      SINCE_DAYS="${1:-7}"
      shift
      ;;
    --project)
      shift
      PROJECT_DIR="${1:-$PWD}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Validate since_days is numeric and positive
SINCE_DAYS=$(( "${SINCE_DAYS}" + 0 )) 2>/dev/null || SINCE_DAYS=7
[[ "$SINCE_DAYS" -lt 1 ]] && SINCE_DAYS=7

# Reject path traversal in project dir
[[ "$PROJECT_DIR" == *..* ]] && { echo "error"; exit 1; }

# Resolve project dir (never symlink)
if [[ ! -d "$PROJECT_DIR" ]]; then
  printf '{"patterns":[],"error":"project_dir_not_found"}\n'
  exit 0
fi

ARC_DIR="${PROJECT_DIR}/.rune/arc"
ECHO_DIR="${PROJECT_DIR}/.rune/echoes/meta-qa"

_trace "Scanning arc dir: $ARC_DIR (since ${SINCE_DAYS} days)"

if [[ ! -d "$ARC_DIR" ]]; then
  printf '{"patterns":[],"error":"no_arc_dir"}\n'
  exit 0
fi

# -- Collect checkpoint files (no symlinks) --
CHECKPOINTS_JSON="[]"

# Use find -P to avoid symlinks; filter by modification time
CHECKPOINT_LIST=""
while IFS= read -r ckpt; do
  [[ -L "$ckpt" ]] && continue
  CHECKPOINT_LIST="${CHECKPOINT_LIST}${ckpt}"$'\n'
done < <(find -P "$ARC_DIR" -maxdepth 2 -name "checkpoint.json" -not -type l -mtime -${SINCE_DAYS} \
  2>/dev/null || true)

# Fallback: if date arithmetic failed, collect all checkpoints
if [[ -z "$CHECKPOINT_LIST" ]]; then
  while IFS= read -r ckpt; do
    [[ -L "$ckpt" ]] && continue
    CHECKPOINT_LIST="${CHECKPOINT_LIST}${ckpt}"$'\n'
  done < <(find -P "$ARC_DIR" -maxdepth 2 -name "checkpoint.json" -not -type l 2>/dev/null || true)
fi

if [[ -z "$CHECKPOINT_LIST" ]]; then
  printf '{"patterns":[],"error":"no_checkpoints_found"}\n'
  exit 0
fi

# Encode checkpoint list as JSON array for python3
CHECKPOINTS_JSON=$(printf '%s' "$CHECKPOINT_LIST" | python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps(lines))
" 2>/dev/null) || CHECKPOINTS_JSON='[]'

if [[ "$CHECKPOINTS_JSON" == '[]' ]]; then
  printf '{"patterns":[],"error":"no_checkpoints_encoded"}\n'
  exit 0
fi

# -- Read existing meta-qa echoes to avoid duplicates --
ECHO_MEMORY=""
if [[ -f "${ECHO_DIR}/MEMORY.md" ]] && [[ ! -L "${ECHO_DIR}/MEMORY.md" ]]; then
  ECHO_MEMORY=$(head -c 65536 < "${ECHO_DIR}/MEMORY.md" 2>/dev/null || true)
fi
ECHO_MEMORY_JSON=$(printf '%s' "$ECHO_MEMORY" | python3 -c "
import sys, json
print(json.dumps(sys.stdin.read()))
" 2>/dev/null) || ECHO_MEMORY_JSON='""'

# -- Write python3 processor to temp file (avoids heredoc+pipe stdin conflict) --
PY_TMP=$(mktemp "${TMPDIR:-/tmp}/rune-mqd-XXXXXX.py" 2>/dev/null) || {
  printf '{"patterns":[],"error":"tmpfile_failed"}\n'
  exit 0
}
cat > "$PY_TMP" << 'PYEOF'
import sys, json, re, os

checkpoint_paths = json.loads(sys.argv[1])
echo_memory = json.loads(sys.argv[2])

# -- Parse each checkpoint --
arcs = []
for path in checkpoint_paths:
    try:
        with open(path, 'r') as f:
            ckpt = json.load(f)
    except Exception:
        continue

    # Only include completed arcs
    phases = ckpt.get('phases', {})
    is_completed = (
        phases.get('ship', {}).get('status') == 'completed' or
        phases.get('merge', {}).get('status') == 'completed'
    )
    if not is_completed:
        continue

    arc_id = os.path.basename(os.path.dirname(path))

    # Extract per-phase retry counts
    phase_retries = {}
    phase_durations = {}
    for pname, pdata in phases.items():
        if isinstance(pdata, dict):
            rc = pdata.get('retry_count', 0)
            dur = pdata.get('duration_ms', 0)
            if rc:
                phase_retries[pname] = rc
            if dur:
                phase_durations[pname] = dur

    # Extract convergence data
    convergence_rounds = ckpt.get('convergence_rounds', 0)
    global_retries = ckpt.get('global_retry_count', 0)

    # Extract QA scores (if present)
    qa_scores = {}
    qa_data = ckpt.get('qa', {})
    if isinstance(qa_data, dict):
        for phase_name, score_val in qa_data.items():
            if isinstance(score_val, (int, float)):
                qa_scores[phase_name] = score_val
            elif isinstance(score_val, dict):
                s = score_val.get('score', score_val.get('percentage', None))
                if s is not None:
                    qa_scores[phase_name] = s

    arcs.append({
        'arc_id': arc_id,
        'path': path,
        'phase_retries': phase_retries,
        'phase_durations': phase_durations,
        'convergence_rounds': convergence_rounds,
        'global_retries': global_retries,
        'qa_scores': qa_scores,
    })

if not arcs:
    print(json.dumps({"patterns": [], "error": "no_completed_arcs"}))
    sys.exit(0)

total_arcs = len(arcs)

# -- Aggregate phase retry rates across arcs --
phase_retry_arcs = {}  # phase -> list of arc_ids where it was retried
for arc in arcs:
    for pname in arc['phase_retries']:
        phase_retry_arcs.setdefault(pname, []).append(arc['arc_id'])

# -- Aggregate convergence round counts --
high_convergence_arcs = [a for a in arcs if a['convergence_rounds'] > 2]

# -- Aggregate low QA score phases --
qa_low_score_arcs = {}  # phase -> list of arc_ids with score < 70
for arc in arcs:
    for pname, score in arc['qa_scores'].items():
        if score < 70:
            qa_low_score_arcs.setdefault(pname, []).append(arc['arc_id'])

# -- Extract already-echoed pattern keys --
echoed_keys = set(re.findall(r'pattern_key[:\s]+([a-zA-Z0-9_:.-]+)', echo_memory))

# -- Build patterns list --
patterns = []

# Pattern type 1: Phase retry rate > 50%
for pname, arc_ids in sorted(phase_retry_arcs.items()):
    arc_count = len(arc_ids)
    retry_rate = arc_count / total_arcs
    if retry_rate < 0.5:
        continue  # Not flagged

    pattern_key = f"retry_rate:{pname}"
    if pattern_key in echoed_keys:
        continue  # Already captured

    # Confidence by arc count
    if arc_count >= 3:
        confidence = 0.8
    elif arc_count >= 2:
        confidence = 0.6
    else:
        confidence = 0.4

    patterns.append({
        "type": "meta-qa",
        "pattern_key": pattern_key,
        "description": f"{pname} phase retried in {arc_count}/{total_arcs} recent arcs ({int(retry_rate*100)}%)",
        "affected_phase": pname,
        "arc_count": arc_count,
        "total_arcs": total_arcs,
        "confidence": confidence,
        "evidence": [a['path'] for a in arcs if pname in a['phase_retries']],
        "category": "retry_rate",
    })

# Pattern type 2: High convergence rounds
if high_convergence_arcs:
    conv_count = len(high_convergence_arcs)
    pattern_key = "convergence:high_rounds"
    if pattern_key not in echoed_keys:
        if conv_count >= 3:
            confidence = 0.8
        elif conv_count >= 2:
            confidence = 0.6
        else:
            confidence = 0.4

        avg_rounds = sum(a['convergence_rounds'] for a in high_convergence_arcs) / conv_count
        patterns.append({
            "type": "meta-qa",
            "pattern_key": pattern_key,
            "description": f"Arc runs needed >2 convergence rounds in {conv_count}/{total_arcs} cases (avg {avg_rounds:.1f} rounds)",
            "affected_phase": "verify_mend",
            "arc_count": conv_count,
            "total_arcs": total_arcs,
            "confidence": confidence,
            "evidence": [a['path'] for a in high_convergence_arcs],
            "category": "convergence",
        })

# Pattern type 3: QA score < 70 for a phase
for pname, arc_ids in sorted(qa_low_score_arcs.items()):
    low_count = len(arc_ids)
    if low_count < 1:
        continue

    pattern_key = f"qa_score:{pname}"
    if pattern_key in echoed_keys:
        continue

    if low_count >= 3:
        confidence = 0.8
    elif low_count >= 2:
        confidence = 0.6
    else:
        confidence = 0.4

    patterns.append({
        "type": "meta-qa",
        "pattern_key": pattern_key,
        "description": f"{pname} QA score below 70 in {low_count}/{total_arcs} recent arcs",
        "affected_phase": pname,
        "arc_count": low_count,
        "total_arcs": total_arcs,
        "confidence": confidence,
        "evidence": [a['path'] for a in arcs if pname in a.get('qa_scores', {}) and a['qa_scores'][pname] < 70],
        "category": "qa_score",
    })

# Sort: confidence desc, then arc_count desc
patterns.sort(key=lambda p: (-p['confidence'], -p['arc_count']))

print(json.dumps({"patterns": patterns, "total_arcs_scanned": total_arcs}))
PYEOF

# -- Execute python3 with checkpoint list and echo memory --
python3 "$PY_TMP" "$CHECKPOINTS_JSON" "$ECHO_MEMORY_JSON"

exit 0
