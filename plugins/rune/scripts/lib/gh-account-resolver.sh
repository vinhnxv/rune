#!/bin/bash
# scripts/lib/gh-account-resolver.sh
# Resolves the correct GitHub account for the current repository.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/gh-account-resolver.sh"
#   rune_gh_ensure_correct_account   # switches to the right account, returns 0 on success
#   rune_gh_check_available          # checks gh CLI + auth, returns 0 if available
#
# PROBLEM:
#   When multiple GitHub accounts are authenticated via `gh auth login`,
#   the active account may not have access to the current repository.
#   This causes `gh pr create`, `gh pr merge`, and `gh api` to fail
#   with cryptic auth errors.
#
# SOLUTION:
#   1. Detect repo owner/name from git remote
#   2. Test if the current active account can access the repo
#   3. If not, iterate through all authenticated accounts and switch
#   4. Return success only when an account with repo access is active
#
# SECURITY:
#   - GH_PROMPT_DISABLED=1 on all gh commands (SEC-DECREE-003)
#   - Username/hostname validated against safe regex before shell use
#   - No eval — direct invocation only
#
# EXIT CODES (for rune_gh_ensure_correct_account):
#   0: Correct account is now active
#   1: No authenticated account has access to this repo
#
# SOURCING GUARD: Safe to source multiple times (idempotent).

export GH_PROMPT_DISABLED=1

# _gh_extract_remote_repo
# Extracts owner/repo from the git remote origin URL.
# Supports: https://github.com/owner/repo.git, git@github.com:owner/repo.git
# Prints: "owner/repo" or empty string on failure.
_gh_extract_remote_repo() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null) || { echo ""; return; }

  local owner_repo=""
  # HTTPS: https://github.com/owner/repo.git  SSH: git@github.com:owner/repo.git
  if [[ "$remote_url" =~ github\.com[/:]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    # zsh populates match[], bash populates BASH_REMATCH[] — support both
    if [[ -n "${match[1]:-}" ]]; then
      owner_repo="${match[1]}/${match[2]}"
    else
      owner_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
  fi

  # Validate extracted owner/repo
  local SAFE_RE='^[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*$'
  if [[ -n "$owner_repo" ]] && [[ "$owner_repo" =~ $SAFE_RE ]]; then
    echo "$owner_repo"
  else
    echo ""
  fi
}

# _gh_get_active_account
# Returns the currently active GitHub account username.
# Prints: "username" or empty string.
_gh_get_active_account() {
  gh auth status 2>&1 | grep -m1 'Logged in to github.com account' | sed 's/.*account \([^ ]*\).*/\1/' | tr -d '[:space:]' || echo ""
}

# _gh_list_all_accounts
# Returns all authenticated GitHub account usernames, one per line.
_gh_list_all_accounts() {
  # gh auth status lists all accounts across all hosts
  # Extract usernames from lines like "  Logged in to github.com account username (...)"
  gh auth status 2>&1 | grep 'Logged in to github.com account' | sed 's/.*account \([^ ]*\).*/\1/' | tr -d ' \t' | sort -u || true
}

# _gh_test_repo_access <owner/repo>
# Tests if the currently active account can access the given repo.
# Returns 0 if accessible, 1 if not.
_gh_test_repo_access() {
  local owner_repo="$1"
  # Use gh api with a lightweight endpoint (repo metadata)
  gh api "repos/${owner_repo}" --jq '.full_name' >/dev/null 2>&1
  return $?
}

# _gh_switch_account <username>
# Switches the active gh account to the given username.
# Returns 0 on success, 1 on failure.
_gh_switch_account() {
  local username="$1"

  # Validate username (alphanumeric + hyphens, GitHub naming rules)
  local USERNAME_RE='^[a-zA-Z0-9][a-zA-Z0-9-]*$'
  if ! [[ "$username" =~ $USERNAME_RE ]]; then
    echo "ERROR: Invalid GitHub username format: $username" >&2
    return 1
  fi

  # gh auth switch requires --hostname and --user
  gh auth switch --hostname github.com --user "$username" 2>/dev/null
  return $?
}

# rune_gh_check_available
# Checks if gh CLI is installed and at least one account is authenticated.
# Returns 0 if available, 1 if not. Prints diagnostic on failure.
rune_gh_check_available() {
  if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found. Install: https://cli.github.com/" >&2
    return 1
  fi

  if ! gh auth status 2>&1 | grep -q 'Logged in'; then
    echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
    return 1
  fi

  return 0
}

# rune_gh_ensure_correct_account
# Ensures the active gh account has access to the current repository.
# If the current account lacks access, iterates through all authenticated
# accounts and switches to one that does.
#
# Returns 0 if a working account is found and active, 1 if none found.
# Prints diagnostic messages to stderr.
rune_gh_ensure_correct_account() {
  # 1. Extract repo identity from git remote
  local owner_repo
  owner_repo=$(_gh_extract_remote_repo)
  if [[ -z "$owner_repo" ]]; then
    echo "WARN: Cannot extract owner/repo from git remote. Proceeding with current account." >&2
    return 0  # Non-fatal — may be a non-GitHub remote
  fi

  # 2. Test current account's access
  if _gh_test_repo_access "$owner_repo"; then
    # Current account works — no switch needed
    return 0
  fi

  local current_account
  current_account=$(_gh_get_active_account)
  echo "INFO: Active account '${current_account:-unknown}' cannot access ${owner_repo}. Trying other accounts..." >&2

  # 3. List all authenticated accounts and try each
  local accounts
  accounts=$(_gh_list_all_accounts)
  if [[ -z "$accounts" ]]; then
    echo "ERROR: No authenticated GitHub accounts found." >&2
    return 1
  fi

  local account
  while IFS= read -r account; do
    [[ -z "$account" ]] && continue
    # Skip the current account (already tested)
    [[ "$account" == "$current_account" ]] && continue

    echo "INFO: Trying account '${account}'..." >&2
    if _gh_switch_account "$account"; then
      if _gh_test_repo_access "$owner_repo"; then
        echo "INFO: Switched to account '${account}' — has access to ${owner_repo}" >&2
        return 0
      fi
    fi
  done <<< "$accounts"

  # 4. None worked — restore original account (best effort) and fail
  if [[ -n "$current_account" ]]; then
    _gh_switch_account "$current_account" 2>/dev/null || true
  fi

  echo "ERROR: No authenticated GitHub account has access to ${owner_repo}." >&2
  echo "ERROR: Run 'gh auth login' with an account that has access to this repository." >&2
  return 1
}
