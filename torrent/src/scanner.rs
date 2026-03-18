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
    /// Date extracted from frontmatter `date:` or filename pattern (YYYY-MM-DD).
    pub date: Option<String>,
}

/// Scan $HOME for Claude config directories, plus any extra custom paths.
///
/// Auto-discovered:
/// - ~/.claude/ (default)
/// - ~/.claude-*/ (custom accounts)
/// - $CLAUDE_CONFIG_DIR (if set and valid)
///
/// Extra paths from `--config-dir` / `-c` CLI arguments are also included.
///
/// Filters: must be a directory containing settings.json or projects/ subdirectory.
/// Deduplicates by canonical path.
pub fn scan_config_dirs(extra_dirs: &[PathBuf]) -> Result<Vec<ConfigDir>> {
    let home = dirs::home_dir().ok_or_else(|| eyre!("cannot resolve home directory"))?;
    let mut configs = Vec::new();
    let mut seen = std::collections::HashSet::new();

    // Helper: add a config dir if valid and not already seen.
    let mut try_add = |path: PathBuf, label: String| {
        let canonical = path.canonicalize().unwrap_or_else(|_| path.clone());
        if is_valid_config_dir(&path) && seen.insert(canonical) {
            configs.push(ConfigDir { path, label });
        }
    };

    // 1. Check ~/.claude/ (default)
    let default_dir = home.join(".claude");
    try_add(default_dir, ".claude (default)".into());

    // 2. Check ~/.claude-*/ (custom accounts)
    let home_str = home.to_string_lossy();
    let pattern = format!("{}/.claude-*/", home_str);
    for path in (glob(&pattern).map_err(|e| eyre!("invalid glob pattern: {e}"))?).flatten() {
        let label = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        try_add(path, label);
    }

    // 3. Check $CLAUDE_CONFIG_DIR env var
    if let Ok(env_dir) = std::env::var("CLAUDE_CONFIG_DIR") {
        if !env_dir.is_empty() {
            let path = resolve_path(&env_dir, &home);
            let label = format!("{} (env)", path.file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| env_dir.clone()));
            try_add(path, label);
        }
    }

    // 4. Extra dirs from --config-dir / -c CLI arguments
    for extra in extra_dirs {
        let path = if extra.is_absolute() {
            extra.clone()
        } else {
            resolve_path(&extra.to_string_lossy(), &home)
        };
        let label = format!("{} (custom)", path.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string()));
        try_add(path, label);
    }

    Ok(configs)
}

/// Resolve a path string, expanding `~` to the home directory.
fn resolve_path(raw: &str, home: &Path) -> PathBuf {
    if raw.starts_with('~') {
        PathBuf::from(raw.replacen('~', &home.to_string_lossy(), 1))
    } else {
        PathBuf::from(raw)
    }
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
                let (title, fm_date) = extract_plan_metadata(&path);
                let title = title.unwrap_or_else(|| name.clone());
                let date = fm_date.or_else(|| extract_date_from_filename(&name));
                plans.push(PlanFile { path, name, title, date });
            }
            _ => {}
        }
    }

    plans.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(plans)
}

/// Extract plan title and date from a markdown file with YAML frontmatter.
///
/// Priority for title:
/// 1. First markdown `# heading` OUTSIDE frontmatter and fenced code blocks
/// 2. `title:` field from YAML frontmatter
/// 3. None (caller falls back to filename)
///
/// Returns (title, date) where date comes from frontmatter `date:` field.
fn extract_plan_metadata(path: &Path) -> (Option<String>, Option<String>) {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return (None, None),
    };

    let mut fm_title: Option<String> = None;
    let mut fm_date: Option<String> = None;
    let mut in_frontmatter = false;
    let mut frontmatter_done = false;
    let mut in_code_block = false;
    let mut first_line = true;

    for line in content.lines() {
        let trimmed = line.trim();

        // Detect YAML frontmatter (must start on line 1)
        if first_line && trimmed == "---" {
            in_frontmatter = true;
            first_line = false;
            continue;
        }
        first_line = false;

        // End of frontmatter
        if in_frontmatter && trimmed == "---" {
            in_frontmatter = false;
            frontmatter_done = true;
            continue;
        }

        // Extract title/date from frontmatter
        if in_frontmatter {
            if let Some(val) = trimmed.strip_prefix("title:") {
                fm_title = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
            } else if let Some(val) = trimmed.strip_prefix("date:") {
                fm_date = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
            }
            continue;
        }

        // Skip content before frontmatter closes (shouldn't happen but guard)
        if !frontmatter_done && !in_frontmatter {
            // No frontmatter in this file — proceed normally
            frontmatter_done = true;
        }

        // Track fenced code blocks (``` or ~~~)
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_code_block = !in_code_block;
            continue;
        }

        // Only look for headings outside code blocks
        if !in_code_block {
            if let Some(heading) = trimmed.strip_prefix("# ") {
                let heading = heading.trim().to_string();
                if !heading.is_empty() {
                    return (Some(heading), fm_date);
                }
            }
        }
    }

    // No markdown heading found — fall back to frontmatter title
    (fm_title, fm_date)
}

/// Extract date (YYYY-MM-DD) from a plan filename like `2026-03-18-feat-xxx-plan.md`.
fn extract_date_from_filename(name: &str) -> Option<String> {
    if name.len() >= 10 {
        let prefix = &name[..10];
        // Validate pattern: DDDD-DD-DD
        let bytes = prefix.as_bytes();
        if bytes[4] == b'-' && bytes[7] == b'-'
            && bytes[..4].iter().all(|b| b.is_ascii_digit())
            && bytes[5..7].iter().all(|b| b.is_ascii_digit())
            && bytes[8..10].iter().all(|b| b.is_ascii_digit())
        {
            return Some(prefix.to_string());
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
/// Reads <cwd>/.rune/arc-phase-loop.local.md (single source of truth),
/// then matches config_dir from loop state to find the correct ConfigDir entry.
/// Uses sysinfo for session enrichment (started, cwd, mcp, teammates).
pub fn scan_active_arcs(
    config_dirs: &[ConfigDir],
    cwd: &Path,
    sys: &sysinfo::System,
) -> Vec<ActiveArc> {
    let tmux_panes = list_all_tmux_panes();
    let mut active = Vec::new();
    let cwd_canonical = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());

    // Read loop state from project dir (not config dirs)
    if let Some(loop_state) = monitor::read_arc_loop_state(cwd) {
        let pid_alive = is_pid_alive_check(&loop_state.owner_pid);

        if pid_alive || loop_state.owner_pid.is_empty() {
            // Happy path: original session is still running
            let tmux_session = find_tmux_for_pid(&tmux_panes, &loop_state.owner_pid, sys);

            let session_info = enrich_session_info(
                &loop_state.owner_pid,
                &loop_state.config_dir,
                sys,
            );

            let config_dir = config_dirs
                .iter()
                .find(|c| c.path.to_string_lossy() == loop_state.config_dir)
                .cloned()
                .unwrap_or_else(|| ConfigDir {
                    path: PathBuf::from(&loop_state.config_dir),
                    label: loop_state.config_dir.clone(),
                });

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
        } else {
            // Owner PID is dead — but a rune-* tmux session may have resumed
            // with a new Claude process. Try to adopt the state file instead
            // of discarding it as stale.
            let adopted = try_adopt_loop_state(
                &loop_state,
                &tmux_panes,
                config_dirs,
                cwd,
                &cwd_canonical,
                sys,
            );
            if let Some(arc) = adopted {
                active.push(arc);
            }
            // If no tmux session adopted it, skip — truly stale.
            // Rune's session-team-hygiene.sh will clean up on next SessionStart.
        }
    }

    // Also scan for orphan tmux sessions (rune-* sessions without a loop state).
    // Only include sessions whose Claude process CWD matches OUR cwd —
    // this prevents torrent in directory A from seeing torrent B's sessions.
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

                // Filter by CWD: only show orphan sessions running in the same directory.
                // If we can determine the session's CWD and it doesn't match ours, skip it.
                if let Some(ref info) = session_info {
                    if !info.cwd.is_empty() {
                        let session_cwd = Path::new(&info.cwd)
                            .canonicalize()
                            .unwrap_or_else(|_| PathBuf::from(&info.cwd));
                        if session_cwd != cwd_canonical {
                            continue; // Different directory — belongs to another torrent instance
                        }
                    }
                }

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

/// When the loop state's owner_pid is dead, try to find a rune-* tmux session
/// in the same CWD that can adopt the state file. This handles the common
/// "session resumed" scenario where Claude restarts with a new PID in the
/// same tmux session.
fn try_adopt_loop_state(
    loop_state: &monitor::ArcLoopState,
    tmux_panes: &[TmuxPaneEntry],
    config_dirs: &[ConfigDir],
    cwd: &Path,
    cwd_canonical: &Path,
    sys: &sysinfo::System,
) -> Option<ActiveArc> {
    let rune_panes: Vec<&TmuxPaneEntry> = tmux_panes
        .iter()
        .filter(|p| p.session_name.starts_with("rune-"))
        .collect();

    for pane in &rune_panes {
        let claude_pid = crate::tmux::Tmux::get_claude_pid(pane.pane_pid)?;
        let pid_str = claude_pid.to_string();

        let session_info = enrich_session_info(&pid_str, &loop_state.config_dir, sys);

        // Verify the tmux session is running in the same directory
        if let Some(ref info) = session_info {
            if !info.cwd.is_empty() {
                let session_cwd = Path::new(&info.cwd)
                    .canonicalize()
                    .unwrap_or_else(|_| PathBuf::from(&info.cwd));
                if session_cwd != *cwd_canonical {
                    continue; // Different directory — not our session
                }
            }
        }

        // Found a matching tmux session — adopt the loop state with the new PID
        let config_dir = config_dirs
            .iter()
            .find(|c| c.path.to_string_lossy() == loop_state.config_dir)
            .cloned()
            .unwrap_or_else(|| ConfigDir {
                path: PathBuf::from(&loop_state.config_dir),
                label: loop_state.config_dir.clone(),
            });

        let checkpoint_path = if loop_state.checkpoint_path.starts_with('/') {
            PathBuf::from(&loop_state.checkpoint_path)
        } else {
            cwd.join(&loop_state.checkpoint_path)
        };

        let (current_phase, pr_url, phase_progress) =
            read_checkpoint_summary(&checkpoint_path);

        // Build an adopted loop state with the new PID but original checkpoint info
        let adopted_state = monitor::ArcLoopState {
            active: loop_state.active,
            checkpoint_path: loop_state.checkpoint_path.clone(),
            plan_file: loop_state.plan_file.clone(),
            config_dir: loop_state.config_dir.clone(),
            owner_pid: pid_str,
            session_id: loop_state.session_id.clone(),
            branch: loop_state.branch.clone(),
            iteration: loop_state.iteration,
            max_iterations: loop_state.max_iterations,
        };

        return Some(ActiveArc {
            config_dir,
            loop_state: adopted_state,
            pid_alive: true,
            tmux_session: Some(pane.session_name.clone()),
            current_phase,
            pr_url,
            phase_progress,
            session_info,
        });
    }

    None // No tmux session found to adopt — truly stale
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

/// Check if a PID is alive (delegates to shared resource::is_pid_alive).
fn is_pid_alive_check(pid_str: &str) -> bool {
    pid_str.parse::<u32>().is_ok_and(crate::resource::is_pid_alive)
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
            let is_mcp = proc_.cmd().iter().any(|s| {
                let arg = s.to_string_lossy();
                arg.contains("server.py")
                    || arg.contains("/mcp/")
                    || arg.contains("mcp-server")
                    || arg.contains("mcp_server")
            });
            if is_mcp {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    // ── is_valid_config_dir ─────────────────────────────────

    #[test]
    fn test_valid_config_dir_with_settings() {
        let dir = std::env::temp_dir().join("torrent-test-config-valid-settings");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("settings.json"), "{}").unwrap();

        assert!(is_valid_config_dir(&dir));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_valid_config_dir_with_projects() {
        let dir = std::env::temp_dir().join("torrent-test-config-valid-projects");
        fs::create_dir_all(dir.join("projects")).unwrap();

        assert!(is_valid_config_dir(&dir));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_invalid_config_dir_empty() {
        let dir = std::env::temp_dir().join("torrent-test-config-invalid-empty");
        fs::create_dir_all(&dir).unwrap();

        assert!(!is_valid_config_dir(&dir));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_invalid_config_dir_nonexistent() {
        let dir = std::env::temp_dir().join("torrent-test-config-nonexistent-xyz");
        assert!(!is_valid_config_dir(&dir));
    }

    // ── extract_date_from_filename ──────────────────────────

    #[test]
    fn test_date_extraction_standard() {
        assert_eq!(
            extract_date_from_filename("2026-03-18-feat-auth-plan.md"),
            Some("2026-03-18".into())
        );
    }

    #[test]
    fn test_date_extraction_short_name() {
        assert_eq!(
            extract_date_from_filename("2026-03-18.md"),
            Some("2026-03-18".into())
        );
    }

    #[test]
    fn test_date_extraction_no_date() {
        assert_eq!(extract_date_from_filename("feat-auth-plan.md"), None);
    }

    #[test]
    fn test_date_extraction_too_short() {
        assert_eq!(extract_date_from_filename("2026.md"), None);
    }

    #[test]
    fn test_date_extraction_invalid_separators() {
        assert_eq!(extract_date_from_filename("2026_03_18-plan.md"), None);
    }

    // ── extract_plan_metadata ───────────────────────────────

    #[test]
    fn test_metadata_heading_over_frontmatter_title() {
        let dir = std::env::temp_dir().join("torrent-test-meta-heading");
        fs::create_dir_all(&dir).unwrap();
        let plan = dir.join("plan.md");
        fs::write(&plan, "---\ntitle: FM Title\ndate: 2026-03-18\n---\n# Real Heading\n").unwrap();

        let (title, date) = extract_plan_metadata(&plan);
        assert_eq!(title, Some("Real Heading".into()));
        assert_eq!(date, Some("2026-03-18".into()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_metadata_frontmatter_only() {
        let dir = std::env::temp_dir().join("torrent-test-meta-fm-only");
        fs::create_dir_all(&dir).unwrap();
        let plan = dir.join("plan.md");
        fs::write(&plan, "---\ntitle: FM Title\n---\nNo heading here.\n").unwrap();

        let (title, _) = extract_plan_metadata(&plan);
        assert_eq!(title, Some("FM Title".into()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_metadata_no_frontmatter() {
        let dir = std::env::temp_dir().join("torrent-test-meta-no-fm");
        fs::create_dir_all(&dir).unwrap();
        let plan = dir.join("plan.md");
        fs::write(&plan, "# Just a Heading\nSome content.\n").unwrap();

        let (title, date) = extract_plan_metadata(&plan);
        assert_eq!(title, Some("Just a Heading".into()));
        assert_eq!(date, None);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_metadata_heading_in_code_block_ignored() {
        let dir = std::env::temp_dir().join("torrent-test-meta-codeblock");
        fs::create_dir_all(&dir).unwrap();
        let plan = dir.join("plan.md");
        fs::write(
            &plan,
            "---\ntitle: FM Title\n---\n```\n# Fake Heading\n```\n# Real Heading\n",
        )
        .unwrap();

        let (title, _) = extract_plan_metadata(&plan);
        assert_eq!(title, Some("Real Heading".into()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_metadata_quoted_title() {
        let dir = std::env::temp_dir().join("torrent-test-meta-quoted");
        fs::create_dir_all(&dir).unwrap();
        let plan = dir.join("plan.md");
        fs::write(&plan, "---\ntitle: \"Quoted Title\"\n---\nNo heading.\n").unwrap();

        let (title, _) = extract_plan_metadata(&plan);
        assert_eq!(title, Some("Quoted Title".into()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_metadata_nonexistent_file() {
        let (title, date) = extract_plan_metadata(Path::new("/nonexistent/plan.md"));
        assert_eq!(title, None);
        assert_eq!(date, None);
    }

    // ── scan_plans ──────────────────────────────────────────

    #[test]
    fn test_scan_plans_finds_md_files() {
        let dir = std::env::temp_dir().join("torrent-test-scan-plans");
        let plans_dir = dir.join("plans");
        fs::create_dir_all(&plans_dir).unwrap();

        fs::write(plans_dir.join("2026-03-18-feat-auth-plan.md"), "# Auth Plan\n").unwrap();
        fs::write(plans_dir.join("2026-03-17-fix-bug-plan.md"), "# Bug Fix\n").unwrap();
        fs::write(plans_dir.join("not-a-plan.txt"), "ignored").unwrap();

        let plans = scan_plans(&dir).unwrap();
        assert_eq!(plans.len(), 2);
        // Sorted by name
        assert_eq!(plans[0].name, "2026-03-17-fix-bug-plan.md");
        assert_eq!(plans[1].name, "2026-03-18-feat-auth-plan.md");
        assert_eq!(plans[0].date, Some("2026-03-17".into()));
        assert_eq!(plans[1].title, "Auth Plan");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_scan_plans_empty_dir() {
        let dir = std::env::temp_dir().join("torrent-test-scan-empty");
        fs::create_dir_all(dir.join("plans")).unwrap();

        let plans = scan_plans(&dir).unwrap();
        assert!(plans.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    // ── read_checkpoint_summary ─────────────────────────────

    #[test]
    fn test_checkpoint_summary_with_phases() {
        let dir = std::env::temp_dir().join("torrent-test-cp-summary");
        let arc_dir = dir.join(".rune").join("arc").join("arc-sum");
        fs::create_dir_all(&arc_dir).unwrap();

        let json = serde_json::json!({
            "id": "arc-sum",
            "plan_file": "plans/test.md",
            "phases": {
                "forge": {"status": "completed"},
                "work": {"status": "in_progress"},
                "ship": {"status": "pending"},
                "gap_analysis": {"status": "skipped"}
            },
            "pr_url": "https://github.com/test/pull/42",
            "started_at": "2026-03-18T00:00:00Z"
        });
        let cp_path = arc_dir.join("checkpoint.json");
        fs::write(&cp_path, json.to_string()).unwrap();

        let (phase, pr_url, progress) = read_checkpoint_summary(&cp_path);
        assert_eq!(phase, Some("work".into()));
        assert_eq!(pr_url, Some("https://github.com/test/pull/42".into()));
        // completed(1) + skipped(1) = 2 out of 4 total
        assert_eq!(progress, Some((2, 4)));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_checkpoint_summary_no_phases() {
        let dir = std::env::temp_dir().join("torrent-test-cp-nophase");
        fs::create_dir_all(&dir).unwrap();

        let json = serde_json::json!({
            "id": "arc-empty",
            "plan_file": "plans/test.md",
            "phases": {},
            "started_at": "2026-03-18T00:00:00Z"
        });
        let cp_path = dir.join("checkpoint.json");
        fs::write(&cp_path, json.to_string()).unwrap();

        let (phase, pr_url, progress) = read_checkpoint_summary(&cp_path);
        assert!(phase.is_none());
        assert!(pr_url.is_none());
        assert!(progress.is_none());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_checkpoint_summary_missing_file() {
        let (phase, pr_url, progress) =
            read_checkpoint_summary(Path::new("/nonexistent/checkpoint.json"));
        assert!(phase.is_none());
        assert!(pr_url.is_none());
        assert!(progress.is_none());
    }

    // ── resolve_path ───────────────────────────────────────────

    #[test]
    fn test_resolve_path_absolute() {
        let home = Path::new("/Users/test");
        let result = resolve_path("/opt/claude-ci", home);
        assert_eq!(result, PathBuf::from("/opt/claude-ci"));
    }

    #[test]
    fn test_resolve_path_tilde() {
        let home = Path::new("/Users/test");
        let result = resolve_path("~/.claude-work", home);
        assert_eq!(result, PathBuf::from("/Users/test/.claude-work"));
    }

    #[test]
    fn test_resolve_path_relative() {
        let home = Path::new("/Users/test");
        let result = resolve_path("configs/claude", home);
        assert_eq!(result, PathBuf::from("configs/claude"));
    }

    // ── scan_config_dirs with extra dirs ────────────────────────

    #[test]
    fn test_scan_config_dirs_with_extra_valid() {
        let dir = std::env::temp_dir().join("torrent-test-extra-config-valid");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("settings.json"), "{}").unwrap();

        let configs = scan_config_dirs(&[dir.clone()]).unwrap();
        let found = configs.iter().any(|c| c.path == dir && c.label.contains("(custom)"));
        assert!(found, "extra config dir should appear with (custom) label");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_scan_config_dirs_with_extra_invalid() {
        let dir = std::env::temp_dir().join("torrent-test-extra-config-invalid-xyz");
        // Don't create it — it's invalid

        let configs = scan_config_dirs(&[dir.clone()]).unwrap();
        let found = configs.iter().any(|c| c.path == dir);
        assert!(!found, "invalid extra dir should be silently skipped");
    }

    #[test]
    fn test_scan_config_dirs_deduplicates() {
        let dir = std::env::temp_dir().join("torrent-test-extra-dedup");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("settings.json"), "{}").unwrap();

        // Pass the same dir twice
        let configs = scan_config_dirs(&[dir.clone(), dir.clone()]).unwrap();
        let count = configs.iter().filter(|c| c.path == dir).count();
        assert_eq!(count, 1, "duplicate extra dirs should be deduplicated");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_scan_config_dirs_empty_extras() {
        // No extra dirs — should still work (backward compatible)
        let configs = scan_config_dirs(&[]).unwrap();
        // Just verify it doesn't crash; actual dirs depend on the host
        assert!(configs.len() >= 0);
    }
}
