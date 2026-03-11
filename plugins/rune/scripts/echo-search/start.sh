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
# Use shared venv helper — venv lives in ${CLAUDE_CONFIG_DIR}/rune-venv/
# shellcheck source=../lib/rune-venv.sh
REQUIREMENTS="${PLUGIN_ROOT}/scripts/requirements.txt"
PYTHON="python3"
if [[ -f "$REQUIREMENTS" ]]; then
    source "${PLUGIN_ROOT}/scripts/lib/rune-venv.sh" 2>/dev/null || true
    if type rune_resolve_venv &>/dev/null; then
        PYTHON=$(rune_resolve_venv "$REQUIREMENTS")
    fi
fi
if ! "$PYTHON" -c "import mcp" 2>/dev/null; then
    echo "Error: MCP package not available. Check venv setup." >&2
    exit 1
fi

# SEC-006: Canonicalize PROJECT_DIR and validate absoluteness
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || { echo "ERROR: invalid PROJECT_DIR" >&2; exit 1; }
[[ "$PROJECT_DIR" == /* ]] || { echo "ERROR: PROJECT_DIR not absolute: $PROJECT_DIR" >&2; exit 1; }
export ECHO_DIR="$PROJECT_DIR/.claude/echoes"
export DB_PATH="$PROJECT_DIR/.claude/echoes/.search-index.db"

exec "$PYTHON" "$SCRIPT_DIR/server.py"
