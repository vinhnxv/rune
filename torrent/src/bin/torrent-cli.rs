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

// ureq is in Cargo.toml dependencies — shared with main torrent binary

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
        "send-msg" | "msg" => cmd_send_msg(&args[2..]),
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
    eprintln!("  new-session --config-dir <path> [--channels]  Create session (--channels loads bridge)");
    eprintln!("  send-keys --session <id> --text <text>   Send keys with Escape workaround");
    eprintln!("  send-msg --session <id> --text <message>   Send message to specific session");
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
    let channels = args.iter().any(|a| a == "--channels");
    let callback_port: u16 = get_arg(args, "--callback-port")
        .and_then(|s| s.parse().ok())
        .unwrap_or(9900);

    let home = dirs::home_dir().expect("no home");
    let config_path = if config_dir.starts_with('/') {
        config_dir.clone()
    } else if config_dir.starts_with('~') {
        config_dir.replacen('~', &home.to_string_lossy(), 1)
    } else {
        home.join(&config_dir).to_string_lossy().to_string()
    };

    let is_default = config_dir == ".claude" || config_dir == "~/.claude";
    let mode = if channels { "channels" } else { "file" };

    eprint!("[torrent-cli] session={session_id} config={config_path} mode={mode}\r\n");

    // Create tmux session
    let o = Command::new("tmux")
        .args(["new-session", "-d", "-s", &session_id, "-x", "200", "-y", "50"])
        .output().unwrap_or_else(|e| {
            eprint!("[torrent-cli] error: tmux failed: {e}\r\n");
            std::process::exit(1);
        });
    if !o.status.success() {
        let err = String::from_utf8_lossy(&o.stderr);
        eprint!("[torrent-cli] tmux new-session failed: {err}\r\n");
        std::process::exit(1);
    }

    // Build claude command
    // SEC-002: shell-escape paths to prevent injection via tmux send-keys
    let mut env_prefix = String::new();
    if !is_default {
        env_prefix.push_str(&format!("CLAUDE_CONFIG_DIR={} ", shell_escape(&config_path)));
    }

    let mut cmd = format!(
        "{env_prefix}{} --dangerously-skip-permissions",
        shell_escape(&claude)
    );

    // Append bridge MCP config when channels enabled
    if channels {
        let bridge_port = callback_port.checked_add(1).unwrap_or(callback_port.saturating_sub(1));
        let bridge_path = std::env::current_dir()
            .map(|cwd| cwd.join("torrent/bridge/server.ts"))
            .unwrap_or_else(|_| std::path::PathBuf::from("torrent/bridge/server.ts"));
        let bridge_str = bridge_path.to_string_lossy().replace('"', r#"\""#);

        let mcp_json = format!(
            concat!(
                r#"{{"mcpServers":{{"torrent-bridge":{{"#,
                r#""command":"npx","args":["--yes","tsx","{}"],"#,
                r#""env":{{"TORRENT_CALLBACK_URL":"http://127.0.0.1:{}","#,
                r#""TORRENT_BRIDGE_PORT":"{}","#,
                r#""TORRENT_SESSION_ID":"{}"}}}}}}}}"#,
            ),
            bridge_str, callback_port, bridge_port, session_id
        );
        cmd.push_str(&format!(" --mcp-config '{mcp_json}'"));

        // Set env hint for send-msg auto-detection
        env_prefix.push_str(&format!(
            "TORRENT_CHANNELS_ENABLED=1 TORRENT_CALLBACK_PORT={callback_port} "
        ));

        eprint!("[torrent-cli] bridge: callback={callback_port} bridge={bridge_port}\r\n");
    }

    // Send command to tmux
    Command::new("tmux")
        .args(["send-keys", "-t", &session_id, "-l", &cmd])
        .output().unwrap_or_else(|e| {
            eprint!("[torrent-cli] error: send-keys failed: {e}\r\n");
            std::process::exit(1);
        });
    Command::new("tmux")
        .args(["send-keys", "-t", &session_id, "Enter"])
        .output().unwrap_or_else(|e| {
            eprint!("[torrent-cli] error: send Enter failed: {e}\r\n");
            std::process::exit(1);
        });

    eprint!("[torrent-cli] created: {session_id}\r\n");
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

    // Escape+delay+Enter workaround for Claude Code Ink TUI
    // Step 1: Send text literally
    let o = Command::new("tmux")
        .args(["send-keys", "-t", &session, "-l", &text])
        .output().unwrap_or_else(|e| {
            eprint!("[torrent-cli] error: tmux send-keys failed: {e}\r\n");
            std::process::exit(1);
        });
    if !o.status.success() {
        let err = String::from_utf8_lossy(&o.stderr);
        eprint!("[torrent-cli] send-keys failed: {err}\r\n");
        std::process::exit(1);
    }

    // Step 2: wait 300ms → Escape → wait 100ms → Enter
    thread::sleep(Duration::from_millis(300));
    let _ = Command::new("tmux")
        .args(["send-keys", "-t", &session, "Escape"])
        .output();
    thread::sleep(Duration::from_millis(100));
    let _ = Command::new("tmux")
        .args(["send-keys", "-t", &session, "Enter"])
        .output();

    eprint!("[torrent-cli] sent to {session}\r\n");
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
    eprint!("[torrent-cli] killed: {session}\r\n");
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
    eprint!("[torrent-cli] waiting {wait_secs}s for Claude Code...\r\n");
    for i in 1..=wait_secs {
        thread::sleep(Duration::from_secs(1));
        if i % 5 == 0 { eprint!("[torrent-cli] {i}s...\r\n"); }
    }

    // Step 3: Capture to verify
    eprint!("[torrent-cli] checking readiness...\r\n");
    let o = Command::new("tmux")
        .args(["capture-pane", "-t", &session_id, "-p", "-S", "-5"])
        .output().unwrap_or_else(|e| {
            eprintln!("[torrent-cli] error: capture-pane failed: {e}");
            std::process::exit(1);
        });
    let pane = String::from_utf8_lossy(&o.stdout);
    let ready = pane.contains("❯") || pane.contains("bypass permissions");
    if ready {
        eprint!("[torrent-cli] Claude Code ready\r\n");
    } else {
        eprint!("[torrent-cli] Claude may not be ready yet\r\n");
    }

    // Step 4: Send /arc
    let arc_text = format!("/arc {}", plan);
    cmd_send_keys(&["--session".into(), session_id.clone(), "--text".into(), arc_text]);

    // Step 5: Verify
    thread::sleep(Duration::from_secs(3));
    eprint!("[torrent-cli] capturing output...\r\n");
    cmd_capture_pane(&["--session".into(), session_id.clone(), "--lines".into(), "10".into()]);

    eprint!("[torrent-cli] attach: tmux attach -t {session_id}\r\n");
}

// ── send-msg ───────────────────────────────────────────────

fn cmd_send_msg(args: &[String]) {
    let text = get_arg(args, "--text").unwrap_or_else(|| {
        let flags = ["--inbox", "--session", "--text", "--via"];
        let mut msg_parts: Vec<&str> = Vec::new();
        let mut skip_next = false;
        for a in args {
            if skip_next { skip_next = false; continue; }
            if flags.contains(&a.as_str()) { skip_next = true; continue; }
            msg_parts.push(a);
        }
        if msg_parts.is_empty() {
            eprintln!("Usage: torrent-cli send-msg --session <id> --text <message>");
            eprintln!("       torrent-cli send-msg --session <id> \"your message\"");
            eprintln!("       torrent-cli send-msg \"message\"  (auto-detect session)");
            eprintln!();
            eprintln!("Options:");
            eprintln!("  --via bridge|tmux|auto   Delivery method (default: auto)");
            eprintln!("  --session <id>           Target tmux session (auto-detect if omitted)");
            std::process::exit(1);
        }
        msg_parts.join(" ")
    });

    let session = get_arg(args, "--session").unwrap_or_else(auto_detect_session);
    validate_session_id(&session);

    // Delivery strategy: auto (default) tries bridge first, falls back to tmux
    let via = get_arg(args, "--via").unwrap_or_else(|| "auto".into());

    match via.as_str() {
        "bridge" => send_via_bridge(&session, &text),
        "tmux" => send_via_tmux(&session, &text),
        "auto" => {
            // Check if bridge inbox exists for this session (indicates channels mode)
            let inbox_path = std::path::Path::new("tmp/bridge-inbox").join(&session);
            if inbox_path.exists() {
                send_via_bridge(&session, &text);
            } else {
                // Try bridge first (create inbox), but if session looks non-channel, use tmux
                // Heuristic: if TORRENT_CHANNELS_ENABLED is set, prefer bridge
                let channels_hint = std::env::var("TORRENT_CHANNELS_ENABLED")
                    .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                    .unwrap_or(false);
                if channels_hint {
                    send_via_bridge(&session, &text);
                } else {
                    send_via_tmux(&session, &text);
                }
            }
        }
        other => {
            eprintln!("error: unknown --via method '{other}'. Use: bridge, tmux, auto");
            std::process::exit(1);
        }
    }
}

fn send_via_bridge(session: &str, text: &str) {
    // Discover bridge port: try bridge-port.txt from multiple base dirs, then default 9901
    let port = discover_bridge_port(session);

    let url = format!("http://127.0.0.1:{port}/msg");
    match ureq::post(&url)
        .set("Content-Type", "text/plain")
        .send_string(text)
    {
        Ok(_) => {
            eprint!("[torrent-cli] sent via bridge → {session} ({} bytes, port {port})\r\n", text.len());
            return;
        }
        Err(e) => {
            eprint!("[torrent-cli] bridge HTTP failed on port {port} ({e}) — trying inbox\r\n");
        }
    }

    // Fallback: file-based inbox
    let inbox_path = std::path::Path::new("tmp/bridge-inbox").join(session);
    if let Err(e) = std::fs::create_dir_all(&inbox_path) {
        eprint!("[torrent-cli] inbox failed ({e}) — using tmux\r\n");
        send_via_tmux(session, text);
        return;
    }
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let msg_file = inbox_path.join(format!("{timestamp}.msg"));
    match std::fs::write(&msg_file, text) {
        Ok(_) => {
            eprint!("[torrent-cli] sent via inbox → {session} ({} bytes)\r\n", text.len());
        }
        Err(e) => {
            eprint!("[torrent-cli] inbox write failed ({e}) — using tmux\r\n");
            send_via_tmux(session, text);
        }
    }
}

fn send_via_tmux(session: &str, text: &str) {
    eprint!("[torrent-cli] sent via tmux → {session}\r\n");
    cmd_send_keys(&[
        "--session".into(), session.to_string(),
        "--text".into(), text.to_string(),
    ]);
}

/// Discover bridge port for a session.
/// Searches bridge-port.txt in CWD, parent dir, and env var. Falls back to 9901.
fn discover_bridge_port(session: &str) -> u16 {
    let port_filename = format!("tmp/arc/arc-{session}/bridge-port.txt");

    // Try CWD
    if let Ok(s) = std::fs::read_to_string(&port_filename) {
        if let Ok(p) = s.trim().parse::<u16>() { return p; }
    }

    // Try parent dir (when running from torrent/ subdir)
    let parent = format!("../{port_filename}");
    if let Ok(s) = std::fs::read_to_string(&parent) {
        if let Ok(p) = s.trim().parse::<u16>() { return p; }
    }

    // Try env var
    if let Ok(s) = std::env::var("TORRENT_BRIDGE_PORT") {
        if let Ok(p) = s.parse::<u16>() { return p; }
    }

    // Default: callback_port (9900) + 1
    let callback = std::env::var("TORRENT_CALLBACK_PORT")
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(9900);
    callback.checked_add(1).unwrap_or(9901)
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
