#!/bin/bash
set -euo pipefail
# Agent Search MCP Server launcher
#
# WHY THIS WRAPPER EXISTS:
# .mcp.json only supports ${CLAUDE_PLUGIN_ROOT} for env substitution.
# PLUGIN_ROOT and PROJECT_DIR need ${CLAUDE_PROJECT_DIR} which is NOT available
# in .mcp.json env blocks. This wrapper resolves them at runtime.
# Do NOT replace this with a direct python3 call in .mcp.json — it will
# fail silently because PLUGIN_ROOT/PROJECT_DIR/DB_PATH would be unset.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Package check ---
# Use shared venv helper — venv lives in ${CLAUDE_CONFIG_DIR}/.rune/venv/
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

# --- SDK version logging (mcp 1.x→2.x boundary guard) ---
MCP_VER=$("$PYTHON" -c "import mcp; print(getattr(mcp, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
echo "INFO: agent-search MCP SDK version: ${MCP_VER}" >&2
# Verify lowlevel import path still resolves (critical: mcp.server.lowlevel may move in 2.x)
if ! "$PYTHON" -c "from mcp.server.lowlevel import Server; from mcp.server.models import InitializationOptions" 2>/dev/null; then
    echo "WARN: agent-search: mcp.server.lowlevel import failed — server.py may need import updates for MCP SDK ${MCP_VER}" >&2
fi

# SEC-006: Canonicalize PROJECT_DIR and validate absoluteness
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || { echo "ERROR: invalid PROJECT_DIR" >&2; exit 1; }
[[ "$PROJECT_DIR" == /* ]] || { echo "ERROR: PROJECT_DIR not absolute: $PROJECT_DIR" >&2; exit 1; }

# Export env vars for server.py
export PLUGIN_ROOT
export PROJECT_DIR
export DB_PATH="$PROJECT_DIR/.claude/.agent-search-index.db"

exec "$PYTHON" "$SCRIPT_DIR/server.py"
