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

/// A tmux pane entry from `tmux list-panes -a`.
#[derive(Debug, Clone)]
struct TmuxPaneEntry {
    pane_pid: u32,
    session_name: String,
}

/// Session enrichment info (from sysinfo + filesystem).
#[derive(Debug, Clone)]
pub struct SessionInfo {
    /// Process start time (unix epoch seconds).
    pub start_time: u64,
    /// Working directory of the Claude Code process.
    pub cwd: String,
    /// Number of MCP server child processes.
    pub mcp_count: u32,
    /// Number of teammates (from team config).
    pub teammate_count: u32,
}

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
    /// Session enrichment (started, cwd, mcp, teammates).
    pub session_info: Option<SessionInfo>,
}

/// Scan for active arc sessions in the project directory.
///
/// Reads <cwd>/.claude/arc-phase-loop.local.md (single source of truth),
/// then matches config_dir from loop state to find the correct ConfigDir entry.
/// Uses sysinfo for session enrichment (started, cwd, mcp, teammates).
pub fn scan_active_arcs(
    config_dirs: &[ConfigDir],
    cwd: &Path,
    sys: &sysinfo::System,
) -> Vec<ActiveArc> {
    let tmux_panes = list_all_tmux_panes();
    let mut active = Vec::new();

    // Read loop state from project dir (not config dirs)
    if let Some(loop_state) = monitor::read_arc_loop_state(cwd) {
        let pid_alive = is_pid_alive_check(&loop_state.owner_pid);
        let tmux_session = find_tmux_for_pid(&tmux_panes, &loop_state.owner_pid, sys);

        // Enrich with sysinfo (started, cwd, mcp, teammates)
        let session_info = enrich_session_info(
            &loop_state.owner_pid,
            &loop_state.config_dir,
            sys,
        );

        // Match config_dir from loop state to our known config dirs
        let config_dir = config_dirs
            .iter()
            .find(|c| c.path.to_string_lossy() == loop_state.config_dir)
            .cloned()
            .unwrap_or_else(|| ConfigDir {
                path: PathBuf::from(&loop_state.config_dir),
                label: loop_state.config_dir.clone(),
            });

        // Read checkpoint for phase info (relative to cwd)
        let checkpoint_path = if loop_state.checkpoint_path.starts_with('/') {
            PathBuf::from(&loop_state.checkpoint_path)
        } else {
            cwd.join(&loop_state.checkpoint_path)
        };

        let (current_phase, pr_url, phase_progress) =
            read_checkpoint_summary(&checkpoint_path);

        active.push(ActiveArc {
            config_dir,
            loop_state,
            pid_alive,
            tmux_session,
            current_phase,
            pr_url,
            phase_progress,
            session_info,
        });
    }

    // Also scan for orphan tmux sessions (rune-* sessions without a loop state)
    let rune_sessions: Vec<&TmuxPaneEntry> = tmux_panes
        .iter()
        .filter(|p| p.session_name.starts_with("rune-"))
        .collect();

    for pane in &rune_sessions {
        let already_matched = active.iter().any(|a| {
            a.tmux_session.as_deref() == Some(pane.session_name.as_str())
        });
        if !already_matched {
            // Check if this tmux pane has a Claude Code child process
            if let Some(claude_pid) = crate::tmux::Tmux::get_claude_pid(pane.pane_pid) {
                let session_info = enrich_session_info(
                    &claude_pid.to_string(),
                    "",
                    sys,
                );
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
                        owner_pid: claude_pid.to_string(),
                        session_id: String::new(),
                        branch: String::new(),
                        iteration: 0,
                        max_iterations: 0,
                    },
                    pid_alive: true,
                    tmux_session: Some(pane.session_name.clone()),
                    current_phase: None,
                    pr_url: None,
                    phase_progress: None,
                    session_info,
                });
            }
        }
    }

    active
}

/// List ALL tmux panes across all sessions/windows (like melina).
/// Returns pane_pid + session_name for each pane.
fn list_all_tmux_panes() -> Vec<TmuxPaneEntry> {
    let output = Command::new("tmux")
        .args(["list-panes", "-a", "-F", "#{pane_pid}|#{session_name}"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter_map(|line| {
                    let parts: Vec<&str> = line.splitn(2, '|').collect();
                    if parts.len() != 2 {
                        return None;
                    }
                    Some(TmuxPaneEntry {
                        pane_pid: parts[0].parse().ok()?,
                        session_name: parts[1].to_string(),
                    })
                })
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

/// Find a tmux session that owns the given owner_pid.
///
/// Strategy (from melina): walk UP the parent chain from owner_pid via sysinfo.
/// If any ancestor matches a tmux pane_pid, that's our session.
/// Skips "claude-swarm-*" sessions (those are agent tmux, not user tmux).
fn find_tmux_for_pid(
    panes: &[TmuxPaneEntry],
    owner_pid: &str,
    sys: &sysinfo::System,
) -> Option<String> {
    use sysinfo::Pid;

    let target_pid: u32 = owner_pid.parse().ok()?;

    if panes.is_empty() {
        return None;
    }

    // Walk up from target_pid through parent chain (max 10 hops)
    let mut current = target_pid;
    let mut visited = std::collections::HashSet::new();
    for _ in 0..10 {
        if !visited.insert(current) {
            break; // cycle detected
        }

        // Check if current matches any tmux pane
        if let Some(entry) = panes.iter().find(|e| e.pane_pid == current) {
            // Skip claude-swarm panes (agent tmux, not user tmux)
            if entry.session_name.starts_with("claude-swarm") {
                return None;
            }
            return Some(entry.session_name.clone());
        }

        // Move to parent via sysinfo (faster than subprocess)
        let parent_pid = sys
            .process(Pid::from_u32(current))
            .and_then(|p| p.parent())
            .map(|p| p.as_u32());

        match parent_pid {
            Some(ppid) if ppid > 1 && ppid != current => current = ppid,
            _ => break,
        }
    }

    None
}

/// Enrich session info from sysinfo + filesystem.
/// Gathers: started_at, cwd, mcp_count, teammate_count.
pub fn enrich_session_info(
    owner_pid_str: &str,
    config_dir: &str,
    sys: &sysinfo::System,
) -> Option<SessionInfo> {
    use sysinfo::Pid;

    let pid: u32 = owner_pid_str.parse().ok()?;
    let root = sys.process(Pid::from_u32(pid))?;

    let start_time = root.start_time();
    let cwd = root.cwd().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();

    // Count MCP servers among child processes (name contains "mcp" or "server.py")
    let mut mcp_count = 0u32;
    let mut teammate_count = 0u32;

    let descendants = crate::resource::collect_descendants(sys, pid);
    for desc_pid in &descendants {
        if let Some(proc_) = sys.process(Pid::from_u32(*desc_pid)) {
            let cmd = proc_.cmd().iter().map(|s| s.to_string_lossy()).collect::<Vec<_>>().join(" ");
            if cmd.contains("server.py")
                || cmd.contains("/mcp/")
                || cmd.contains("mcp-server")
                || cmd.contains("mcp_server")
            {
                mcp_count += 1;
            }
        }
    }

    // Count teammates from team config (filesystem)
    if !config_dir.is_empty() {
        let teams_dir = Path::new(config_dir).join("teams");
        if let Ok(entries) = fs::read_dir(&teams_dir) {
            for entry in entries.flatten() {
                let config_path = entry.path().join("config.json");
                if let Ok(content) = fs::read_to_string(&config_path) {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                        if let Some(members) = val.get("members").and_then(|m| m.as_array()) {
                            teammate_count += members
                                .iter()
                                .filter(|m| {
                                    m.get("name")
                                        .and_then(|n| n.as_str())
                                        .map(|n| n != "team-lead")
                                        .unwrap_or(false)
                                })
                                .count() as u32;
                        }
                    }
                }
            }
        }
    }

    Some(SessionInfo {
        start_time,
        cwd,
        mcp_count,
        teammate_count,
    })
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
