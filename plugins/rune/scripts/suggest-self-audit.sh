#!/usr/bin/env bash
# scripts/suggest-self-audit.sh
# SELF-AUDIT-001: Advisory suggestion to run /rune:self-audit after repeated
# marginal QA scores. Non-blocking. Talisman-gated via self_audit.auto_suggest_threshold.
#
# Hook event: Stop
# Exit 0: No suggestion needed (stdout/stderr discarded)
# Exit 2: Suggestion emitted via stderr (plain text, non-blocking advisory)
#
# Fast-path exits:
#   - No jq available → exit 0
#   - Active arc loop → exit 0
#   - <3 QA verdict files → exit 0
#   - Already suggested this session (debounce) → exit 0

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077  # PAT-003 FIX

# Fail-forward: any error → exit 0 (allow stop, don't crash session)
_rune_fail_forward() { exit 0; }
trap '_rune_fail_forward' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source platform helpers for _stat_mtime
# shellcheck source=lib/platform.sh
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  source "${SCRIPT_DIR}/lib/platform.sh"
fi

# ── Fast-path: jq required ──
command -v jq >/dev/null 2>&1 || exit 0

# ── Parse CWD from hook input ──
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT=$(head -c 1048576 2>/dev/null || true)  # FLAW-006 FIX: 1MB cap consistent with all other hooks
fi
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
[[ -n "$CWD" && -d "$CWD" ]] || exit 0

# ── Fast-path: active arc → exit 0 (don't suggest during arc) ──
# Arc loop state files — one per loop type. If a new loop type is added,
# update this list AND the corresponding stop hook (e.g., arc-new-loop-stop-hook.sh).
# Current types: phase (inner), batch, hierarchy, issues (outer loops).
for _loop_file in arc-phase-loop.local.md arc-batch-loop.local.md arc-hierarchy-loop.local.md arc-issues-loop.local.md; do
  if [[ -f "${CWD}/.rune/${_loop_file}" ]]; then
    exit 0
  fi
done

# ── Fast-path: debounce — max 1 suggestion per session ──
# BACK-001 FIX: Use PPID as fallback for session isolation (session_id may be empty)
_session_id=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""
_owner_pid="${PPID:-$$}"
_debounce_key="${_session_id:-pid-${_owner_pid}}"
_debounce_file="${TMPDIR:-/tmp}/rune-self-audit-suggested-${_debounce_key}"
if [[ -f "$_debounce_file" ]]; then
  exit 0
fi

# ── Collect QA verdict files from recent arc runs ──
shopt -s nullglob
_verdict_files=("${CWD}"/tmp/arc/*/qa/*-verdict.json)
shopt -u nullglob

# Fast-path: fewer than 3 verdicts → not enough data
_verdict_count=${#_verdict_files[@]}
[[ "$_verdict_count" -ge 3 ]] || exit 0

# ── Read threshold from talisman (default: 75) ──
_threshold=75
_talisman_shard="${CWD}/tmp/.talisman-resolved/misc.json"
if [[ -f "$_talisman_shard" && ! -L "$_talisman_shard" ]]; then
  _t=$(jq -r '.self_audit.auto_suggest_threshold // 75' "$_talisman_shard" 2>/dev/null) || _t=75
  # Numeric guard
  if [[ "$_t" =~ ^[0-9]+$ ]] && [[ "$_t" -ge 1 ]] && [[ "$_t" -le 100 ]]; then
    _threshold="$_t"
  fi
fi

# ── Score the most recent 5 verdicts ──
# Sort by mtime (most recent first), take up to 5
_marginal_count=0
_checked=0
_max_check=5

for _vf in $(printf '%s\n' "${_verdict_files[@]}" | while read -r f; do
  _mt=$(_stat_mtime "$f" 2>/dev/null || echo "0")
  echo "${_mt} ${f}"
done | sort -rn | head -"${_max_check}" | awk '{print $2}'); do
  _score=$(jq -r '.scores.overall_score // 0' "$_vf" 2>/dev/null) || _score=0
  # Truncate float to integer
  _score="${_score%.*}"
  # Numeric guard
  if [[ "$_score" =~ ^[0-9]+$ ]]; then
    (( _checked++ )) || true
    if [[ "$_score" -lt "$_threshold" ]]; then
      (( _marginal_count++ )) || true
    fi
  fi
done

# ── Decision: suggest if ≥60% of recent verdicts are marginal ──
[[ "$_checked" -ge 3 ]] || exit 0
_suggest_threshold=$(( _checked * 60 / 100 ))
[[ "$_suggest_threshold" -ge 1 ]] || _suggest_threshold=1
[[ "$_marginal_count" -ge "$_suggest_threshold" ]] || exit 0

# ── Write debounce marker ──
echo "$(date +%s)" > "$_debounce_file" 2>/dev/null || true

# ── Emit suggestion ──
cat >&2 <<'SUGGESTION'
[SELF-AUDIT ADVISORY] Multiple recent arc runs have marginal QA scores.
Consider running /rune:self-audit to analyze recurring quality patterns
and generate improvement recommendations. This is a non-blocking suggestion.
SUGGESTION
exit 2
