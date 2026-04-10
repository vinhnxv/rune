#!/usr/bin/env bash
# lib/rune-venv.sh — Shared venv resolution for Rune plugin
#
# Exports:
#   rune_resolve_venv <requirements_path> → prints path to venv python3
#
# Venv location: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.rune/venv/
# Hash guard: .requirements-hash in venv dir (SHA-256 of requirements.txt)
# Migration: removes old in-tree .venv/ on first run (best-effort)
#
# Dependencies: python3, shasum (macOS) or sha256sum (Linux)
# Error handling: fail-forward — returns "python3" (system) on any failure

# Source guard — prevent double-loading
[[ -n "${_RUNE_VENV_LOADED:-}" ]] && return 0
_RUNE_VENV_LOADED=1

# ── Internal: compute SHA-256 hash of a file ──
_rune_venv_hash() {
  local req_file="$1"
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$req_file" 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$req_file" 2>/dev/null | cut -d' ' -f1
  else
    # Last resort: python3 hashlib
    python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$req_file" 2>/dev/null || echo "no-hash"
  fi
}

# ── Internal: remove old in-tree venvs (one-time migration) ──
_rune_venv_migrate_old() {
  local plugin_root="$1"
  [[ -n "$plugin_root" ]] || return 0
  local old_paths=("${plugin_root}/scripts/.venv" "${plugin_root}/.venv")
  for old_path in "${old_paths[@]}"; do
    if [[ -d "$old_path" && ! -L "$old_path" ]]; then
      rm -rf "$old_path" 2>/dev/null || true
    fi
  done
}

# ── Internal: remove old CHOME-level venv (one-time migration to .rune/venv/) ──
_rune_venv_migrate_chome() {
  local chome="$1"
  [[ -n "$chome" ]] || return 0
  local old_venv="${chome}/rune-venv"
  # Only migrate if old path exists, is a real dir (not symlink), and new path doesn't
  if [[ -d "$old_venv" && ! -L "$old_venv" ]]; then
    rm -rf "$old_venv" 2>/dev/null || true
  fi
}

# ── Public: resolve venv python path, create/update if needed ──
# Usage: PYTHON=$(rune_resolve_venv "/path/to/requirements.txt")
# Returns: absolute path to venv python3 binary (or "python3" on failure)
rune_resolve_venv() {
  local req_file="${1:?Usage: rune_resolve_venv <requirements.txt path>}"
  local chome="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local venv_dir="${chome}/.rune/venv"
  local hash_file="${venv_dir}/.requirements-hash"
  local python_bin="${venv_dir}/bin/python3"

  local current_hash
  current_hash=$(_rune_venv_hash "$req_file")

  # Fast path: venv exists + hash matches → return immediately
  if [[ -x "$python_bin" && -f "$hash_file" ]]; then
    local stored_hash
    stored_hash=$(cat "$hash_file" 2>/dev/null || true)
    if [[ -n "$stored_hash" && "$stored_hash" == "$current_hash" && "$current_hash" != "no-hash" ]]; then
      echo "$python_bin"
      return 0
    fi
  fi

  # Slow path: need python3 to create/update venv
  if ! command -v python3 &>/dev/null; then
    echo "python3"
    return 1
  fi

  # Ensure config dir exists
  [[ -d "$chome" ]] || mkdir -p "$chome" 2>/dev/null || true
  # Symlink guard for .rune/ (SEC-002)
  if [[ -L "${chome}/.rune" ]]; then
    echo "python3"
    return 1
  fi
  (umask 077 && mkdir -p "${chome}/.rune" 2>/dev/null) || true

  # Create venv if missing
  if [[ ! -d "$venv_dir" ]]; then
    python3 -m venv "$venv_dir" 2>/dev/null || { echo "python3"; return 1; }
  fi

  # Install/update dependencies
  if [[ -x "${venv_dir}/bin/pip" && -f "$req_file" ]]; then
    "${venv_dir}/bin/pip" install -q --no-cache-dir -r "$req_file" 2>/dev/null || true
    # ERR-012 FIX: Verify at least one key dependency is importable
    # If pip install silently failed, fall back to system python
    if ! "${venv_dir}/bin/python3" -c "import yaml" 2>/dev/null; then
      echo "python3"
      return 1
    fi
  fi

  # Write hash (atomic: write to tmp then rename)
  if [[ "$current_hash" != "no-hash" ]]; then
    local tmp_hash
    tmp_hash=$(mktemp "${hash_file}.XXXXXX" 2>/dev/null || echo "${hash_file}.tmp.$$")
    echo "$current_hash" > "$tmp_hash" 2>/dev/null && mv -f "$tmp_hash" "$hash_file" 2>/dev/null || rm -f "$tmp_hash" 2>/dev/null
  fi

  # Migrate old in-tree venvs (one-time, best-effort)
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _rune_venv_migrate_old "$CLAUDE_PLUGIN_ROOT"
  fi
  # Migrate old CHOME-level venv (rune-venv/ → .rune/venv/)
  _rune_venv_migrate_chome "$chome"

  echo "$python_bin"
  return 0
}
