#!/bin/bash
# scripts/lib/pr-comment-poster.sh
# Post review findings to GitHub PR as a comment.
#
# USAGE:
#   pr-comment-poster.sh <pr_number> <comment_body_file> [--force]
#
# ARGS:
#   pr_number:        GitHub PR number (positive integer)
#   comment_body_file: Path to file containing markdown comment body
#   --force:          Skip idempotency check and post even if comment exists
#
# REQUIRES: gh auth (repo scope), GH_PROMPT_DISABLED=1
# SECURITY:
#   SEC-FORGE-001: No eval — direct invocation only
#   SEC-FORGE-003: GH_PROMPT_DISABLED=1 on all gh commands
#   SEC-FORGE-004: Owner/repo name validation
#   SEC-FORGE-005: Idempotency via <!-- rune-review-findings --> marker
#   SEC-FORGE-006: Path traversal guard for body_file
#
# EXIT CODES:
#   0: Success (comment posted or already exists)
#   1: Error (validation failure, gh error)

set -euo pipefail
export GH_PROMPT_DISABLED=1

# Pre-flight: gh CLI must be installed
if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not found. Install via: brew install gh" >&2
  exit 1
fi

# --- Input Validation ---

if [[ $# -lt 2 ]]; then
  echo "ERROR: Usage: pr-comment-poster.sh <pr_number> <body_file> [--force]" >&2
  exit 1
fi

pr_number="$1"
body_file="$2"
force_flag="${3:-}"

# Validate PR number (reuse existing pattern from resolve skills)
if ! [[ "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: Invalid PR number: $pr_number" >&2
  exit 1
fi

# Validate body file exists and is not empty
if [[ ! -s "$body_file" ]]; then
  echo "ERROR: Body file empty or missing: $body_file" >&2
  exit 1
fi

# SEC-FORGE-006: Path traversal guard
if [[ "$body_file" == *".."* ]]; then
  echo "ERROR: Path traversal detected in body_file" >&2
  exit 1
fi
if [[ "$body_file" != tmp/* ]] && [[ "$body_file" != /tmp/* ]] && [[ "$body_file" != "${TMPDIR:-/tmp}"/* ]]; then
  echo "ERROR: body_file must be under tmp/ directory" >&2
  exit 1
fi
# SEC-FORGE-007: Symlink guard — prevent symlink traversal
if [[ -L "$body_file" ]]; then
  echo "ERROR: Symlinks not allowed for body_file" >&2
  exit 1
fi

# --- Owner/Repo Extraction + Validation ---

owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null) || {
  echo "ERROR: Cannot determine repo owner. Is gh authenticated?" >&2
  exit 1
}
repo=$(gh repo view --json name -q '.name' 2>/dev/null) || {
  echo "ERROR: Cannot determine repo name." >&2
  exit 1
}

# SEC-FORGE-004: Validate owner/repo (alphanumeric + hyphens, GitHub naming rules)
REPO_NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9._-]*$'
if ! [[ "$owner" =~ $REPO_NAME_RE ]] || ! [[ "$repo" =~ $REPO_NAME_RE ]]; then
  echo "ERROR: Invalid owner/repo name detected" >&2
  exit 1
fi

# --- Body Size Guard ---

BODY_SIZE=$(wc -c < "$body_file" | tr -d ' ')
GITHUB_COMMENT_LIMIT=65000
if [[ "$BODY_SIZE" -gt "$GITHUB_COMMENT_LIMIT" ]]; then
  echo "WARNING: Comment body exceeds GitHub limit (${BODY_SIZE} > ${GITHUB_COMMENT_LIMIT}). Truncating." >&2
  truncated_file="${body_file}.truncated"
  head -c "$GITHUB_COMMENT_LIMIT" "$body_file" > "$truncated_file"
  printf '\n\n---\n*Comment truncated. Full findings in TOME file.*' >> "$truncated_file"
  body_file="$truncated_file"
fi

# --- Idempotency Check (SEC-FORGE-005) ---

MARKER="<!-- rune-review-findings -->"
if [[ "$force_flag" != "--force" ]]; then
  existing=$(gh api "repos/${owner}/${repo}/issues/${pr_number}/comments" \
    --arg marker "$MARKER" \
    --jq '[.[] | select(.body | contains($marker))] | length' 2>/dev/null || echo "0")
  if [[ "$existing" -gt 0 ]]; then
    echo "INFO: Rune findings already posted to PR #${pr_number}. Use --force to post again." >&2
    exit 0
  fi
fi

# --- Post Comment ---
# Use gh issue comment --body-file (matches arc-issues-stop-hook.sh pattern)
# NEVER use eval — SEC-FORGE-001

gh issue comment "$pr_number" --body-file "$body_file" 2>/dev/null || {
  echo "ERROR: Failed to post PR comment. Check gh auth scope (requires 'repo')." >&2
  exit 1
}

echo "SUCCESS: Review findings posted to PR #${pr_number}"
