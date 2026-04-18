#!/usr/bin/env bash
# test-canary-flag-opt-out.sh — AC-10 regression test for v2.55.0 canary flip
#
# Verifies: a user talisman.yml that explicitly sets
# `arc.state_file.code_enforced_writes: false` keeps dry-run behavior
# after the v2.55.0 default flip (from false to true).
#
# Exit codes:
#   0 — PASS (opt-out preserved)
#   1 — FAIL (opt-out broken)
#   2 — Skipped (missing prerequisite)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
RESOLVER="${REPO_ROOT}/plugins/rune/scripts/talisman-resolve.sh"

# Prerequisite: talisman resolver must exist
if [[ ! -x "$RESOLVER" ]]; then
  echo "SKIP: talisman-resolve.sh not found or not executable at $RESOLVER" >&2
  exit 2
fi

# Create isolated temp project so we don't clobber the real talisman
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rune-canary-optout-XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "${WORKDIR}/.rune"
cat > "${WORKDIR}/.rune/talisman.yml" <<'YAML'
# Synthetic opt-out talisman for AC-10 regression test
arc:
  state_file:
    code_enforced_writes: false
YAML

# Run resolver inside the synthetic project
# RUNE_STATE is resolved from env by talisman-resolve.sh via
# `PROJECT_TALISMAN="${CWD}/${RUNE_STATE}/talisman.yml"`.
# The env var is normally set by the SessionStart hook but is absent in a
# synthetic subshell, so the resolver would look for a bad path. Export it
# here to match the convention used by real Rune sessions.
export RUNE_STATE=".rune"

cd "$WORKDIR"
# </dev/null is required: the resolver reads up to 1MB of optional hook-input
# JSON from stdin. Without this redirect, `head -c 1048576` blocks or reads
# inherited-terminal data, causing the resolver to never produce output shards.
"$RESOLVER" </dev/null >/dev/null 2>&1 || {
  echo "FAIL: talisman-resolve.sh exited non-zero in synthetic project" >&2
  exit 1
}

# Verify the resolved shard shows the opt-out value
ARC_SHARD="${WORKDIR}/tmp/.talisman-resolved/arc.json"
if [[ ! -f "$ARC_SHARD" ]]; then
  echo "FAIL: arc.json shard not produced at $ARC_SHARD" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available — cannot inspect resolved shard" >&2
  exit 2
fi

# jq's `//` operator treats boolean `false` as a "missing" alternative trigger,
# which would turn a correctly-preserved opt-out into a false failure. Use an
# explicit null-check instead so `false` is carried through unchanged.
RESOLVED=$(jq -r 'if .state_file.code_enforced_writes == null then "missing" else (.state_file.code_enforced_writes | tostring) end' "$ARC_SHARD")
if [[ "$RESOLVED" != "false" ]]; then
  echo "FAIL: opt-out not preserved — resolved value is \"$RESOLVED\", expected \"false\"" >&2
  exit 1
fi

echo "PASS: opt-out preserved — user talisman with code_enforced_writes=false resolves to false"
exit 0
