#!/bin/bash
# tests/bats/test_helper.bash — Shared fixtures for BATS tests

PLUGIN_DIR="${BATS_TEST_DIRNAME}/../../plugins/rune"
SCRIPTS_DIR="${PLUGIN_DIR}/scripts"

# Check jq availability
has_jq() {
  command -v jq &>/dev/null
}

# Run a hook script with JSON piped to stdin
run_hook() {
  local script="$1"
  shift
  echo "$@" | bash "$script"
}

# Create a temporary directory with project structure
setup_project_dir() {
  export TEST_CWD=$(mktemp -d -t rune-test-XXXXXX)
  mkdir -p "$TEST_CWD/tmp"
  mkdir -p "$TEST_CWD/.claude"
  mkdir -p "$TEST_CWD/.rune/arc"
}

# Create a temporary CLAUDE_CONFIG_DIR
setup_config_dir() {
  export TEST_CONFIG_DIR=$(mktemp -d -t rune-config-XXXXXX)
  mkdir -p "$TEST_CONFIG_DIR/teams"
  mkdir -p "$TEST_CONFIG_DIR/tasks"
  export CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR"
}

# Cleanup temp dirs
teardown_dirs() {
  [[ -d "${TEST_CWD:-}" ]] && rm -rf "$TEST_CWD"
  [[ -d "${TEST_CONFIG_DIR:-}" ]] && rm -rf "$TEST_CONFIG_DIR"
  unset CLAUDE_CONFIG_DIR
}

# Create a mock state file with session ownership
create_state_file() {
  local path="$1"
  local team_name="$2"
  local status="${3:-active}"
  cat > "$path" << EOF
{
  "team_name": "$team_name",
  "status": "$status",
  "config_dir": "$TEST_CONFIG_DIR",
  "owner_pid": "$$"
}
EOF
}

# Build a minimal PreToolUse JSON input
build_pretooluse_json() {
  local tool_name="$1"
  local command="${2:-}"
  local file_path="${3:-}"
  if [[ -n "$command" ]]; then
    printf '{"tool_name":"%s","tool_input":{"command":"%s"},"cwd":"%s"}' "$tool_name" "$command" "$TEST_CWD"
  elif [[ -n "$file_path" ]]; then
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$tool_name" "$file_path" "$TEST_CWD"
  else
    printf '{"tool_name":"%s","tool_input":{},"cwd":"%s"}' "$tool_name" "$TEST_CWD"
  fi
}
