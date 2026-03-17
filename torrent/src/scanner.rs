use color_eyre::{eyre::eyre, Result};
use glob::glob;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::monitor;

/// A discovered Claude config directory (e.g. ~/.claude or ~/.claude-work).
#[derive(Debug, Clone)]
pub struct ConfigDir {
    pub path: PathBuf,
    pub label: String,
}

/// A plan file discovered in plans/*.md.
#[derive(Debug, Clone)]
pub struct PlanFile {
    pub path: PathBuf,
    pub name: String,
    pub title: String,
}

/// Scan $HOME for Claude config directories.
///
/// Matches:
/// - ~/.claude/ (default)
/// - ~/.claude-*/ (custom accounts)
///
/// Filters: must be a directory containing settings.json or projects/ subdirectory.
pub fn scan_config_dirs() -> Result<Vec<ConfigDir>> {
    let home = dirs::home_dir().ok_or_else(|| eyre!("cannot resolve home directory"))?;
    let mut configs = Vec::new();

    // Check ~/.claude/
    let default_dir = home.join(".claude");
    if is_valid_config_dir(&default_dir) {
        configs.push(ConfigDir {
            path: default_dir,
            label: ".claude (default)".into(),
        });
    }

    // Check ~/.claude-*/
    // SAFETY: home.display() may panic on non-UTF8 paths. We validate UTF-8 first.
    let home_str = home.to_string_lossy();
    let pattern = format!("{}/.claude-*/", home_str);
    for entry in glob(&pattern).map_err(|e| eyre!("invalid glob pattern: {e}"))? {
        match entry {
            Ok(path) if is_valid_config_dir(&path) => {
                let label = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.display().to_string());
                configs.push(ConfigDir { path, label });
            }
            _ => {}
        }
    }

    Ok(configs)
}

/// A valid config dir must contain settings.json or a projects/ subdirectory.
fn is_valid_config_dir(path: &Path) -> bool {
    path.is_dir() && (path.join("settings.json").exists() || path.join("projects").is_dir())
}

/// Scan plans/*.md in the given directory (non-recursive).
pub fn scan_plans(cwd: &Path) -> Result<Vec<PlanFile>> {
    let pattern = cwd.join("plans").join("*.md");
    let pattern_str = pattern.to_string_lossy();
    let mut plans = Vec::new();

    for entry in glob(&pattern_str).map_err(|e| eyre!("invalid glob pattern: {e}"))? {
        match entry {
            Ok(path) if path.is_file() => {
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let title = read_first_heading(&path).unwrap_or_else(|| name.clone());
                plans.push(PlanFile { path, name, title });
            }
            _ => {}
        }
    }

    plans.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(plans)
}

/// Extract the first markdown heading (# ...) from a file.
fn read_first_heading(path: &Path) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(heading) = trimmed.strip_prefix("# ") {
            return Some(heading.trim().to_string());
        }
    }
    None
}

// ── Active Arc Detection ────────────────────────────────────

/// An active arc session discovered at startup.
#[derive(Debug, Clone)]
pub struct ActiveArc {
    /// Config dir where this arc is running.
    pub config_dir: ConfigDir,
    /// Loop state from arc-phase-loop.local.md.
    pub loop_state: monitor::ArcLoopState,
    /// Whether the owner_pid process is still alive.
    pub pid_alive: bool,
    /// Tmux session ID if found (matching rune-* prefix).
    pub tmux_session: Option<String>,
    /// Current phase from checkpoint (if readable).
    pub current_phase: Option<String>,
    /// PR URL from checkpoint (if available).
    pub pr_url: Option<String>,
    /// Phase progress (completed/total).
    pub phase_progress: Option<(u32, u32)>,
}

/// Scan all config dirs for active arc sessions.
///
/// For each config dir:
/// 1. Read arc-phase-loop.local.md
/// 2. Check if owner_pid is alive
/// 3. Scan tmux sessions for matching rune-* session
/// 4. Read checkpoint for phase progress
pub fn scan_active_arcs(config_dirs: &[ConfigDir], cwd: &Path) -> Vec<ActiveArc> {
    let tmux_sessions = list_rune_tmux_sessions();
    let mut active = Vec::new();

    for config in config_dirs {
        if let Some(loop_state) = monitor::read_arc_loop_state(&config.path) {
            let pid_alive = is_pid_alive_check(&loop_state.owner_pid);

            // Find matching tmux session by checking all rune-* sessions
            // for the Claude Code PID that matches owner_pid
            let tmux_session = find_tmux_for_pid(&tmux_sessions, &loop_state.owner_pid);

            // Read checkpoint for phase info (resolve path via config_dir)
            let checkpoint_path = monitor::resolve_checkpoint_path(
                &loop_state.checkpoint_path, &config.path, cwd,
            );

            let (current_phase, pr_url, phase_progress) =
                read_checkpoint_summary(&checkpoint_path);

            active.push(ActiveArc {
                config_dir: config.clone(),
                loop_state,
                pid_alive,
                tmux_session,
                current_phase,
                pr_url,
                phase_progress,
            });
        }
    }

    // Also scan for orphan tmux sessions (rune-* sessions without a loop state)
    for session in &tmux_sessions {
        let already_matched = active.iter().any(|a| {
            a.tmux_session.as_deref() == Some(session.as_str())
        });
        if !already_matched {
            // Check if this tmux session has Claude Code running
            if let Some(pane_pid) = get_tmux_pane_pid(session) {
                if crate::tmux::Tmux::get_claude_pid(pane_pid).is_some() {
                    active.push(ActiveArc {
                        config_dir: ConfigDir {
                            path: PathBuf::new(),
                            label: "(unknown config)".into(),
                        },
                        loop_state: monitor::ArcLoopState {
                            active: true,
                            checkpoint_path: String::new(),
                            plan_file: "(orphan tmux session)".into(),
                            config_dir: String::new(),
                            owner_pid: String::new(),
                            session_id: String::new(),
                            branch: String::new(),
                            iteration: 0,
                            max_iterations: 0,
                        },
                        pid_alive: true,
                        tmux_session: Some(session.clone()),
                        current_phase: None,
                        pr_url: None,
                        phase_progress: None,
                    });
                }
            }
        }
    }

    active
}

/// List all tmux sessions with prefix "rune-".
fn list_rune_tmux_sessions() -> Vec<String> {
    let output = Command::new("tmux")
        .args(["list-sessions", "-F", "#{session_name}"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|s| s.starts_with("rune-"))
                .map(|s| s.to_string())
                .collect()
        }
        _ => Vec::new(),
    }
}

/// Check if a PID is alive using kill -0.
fn is_pid_alive_check(pid_str: &str) -> bool {
    let pid: u32 = match pid_str.parse() {
        Ok(p) => p,
        Err(_) => return false,
    };
    Command::new("kill")
        .args(["-0", &pid.to_string()])
        .output()
        .is_ok_and(|o| o.status.success())
}

/// Find a tmux session whose Claude Code PID matches the given owner_pid.
fn find_tmux_for_pid(sessions: &[String], owner_pid: &str) -> Option<String> {
    let target_pid: u32 = owner_pid.parse().ok()?;
    for session in sessions {
        if let Some(pane_pid) = get_tmux_pane_pid(session) {
            if let Some(claude_pid) = crate::tmux::Tmux::get_claude_pid(pane_pid) {
                if claude_pid == target_pid {
                    return Some(session.clone());
                }
            }
        }
    }
    None
}

/// Get the pane PID for a tmux session.
fn get_tmux_pane_pid(session_id: &str) -> Option<u32> {
    let output = Command::new("tmux")
        .args(["display-message", "-t", session_id, "-p", "#{pane_pid}"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .ok()
}

/// Read checkpoint.json and extract phase summary info.
fn read_checkpoint_summary(path: &Path) -> (Option<String>, Option<String>, Option<(u32, u32)>) {
    let contents = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return (None, None, None),
    };

    let checkpoint: crate::checkpoint::Checkpoint = match serde_json::from_str(&contents) {
        Ok(c) => c,
        Err(_) => return (None, None, None),
    };

    let mut completed = 0u32;
    let mut total = 0u32;
    let mut current_phase = None;

    for (name, phase) in &checkpoint.phases {
        total += 1;
        match phase.status.as_str() {
            "completed" | "skipped" => completed += 1,
            "in_progress" => current_phase = Some(name.clone()),
            _ => {}
        }
    }

    let progress = if total > 0 { Some((completed, total)) } else { None };

    (current_phase, checkpoint.pr_url.clone(), progress)
}
