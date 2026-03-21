use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;

use color_eyre::eyre::{eyre, Result};
use rand::Rng;

use crate::channel::ChannelsConfig;

/// Shell-escape a string by wrapping in single quotes.
/// Internal single quotes are replaced with `'\''` (end-quote, escaped-quote, start-quote).
/// SEC-002 FIX: prevents command injection when values are sent to a shell via tmux send-keys.
fn shell_escape(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Delay between send-keys steps (Ink autocomplete workaround).
const SEND_DELAY_MS: u64 = 300;

/// Validate session_id contains only safe characters for tmux -t flag.
fn validate_session_id(session_id: &str) -> Result<()> {
    if session_id.is_empty() || session_id.len() > 64 {
        return Err(eyre!("Invalid session_id length: {}", session_id.len()));
    }
    if !session_id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(eyre!(
            "Invalid session_id characters: {session_id}"
        ));
    }
    Ok(())
}

/// Wrapper around tmux CLI for managing Claude Code sessions.
/// Based on varre's TmuxWrapper pattern with Escape+delay+Enter workaround.
pub struct Tmux;

impl Tmux {
    /// Resolve the absolute path to the `claude` binary.
    pub fn resolve_claude_path() -> Result<String> {
        let output = Command::new("which")
            .arg("claude")
            .output()
            .map_err(|e| eyre!("failed to run 'which claude': {e}"))?;

        if !output.status.success() {
            return Err(eyre!("claude not found in PATH"));
        }

        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if path.is_empty() {
            return Err(eyre!("'which claude' returned empty path"));
        }
        Ok(path)
    }

    /// Check that tmux is available.
    pub fn verify_available() -> Result<()> {
        let output = Command::new("tmux")
            .arg("-V")
            .output()
            .map_err(|e| eyre!("tmux not found — brew install tmux: {e}"))?;

        if !output.status.success() {
            return Err(eyre!("tmux -V failed: {}", output.status));
        }
        Ok(())
    }

    /// Generate a random session name: `rune-{6-char-hex}`.
    pub fn generate_session_id() -> String {
        let bytes: [u8; 3] = rand::thread_rng().gen();
        format!("rune-{:02x}{:02x}{:02x}", bytes[0], bytes[1], bytes[2])
    }

    /// Check if a tmux session exists.
    pub fn has_session(session_id: &str) -> bool {
        Command::new("tmux")
            .args(["has-session", "-t", session_id])
            .output()
            .is_ok_and(|o| o.status.success())
    }

    /// Create a detached tmux session (empty shell) in the given working directory.
    ///
    /// The `-c` flag sets the tmux session's starting directory, ensuring that
    /// Claude Code launched inside will inherit the correct CWD. This is critical
    /// for CWD-based session isolation — two torrent instances in different
    /// directories must not interfere with each other.
    pub fn create_session(session_id: &str, working_dir: &Path) -> Result<()> {
        validate_session_id(session_id)?;

        if Self::has_session(session_id) {
            return Err(eyre!("session '{}' already exists", session_id));
        }

        let dir_str = working_dir.to_string_lossy();
        let output = Command::new("tmux")
            .args([
                "new-session", "-d", "-s", session_id,
                "-x", "200", "-y", "50",
                "-c", &dir_str,
            ])
            .output()
            .map_err(|e| eyre!("tmux new-session failed: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(eyre!("tmux new-session failed: {}", stderr.trim()));
        }
        Ok(())
    }

    /// Start Claude Code inside a tmux session.
    ///
    /// Sends the claude binary command via send-keys (not as session command).
    /// Only sets CLAUDE_CONFIG_DIR for non-default config dirs.
    ///
    /// When `channels` is `Some`, appends the channels bridge flag and sets
    /// `TORRENT_CALLBACK_URL` + `TORRENT_BRIDGE_PORT` env vars for the bridge
    /// server. Channels are OUTBOUND-ONLY (Claude → Torrent) in v0.7.0.
    ///
    /// **IMPORTANT**: Pass `None` for resumed sessions — `--resume` +
    /// `--dangerously-load-development-channels` = crash (#36638).
    pub fn start_claude(
        session_id: &str,
        config_dir: &Path,
        claude_path: &str,
        channels: Option<&ChannelsConfig>,
    ) -> Result<()> {
        validate_session_id(session_id)?;

        let is_default = config_dir
            .file_name()
            .map(|n| n == ".claude")
            .unwrap_or(false);

        // Build env var prefix: TORRENT_CALLBACK_URL + TORRENT_BRIDGE_PORT (if channels)
        // + CLAUDE_CONFIG_DIR (if non-default config dir)
        // SEC-002 FIX: shell-escape all interpolated values
        let mut env_prefix = String::new();

        if let Some(ch) = channels {
            // Numeric u16 values are inherently safe, but we format cleanly
            env_prefix.push_str(&format!(
                "TORRENT_CALLBACK_URL=http://127.0.0.1:{} TORRENT_BRIDGE_PORT={} ",
                ch.callback_port, ch.bridge_port
            ));
        }

        if !is_default {
            let config_str = config_dir.to_string_lossy();
            env_prefix.push_str(&format!(
                "CLAUDE_CONFIG_DIR={} ",
                shell_escape(&config_str)
            ));
        }

        // Build base command
        let mut cmd = format!(
            "{}{} --dangerously-skip-permissions",
            env_prefix,
            shell_escape(claude_path)
        );

        // Append channels flag if enabled
        if channels.is_some() {
            cmd.push_str(" --dangerously-load-development-channels server:torrent-bridge");
        }

        // Send command text literally (-l), then Enter separately.
        // This is a shell command, not Claude Code input — simple send works.
        let output = Command::new("tmux")
            .args(["send-keys", "-t", session_id, "-l", &cmd])
            .output()
            .map_err(|e| eyre!("send-keys failed: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(eyre!("send-keys failed: {}", stderr.trim()));
        }

        // Enter to execute the shell command
        Command::new("tmux")
            .args(["send-keys", "-t", session_id, "Enter"])
            .output()
            .map_err(|e| eyre!("send Enter failed: {e}"))?;

        Ok(())
    }

    /// Send keys to Claude Code using the Escape+delay+Enter workaround.
    ///
    /// # Why This Workaround Is Needed
    ///
    /// Claude Code uses [Ink](https://github.com/vadimdemedes/ink) (a React-based terminal UI
    /// framework). Ink intercepts the Enter key for autocomplete suggestions. When we send text
    /// followed by Enter, Ink shows autocomplete options instead of submitting the prompt.
    ///
    /// The workaround (discovered through experimentation, similar to varre's approach):
    /// 1. Send text literally with `-l` flag (prevents tmux from interpreting special keys)
    /// 2. Wait 300ms for Ink's autocomplete to render
    /// 3. Send Escape to dismiss the autocomplete popup
    /// 4. Wait 100ms for Ink to process the dismissal
    /// 5. Send Enter to submit the prompt
    ///
    /// This pattern ensures the prompt is submitted rather than triggering autocomplete.
    pub fn send_keys(session_id: &str, text: &str) -> Result<()> {
        validate_session_id(session_id)?;

        if !Self::has_session(session_id) {
            return Err(eyre!("session '{}' not found", session_id));
        }

        // Step 1: Send text literally (no Enter, -l prevents key name interpretation)
        let output = Command::new("tmux")
            .args(["send-keys", "-t", session_id, "-l", text])
            .output()
            .map_err(|e| eyre!("send-keys text failed: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(eyre!("send-keys text failed: {}", stderr.trim()));
        }

        // Step 2: Wait for autocomplete to render
        thread::sleep(Duration::from_millis(SEND_DELAY_MS));

        // Step 3: Send Escape to dismiss autocomplete
        Command::new("tmux")
            .args(["send-keys", "-t", session_id, "Escape"])
            .output()
            .map_err(|e| eyre!("send Escape failed: {e}"))?;

        // Step 4: Brief wait for Ink to process
        thread::sleep(Duration::from_millis(100));

        // Step 5: Send Enter to submit
        let output = Command::new("tmux")
            .args(["send-keys", "-t", session_id, "Enter"])
            .output()
            .map_err(|e| eyre!("send Enter failed: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(eyre!("send Enter failed: {}", stderr.trim()));
        }

        Ok(())
    }

    /// Send /arc command to Claude Code session.
    pub fn send_arc_command(session_id: &str, plan_path: &Path) -> Result<()> {
        // Extract relative path for the /arc command.
        let display_path = plan_path.display().to_string();
        let arc_path = if let Some(idx) = display_path.find("plans/") {
            &display_path[idx..]
        } else {
            &display_path
        };
        let arc_cmd = format!("/arc {}", arc_path);

        // Use the Ink-aware send_keys (Escape+delay+Enter workaround)
        Self::send_keys(session_id, &arc_cmd)
    }

    /// Capture pane output from a tmux session.
    pub fn capture_pane(session_id: &str, lines: i32) -> Result<String> {
        let start = format!("-{}", lines);
        let output = Command::new("tmux")
            .args(["capture-pane", "-t", session_id, "-p", "-S", &start])
            .output()
            .map_err(|e| eyre!("capture-pane failed: {e}"))?;

        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    /// Capture pane output and compute a hash for change detection.
    ///
    /// Returns `None` if the tmux session doesn't exist or capture fails.
    /// Uses `DefaultHasher` (SipHash) — adequate for change detection, not security.
    pub fn capture_pane_hash(session_id: &str, lines: i32) -> Option<u64> {
        use std::hash::{Hash, Hasher};
        let content = Self::capture_pane(session_id, lines).ok()?;
        if content.is_empty() {
            return None;
        }
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        content.hash(&mut hasher);
        Some(hasher.finish())
    }

    /// Capture the last non-empty line from a tmux pane.
    ///
    /// Used for input prompt detection (shell prompt, permission prompt, etc.).
    /// Returns `None` if the session doesn't exist or the pane is empty.
    pub fn capture_last_line(session_id: &str) -> Option<String> {
        let content = Self::capture_pane(session_id, 5).ok()?;
        content.lines().rev().find(|l| !l.trim().is_empty()).map(|s| s.to_string())
    }

    /// Get the PID of the process running in the tmux pane.
    /// Uses `tmux display-message -t {session} -p '#{pane_pid}'`.
    pub fn get_pane_pid(session_id: &str) -> Result<u32> {
        validate_session_id(session_id)?;
        let output = Command::new("tmux")
            .args(["display-message", "-t", session_id, "-p", "#{pane_pid}"])
            .output()
            .map_err(|e| eyre!("tmux display-message failed: {e}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(eyre!("tmux display-message failed: {}", stderr.trim()));
        }
        let pid_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
        pid_str
            .parse::<u32>()
            .map_err(|_| eyre!("invalid pane_pid: {pid_str}"))
    }

    /// Find the Claude Code process PID (child of pane shell).
    /// The pane_pid is the shell; Claude Code is its child process.
    /// Uses `pgrep -P <pane_pid>` to find child processes, then verifies
    /// the process is actually Claude Code (node/claude) via `ps -o comm=`.
    pub fn get_claude_pid(pane_pid: u32) -> Option<u32> {
        let output = Command::new("pgrep")
            .args(["-P", &pane_pid.to_string()])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Check each child — find one that's a Claude Code process (node or claude*)
        for line in stdout.lines() {
            if let Ok(pid) = line.trim().parse::<u32>() {
                if Self::is_claude_process(pid) {
                    return Some(pid);
                }
            }
        }
        None
    }

    /// Check if a PID is a Claude Code process by examining its command name.
    fn is_claude_process(pid: u32) -> bool {
        let output = Command::new("ps")
            .args(["-p", &pid.to_string(), "-o", "comm="])
            .output();
        match output {
            Ok(o) if o.status.success() => {
                let comm = String::from_utf8_lossy(&o.stdout).trim().to_lowercase();
                comm.contains("node") || comm.contains("claude")
            }
            _ => false,
        }
    }

    // session_exists() removed — QUAL-009: identical to has_session().
    // Callers migrated to has_session().

    /// Kill a tmux session. Best-effort.
    pub fn kill_session(session_id: &str) -> Result<()> {
        validate_session_id(session_id)?;
        let _ = Command::new("tmux")
            .args(["kill-session", "-t", session_id])
            .output();
        Ok(())
    }

    /// Kill an old session, create a fresh one, and start Claude Code in it.
    ///
    /// Thin composition of existing methods for the watchdog auto-resume flow.
    /// The old session is killed best-effort (it may already be dead).
    /// Returns the new session ID.
    ///
    /// **SAFETY**: The `_channels` parameter is accepted for API consistency
    /// but ALWAYS ignored. Resume sessions MUST NOT use channels because
    /// `--resume` + `--dangerously-load-development-channels` crashes with
    /// "No conversation found" (#36638). This makes the safety guarantee
    /// explicit at the type level.
    pub fn recreate_session(
        old_session: &str,
        working_dir: &Path,
        config_dir: &Path,
        claude_path: &str,
        _channels: Option<&ChannelsConfig>, // Intentionally unused — resume MUST NOT use channels
    ) -> Result<String> {
        let _ = Self::kill_session(old_session); // best effort
        let new_id = Self::generate_session_id();
        Self::create_session(&new_id, working_dir)?;
        // SAFETY: Always None — channels + resume = broken (#36638)
        Self::start_claude(&new_id, config_dir, claude_path, None)?;
        Ok(new_id)
    }

    /// Send `/arc <plan> --resume` command to a Claude Code session.
    ///
    /// Extracts the relative plan path (from `plans/` onwards) and appends
    /// `--resume` so arc continues from the last completed phase.
    pub fn send_arc_resume_command(session_id: &str, plan_path: &Path) -> Result<()> {
        let display_path = plan_path.display().to_string();
        let arc_path = if let Some(idx) = display_path.find("plans/") {
            &display_path[idx..]
        } else {
            &display_path
        };
        let cmd = format!("/arc {} --resume", arc_path);
        Self::send_keys(session_id, &cmd)
    }

    /// Attach to a tmux session (foreground — blocks until Ctrl-B D detach).
    pub fn attach(session_id: &str) -> Result<()> {
        let status = Command::new("tmux")
            .args(["attach-session", "-t", session_id])
            .status()
            .map_err(|e| eyre!("tmux attach failed: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux attach failed: {status}"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_shell_escape_simple() {
        assert_eq!(shell_escape("hello"), "'hello'");
    }

    #[test]
    fn test_shell_escape_with_spaces() {
        assert_eq!(shell_escape("/path/with spaces/dir"), "'/path/with spaces/dir'");
    }

    #[test]
    fn test_shell_escape_with_metacharacters() {
        assert_eq!(shell_escape("foo;rm -rf /"), "'foo;rm -rf /'");
        assert_eq!(shell_escape("$(evil)"), "'$(evil)'");
        assert_eq!(shell_escape("a`cmd`b"), "'a`cmd`b'");
    }

    #[test]
    fn test_shell_escape_with_single_quotes() {
        assert_eq!(shell_escape("it's"), "'it'\\''s'");
    }

    #[test]
    fn test_generate_session_id_format() {
        let id = Tmux::generate_session_id();
        assert!(id.starts_with("rune-"));
        assert_eq!(id.len(), 11);
        assert!(id[5..].chars().all(|c| c.is_ascii_hexdigit()));
    }
}
