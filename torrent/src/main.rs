#[macro_use]
mod console;
mod app;
mod callback;
mod channel;
mod checkpoint;
mod diagnostic;
mod keybindings;
mod lock;
mod log;
mod monitor;
#[allow(dead_code)]
mod recovery;
mod resource;
mod resume;
mod scanner;
mod tmux;
mod ui;

use std::path::PathBuf;
use std::time::Duration;

use color_eyre::Result;
use crossterm::event::{self, Event};

use crate::app::{App, AppView};
use crate::tmux::Tmux;

const VERSION: &str = env!("CARGO_PKG_VERSION");

use crate::callback::DEFAULT_CALLBACK_PORT;

/// Parsed CLI arguments.
struct CliArgs {
    extra_config_dirs: Vec<PathBuf>,
    timeout_overrides: Vec<(String, u64)>, // (PHASE, minutes)
    /// Enable channels bridge communication (opt-in, default false).
    /// Precedence: CLI --channels > env TORRENT_CHANNELS_ENABLED > default (false).
    channels_enabled: bool,
    /// Port for the callback HTTP server (default 9900).
    /// Precedence: CLI --callback-port > env TORRENT_CALLBACK_PORT > default.
    callback_port: u16,
}

/// Parse CLI arguments for extra config directories and timeout overrides.
///
/// Supports:
///   --config-dir <path>         (long form)
///   -c <path>                   (short form)
///   --phase-timeout PHASE:MIN   (per-phase timeout override)
///   -t PHASE:MIN                (short form)
///   --version / -V              (show version)
///   --help / -h                 (show help)
///
/// Multiple values allowed.
fn parse_args() -> CliArgs {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut extra_dirs = Vec::new();
    let mut timeout_overrides = Vec::new();
    let mut channels_cli: Option<bool> = None;
    let mut callback_port_cli: Option<u16> = None;
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "--version" | "-V" => {
                println!("torrent {VERSION}");
                std::process::exit(0);
            }
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            "--config-dir" | "-c" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: {} requires a path argument", args[i - 1]);
                    std::process::exit(1);
                }
                extra_dirs.push(PathBuf::from(&args[i]));
            }
            "--phase-timeout" | "-t" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: {} requires a PHASE:MINUTES argument", args[i - 1]);
                    std::process::exit(1);
                }
                match parse_timeout_arg(&args[i]) {
                    Some(pair) => timeout_overrides.push(pair),
                    None => {
                        eprintln!(
                            "error: invalid timeout format '{}'. Expected PHASE:MINUTES (e.g. forge:120)",
                            args[i]
                        );
                        std::process::exit(1);
                    }
                }
            }
            "--channels" => {
                channels_cli = Some(true);
            }
            "--no-channels" => {
                channels_cli = Some(false);
            }
            "--callback-port" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --callback-port requires a PORT argument");
                    std::process::exit(1);
                }
                match args[i].parse::<u16>() {
                    Ok(port) if port > 0 && port <= 65534 => callback_port_cli = Some(port),
                    _ => {
                        eprintln!(
                            "error: invalid callback port '{}'. Expected a number 1-65534 (port+1 used for bridge).",
                            args[i]
                        );
                        std::process::exit(1);
                    }
                }
            }
            other => {
                eprintln!("error: unknown argument '{}'. Use --help for usage.", other);
                std::process::exit(1);
            }
        }
        i += 1;
    }

    // Resolve channels_enabled: CLI > env > default (false)
    let channels_enabled = channels_cli.unwrap_or_else(|| {
        std::env::var("TORRENT_CHANNELS_ENABLED")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
    });

    // Resolve callback_port: CLI > env > default (9900)
    let callback_port = callback_port_cli.unwrap_or_else(|| {
        std::env::var("TORRENT_CALLBACK_PORT")
            .ok()
            .and_then(|v| v.parse::<u16>().ok())
            .filter(|&p| p > 0 && p <= 65534)
            .unwrap_or(DEFAULT_CALLBACK_PORT)
    });

    CliArgs {
        extra_config_dirs: extra_dirs,
        timeout_overrides,
        channels_enabled,
        callback_port,
    }
}

/// Parse a "PHASE:MINUTES" string into (phase, minutes).
fn parse_timeout_arg(s: &str) -> Option<(String, u64)> {
    let (phase, mins_str) = s.split_once(':')?;
    if phase.is_empty() {
        return None;
    }
    let mins: u64 = mins_str.parse().ok()?;
    Some((phase.to_lowercase(), mins))
}

fn print_help() {
    println!("torrent {VERSION} — Arc Orchestrator TUI for Claude Code");
    println!();
    println!("USAGE:");
    println!("  torrent [OPTIONS]");
    println!();
    println!("OPTIONS:");
    println!("  -c, --config-dir <PATH>       Add a custom Claude config directory");
    println!("                                (can be specified multiple times)");
    println!("  -t, --phase-timeout PHASE:MIN Set per-phase timeout in minutes");
    println!("                                (overrides TORRENT_TIMEOUT_* env vars)");
    println!("                                Phases: forge, work, test, review, ship");
    println!("      --channels                Enable channels bridge (default: off)");
    println!("      --no-channels             Explicitly disable channels bridge");
    println!("      --callback-port <PORT>    Callback server port (default: 9900)");
    println!("  -V, --version                 Show version");
    println!("  -h, --help                    Show this help message");
    println!();
    println!("CONFIG DIR DISCOVERY:");
    println!("  torrent discovers Claude Code config directories from multiple sources,");
    println!("  in order of priority:");
    println!();
    println!("  1. ~/.claude/              default config (auto-discovered)");
    println!("  2. ~/.claude-*/            custom accounts (auto-discovered)");
    println!("  3. $CLAUDE_CONFIG_DIR      env var (auto-included if set)");
    println!("  4. --config-dir <PATH>     CLI argument (can repeat)");
    println!();
    println!("  Duplicates are deduplicated by canonical path. Invalid dirs (missing");
    println!("  settings.json and projects/) are silently skipped.");
    println!();
    println!("KEYBINDINGS:");
    println!();
    println!("  Active Arcs View (shown when running arcs are detected):");
    println!("    m / Enter    Monitor selected arc (resume polling)");
    println!("    a            Attach to tmux session");
    println!("    n / Esc      Dismiss and start new run");
    println!("    Up/Down      Navigate arcs");
    println!("    q            Quit");
    println!();
    println!("  Selection View (pick config + plans):");
    println!("    Tab          Switch between Config and Plans panels");
    println!("    Enter        Select config dir (Config panel)");
    println!("    Space        Toggle plan selection (Plans panel)");
    println!("    a            Toggle all plans");
    println!("    r            Run selected plans");
    println!("    Up/Down      Navigate list");
    println!("    q            Quit");
    println!();
    println!("  Running View (monitoring active arc execution):");
    println!("    a            Attach to tmux session (Ctrl-B D to detach)");
    println!("    s            Skip current plan (kill + advance queue)");
    println!("    k            Kill tmux session");
    println!("    p            Pick more plans to append to queue");
    println!("    d            Remove selected item from queue");
    println!("    Up/Down      Navigate queue");
    println!("    q            Quit");
    println!();
    println!("  Queue Edit Mode (adding plans while arc is running):");
    println!("    Tab          Switch panels");
    println!("    Space        Toggle plan / select config");
    println!("    r / Enter    Append selected plans to queue");
    println!("    Esc          Cancel and return to Running view");
    println!();
    println!("EXAMPLES:");
    println!("  torrent                              # auto-discover configs");
    println!("  torrent -c /opt/claude-ci             # add CI config dir");
    println!("  torrent -c ~/.claude-work -c ~/.claude-personal");
    println!("  torrent -t forge:120 -t work:90       # 120m forge, 90m work timeout");
    println!("  CLAUDE_CONFIG_DIR=~/.claude-work torrent");
    println!("  torrent --channels                     # enable channels bridge");
    println!("  torrent --channels --callback-port 9999");
    println!("  TORRENT_CHANNELS_ENABLED=1 torrent     # env var channels enable");
    println!("  TORRENT_TIMEOUT_FORGE=120 torrent      # env var timeout override");
    println!();
    println!("SEE ALSO:");
    println!("  torrent-cli  — non-TUI CLI for tmux session management");
    println!("               (new-session, send-keys, capture-pane, list, kill, run)");
}

fn main() -> Result<()> {
    // Parse CLI args before anything else (may exit on --help or error)
    let cli = parse_args();

    // Install panic/error hooks BEFORE ratatui::init() so panics restore terminal
    color_eyre::install()?;

    // Verify tmux is available before starting the TUI
    Tmux::verify_available()?;

    // Acquire CWD instance lock — prevents 2 torrents from conflicting
    // on git working tree and arc-phase-loop.local.md in the same directory.
    let cwd = std::env::current_dir()?;
    let _lock_guard = match lock::acquire(&cwd) {
        lock::LockResult::Acquired(guard) => guard,
        lock::LockResult::StaleRecovered(guard) => {
            eprintln!(
                "warning: cleaned up stale lock from dead torrent process"
            );
            guard
        }
        lock::LockResult::AlreadyRunning { pid, lock_path } => {
            eprintln!(
                "error: another torrent instance is already running in this directory (PID {})",
                pid
            );
            eprintln!("  lock: {}", lock_path.display());
            eprintln!();
            eprintln!("  Kill it first:  kill {}  (or kill -9 {})", pid, pid);
            eprintln!("  Or remove lock: rm {}", lock_path.display());
            std::process::exit(1);
        }
    };

    // Initialize terminal (raw mode + alternate screen)
    let mut terminal = ratatui::init();

    // Create application state (scans config dirs + plan files)
    let mut app = App::new(cli.extra_config_dirs)?;

    // Store channels configuration for session startup
    app.channels_enabled = cli.channels_enabled;
    app.callback_port = cli.callback_port;

    // Apply CLI timeout overrides (on top of env vars)
    if !cli.timeout_overrides.is_empty() {
        app.phase_timeout_config
            .apply_overrides(&cli.timeout_overrides);
    }

    // Main event loop — 1s tick rate
    let tick_rate = Duration::from_secs(1);

    while !app.should_quit {
        // Draw current state
        terminal.draw(|frame| ui::draw(frame, &mut app))?;

        // Poll for input events with tick timeout
        if event::poll(tick_rate)? {
            if let Event::Key(key) = event::read()? {
                let action = keybindings::handle_key(&app, key);
                app.handle_action(action)?;
            }
        }

        // Tick execution logic (discovery, polling, grace period, next plan)
        match app.view {
            AppView::Running => app.tick_execution()?,
            AppView::ActiveArcs => app.prune_stale_active_arcs(),
            _ => {}
        }
    }

    // Restore terminal (disable raw mode + leave alternate screen)
    ratatui::restore();

    // Write structured batch summary to JSONL log
    if let Err(e) = crate::log::write_batch_summary(&app.completed_runs) {
        eprintln!("warning: failed to write batch summary log: {}", e);
    }

    // Print summary to stdout
    app.print_quit_summary();

    // _lock_guard drops here — releases .torrent.lock

    Ok(())
}
