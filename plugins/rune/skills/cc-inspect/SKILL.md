---
name: cc-inspect
description: |
  Claude Code runtime environment inspector. Comprehensive diagnostic tool
  that reports all Claude Code environment variables, session identity,
  config directory, plugin paths, system toolchain versions, Rune runtime
  state, and platform details.
  Use when debugging environment issues, verifying session isolation,
  checking config directory resolution, or diagnosing plugin loading.
  Trigger keywords: cc inspect, claude code inspect, env check,
  environment, session id, config dir, diagnostic, runtime info,
  plugin env, plugin root, system info, toolchain.
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash, Read, Glob
argument-hint: "[--json] [--section <name>]"
---

# Claude Code Runtime Inspector

Comprehensive diagnostic view of the Claude Code runtime environment,
session identity, plugin state, and system toolchain.

## Instructions

Run the diagnostic script:

```bash
bash "${RUNE_PLUGIN_ROOT}/scripts/cc-inspect.sh"
```

Fallback (outside plugin context):

```bash
bash plugins/rune/scripts/cc-inspect.sh
```

### Section Filter

If the user passes `--section <name>`, only show that section. Valid names:
`env`, `session`, `system`, `plugin`, `runtime`, `echoes`, `all` (default).

### JSON Output Mode

If the user passes `--json`, present findings as structured key-value data.

### Environment Variable Reference

#### Claude Code Core

| Variable | Description |
|----------|-------------|
| `CLAUDE_CONFIG_DIR` | Config directory override (default: `~/.claude`) |
| `CLAUDE_SESSION_ID` | Current session UUID — used for session isolation |
| `CLAUDE_PROJECT_DIR` | Project root directory |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Agent Teams feature flag (`1` = enabled) |

#### Plugin System

| Variable | Description |
|----------|-------------|
| `CLAUDE_PLUGIN_ROOT` | Absolute path to the active plugin directory (hook context only) |
| `RUNE_PLUGIN_ROOT` | Bridged plugin root path (available in Bash() tool calls via CLAUDE_ENV_FILE) |
| `CLAUDE_PLUGIN_DATA` | Plugin-scoped persistent data directory |

#### Rune-Specific

| Variable | Description |
|----------|-------------|
| `RUNE_SESSION_ID` | Rune workflow session ID (injected by SessionStart hook) |
| `RUNE_TRACE` | Trace logging toggle (`1` = enabled) |
| `RUNE_TRACE_LOG` | Trace log file path |
| `RUNE_CLEANUP_DRY_RUN` | Dry-run mode for cleanup hooks (`1` = log only) |

#### Process & System

| Variable | Description |
|----------|-------------|
| `PPID` | Parent process ID (Claude Code PID — used for session isolation) |
| `HOME` | User home directory |
| `USER` | Current user name |
| `SHELL` | User's default shell |
| `TMPDIR` | Temporary directory (macOS sets this per-session) |
| `PATH` | Executable search path (truncated for readability) |

### What to Report

1. **Session Identity** — Session ID, PID, config dir, resolved CHOME
2. **Claude Code Env** — All `CLAUDE_*` variables with set/unset status
3. **Rune Env** — All `RUNE_*` variables
4. **Plugin System** — Plugin root, data dir, cache, component counts
5. **System Toolchain** — Shell, Node.js, Python, jq, git, gh versions
6. **Platform** — OS, architecture, kernel version
7. **Runtime State** — Active state files, talisman shards, signals
8. **Echoes** — Persistent memory entry counts per role

### Troubleshooting

- `CLAUDE_PLUGIN_ROOT` / `CLAUDE_PLUGIN_DATA` not set: running outside plugin context (hook context)
- `RUNE_PLUGIN_ROOT` not set: SessionStart hook failed to inject (check CLAUDE_ENV_FILE)
- `CLAUDE_CONFIG_DIR` not set: using default `~/.claude` (single-account setup)
- `CLAUDE_SESSION_ID` not set: older Claude Code version or non-interactive context
- `PPID` mismatch between skill and hook: expected — hooks run via hook runner subprocess
