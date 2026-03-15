#!/bin/bash
set -euo pipefail
# Figma-to-React MCP Server launcher
#
# WHY THIS WRAPPER EXISTS:
# .mcp.json only supports ${CLAUDE_PLUGIN_ROOT} for env substitution.
# This wrapper resolves runtime environment variables and ensures
# required packages are installed before launching the server.
# Do NOT replace this with a direct python3 call in .mcp.json.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
if ! "$PYTHON" -c "import mcp; import httpx; import pydantic" 2>/dev/null; then
    echo "Error: Required packages not available. Check venv setup." >&2
    exit 1
fi

# --- SDK version logging (mcp 1.x→2.x boundary guard) ---
MCP_VER=$("$PYTHON" -c "import mcp; print(getattr(mcp, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
echo "INFO: figma-to-react MCP SDK version: ${MCP_VER}" >&2

# --- Environment ---
# FIGMA_TOKEN is required at runtime (not at launch) — the server
# validates it when a tool call actually needs the Figma API.
# Cache TTL env vars (seconds):
#   FIGMA_FILE_CACHE_TTL  - TTL for file/node data (default: 1800)
#   FIGMA_IMAGE_CACHE_TTL - TTL for image export URLs (default: 86400)

exec "$PYTHON" "$SCRIPT_DIR/server.py"
