//! torrent-cli — CLI for tmux session management (no TUI)
//!
//! Usage:
//!   torrent-cli new-session --config-dir ~/.claude-true
//!   torrent-cli send-keys --session <id> --text "/arc plans/foo.md"
//!   torrent-cli capture-pane --session <id>
//!   torrent-cli list
//!   torrent-cli kill --session <id>

use std::process::Command;
use std::thread;
use std::time::Duration;

/// Shell-escape a string by wrapping in single quotes.
/// Internal single quotes are replaced with `'\''` (end-quote, escaped-quote, start-quote).
/// SEC-002 FIX: prevents command injection when values are sent to a shell via tmux send-keys.
fn shell_escape(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Validate session ID: ASCII alphanumeric + hyphens + underscores, max 64 chars.
/// Mirrors tmux.rs validate_session_id() — prevents tmux target injection.
fn validate_session_id(id: &str) {
    if id.is_empty()
        || id.len() > 64
        || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        eprintln!("error: invalid session ID '{}' — must be ASCII alphanumeric + hyphens/underscores, max 64 chars", id);
        std::process::exit(1);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        print_usage();
        std::process::exit(1);
    }

    match args[1].as_str() {
        "new-session" => { cmd_new_session(&args[2..]); },
        "send-keys" => cmd_send_keys(&args[2..]),
        "capture-pane" | "capture" => cmd_capture_pane(&args[2..]),
        "list" | "ls" => cmd_list(),
        "kill" => cmd_kill(&args[2..]),
        "run" => cmd_run(&args[2..]),
        _ => { print_usage(); std::process::exit(1); }
    }
}

fn print_usage() {
    eprintln!("torrent-cli — tmux session manager for Claude Code\n");
    eprintln!("Commands:");
    eprintln!("  new-session --config-dir <path>          Create tmux session + start Claude");
    eprintln!("  send-keys --session <id> --text <text>   Send keys with Escape workaround");
    eprintln!("  capture-pane --session <id>              Capture pane output");
    eprintln!("  list                                     List torrent sessions");
    eprintln!("  kill --session <id>                      Kill session");
    eprintln!("  run --config-dir <path> --plan <path>    Full flow: new + wait + send /arc");
}

fn get_arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

fn resolve_claude() -> String {
    let o = Command::new("which").arg("claude").output().unwrap_or_else(|e| {
        eprintln!("error: failed to run 'which claude': {}", e);
        std::process::exit(1);
    });
    let path = String::from_utf8_lossy(&o.stdout).trim().to_string();
    if path.is_empty() { eprintln!("claude not found in PATH"); std::process::exit(1); }
    path
}

fn gen_session_id() -> String {
    format!("torrent-{}", std::process::id())
}

// ── new-session ─────────────────────────────────────────────

fn cmd_new_session(args: &[String]) -> String {
    let config_dir = get_arg(args, "--config-dir").unwrap_or_else(|| {
        eprintln!("--config-dir required"); std::process::exit(1);
    });
    let claude = resolve_claude();
    let session_id = get_arg(args, "--session").unwrap_or_else(gen_session_id);

    let home = dirs::home_dir().expect("no home");
    let config_path = if config_dir.starts_with('/') {
        config_dir.clone()
    } else if config_dir.starts_with('~') {
        config_dir.replacen('~', &home.to_string_lossy(), 1)
    } else {
        home.join(&config_dir).to_string_lossy().to_string()
    };

    let is_default = config_dir == ".claude" || config_dir == "~/.claude";

    println!("Creating session: {}", session_id);
    println!("Config: {} (default={})", config_path, is_default);
    println!("Claude: {}", claude);

    // Create session
    let o = Command::new("tmux")
        .args(["new-session", "-d", "-s", &session_id, "-x", "200", "-y", "50"])
        .output().unwrap_or_else(|e| {
            eprintln!("error: failed to start tmux: {}", e);
            std::process::exit(1);
        });
    if !o.status.success() {
        eprintln!("tmux new-session failed: {}", String::from_utf8_lossy(&o.stderr));
        std::process::exit(1);
    }

    // Start claude (SEC-002: shell-escape both paths to prevent injection via tmux send-keys)
    let cmd = if is_default {
        format!("{} --dangerously-skip-permissions", shell_escape(&claude))
    } else {
        format!("CLAUDE_CONFIG_DIR={} {} --dangerously-skip-permissions",
            shell_escape(&config_path), shell_escape(&claude))
    };

    Command::new("tmux")
        .args(["send-keys", "-t", &session_id, "-l", &cmd])
        .output().unwrap_or_else(|e| {
            eprintln!("error: tmux send-keys failed: {}", e);
            std::process::exit(1);
        });
    Command::new("tmux")
        .args(["send-keys", "-t", &session_id, "Enter"])
        .output().unwrap_or_else(|e| {
            eprintln!("error: tmux send Enter failed: {}", e);
            std::process::exit(1);
        });

    println!("✓ Session created: {}", session_id);
    println!("  Attach: tmux attach -t {}", session_id);
    session_id
}

// ── send-keys ───────────────────────────────────────────────

fn cmd_send_keys(args: &[String]) {
    let session = get_arg(args, "--session").unwrap_or_else(|| {
        // Auto-detect: find first torrent-* session
        auto_detect_session()
    });
    validate_session_id(&session);
    let text = get_arg(args, "--text").unwrap_or_else(|| {
        eprintln!("--text required"); std::process::exit(1);
    });

    println!("Sending to {}: {}", session, text);

    // Escape+delay+Enter workaround for Claude Code Ink TUI
    // Step 1: text literally
    let o = Command::new("tmux")
        .args(["send-keys", "-t", &session, "-l", &text])
        .output().unwrap_or_else(|e| {
            eprintln!("error: tmux send-keys failed: {}", e);
            std::process::exit(1);
        });
    if !o.status.success() {
        eprintln!("send-keys failed: {}", String::from_utf8_lossy(&o.stderr));
        std::process::exit(1);
    }
    println!("  text sent ✓");

    // Step 2: wait 300ms
    thread::sleep(Duration::from_millis(300));

    // Step 3: Escape
    Command::new("tmux")
        .args(["send-keys", "-t", &session, "Escape"])
        .output().unwrap_or_else(|e| {
            eprintln!("error: tmux send Escape failed: {}", e);
            std::process::exit(1);
        });
    println!("  escape ✓");

    // Step 4: wait 100ms
    thread::sleep(Duration::from_millis(100));

    // Step 5: Enter
    Command::new("tmux")
        .args(["send-keys", "-t", &session, "Enter"])
        .output().unwrap_or_else(|e| {
            eprintln!("error: tmux send Enter failed: {}", e);
            std::process::exit(1);
        });
    println!("  enter ✓");

    println!("✓ Keys sent");
}

// ── capture-pane ────────────────────────────────────────────

fn cmd_capture_pane(args: &[String]) {
    let session = get_arg(args, "--session").unwrap_or_else(auto_detect_session);
    validate_session_id(&session);
    let lines = get_arg(args, "--lines").unwrap_or_else(|| "30".into());

    let o = Command::new("tmux")
        .args(["capture-pane", "-t", &session, "-p", "-S", &format!("-{}", lines)])
        .output().unwrap_or_else(|e| {
            eprintln!("error: tmux capture-pane failed: {}", e);
            std::process::exit(1);
        });

    print!("{}", String::from_utf8_lossy(&o.stdout));
}

// ── list ────────────────────────────────────────────────────

fn cmd_list() {
    let o = Command::new("tmux")
        .args(["list-sessions", "-F", "#{session_name} #{session_created} #{session_windows}w"])
        .output();

    match o {
        Ok(o) if o.status.success() => {
            let out = String::from_utf8_lossy(&o.stdout);
            let sessions: Vec<&str> = out.lines()
                .filter(|l| l.starts_with("torrent-") || l.starts_with("rune-"))
                .collect();
            if sessions.is_empty() {
                println!("No torrent/rune sessions found");
            } else {
                for s in sessions { println!("  {}", s); }
            }
        }
        _ => println!("No tmux server running"),
    }
}

// ── kill ────────────────────────────────────────────────────

fn cmd_kill(args: &[String]) {
    let session = get_arg(args, "--session").unwrap_or_else(auto_detect_session);
    validate_session_id(&session);
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", &session])
        .output();
    println!("✓ Killed: {}", session);
}

// ── run (full flow) ─────────────────────────────────────────

fn cmd_run(args: &[String]) {
    let config_dir = get_arg(args, "--config-dir").unwrap_or_else(|| ".claude".into());
    let plan = get_arg(args, "--plan").unwrap_or_else(|| {
        eprintln!("--plan required"); std::process::exit(1);
    });
    let wait_secs: u64 = get_arg(args, "--wait").and_then(|s| s.parse().ok()).unwrap_or(15);

    // Step 1: Create session
    let new_args: Vec<String> = vec!["--config-dir".into(), config_dir];
    let session_id = cmd_new_session(&new_args);

    // Step 2: Wait for Claude
    println!("\nWaiting {}s for Claude Code...", wait_secs);
    for i in 1..=wait_secs {
        thread::sleep(Duration::from_secs(1));
        if i % 5 == 0 { println!("  {}s", i); }
    }

    // Step 3: Capture to verify
    println!("\nCapturing pane to verify Claude is ready...");
    let o = Command::new("tmux")
        .args(["capture-pane", "-t", &session_id, "-p", "-S", "-5"])
        .output().unwrap_or_else(|e| {
            eprintln!("error: tmux capture-pane failed: {}", e);
            std::process::exit(1);
        });
    let pane = String::from_utf8_lossy(&o.stdout);
    let ready = pane.contains("❯") || pane.contains("bypass permissions");
    if ready {
        println!("  ✓ Claude Code is ready");
    } else {
        println!("  ⚠ Claude may not be ready. Pane tail:");
        for l in pane.lines().filter(|l| !l.trim().is_empty()).rev().take(3).collect::<Vec<_>>().into_iter().rev() {
            println!("    | {}", l);
        }
    }

    // Step 4: Send /arc
    let arc_text = format!("/arc {}", plan);
    cmd_send_keys(&["--session".into(), session_id.clone(), "--text".into(), arc_text]);

    // Step 5: Verify
    thread::sleep(Duration::from_secs(3));
    println!("\nFinal capture:");
    cmd_capture_pane(&["--session".into(), session_id.clone(), "--lines".into(), "10".into()]);

    println!("\nAttach: tmux attach -t {}", session_id);
}

fn auto_detect_session() -> String {
    let o = Command::new("tmux")
        .args(["list-sessions", "-F", "#{session_name}"])
        .output().ok();
    let out = o.map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
    out.lines()
        .find(|l| l.starts_with("torrent-") || l.starts_with("rune-"))
        .map(|s| s.to_string())
        .unwrap_or_else(|| { eprintln!("No session found. Use --session <id>"); std::process::exit(1); })
}
