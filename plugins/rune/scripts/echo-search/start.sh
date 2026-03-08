#!/bin/bash
set -euo pipefail
# Echo Search MCP Server launcher
#
# WHY THIS WRAPPER EXISTS:
# .mcp.json only supports ${CLAUDE_PLUGIN_ROOT} for env substitution.
# ECHO_DIR and DB_PATH need ${CLAUDE_PROJECT_DIR} which is NOT available
# in .mcp.json env blocks. This wrapper resolves them at runtime.
# Do NOT replace this with a direct python3 call in .mcp.json — it will
# fail silently because ECHO_DIR/DB_PATH would be unset.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Package check ---
# Use shared plugin venv (created by session-start.sh).
# Fallback: create venv from shared requirements.txt if not ready.
RUNE_VENV="${PLUGIN_ROOT}/.venv"
PYTHON="python3"
if [[ -x "${RUNE_VENV}/bin/python3" ]]; then
    PYTHON="${RUNE_VENV}/bin/python3"
fi
if ! "$PYTHON" -c "import mcp" 2>/dev/null; then
    REQUIREMENTS="${PLUGIN_ROOT}/requirements.txt"
    if [[ -f "$REQUIREMENTS" ]]; then
        echo "Installing shared plugin dependencies..." >&2
        if [[ ! -d "$RUNE_VENV" ]]; then
            python3 -m venv "$RUNE_VENV" >&2
        fi
        "${RUNE_VENV}/bin/pip" install -r "$REQUIREMENTS" >&2
        PYTHON="${RUNE_VENV}/bin/python3"
    else
        echo "Error: Missing dependencies and no requirements.txt found" >&2
        exit 1
    fi
fi

# SEC-006: Canonicalize PROJECT_DIR and validate absoluteness
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || { echo "ERROR: invalid PROJECT_DIR" >&2; exit 1; }
[[ "$PROJECT_DIR" == /* ]] || { echo "ERROR: PROJECT_DIR not absolute: $PROJECT_DIR" >&2; exit 1; }
export ECHO_DIR="$PROJECT_DIR/.claude/echoes"
export DB_PATH="$PROJECT_DIR/.claude/echoes/.search-index.db"

exec "$PYTHON" "$SCRIPT_DIR/server.py"
