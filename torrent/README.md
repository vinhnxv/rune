# Torrent — Tmux Arc Orchestrator

A standalone Rust TUI tool that manages `rune:arc` execution across multiple Claude Code
sessions using tmux. Runs plans **sequentially**, each in a **fresh tmux session** with
an independent Claude Code instance.

## Why

The existing `/rune:arc-batch` runs arcs sequentially within a single Claude Code session.
Torrent improves on this by:

- **Multi-config support** — use different `CLAUDE_CONFIG_DIR` accounts
- **tmux isolation** — each arc gets its own Claude Code instance with clean context
- **Independent monitoring** — observe arc progress via checkpoint/heartbeat files
- **Crash resilience** — tmux sessions survive if torrent exits

Torrent complements `arc-batch` (which handles smart-sort and dependency ordering).
Use torrent when you need config-dir rotation or tmux-based process isolation.

## Prerequisites

- **tmux** — `brew install tmux` (macOS) or `apt install tmux` (Linux)
- **Claude Code** — must be on `$PATH`

## Installation

### Quick Install (curl)

```bash
# Install to ~/.local/bin (recommended)
curl -fsSL https://raw.githubusercontent.com/vinhnxv/rune/main/torrent/install.sh | bash

# Or install system-wide (may require sudo)
curl -fsSL https://raw.githubusercontent.com/vinhnxv/rune/main/torrent/install.sh | bash -s -- --system
```

**Platform support:**
| Platform | Pre-built binary | Fallback |
|----------|------------------|----------|
| macOS (Apple Silicon) | ✅ `torrent-arm64-apple-darwin.tar.gz` | — |
| macOS (Intel) | ✅ `torrent-x86_64-apple-darwin.tar.gz` | — |
| Linux (x86_64) | ❌ | Build from source (requires Rust) |
| Linux (ARM64) | ❌ | Build from source (requires Rust) |

After installation, ensure `~/.local/bin` is in your PATH:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Build from Source

Requires [Rust](https://rustup.rs/):

```bash
cd torrent/
cargo build --release
```

Binary at `torrent/target/release/torrent`.

### Using Make (from repo root)

```bash
# Build release binary
make build

# Build debug binary (fast compile)
make dev

# Install to /usr/local/bin (may need sudo)
make install

# Install to ~/.local/bin (no sudo)
make install-local

# Create release tarballs
make dist

# Uninstall
make uninstall

# See all targets
make help
```

## Usage

```bash
# Run from the project root (where plans/ directory lives)
cd /path/to/project
./torrent/target/release/torrent

# With per-phase timeouts (minutes)
./torrent/target/release/torrent -t forge:120 -t work:90
```

### Selection View

1. **Left panel** — choose a Claude config directory (`~/.claude`, `~/.claude-work`, etc.)
2. **Right panel** — toggle plans to run (selection order = execution order)
3. Press `r` to start sequential execution

### Running View

Torrent launches each plan in a fresh tmux session, monitors arc progress via
checkpoint and heartbeat JSON files, and automatically advances to the next plan
when an arc completes (merge phase done + adaptive grace period of 10-120s).

The current phase displays elapsed time alongside its timeout limit with a color-coded
indicator (green < 50%, yellow 50-80%, red > 80%). When a phase times out, a red
warning banner appears in the heartbeat panel.

## Keybindings

### Selection View

| Key       | Action                            |
|-----------|-----------------------------------|
| `↑` / `↓` | Navigate within panel            |
| `Tab`     | Switch between config/plan panels |
| `Enter`   | Select config directory           |
| `Space`   | Toggle plan (ordered selection)   |
| `a`       | Toggle all plans                  |
| `r`       | Run selected plans sequentially   |
| `q`       | Quit                              |

### Running View

| Key | Action                                              |
|-----|-----------------------------------------------------|
| `a` | Attach to tmux session (Ctrl-B D to detach back)    |
| `s` | Skip current plan (or skip grace period if active)   |
| `k` | Kill tmux session, stop all execution               |
| `q` | Quit TUI (tmux session continues in background)     |

## Architecture

```
torrent (TUI)
├── main.rs         — entry point, CLI arg parsing, event loop
├── scanner.rs      — discovers ~/.claude* dirs and plans/*.md files
├── app.rs          — application state, selection logic, quit summary
├── ui.rs           — ratatui rendering (selection + running views)
├── keybindings.rs  — input handling per view
├── tmux.rs         — tmux session lifecycle (create, send-keys, kill)
├── monitor.rs      — arc discovery + heartbeat/checkpoint polling
├── checkpoint.rs   — serde structs for checkpoint.json + heartbeat.json
├── callback.rs     — HTTP callback server for receiving push events from bridge
├── channel.rs      — channel health state machine (auto-disable, stale detection)
├── lock.rs         — CWD-based instance lock (prevents concurrent torrent)
├── log.rs          — Structured JSONL run logging (append-only)
├── resume.rs       — Auto-resume state: retry strategies, backoff, state persistence
├── resource.rs     — process resource monitoring via sysinfo (CPU/memory)
└── recovery.rs     — tmux session recovery (output hash-based idle detection)

bridge/
└── server.ts       — MCP server that forwards arc events from Claude Code to callback
```

### Data Flow

1. **Scan** — discover config dirs and plan files at startup
2. **Select** — user picks a config dir and orders plans
3. **Launch** — create tmux session, send `/arc <plan>` command
4. **Discover** — poll for matching checkpoint.json (up to 3 min)
5. **Monitor** — watch heartbeat.json for liveness, checkpoint.json for phase progress
6. **Complete** — detect merge completion, wait grace period, kill tmux, start next plan

---

## CLI Tool: torrent-cli

In addition to the TUI, torrent includes a CLI tool for direct tmux session management:

```bash
# Build the CLI
cargo build --release --bin torrent-cli

# Create a new tmux session with Claude Code
./target/release/torrent-cli new-session --config-dir ~/.claude-work

# Send keys with the Ink autocomplete workaround
./target/release/torrent-cli send-keys --session rune-abc123 --text "/arc plans/my-plan.md"

# Capture pane output for debugging
./target/release/torrent-cli capture-pane --session rune-abc123 --lines 30

# List all torrent/rune sessions
./target/release/torrent-cli list

# Kill a session
./target/release/torrent-cli kill --session rune-abc123

# Full flow: create session, wait for Claude, send /arc
./target/release/torrent-cli run --config-dir ~/.claude --plan plans/my-plan.md --wait 15
```

---

## Configuration

### Grace Period

After merge detection, torrent waits an adaptive grace period before starting the next plan. The duration is computed from runtime metrics:

```
grace = base + (child_count × 2) + (cpu_percent × 0.5)
grace = clamp(grace, min, max)
```

**Defaults**: base=30s, min=10s, max=120s. A visible countdown with progress bar is shown during the grace period. Press `s` to skip (minimum 5s remaining).

**Environment variables**:

```bash
# Adjust adaptive grace formula parameters
TORRENT_GRACE_BASE=30   # Base duration in seconds (default: 30)
TORRENT_GRACE_MIN=10    # Minimum grace period (default: 10)
TORRENT_GRACE_MAX=120   # Maximum grace period (default: 120)
```

**Migration from `GRACE_PERIOD_SECS`**: The old `GRACE_PERIOD_SECS` variable is still respected as a backward-compatible fallback. If set and no `TORRENT_GRACE_*` variables are configured, the fixed duration is used. To migrate, replace `GRACE_PERIOD_SECS=120` with `TORRENT_GRACE_MAX=120`.

### Phase Timeouts

Each arc phase has a timeout (default: 60 minutes). When a phase exceeds its limit, torrent sends SIGTERM to the Claude Code process, waits 15 seconds, then hard-kills the tmux session and marks the run as failed.

**Environment variables** (values in minutes):

| Variable | Phase category | Default |
|----------|---------------|---------|
| `TORRENT_TIMEOUT_DEFAULT` | All phases (global default) | 60 |
| `TORRENT_TIMEOUT_FORGE` | forge | 60 |
| `TORRENT_TIMEOUT_WORK` | work, task_decomposition, design_* | 60 |
| `TORRENT_TIMEOUT_TEST` | test, test_coverage_critique | 60 |
| `TORRENT_TIMEOUT_REVIEW` | code_review, plan_review, etc. | 60 |
| `TORRENT_TIMEOUT_SHIP` | ship, merge, pre_ship_validation, etc. | 60 |
| `TORRENT_LOG_DIR` | Override log directory (default: `.torrent/logs/`) | — |
| `TORRENT_MAX_RESUMES` | Max retries per plan per phase before skipping | 3 |
| `TORRENT_RESTART_COOLDOWN` | Seconds between automatic restarts | 30 |
| `TORRENT_CHANNELS_ENABLED` | Enable channels bridge (`1` or `true`) | `false` |
| `TORRENT_CALLBACK_PORT` | Callback server port (1–65534) | 9900 |

```bash
# 120-minute forge timeout, 30-minute ship timeout
TORRENT_TIMEOUT_FORGE=120 TORRENT_TIMEOUT_SHIP=30 torrent
```

**CLI flag** (`--phase-timeout` / `-t`) overrides env vars:

```bash
torrent -t forge:120 -t work:90 -t ship:30
```

---

## Channels Bridge (Experimental)

The channels bridge provides a **real-time push communication channel** from Claude Code back to Torrent. Instead of relying solely on file-based polling (checkpoint.json + heartbeat.json), the bridge sends structured events over HTTP as they happen — giving Torrent instant phase updates, heartbeats, and arc completion signals.

> **Note:** Channels are **outbound-only** (Claude → Torrent) in v0.7.0. Inbound communication (Torrent → Claude) still uses tmux send-keys.

### Enabling Channels

Channels are **opt-in** (disabled by default). Enable via CLI flag or environment variable:

```bash
# CLI flag (recommended)
torrent --channels

# Environment variable
TORRENT_CHANNELS_ENABLED=1 torrent

# Explicitly disable (overrides env var)
torrent --no-channels
```

**Precedence:** CLI flag (`--channels` / `--no-channels`) > `TORRENT_CHANNELS_ENABLED` env var > default (`false`).

### How It Works

When channels are enabled, Torrent starts two additional services:

1. **Callback Server** — an HTTP server on `127.0.0.1:<port>` (default: 9900) that receives push events from the bridge
2. **Bridge MCP Server** — a Node.js MCP server (`torrent/bridge/server.ts`) injected into the Claude Code session that forwards arc events to the callback server

```
Claude Code (arc phases)
    │
    ▼
torrent-bridge (MCP server, port callback+1)
    │  POST /event  {"type":"phase", "session_id":"...", ...}
    ▼
Callback Server (port 9900)
    │  mpsc channel
    ▼
Torrent TUI (instant phase updates)
```

### Event Types

| Event | Trigger | Fields |
|-------|---------|--------|
| `phase` | Phase starts/completes | `session_id`, `phase`, `status`, `details` |
| `complete` | Arc finishes | `session_id`, `result`, `pr_url`, `error` |
| `heartbeat` | Periodic liveness | `session_id`, `activity`, `current_tool` |

### Configuring the Callback Port

The callback server defaults to port **9900**. The bridge server runs on `port + 1` (9901).

```bash
# CLI flag
torrent --channels --callback-port 8800

# Environment variable
TORRENT_CALLBACK_PORT=8800 torrent --channels
```

**Precedence:** CLI flag > `TORRENT_CALLBACK_PORT` env var > default (9900).

**Port range:** 1–65534 (port+1 must fit in u16). Port 65535 is rejected by the CLI.

### Channel Health

Torrent monitors channel health automatically:

- **Health check:** Probes the bridge server every 2 seconds
- **Auto-disable:** After 3 consecutive failures, channels are disabled for that session — Torrent falls back to file-based monitoring
- **Stale detection:** Channels with no events for 5 minutes are marked stale (shown as red indicator in TUI)
- **Session validation:** Events from foreign/stale sessions are silently dropped

### Fallback Behavior

When channels are disabled, unhealthy, or fail:

- Torrent operates in **file-only monitoring mode** — the same behavior as without channels
- Phase progress comes from `checkpoint.json` polling
- Liveness comes from `heartbeat.json` timestamps
- No functionality is lost; channels only add speed

### Security

- The callback server binds to `127.0.0.1` only — no external network access
- The bridge validates `TORRENT_CALLBACK_URL` must use `http:` protocol and point to `localhost`/`127.0.0.1`
- Events are validated: per-field length limits, session_id matching, and JSON schema checks
- Events received before a session is established (init window) are dropped

---

## Troubleshooting

### "git checkout main failed — clean up working tree"

**Cause:** Uncommitted changes or unmerged files in the working tree.

**Solution:**
```bash
# Check status
git status

# Stash or discard changes
git stash
# or
git checkout -- .

# Remove untracked files if needed
git clean -fd
```

### "tmux failed: session already exists"

**Cause:** A previous torrent session wasn't cleaned up.

**Solution:**
```bash
# List sessions
tmux list-sessions

# Kill the orphan session
tmux kill-session -t rune-XXXXXX

# Or use torrent-cli
./target/release/torrent-cli kill --session rune-XXXXXX
```

### "Claude Code is ready" but /arc didn't execute

**Cause:** The Ink autocomplete workaround may need adjustment on your system.

**Solution:**
1. Attach to the tmux session: `tmux attach -t rune-XXXXXX`
2. Check if Claude Code is showing an error
3. Manually type `/arc plans/your-plan.md` and press Enter
4. The Escape+delay+Enter workaround may need tuning for slower systems

### Checkpoint discovery takes too long (>3 min)

**Cause:** Multiple arcs running concurrently, or the plan file path doesn't match.

**Solution:**
1. Check `.rune/arc/` for existing arc directories
2. Verify the plan file name matches exactly (case-sensitive)
3. Ensure `CLAUDE_CONFIG_DIR` is set correctly for non-default accounts

### Heartbeat shows "stale" (red indicator)

**Cause:** No activity for >5 minutes. The arc may be stuck or waiting for user input.

**Solution:**
1. Attach to the session: `tmux attach -t rune-XXXXXX`
2. Check for permission prompts or other blocking dialogs
3. Use `[k]` to kill and restart if necessary

---

## Security Notes

- **`--dangerously-skip-permissions`:** Torrent launches Claude Code with this flag to enable non-interactive execution. This bypasses all permission prompts. Only use torrent in trusted environments.
- **Session ID validation:** All tmux session names are validated to contain only alphanumeric characters, hyphens, and underscores to prevent command injection.
- **Shell escaping:** All paths sent to tmux are shell-escaped to prevent command injection via special characters.

---

## Run Logs

Torrent writes structured run logs in JSONL format (one JSON object per line) to `.torrent/logs/runs.jsonl`. Each plan execution produces a per-plan entry, and a batch summary is appended when all plans finish.

Auto-resume state is persisted at `.torrent/state/{plan-hash}.json` — one file per plan, keyed by a hash of the plan path. These files track retry counts and backoff state across torrent restarts.

### Log Location

By default, logs are written to `.torrent/logs/` in the current working directory. Override with:

```bash
TORRENT_LOG_DIR=/tmp/torrent-logs torrent
```

### Log Format

Each line is a self-contained JSON object. Per-plan entries include:

```json
{
  "timestamp": "2026-03-19T10:30:00Z",
  "event": "plan_complete",
  "plan": "plans/add-logging.md",
  "status": "success",
  "urgency": "green",
  "restarts": 0,
  "duration_secs": 1842,
  "config_dir": "~/.claude",
  "session": "rune-a1b2c3"
}
```

### Urgency Tiers

| Tier | Meaning |
|------|---------|
| `green` | Completed normally, well within timeout |
| `yellow` | Completed but took >50% of timeout budget |
| `orange` | Completed with restarts or near timeout |
| `red` | Failed, timed out, or killed |

### Batch Summary

When all plans in a run finish, a summary entry is appended:

```json
{
  "timestamp": "2026-03-19T12:00:00Z",
  "event": "batch_summary",
  "total": 5,
  "succeeded": 4,
  "failed": 1,
  "total_duration_secs": 9200
}
```

### Parsing Logs

```bash
# Pretty-print all entries
jq . .torrent/logs/runs.jsonl

# Show only failures
jq 'select(.status == "failed")' .torrent/logs/runs.jsonl

# Show batch summaries
jq 'select(.event == "batch_summary")' .torrent/logs/runs.jsonl
```

### Log Rotation

Logs rotate automatically when `runs.jsonl` exceeds **10 MB**. Rotated files are named `runs.jsonl.1`, `runs.jsonl.2`, etc., up to a maximum of **5 archived files**. The oldest archive is deleted when the limit is reached.
