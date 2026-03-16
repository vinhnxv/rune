use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;

use color_eyre::eyre::{eyre, Result};
use rand::Rng;

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
            .map_or(false, |o| o.status.success())
    }

    /// Create a detached tmux session (empty shell).
    pub fn create_session(session_id: &str) -> Result<()> {
        validate_session_id(session_id)?;

        if Self::has_session(session_id) {
            return Err(eyre!("session '{}' already exists", session_id));
        }

        let output = Command::new("tmux")
            .args([
                "new-session", "-d", "-s", session_id, "-x", "200", "-y", "50",
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
    pub fn start_claude(
        session_id: &str,
        config_dir: &Path,
        claude_path: &str,
    ) -> Result<()> {
        validate_session_id(session_id)?;

        let is_default = config_dir
            .file_name()
            .map(|n| n == ".claude")
            .unwrap_or(false);

        let cmd = if is_default {
            format!("{} --dangerously-skip-permissions", claude_path)
        } else {
            let config_str = config_dir.to_string_lossy();
            format!(
                "CLAUDE_CONFIG_DIR={} {} --dangerously-skip-permissions",
                config_str, claude_path
            )
        };

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
    /// Claude Code uses Ink (React terminal framework) which intercepts Enter
    /// for autocomplete. The workaround from varre:
    /// 1. Send text literally with -l
    /// 2. Wait 300ms for autocomplete to render
    /// 3. Send Escape to dismiss autocomplete
    /// 4. Wait 100ms for Ink to process
    /// 5. Send Enter to submit the prompt
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
    #[allow(dead_code)] // utility — used by torrent-cli, will be used by TUI monitor
    pub fn capture_pane(session_id: &str, lines: i32) -> Result<String> {
        let start = format!("-{}", lines);
        let output = Command::new("tmux")
            .args(["capture-pane", "-t", session_id, "-p", "-S", &start])
            .output()
            .map_err(|e| eyre!("capture-pane failed: {e}"))?;

        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    /// Kill a tmux session. Best-effort.
    pub fn kill_session(session_id: &str) -> Result<()> {
        validate_session_id(session_id)?;
        let _ = Command::new("tmux")
            .args(["kill-session", "-t", session_id])
            .output();
        Ok(())
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
    fn test_generate_session_id_format() {
        let id = Tmux::generate_session_id();
        assert!(id.starts_with("rune-"));
        assert_eq!(id.len(), 11);
        assert!(id[5..].chars().all(|c| c.is_ascii_hexdigit()));
    }
}
