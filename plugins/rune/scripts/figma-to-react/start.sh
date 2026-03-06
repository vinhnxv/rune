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

# --- Package check ---
# Verify required packages are importable. If any import fails,
# install from requirements.txt. This is fast when packages exist
# (single python3 invocation) and self-healing when they don't.
if ! python3 -c "import mcp; import httpx; import pydantic" 2>/dev/null; then
    REQUIREMENTS="$SCRIPT_DIR/requirements.txt"
    if [ -f "$REQUIREMENTS" ]; then
        echo "Installing figma-to-react dependencies..." >&2
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

# --- Environment ---
# FIGMA_TOKEN is required at runtime (not at launch) — the server
# validates it when a tool call actually needs the Figma API.
# Cache TTL env vars (seconds):
#   FIGMA_FILE_CACHE_TTL  - TTL for file/node data (default: 1800)
#   FIGMA_IMAGE_CACHE_TTL - TTL for image export URLs (default: 86400)

exec python3 "$SCRIPT_DIR/server.py"
