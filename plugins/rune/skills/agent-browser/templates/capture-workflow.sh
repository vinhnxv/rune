#!/usr/bin/env bash
# Capture workflow template: navigate -> screenshot -> snapshot -> extract
# Usage: Adapt this pattern — do not execute directly
set -euo pipefail

URL="${1:?Usage: provide URL}"
OUTPUT_DIR="${2:-tmp/test/captures}"
# SEC-002 fix: reject path traversal in OUTPUT_DIR
[[ "$OUTPUT_DIR" == *..* ]] && { echo "ERROR: path traversal in OUTPUT_DIR" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

# Cleanup on exit
trap 'agent-browser close 2>/dev/null' EXIT

agent-browser open "$URL" --timeout 30s
agent-browser wait --load networkidle

# Capture screenshots (regular + annotated + full-page)
agent-browser screenshot "$OUTPUT_DIR/viewport.png"
agent-browser screenshot --annotate "$OUTPUT_DIR/annotated.png"
agent-browser screenshot --full-page "$OUTPUT_DIR/full-page.png"

# Optional: video recording wrapper
# agent-browser record start
# ... interactions ...
# agent-browser record stop "$OUTPUT_DIR/session.webm"

# Snapshot for data extraction
agent-browser snapshot --json > "$OUTPUT_DIR/snapshot.json"

agent-browser close
echo "Captures saved to $OUTPUT_DIR"
