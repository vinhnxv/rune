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
# Use shared plugin venv (created by session-start.sh).
# Fallback: create venv from shared requirements.txt if not ready.
RUNE_VENV="${PLUGIN_ROOT}/.venv"
PYTHON="python3"
if [[ -x "${RUNE_VENV}/bin/python3" ]]; then
    PYTHON="${RUNE_VENV}/bin/python3"
fi
if ! "$PYTHON" -c "import mcp; import httpx; import pydantic" 2>/dev/null; then
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

# --- Environment ---
# FIGMA_TOKEN is required at runtime (not at launch) — the server
# validates it when a tool call actually needs the Figma API.
# Cache TTL env vars (seconds):
#   FIGMA_FILE_CACHE_TTL  - TTL for file/node data (default: 1800)
#   FIGMA_IMAGE_CACHE_TTL - TTL for image export URLs (default: 86400)

exec "$PYTHON" "$SCRIPT_DIR/server.py"
