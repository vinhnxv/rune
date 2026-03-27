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

# Option 1: Global install with version check + auto-update
if mcp_ensure_package "$PACKAGE" "$VERSION" "$PACKAGE"; then
  exec "$PACKAGE" --figma-api-key="$FIGMA_TOKEN" --stdio
fi

# Option 2: npx fallback (exec replaces shell — proper signal forwarding)
if command -v npx >/dev/null 2>&1; then
  exec npx -y "${PACKAGE}@${VERSION}" --figma-api-key="$FIGMA_TOKEN" --stdio
fi

echo "Error: npm/npx not found in PATH. Cannot install or run ${PACKAGE}." >&2
exit 1
