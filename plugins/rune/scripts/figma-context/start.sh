#!/bin/bash
set -euo pipefail
# Figma Context MCP Server launcher (Framelink figma-developer-mcp)
#
# WHY THIS WRAPPER EXISTS:
# Provides a stable MCP server launch with fallback chain:
#   1. Global install — fast startup, direct signal handling, auto-updated
#   2. npx fallback — exec replaces shell, proper signal forwarding
#
# Version staleness: checks every 7 days (MCP_STALENESS_TTL env override).
# Version mismatch triggers immediate update regardless of TTL.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/mcp-pkg-manager.sh"

# Resolve FIGMA_TOKEN from env
FIGMA_TOKEN="${FIGMA_TOKEN:-}"
if [[ -z "$FIGMA_TOKEN" ]]; then
  echo "Error: FIGMA_TOKEN not set." >&2
  exit 1
fi

PACKAGE="figma-developer-mcp"
VERSION="0.8.0"

# SEC-001 FIX: Pass token via env var instead of CLI arg
# to avoid exposure in process listings (ps aux). The figma-developer-mcp package
# v0.8.0+ reads FIGMA_API_KEY from env when --figma-api-key is not provided.
# (Earlier versions used FIGMA_ACCESS_TOKEN, which no longer works.)
export FIGMA_API_KEY="$FIGMA_TOKEN"

# Option 1: Global install with version check + auto-update
if mcp_ensure_package "$PACKAGE" "$VERSION" "$PACKAGE"; then
  exec "$PACKAGE" --stdio
fi

# Option 2: npx fallback (exec replaces shell — proper signal forwarding)
if command -v npx >/dev/null 2>&1; then
  exec npx -y "${PACKAGE}@${VERSION}" --stdio
fi

echo "Error: npm/npx not found in PATH. Cannot install or run ${PACKAGE}." >&2
exit 1
