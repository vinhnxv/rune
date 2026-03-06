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

# --- Package check ---
# Verify required packages are importable. If any import fails,
# install from requirements.txt. This is fast when packages exist
# (single python3 invocation) and self-healing when they don't.
if ! python3 -c "import mcp" 2>/dev/null; then
    REQUIREMENTS="$SCRIPT_DIR/requirements.txt"
    if [ -f "$REQUIREMENTS" ]; then
        echo "Installing echo-search dependencies..." >&2
        VENV_DIR="$SCRIPT_DIR/.venv"
        if [ ! -d "$VENV_DIR" ]; then
            python3 -m venv "$VENV_DIR" >&2
        fi
        "$VENV_DIR/bin/pip" install -r "$REQUIREMENTS" >&2
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

exec python3 "$SCRIPT_DIR/server.py"
