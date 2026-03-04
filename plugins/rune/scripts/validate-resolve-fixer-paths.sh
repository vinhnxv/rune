#!/bin/bash
# validate-resolve-fixer-paths.sh — SEC-RESOLVE-001
# Validates fixer Write/Edit paths against inscription.json allowlist.
# Mandatory, fail-open design — zero cost in non-resolve-todos sessions.
#
# Exit codes:
#   0 = Allow (path is valid or no active resolve-todos workflow)
#   2 = Deny (path is outside allowed scope)

set -euo pipefail

# ── Fast-path exit: check for active resolve-todos workflow ──
INSCRIPTION_PATTERN="tmp/.rune-signals/rune-resolve-todos*/inscription.json"
INSCRIPTION_FILES=$(find tmp -maxdepth 4 -path "*/.rune-signals/rune-resolve-todos*/inscription.json" 2>/dev/null | head -5 || true)

if [[ -z "$INSCRIPTION_FILES" ]]; then
  # No active resolve-todos workflow — allow all
  exit 0
fi

# ── Parse tool input for file path ──
INPUT="${CLAUDE_TOOL_INPUT:-}"
if [[ -z "$INPUT" ]]; then
  # No input available — fail-open
  exit 0
fi

# Extract file path from JSON input
FILE_PATH=$(echo "$INPUT" | jq -r '.file_path // .path // ""' 2>/dev/null || true)
if [[ -z "$FILE_PATH" || "$FILE_PATH" == "null" ]]; then
  # Could not extract path — fail-open
  exit 0
fi

# ── Security validation ──

# Block path traversal
if [[ "$FILE_PATH" == *".."* ]]; then
  echo "SEC-RESOLVE-001: Path traversal blocked: $FILE_PATH" >&2
  exit 2
fi

# Block absolute paths outside project
if [[ "$FILE_PATH" == /* && "$FILE_PATH" != "$(pwd)"* ]]; then
  echo "SEC-RESOLVE-001: Absolute path outside project: $FILE_PATH" >&2
  exit 2
fi

# ── Deny-overlay patterns ──
# These patterns are never allowed for resolve-todos fixers

DENY_PATTERNS=(
  ".claude/"
  ".github/"
  "node_modules/"
  ".env"
  ".env."
  "hooks/"
  ".hooks/"
  "*.sh"
  "scripts/"
  "CI*.yml"
  "*.ci.yml"
)

for pattern in "${DENY_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "SEC-RESOLVE-001: Deny-overlay blocked: $FILE_PATH matches $pattern" >&2
    exit 2
  fi
done

# ── Check inscription allowlist ──
# Read the most recent inscription file
INSCRIPTION_FILE=$(echo "$INSCRIPTION_FILES" | head -1)

if [[ ! -f "$INSCRIPTION_FILE" ]]; then
  # No inscription file — fail-open
  exit 0
fi

# Extract allowed files from task_ownership
ALLOWED_FILES=$(jq -r '.task_ownership[]?.files[]?' "$INSCRIPTION_FILE" 2>/dev/null || true)

if [[ -z "$ALLOWED_FILES" ]]; then
  # No files in allowlist yet — fail-open (workflow just started)
  exit 0
fi

# Check if FILE_PATH matches any allowed file
while IFS= read -r allowed; do
  if [[ -n "$allowed" && "$FILE_PATH" == *"$allowed"* ]]; then
    # Path matches allowed file — allow
    exit 0
  fi
done <<< "$ALLOWED_FILES"

# ── Path not in allowlist ──
echo "SEC-RESOLVE-001: Path not in allowlist: $FILE_PATH" >&2
echo "Allowed files: $ALLOWED_FILES" >&2
exit 2