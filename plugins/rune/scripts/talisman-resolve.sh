#!/bin/bash
# scripts/talisman-resolve.sh
# SessionStart hook: Pre-processes talisman.yml into per-namespace JSON shards.
# Reduces per-phase token cost from ~1,200 to ~50-100 tokens (94% reduction).
#
# Merge order: defaults <- global <- project (project wins)
# Output: tmp/.talisman-resolved/{arc,codex,review,...,_meta}.json (14 files)
#
# Hook events: SessionStart (startup|resume)
# Timeout budget: <2 seconds (5s hard limit)
# Non-blocking: exits 0 on all failures (consumers fall back to readTalisman())

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  # BACK-003 FIX: Always emit stderr warning so fail-forward bypasses are observable.
  printf 'WARNING: %s: ERR trap — fail-forward activated (line %s). Talisman resolution skipped.\n' \
    "${BASH_SOURCE[0]##*/}" \
    "${BASH_LINENO[0]:-?}" \
    >&2 2>/dev/null || true
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

# ── Guard: jq dependency ──
if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── Timing (macOS-safe — no date +%s%3N) ──
# NOTE: $SECONDS is integer-precision only in bash. Sub-second runs report 0.
# This is intentionally coarse-grained: it detects pathological stalls (>3s),
# not sub-second performance regressions. Typical resolve time: 0.3-1.5s.
RESOLVE_START=$SECONDS

# ── Trace logging ──
_trace() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ ! -L "$_log" ]] && echo "[talisman-resolve] $*" >> "$_log" 2>/dev/null
  fi
  return 0
}

# ── Paths ──
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DEFAULTS_FILE="${PLUGIN_ROOT}/scripts/talisman-defaults.json"
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# CHOME absoluteness guard
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  _trace "WARN: CHOME is empty or relative, aborting"
  exit 0
fi

# ── Read hook input (1MB cap) ──
INPUT=$(head -c 1048576 2>/dev/null || true)
CWD=""
SESSION_ID=""
if [[ -n "$INPUT" ]]; then
  # BACK-005 FIX: Use printf instead of echo to avoid flag interpretation if $INPUT starts with '-'
  CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
fi

# Fallback CWD
if [[ -z "$CWD" ]]; then
  CWD=$(pwd)
fi

# Canonicalize CWD to prevent symlink-based path manipulation (SEC-002)
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || CWD=$(pwd -P)

PROJECT_TALISMAN="${CWD}/.claude/talisman.yml"
GLOBAL_TALISMAN="${CHOME}/talisman.yml"

# System-level shard directory for defaults-only cache
SYSTEM_SHARD_DIR="${CHOME}/.rune/talisman-resolved"

# Symlink guard for .rune/ directory (SEC-001)
if [[ -L "${CHOME}/.rune" ]]; then
  _trace "WARN: ${CHOME}/.rune is a symlink — refusing to write"
  exit 0
fi

# ── Canonical shard name list (used by both fast-path check and write loop) ──
# BACK-001 FIX: Single source of truth — prevents drift between fast-path and write loop
SHARD_NAMES=("arc" "codex" "review" "work" "goldmask" "plan" "gates" "settings" "inspect" "testing" "audit" "ux" "misc" "keyword_detection" "tool_failure_tracking" "deliverable_verification" "context_stop_guard")

# ── Guard: defaults file must exist and not be a symlink ──
# SEC-004 FIX: Add symlink check to prevent symlink-based content injection
if [[ ! -f "$DEFAULTS_FILE" ]] || [[ -L "$DEFAULTS_FILE" ]]; then
  _trace "WARN: talisman-defaults.json not found or is a symlink at $DEFAULTS_FILE"
  exit 0
fi

# ── Pre-check python3+PyYAML availability (once) ──
# Uses shared venv helper (lib/rune-venv.sh) — venv lives in CLAUDE_CONFIG_DIR.
# Self-sufficient: creates venv if session-start.sh hasn't run yet (parallel hooks).
# shellcheck source=lib/rune-venv.sh
RUNE_PYTHON="python3"
RUNE_REQUIREMENTS="${PLUGIN_ROOT}/scripts/requirements.txt"
if [[ -f "$RUNE_REQUIREMENTS" ]] && command -v python3 &>/dev/null; then
  source "${PLUGIN_ROOT}/scripts/lib/rune-venv.sh" 2>/dev/null || true
  if type rune_resolve_venv &>/dev/null; then
    RUNE_PYTHON=$(rune_resolve_venv "$RUNE_REQUIREMENTS")
  fi
fi

HAS_PYYAML=false
if "$RUNE_PYTHON" -c "import yaml" 2>/dev/null; then
  HAS_PYYAML=true
fi

# ── Guard: warn if no YAML parser available (VEIL-007) ──
if [[ "$HAS_PYYAML" != "true" ]] && ! command -v yq &>/dev/null; then
  _trace "WARN: No YAML parser available (need python3+PyYAML or yq). Using defaults only."
fi

# ── YAML→JSON conversion ──
yaml_to_json() {
  local file="$1"

  # Guard: file must exist, not be a symlink, and have content
  if [[ ! -f "$file" ]] || [[ -L "$file" ]]; then
    echo '{}'
    return 0
  fi

  # Attempt 1: python3 with PyYAML (via shared venv)
  if [[ "$HAS_PYYAML" == "true" ]]; then
    "$RUNE_PYTHON" -c "
import yaml, json, sys
try:
    with open(sys.argv[1], encoding='utf-8-sig') as f:
        data = yaml.safe_load(f)
    print(json.dumps(data if isinstance(data, dict) else {}))
except Exception:
    print('{}')
" "$file" 2>/dev/null && return 0
  fi

  # Attempt 2: yq if available
  if command -v yq &>/dev/null; then
    yq -o=json '.' "$file" 2>/dev/null && return 0
  fi

  # Attempt 3: graceful failure
  echo '{}'
  return 0
}

# ── Convert YAML sources to JSON ──
# Track which sources were used
PROJECT_SOURCE="null"
GLOBAL_SOURCE="null"

project_json='{}'
if [[ -f "$PROJECT_TALISMAN" && ! -L "$PROJECT_TALISMAN" ]]; then
  project_json=$(yaml_to_json "$PROJECT_TALISMAN")
  PROJECT_SOURCE="\"${PROJECT_TALISMAN}\""
fi

global_json='{}'
if [[ -f "$GLOBAL_TALISMAN" && ! -L "$GLOBAL_TALISMAN" ]]; then
  global_json=$(yaml_to_json "$GLOBAL_TALISMAN")
  GLOBAL_SOURCE="\"${GLOBAL_TALISMAN}\""
fi

defaults_json=$(cat "$DEFAULTS_FILE")

# ── Deep merge: defaults <- global <- project ──
# jq -s '.[0] * .[1] * .[2]' performs recursive merge for objects, replaces arrays
# FLAW-001 FIX: MERGE_STATUS assignment was inside $() subshell — never propagated.
# Move merge to temp var and detect failure via exit code.
MERGE_STATUS="full"
merged=$(jq -s '.[0] * .[1] * .[2]' \
  <(echo "$defaults_json") \
  <(echo "$global_json") \
  <(echo "$project_json") 2>/dev/null) || { MERGE_STATUS="partial"; merged='{}'; }

if [[ "$merged" == '{}' || -z "$merged" ]]; then
  _trace "WARN: merged config is empty, using defaults only"
  merged="$defaults_json"
  MERGE_STATUS="defaults_only"
fi

# ── SEC-003: Content validation — reject injection patterns in resolved config ──
# Talisman values are user-authored YAML. Validate merged JSON before writing shards.
# Check 1: Size cap (512KB) — prevents memory exhaustion in downstream consumers
merged_size=${#merged}
if [[ $merged_size -gt 524288 ]]; then
  _trace "WARN: merged config exceeds 512KB ($merged_size bytes), using defaults only"
  merged="$defaults_json"
  MERGE_STATUS="defaults_only"
fi
# Check 2: Reject values containing shell injection patterns (backticks, $(), process substitution)
# These should never appear in talisman config values — they indicate tampering or misconfiguration
# Exclude ward_commands (intentionally shell commands) before checking
if printf '%s' "$merged" | jq 'del(.work.ward_commands)' 2>/dev/null | grep -qE '`[^`]+`|\$\([^)]+\)|<\(|>\(' 2>/dev/null; then
  _trace "WARN: merged config contains shell injection patterns, using defaults only"
  merged="$defaults_json"
  MERGE_STATUS="defaults_only"
fi

# ── Determine shard output directory based on source availability ──
CACHE_TYPE="project"
if [[ "$project_json" == '{}' && "$global_json" == '{}' ]]; then
  # Defaults-only: use system-level cache with hash guard
  SHARD_DIR="$SYSTEM_SHARD_DIR"
  CACHE_TYPE="system"

  # Hash guard: fast-path skip if defaults unchanged
  DEFAULTS_HASH_FILE="${SYSTEM_SHARD_DIR}/.defaults-hash"
  if type _rune_venv_hash &>/dev/null; then
    CURRENT_DEFAULTS_HASH=$(_rune_venv_hash "$DEFAULTS_FILE")
  else
    # Inline fallback if rune-venv.sh not sourced
    CURRENT_DEFAULTS_HASH=$(shasum -a 256 "$DEFAULTS_FILE" 2>/dev/null | cut -d' ' -f1 || sha256sum "$DEFAULTS_FILE" 2>/dev/null | cut -d' ' -f1 || echo "no-hash")
  fi

  if [[ -f "$DEFAULTS_HASH_FILE" && -f "${SYSTEM_SHARD_DIR}/_meta.json" ]]; then
    stored_hash=$(cat "$DEFAULTS_HASH_FILE" 2>/dev/null || true)
    if [[ -n "$stored_hash" && "$stored_hash" == "$CURRENT_DEFAULTS_HASH" && "$CURRENT_DEFAULTS_HASH" != "no-hash" ]]; then
      # Verify completeness: check all shards exist
      all_shards_exist=true
      for sn in "${SHARD_NAMES[@]}"; do
        if [[ ! -f "${SYSTEM_SHARD_DIR}/${sn}.json" ]]; then
          all_shards_exist=false
          break
        fi
      done

      if [[ "$all_shards_exist" == "true" ]]; then
        _trace "Fast path: defaults hash match, skipping resolve"
        existing_meta=$(cat "${SYSTEM_SHARD_DIR}/_meta.json" 2>/dev/null || echo '{}')
        shard_count=$(printf '%s' "$existing_meta" | jq -r '.shard_count // 17' 2>/dev/null || echo "17")
        jq -n \
          --arg count "$shard_count" \
          --arg dir "$SYSTEM_SHARD_DIR" \
          '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":("[Talisman Shards] Resolved " + $count + " config shards to " + $dir + "/ (status: defaults_only, cached). Use readTalismanSection(section) for shard-aware config access.")}}'
        exit 0
      fi
    fi
  fi

  # Hash mismatch or incomplete cache — resolve to system dir
  # SEC-001: Post-mkdir symlink recheck (TOCTOU mitigation)
  mkdir -p "$SYSTEM_SHARD_DIR" 2>/dev/null || { _trace "WARN: cannot create $SYSTEM_SHARD_DIR"; exit 0; }
  if [[ -L "${CHOME}/.rune" ]] || [[ -L "$SYSTEM_SHARD_DIR" ]]; then
    _trace "WARN: symlink detected post-mkdir — refusing to write"
    exit 0
  fi
else
  # User has talisman.yml — use project-level dir
  SHARD_DIR="${CWD}/tmp/.talisman-resolved"
  CACHE_TYPE="project"
  mkdir -p "$SHARD_DIR" 2>/dev/null || { _trace "WARN: cannot create $SHARD_DIR"; exit 0; }
fi

# ── Batch shard extraction (single jq call) ──
# Produces a JSON object with all 13 shard payloads keyed by shard name
all_shards=$(echo "$merged" | jq '{
  arc: {
    defaults: .arc.defaults,
    ship: .arc.ship,
    pre_merge_checks: .arc.pre_merge_checks,
    timeouts: .arc.timeouts,
    sharding: .arc.sharding,
    batch: .arc.batch,
    gap_analysis: .arc.gap_analysis,
    consistency: .arc.consistency
  },
  codex: (.codex // {}),
  review: (.review // {}),
  work: (.work // {}),
  goldmask: (.goldmask // {}),
  plan: (.plan // {}),
  gates: {
    elicitation: (.elicitation // {}),
    horizon: (.horizon // {}),
    evidence: (.evidence // {}),
    doubt_seer: (.doubt_seer // {}),
    state_weaver: (.state_weaver // {})
  },
  settings: {
    version: .version,
    cost_tier: (.cost_tier // "balanced"),
    settings: (.settings // {}),
    defaults: (.defaults // {}),
    "rune-gaze": (."rune-gaze" // {}),
    ashes: (.ashes // {}),
    echoes: (.echoes // {})
  },
  inspect: (.inspect // {}),
  testing: (.testing // {}),
  audit: (.audit // {}),
  ux: (.ux // {}),
  misc: {
    debug: (.debug // {}),
    mend: (.mend // {}),
    design_sync: (.design_sync // {}),
    storybook: (.storybook // {}),
    stack_awareness: (.stack_awareness // {}),
    question_relay: (.question_relay // {}),
    context_monitor: (.context_monitor // {}),
    context_weaving: (.context_weaving // {}),
    codex_review: (.codex_review // {}),
    teammate_lifecycle: (.teammate_lifecycle // {}),
    inner_flame: (.inner_flame // {}),
    solution_arena: (.solution_arena // {}),
    arc_hierarchy: (.arc_hierarchy // {}),
    schema_drift: (.schema_drift // {}),
    deployment_verification: (.deployment_verification // {}),
    integrations: (.integrations // {})
  },
  keyword_detection: (.keyword_detection // {}),
  tool_failure_tracking: (.tool_failure_tracking // {}),
  deliverable_verification: (.deliverable_verification // {}),
  context_stop_guard: (.context_stop_guard // {})
}' 2>/dev/null)

if [[ -z "$all_shards" || "$all_shards" == "null" ]]; then
  _trace "WARN: shard extraction failed"
  exit 0
fi

# ── Write shards atomically (mktemp in $SHARD_DIR + mv) ──
# SHARD_NAMES defined at line 99 (single source of truth — BACK-001 fix)
shard_count=0

for shard_name in "${SHARD_NAMES[@]}"; do
  shard_data=$(echo "$all_shards" | jq --arg s "$shard_name" '.[$s]' 2>/dev/null)
  if [[ -n "$shard_data" && "$shard_data" != "null" ]]; then
    # SEC-003: Basic content validation — ensure valid JSON and reasonable size (1MB max)
    if ! echo "$shard_data" | jq empty 2>/dev/null; then
      _trace "WARN: shard $shard_name failed JSON validation, skipping"
      continue
    fi
    shard_len=${#shard_data}
    if [[ "$shard_len" -gt 1048576 ]]; then
      _trace "WARN: shard $shard_name exceeds 1MB ($shard_len bytes), skipping"
      continue
    fi
    tmp_file=$(mktemp "$SHARD_DIR/.tmp-${shard_name}.XXXXXX") || continue
    if printf '%s\n' "$shard_data" > "$tmp_file" 2>/dev/null; then
      mv -f "$tmp_file" "$SHARD_DIR/${shard_name}.json" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
      shard_count=$((shard_count + 1))
    else
      rm -f "$tmp_file" 2>/dev/null
    fi
  fi
done

# Determine resolver status
RESOLVER_STATUS="full"
if [[ "$HAS_PYYAML" != "true" ]]; then
  if command -v yq &>/dev/null; then
    RESOLVER_STATUS="partial"
  else
    RESOLVER_STATUS="fallback"
  fi
fi
if [[ "$project_json" == '{}' && "$global_json" == '{}' ]]; then
  RESOLVER_STATUS="defaults_only"
fi

# ── Write _meta.json LAST (commit signal) ──
RESOLVED_AT=$("$RUNE_PYTHON" -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")

# Session isolation fields
# QUAL-008 FIX: Canonicalize config_dir via cd+pwd -P (matches resolve-session-identity.sh)
# SEC-001 FIX: Canonicalize and validate config_dir path structure
CURRENT_CFG=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P) || CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ ! "$CURRENT_CFG" =~ ^/ ]]; then
  CURRENT_CFG="$HOME/.claude"
fi
OWNER_PID="${PPID:-0}"

if [[ "$CACHE_TYPE" == "system" ]]; then
  meta_json=$(jq -n \
    --arg resolved_at "$RESOLVED_AT" \
    --arg defaults_src "talisman-defaults.json" \
    --argjson shard_count "$shard_count" \
    --argjson schema_version 2 \
    --arg resolver_status "$RESOLVER_STATUS" \
    --arg merge_status "$MERGE_STATUS" \
    --arg cache_type "system" \
    --arg defaults_hash "${CURRENT_DEFAULTS_HASH:-}" \
    '{
      cache_type: $cache_type,
      resolved_at: $resolved_at,
      sources: { project: null, global: null, defaults: $defaults_src },
      merge_order: ["defaults"],
      merge_status: $merge_status,
      shard_count: $shard_count,
      schema_version: $schema_version,
      resolver_status: $resolver_status,
      defaults_hash: $defaults_hash
    }')
else
  meta_json=$(jq -n \
    --arg resolved_at "$RESOLVED_AT" \
    --arg project_src "${PROJECT_TALISMAN}" \
    --argjson project_exists "$([ -f "$PROJECT_TALISMAN" ] && echo true || echo false)" \
    --arg global_src "${GLOBAL_TALISMAN}" \
    --argjson global_exists "$([ -f "$GLOBAL_TALISMAN" ] && echo true || echo false)" \
    --arg defaults_src "talisman-defaults.json" \
    --argjson shard_count "$shard_count" \
    --argjson schema_version 2 \
    --arg resolver_status "$RESOLVER_STATUS" \
    --arg merge_status "$MERGE_STATUS" \
    --arg config_dir "$CURRENT_CFG" \
    --arg owner_pid "$OWNER_PID" \
    --arg session_id "${SESSION_ID:-unknown}" \
    --arg cache_type "project" \
    '{
      cache_type: $cache_type,
      resolved_at: $resolved_at,
      sources: {
        project: (if $project_exists then $project_src else null end),
        global: (if $global_exists then $global_src else null end),
        defaults: $defaults_src
      },
      merge_order: ["defaults", (if $global_exists then "global" else null end), (if $project_exists then "project" else null end)] | map(select(. != null)),
      merge_status: $merge_status,
      shard_count: $shard_count,
      schema_version: $schema_version,
      resolver_status: $resolver_status,
      config_dir: $config_dir,
      owner_pid: $owner_pid,
      session_id: $session_id
    }')
fi

tmp_meta=$(mktemp "$SHARD_DIR/.tmp-_meta.XXXXXX") || { _trace "WARN: cannot write _meta.json"; exit 0; }
if printf '%s\n' "$meta_json" > "$tmp_meta" 2>/dev/null; then
  mv -f "$tmp_meta" "$SHARD_DIR/_meta.json" 2>/dev/null || rm -f "$tmp_meta" 2>/dev/null
  shard_count=$((shard_count + 1))
else
  rm -f "$tmp_meta" 2>/dev/null
fi

# ── Timing check (integer precision — see RESOLVE_START comment) ──
ELAPSED=$((SECONDS - RESOLVE_START))
if [[ $ELAPSED -gt 3 ]]; then
  _trace "WARN: resolver took ${ELAPSED}s (>80% of 5s budget, integer precision)"
fi

# ── Write defaults hash after successful system-level resolve ──
if [[ "$CACHE_TYPE" == "system" && -n "${CURRENT_DEFAULTS_HASH:-}" && "$CURRENT_DEFAULTS_HASH" != "no-hash" ]]; then
  tmp_hash=$(mktemp "${SYSTEM_SHARD_DIR}/.defaults-hash.XXXXXX" 2>/dev/null) || tmp_hash="${SYSTEM_SHARD_DIR}/.defaults-hash.tmp.$$"
  echo "$CURRENT_DEFAULTS_HASH" > "$tmp_hash" 2>/dev/null && \
    mv -f "$tmp_hash" "${SYSTEM_SHARD_DIR}/.defaults-hash" 2>/dev/null || \
    rm -f "$tmp_hash" 2>/dev/null
fi

_trace "OK: resolved $shard_count shards to $SHARD_DIR in ~${ELAPSED}s (status=$RESOLVER_STATUS, timing=coarse)"

# ── Output hook-specific JSON (SEC-006: jq --arg instead of heredoc interpolation) ──
jq -n \
  --arg count "$shard_count" \
  --arg dir "$SHARD_DIR" \
  --arg status "$RESOLVER_STATUS" \
  '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":("[Talisman Shards] Resolved " + $count + " config shards to " + $dir + "/ (status: " + $status + "). Use readTalismanSection(section) for shard-aware config access.")}}'

exit 0
