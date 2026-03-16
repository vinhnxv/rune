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

    /// Create a detached tmux session running `claude --dangerously-skip-permissions`.
    ///
    /// The session inherits the current working directory so Claude Code
    /// starts in the repo root. `CLAUDE_CONFIG_DIR` is injected via env.
    pub fn create_session(config_dir: &Path, session_id: &str) -> Result<()> {
        validate_session_id(session_id)?;
        let status = Command::new("tmux")
            .args([
                "new-session",
                "-d",
                "-s",
                session_id,
                "-x",
                "200",
                "-y",
                "50",
            ])
            .env("CLAUDE_CONFIG_DIR", config_dir)
            .args(["claude", "--dangerously-skip-permissions"])
            .status()
            .map_err(|e| eyre!("failed to spawn tmux: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux new-session failed: {status}"));
        }
        Ok(())
    }

    /// Send `/arc <plan_path>` followed by Enter to the target session.
    ///
    /// Uses `-l` (literal) so tmux doesn't interpret special characters
    /// in the plan path. Enter is sent as a separate command to avoid
    /// paste-mode edge cases.
    pub fn send_arc_command(session_id: &str, plan_path: &Path) -> Result<()> {
        validate_session_id(session_id)?;
        validate_plan_path(plan_path)?;
        let arc_cmd = format!("/arc {}", plan_path.display());

        // Send the literal command text
        let status = Command::new("tmux")
            .args(["send-keys", "-t", session_id, "-l", &arc_cmd])
            .status()
            .map_err(|e| eyre!("tmux send-keys failed: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux send-keys (literal) failed: {status}"));
        }

        // Send Enter separately
        let status = Command::new("tmux")
            .args(["send-keys", "-t", session_id, "Enter"])
            .status()
            .map_err(|e| eyre!("tmux send-keys Enter failed: {e}"))?;

        if !status.success() {
            return Err(eyre!("tmux send-keys Enter failed: {status}"));
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
