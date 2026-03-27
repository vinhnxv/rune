#!/bin/bash
set -euo pipefail
# Context7 MCP Server launcher (@upstash/context7-mcp)
#
# WHY THIS WRAPPER EXISTS:
# Provides a stable MCP server launch with fallback chain:
#   1. Global install — fast startup, direct signal handling, auto-updated
#   2. npx fallback — exec replaces shell, proper signal forwarding
#
# Pinned to exact version for supply chain safety.
# Version staleness: checks every 7 days (MCP_STALENESS_TTL env override).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/mcp-pkg-manager.sh"

PACKAGE="@upstash/context7-mcp"
VERSION="2.1.3"
BINARY="context7-mcp"

# Option 1: Global install with version check + auto-update
if mcp_ensure_package "$PACKAGE" "$VERSION" "$BINARY"; then
  exec "$BINARY"
fi

# Option 2: npx fallback (exec replaces shell — proper signal forwarding)
if command -v npx >/dev/null 2>&1; then
  exec npx -y "${PACKAGE}@${VERSION}"
fi

echo "Error: npm/npx not found in PATH. Cannot install or run ${PACKAGE}." >&2
exit 1
