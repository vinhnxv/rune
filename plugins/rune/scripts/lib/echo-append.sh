#!/bin/bash
# scripts/lib/echo-append.sh
# Thin sourceable library for appending echo entries via echo-writer.sh.
#
# USAGE:
#   source scripts/lib/echo-append.sh
#   rune_echo_append --role planner --layer inscribed --source "rune:devise" \
#     --title "Architecture: layered API" \
#     --content "Project uses api→services→repos→models pattern" \
#     --confidence HIGH \
#     --tags "architecture,layers" \
#     --domain backend
#
# Provides:
#   rune_echo_append  — Format JSON and pipe to echo-writer.sh
#
# Dependencies:
#   - jq (required for safe JSON construction)
#   - echo-writer.sh (resolved relative to this script)
#   - rune-state.sh (for RUNE_STATE variable)
#
# Exit codes:
#   0 — success (or skipped by echo-writer.sh dedup/guard)
#   1 — validation failure (missing required args, invalid role)
#   2 — missing dependency (jq not found)
#
# SOURCING GUARD: Safe to source multiple times (idempotent).
# Cross-platform: POSIX-safe, no bash 4+ features.

# ── Resolve paths ──
# Use _ECHO_APPEND_DIR to avoid collision with caller's SCRIPT_DIR
_ECHO_APPEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source rune-state.sh for RUNE_STATE variable (idempotent)
if [[ -z "${RUNE_STATE:-}" ]]; then
  # shellcheck source=rune-state.sh
  source "${_ECHO_APPEND_DIR}/rune-state.sh"
fi

# ── Main function ──
# ADVISORY: INTG-002 — rune_echo_append() is currently unused. Reserved for future
# echo workflow integration from bash hooks. Remove if still unused by v3.0.0.
# rune_echo_append --role ROLE --layer LAYER --source SOURCE \
#   --title TITLE --content CONTENT [--confidence HIGH|MEDIUM|LOW] [--tags "t1,t2"] \
#   [--domain DOMAIN]
rune_echo_append() {
  # ── Guard: jq required ──
  if ! command -v jq &>/dev/null; then
    echo "WARN: jq not found — echo-append skipped." >&2
    return 2
  fi

  # ── Resolve echo-writer.sh path ──
  local _writer="${_ECHO_APPEND_DIR}/../learn/echo-writer.sh"
  if [[ ! -f "$_writer" ]]; then
    echo "WARN: echo-writer.sh not found at ${_writer} — echo-append skipped." >&2
    return 2
  fi

  # ── Parse named arguments ──
  local _role="" _layer="observations" _source="" _title="" _content=""
  local _confidence="MEDIUM" _tags="" _domain=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        shift
        _role="${1:-}"
        ;;
      --layer)
        shift
        _layer="${1:-}"
        ;;
      --source)
        shift
        _source="${1:-}"
        ;;
      --title)
        shift
        _title="${1:-}"
        ;;
      --content)
        shift
        _content="${1:-}"
        ;;
      --confidence)
        shift
        _confidence="${1:-MEDIUM}"
        ;;
      --tags)
        shift
        _tags="${1:-}"
        ;;
      --domain)
        shift
        _domain="${1:-}"
        ;;
      *)
        # Skip unknown args
        ;;
    esac
    [[ $# -gt 0 ]] && shift
  done

  # ── Validate required args ──
  if [[ -z "$_role" ]]; then
    echo "ERROR: --role is required" >&2
    return 1
  fi
  if [[ -z "$_title" ]]; then
    echo "ERROR: --title is required" >&2
    return 1
  fi
  if [[ -z "$_content" ]]; then
    echo "ERROR: --content is required" >&2
    return 1
  fi
  if [[ -z "$_source" ]]; then
    echo "ERROR: --source is required" >&2
    return 1
  fi

  # ── Validate role name: /^[a-zA-Z0-9_-]+$/ ──
  if [[ ! "$_role" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid role name (must match [a-zA-Z0-9_-]+): ${_role}" >&2
    return 1
  fi

  # ── Validate layer ──
  case "$_layer" in
    etched|inscribed|notes|observations|traced) ;;
    *)
      echo "WARN: unknown layer '${_layer}', defaulting to observations" >&2
      _layer="observations"
      ;;
  esac

  # ── Validate confidence ──
  case "$(printf '%s' "$_confidence" | tr '[:lower:]' '[:upper:]')" in
    HIGH|MEDIUM|LOW) _confidence="$(printf '%s' "$_confidence" | tr '[:lower:]' '[:upper:]')" ;;
    *) _confidence="MEDIUM" ;;
  esac

  # ── CRITICAL: Create role directory if missing ──
  # echo-writer.sh (line 164-169) silently exits 0 when role dir doesn't exist.
  # We must ensure the directory exists before piping to echo-writer.sh.
  local _echoes_dir="${RUNE_STATE_ABS:-${RUNE_STATE:-.rune}}/echoes"
  local _role_dir="${_echoes_dir}/${_role}"

  # SEC-001 FIX: Symlink guard on echoes directory before mkdir
  if [[ -L "$_echoes_dir" ]]; then
    echo "WARN: echoes directory is a symlink — refusing to write: ${_echoes_dir}" >&2
    return 1
  fi

  # Ensure base echoes directory exists
  if [[ ! -d "$_echoes_dir" ]]; then
    mkdir -p "$_echoes_dir" 2>/dev/null || {
      echo "WARN: cannot create echoes directory: ${_echoes_dir}" >&2
      return 1
    }
  fi

  # SEC-001 FIX: Symlink guard on role directory
  if [[ -L "$_role_dir" ]]; then
    echo "WARN: role directory is a symlink — refusing to write: ${_role_dir}" >&2
    return 1
  fi

  # Create role directory (the key fix for the silent-skip bug)
  if [[ ! -d "$_role_dir" ]]; then
    mkdir -p "$_role_dir" 2>/dev/null || {
      echo "WARN: cannot create role directory: ${_role_dir}" >&2
      return 1
    }
  fi

  # ── Prepend domain metadata to content (if --domain provided) ──
  if [[ -n "$_domain" ]]; then
    # Validate domain: alphanumeric + hyphens only
    if [[ "$_domain" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      _content="**Domain**: ${_domain}
${_content}"
    else
      echo "WARN: invalid domain '${_domain}' (must match [a-zA-Z0-9_-]+), skipping domain tag" >&2
    fi
  fi

  # ── Build tags JSON array ──
  # Convert comma-separated tags to JSON array using jq
  local _tags_json="[]"
  if [[ -n "$_tags" ]]; then
    _tags_json=$(printf '%s' "$_tags" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' 2>/dev/null) || _tags_json="[]"
  fi

  # ── Build JSON using jq -n --arg (safe escaping) ──
  local _json
  _json=$(jq -n \
    --arg title "$_title" \
    --arg content "$_content" \
    --arg confidence "$_confidence" \
    --argjson tags "$_tags_json" \
    '{title: $title, content: $content, confidence: $confidence, tags: $tags}' 2>/dev/null)

  if [[ -z "$_json" ]]; then
    echo "WARN: JSON construction failed — echo-append skipped." >&2
    return 1
  fi

  # ── Pipe JSON to echo-writer.sh ──
  printf '%s' "$_json" | bash "$_writer" --role "$_role" --layer "$_layer" --source "$_source"
  return $?
}
