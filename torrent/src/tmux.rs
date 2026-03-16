use std::path::Path;
use std::process::Command;

use color_eyre::eyre::{eyre, Result};
use rand::Rng;

/// Validate session_id contains only safe characters for tmux -t flag.
/// Prevents tmux target syntax injection (session:window.pane).
fn validate_session_id(session_id: &str) -> Result<()> {
    if session_id.is_empty() || session_id.len() > 64 {
        return Err(eyre!("Invalid session_id length: {}", session_id.len()));
    }
    if !session_id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(eyre!(
            "Invalid session_id characters: {session_id} (only alphanumeric, hyphen, underscore allowed)"
        ));
    }
    Ok(())
}

/// Validate plan path contains no shell metacharacters or traversal.
fn validate_plan_path(path: &Path) -> Result<()> {
    let s = path.to_string_lossy();
    if s.contains("..") || s.starts_with('/') || s.starts_with('-') {
        return Err(eyre!("Invalid plan path: {s}"));
    }
    if !s
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "._-/".contains(c))
    {
        return Err(eyre!("Plan path contains unsafe characters: {s}"));
    }
    Ok(())
}

/// Wrapper around tmux CLI for managing Claude Code sessions.
pub struct Tmux;

impl Tmux {
    /// Resolve the absolute path to the `claude` binary.
    /// Uses `which claude` from the current shell — this finds the correct binary
    /// even when tmux's bash would resolve to a different one (brew/npm vs ~/.local/bin).
    pub fn resolve_claude_path() -> Result<String> {
        let output = Command::new("which")
            .arg("claude")
            .output()
            .map_err(|e| eyre!("failed to run 'which claude': {e}"))?;

        if !output.status.success() {
            return Err(eyre!("claude not found in PATH. Install: https://docs.anthropic.com/en/docs/claude-code"));
        }

        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if path.is_empty() {
            return Err(eyre!("'which claude' returned empty path"));
        }
        Ok(path)
    }

    /// Check that tmux is installed and reachable.
    pub fn verify_available() -> Result<()> {
        let output = Command::new("tmux")
            .arg("-V")
            .output()
            .map_err(|e| eyre!("tmux not found: {e}"))?;

        if !output.status.success() {
            return Err(eyre!("tmux -V failed: {}", output.status));
        }
        Ok(())
    }

    /// Generate a random session name: `rune-{6-char-hex}`.
    pub fn generate_session_id() -> String {
        let bytes: [u8; 3] = rand::thread_rng().gen();
        format!("rune-{}", hex_encode(bytes))
    }

    /// Create a detached tmux session running Claude Code with CLAUDE_CONFIG_DIR.
    ///
    /// Passes the full command as the tmux session command via `bash -c`.
    /// This is the most reliable way to ensure env vars are available to Claude Code —
    /// neither `.env()` on Command nor `tmux set-environment` propagate to the session shell.
    pub fn create_session(config_dir: &Path, session_id: &str, claude_path: &str) -> Result<()> {
        validate_session_id(session_id)?;

        let config_str = config_dir.to_string_lossy();

        // Step 1: Create empty tmux session (default shell)
        let status = Command::new("tmux")
            .args([
                "new-session", "-d", "-s", session_id, "-x", "200", "-y", "50",
            ])
            .status()
            .map_err(|e| eyre!("failed to create tmux session: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux new-session failed: {status}"));
        }

        // Step 2: Send claude command via send-keys into the shell
        // This starts Claude Code INSIDE the shell — if it exits, the shell remains.
        // Using send-keys ensures the shell's PATH and env are available.
        let claude_cmd = format!(
            "CLAUDE_CONFIG_DIR='{}' '{}' --dangerously-skip-permissions",
            config_str, claude_path
        );
        let status = Command::new("tmux")
            .args(["send-keys", "-t", session_id, &claude_cmd, "Enter"])
            .status()
            .map_err(|e| eyre!("tmux send-keys claude failed: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux send-keys claude failed: {status}"));
        }

        Ok(())
    }

    /// Send `/arc <plan_path>` + Enter to the target tmux session.
    ///
    /// Uses standard tmux `send-keys -t $id "text" Enter` syntax —
    /// text and Enter in the same command (not `-l` with separate Enter).
    pub fn send_arc_command(session_id: &str, plan_path: &Path) -> Result<()> {
        validate_session_id(session_id)?;
        // Extract relative path for the /arc command.
        let display_path = plan_path.display().to_string();
        let arc_path = if let Some(idx) = display_path.find("plans/") {
            &display_path[idx..]
        } else {
            &display_path
        };
        let arc_cmd = format!("/arc {}", arc_path);

        // Single send-keys call: "text" + Enter (same as: tmux send-keys -t $id "text" Enter)
        let status = Command::new("tmux")
            .args(["send-keys", "-t", session_id, &arc_cmd, "Enter"])
            .status()
            .map_err(|e| eyre!("tmux send-keys failed: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux send-keys failed: {status}"));
        }

        Ok(())
    }

    /// Kill a tmux session by name. Best-effort — ignores errors if the
    /// session already exited.
    pub fn kill_session(session_id: &str) -> Result<()> {
        validate_session_id(session_id)?;
        let status = Command::new("tmux")
            .args(["kill-session", "-t", session_id])
            .status()
            .map_err(|e| eyre!("tmux kill-session failed: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux kill-session failed: {status}"));
        }
        Ok(())
    }

    /// Check if a tmux session with the given name exists.
    pub fn has_session(session_id: &str) -> bool {
        Command::new("tmux")
            .args(["has-session", "-t", session_id])
            .status()
            .map_or(false, |s| s.success())
    }

    /// Attach to a tmux session (foreground — blocks until detach).
    ///
    /// This suspends the TUI. The user returns via `Ctrl-B D`.
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

/// Encode 3 bytes as a 6-character lowercase hex string.
fn hex_encode(bytes: [u8; 3]) -> String {
    format!("{:02x}{:02x}{:02x}", bytes[0], bytes[1], bytes[2])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hex_encode() {
        assert_eq!(hex_encode([0xa1, 0xb2, 0xc3]), "a1b2c3");
        assert_eq!(hex_encode([0x00, 0x00, 0x00]), "000000");
        assert_eq!(hex_encode([0xff, 0xff, 0xff]), "ffffff");
    }

    #[test]
    fn test_generate_session_id_format() {
        let id = Tmux::generate_session_id();
        assert!(id.starts_with("rune-"));
        assert_eq!(id.len(), 11); // "rune-" (5) + 6 hex chars
        // All chars after prefix are valid hex
        assert!(id[5..].chars().all(|c| c.is_ascii_hexdigit()));
    }
}
