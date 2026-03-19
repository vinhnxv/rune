use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use chrono::{DateTime, Utc};

use crate::checkpoint::{Checkpoint, Heartbeat};

/// Handle to a discovered arc instance. Links checkpoint + heartbeat paths.
#[derive(Debug, Clone)]
pub struct ArcHandle {
    pub arc_id: String,
    pub checkpoint_path: PathBuf,
    pub heartbeat_path: PathBuf,
    pub plan_file: String,
    pub config_dir: String,
    pub owner_pid: String,
    pub session_id: String,
}

// ── Arc Phase Loop State ───────────────────────────────────────

/// Parsed state from `.rune/arc-phase-loop.local.md` (YAML frontmatter).
///
/// This file is the primary source of truth for an active arc run.
/// It contains the checkpoint_path, owner_pid, and session_id — allowing
/// instant discovery without glob-scanning arc directories.
#[derive(Debug, Clone)]
#[allow(dead_code)] // fields stored for UI display and future use
pub struct ArcLoopState {
    pub active: bool,
    pub checkpoint_path: String,
    pub plan_file: String,
    pub config_dir: String,
    pub owner_pid: String,
    pub session_id: String,
    pub branch: String,
    pub iteration: u32,
    pub max_iterations: u32,
}

/// Parse `arc-phase-loop.local.md` from the project directory.
///
/// File location: `<project_dir>/.rune/arc-phase-loop.local.md`
/// Uses YAML frontmatter between `---` delimiters.
/// Returns `None` if the file doesn't exist, is not active, or can't be parsed.
pub fn read_arc_loop_state(project_dir: &Path) -> Option<ArcLoopState> {
    // Primary: .rune/ (v2.0.0+)
    let loop_file = project_dir.join(".rune").join("arc-phase-loop.local.md");
    // Legacy fallback: .claude/ (remove in v3.0.0 — RUNE_LEGACY_SUPPORT_UNTIL)
    let legacy_file = project_dir.join(".claude").join("arc-phase-loop.local.md");
    let contents = fs::read_to_string(&loop_file)
        .or_else(|_| fs::read_to_string(&legacy_file))
        .ok()?;

    // Extract YAML frontmatter between --- delimiters
    let yaml = extract_frontmatter(&contents)?;

    let active = parse_yaml_bool(&yaml, "active")?;
    if !active {
        return None;
    }

    Some(ArcLoopState {
        active,
        checkpoint_path: parse_yaml_str(&yaml, "checkpoint_path")?,
        plan_file: parse_yaml_str(&yaml, "plan_file")?,
        config_dir: parse_yaml_str(&yaml, "config_dir")?,
        owner_pid: parse_yaml_str(&yaml, "owner_pid")?,
        session_id: parse_yaml_str(&yaml, "session_id")?,
        branch: parse_yaml_str(&yaml, "branch").unwrap_or_default(),
        iteration: parse_yaml_str(&yaml, "iteration")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0),
        max_iterations: parse_yaml_str(&yaml, "max_iterations")
            .and_then(|s| s.parse().ok())
            .unwrap_or(50),
    })
}

/// Extract YAML frontmatter content between `---` markers.
fn extract_frontmatter(content: &str) -> Option<String> {
    let trimmed = content.trim();
    if !trimmed.starts_with("---") {
        return None;
    }
    let after_first = &trimmed[3..];
    let end = after_first.find("---")?;
    Some(after_first[..end].to_string())
}

/// Parse a simple `key: value` from YAML content.
fn parse_yaml_str(yaml: &str, key: &str) -> Option<String> {
    for line in yaml.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix(key) {
            if let Some(value) = rest.strip_prefix(':') {
                let val = value.trim();
                // Strip surrounding quotes if present
                let val = val.trim_matches('"').trim_matches('\'');
                if val.is_empty() || val == "null" {
                    return None;
                }
                return Some(val.to_string());
            }
        }
    }
    None
}

/// Parse a boolean `key: true/false` from YAML content.
fn parse_yaml_bool(yaml: &str, key: &str) -> Option<bool> {
    let val = parse_yaml_str(yaml, key)?;
    match val.as_str() {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// Activity state for a Claude Code session, combining multiple detection signals.
///
/// Multi-signal detection: heartbeat freshness, pane output hash, CPU activity,
/// and input prompt patterns. This is INFORMATIONAL ONLY — does not trigger
/// any kill or restart action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityState {
    /// Heartbeat fresh + pane changing + CPU active.
    Active,
    /// Heartbeat fresh but pane output unchanged for 1 cycle.
    Slow,
    /// Heartbeat stale (>5min) but pane or CPU still showing activity.
    Stale,
    /// Heartbeat stale + pane frozen (2+ cycles) + low CPU (<1%).
    Idle,
    /// Claude Code process not found (crashed or exited).
    Stopped,
    /// Input prompt pattern detected in pane output.
    WaitingInput,
}

impl ActivityState {
    /// Short label for logging and serialization.
    pub fn label(&self) -> &'static str {
        match self {
            ActivityState::Active => "active",
            ActivityState::Slow => "slow",
            ActivityState::Stale => "stale",
            ActivityState::Idle => "idle",
            ActivityState::Stopped => "stopped",
            ActivityState::WaitingInput => "waiting-input",
        }
    }

    /// Icon for TUI display.
    pub fn icon(&self) -> &'static str {
        match self {
            ActivityState::Active => "●",
            ActivityState::Slow => "◐",
            ActivityState::Stale => "◑",
            ActivityState::Idle => "○",
            ActivityState::Stopped => "✗",
            ActivityState::WaitingInput => "?",
        }
    }
}

/// Tracks pane output changes over time for activity detection.
///
/// Stored inside the per-arc run state. Polling interval: 30 seconds.
/// Uses hash comparison (not content diff) to minimize memory usage.
#[derive(Debug)]
pub struct ActivityDetector {
    /// Hash of the last captured pane output.
    last_pane_hash: Option<u64>,
    /// Number of consecutive polls where pane hash was unchanged.
    pub hash_unchanged_count: u32,
    /// Timestamp of last hash check (for interval enforcement).
    last_hash_check: Option<Instant>,
    /// Check interval (30 seconds default).
    check_interval: std::time::Duration,
}

/// Well-known input prompt patterns (checked via simple string matching).
const PROMPT_INDICATORS: &[&str] = &["$ ", "% ", "# ", "> ", "❯ ", "› ", "? (y/n)", "? (yes/no)", "Allow", "Deny", "approve", "Enter "];

impl ActivityDetector {
    /// Create a new detector with default 30-second check interval.
    pub fn new() -> Self {
        Self {
            last_pane_hash: None,
            hash_unchanged_count: 0,
            last_hash_check: None,
            check_interval: std::time::Duration::from_secs(30),
        }
    }

    /// Check if it's time for a new pane capture based on the check interval.
    pub fn should_check(&self) -> bool {
        self.last_hash_check
            .map(|t| t.elapsed() >= self.check_interval)
            .unwrap_or(true) // First check: always
    }

    /// Update pane hash state after a capture. Returns whether the hash changed.
    pub fn update_hash(&mut self, new_hash: Option<u64>) -> bool {
        self.last_hash_check = Some(Instant::now());
        match (self.last_pane_hash, new_hash) {
            (None, Some(h)) => {
                // First capture — establish baseline, don't count as unchanged
                self.last_pane_hash = Some(h);
                self.hash_unchanged_count = 0;
                true // "changed" from no baseline to baseline
            }
            (Some(old), Some(new)) if old == new => {
                self.hash_unchanged_count += 1;
                false
            }
            (Some(_), Some(new)) => {
                self.last_pane_hash = Some(new);
                self.hash_unchanged_count = 0;
                true
            }
            (_, None) => {
                // Capture failed — don't update hash, increment unchanged as conservative
                self.hash_unchanged_count += 1;
                false
            }
        }
    }

    /// Detect activity state from combined signals.
    ///
    /// Decision matrix (from plan):
    /// | Heartbeat | Pane Hash | CPU | → State |
    /// |-----------|-----------|-----|---------|
    /// | Fresh | Changing | Any | Active |
    /// | Fresh | Unchanged(1) | ≥1% | Slow |
    /// | Stale | Changing | Any | Stale |
    /// | Stale | Unchanged(2+) | ≥1% | Stale |
    /// | Stale | Unchanged(2+) | <1% | Idle |
    /// | N/A | N/A | NotFound | Stopped |
    /// | Any | Prompt match | Any | WaitingInput |
    pub fn detect(
        &self,
        heartbeat_stale: bool,
        cpu_percent: Option<f32>,
        process_found: bool,
        last_line: Option<&str>,
    ) -> ActivityState {
        // Stopped: process not found
        if !process_found {
            return ActivityState::Stopped;
        }

        // WaitingInput: prompt pattern detected in last pane line
        if let Some(line) = last_line {
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                for pattern in PROMPT_INDICATORS {
                    if trimmed.contains(pattern) || trimmed.ends_with(pattern.trim()) {
                        return ActivityState::WaitingInput;
                    }
                }
            }
        }

        let cpu = cpu_percent.unwrap_or(0.0);
        let pane_changing = self.hash_unchanged_count == 0;
        let pane_unchanged_long = self.hash_unchanged_count >= 2;

        if heartbeat_stale {
            if pane_changing {
                ActivityState::Stale
            } else if pane_unchanged_long && cpu < 1.0 {
                ActivityState::Idle
            } else {
                // Stale heartbeat + some CPU activity or short unchanged → Stale
                ActivityState::Stale
            }
        } else {
            // Fresh heartbeat
            if pane_changing {
                ActivityState::Active
            } else {
                // Pane unchanged but heartbeat fresh
                if cpu >= 1.0 {
                    ActivityState::Slow
                } else {
                    ActivityState::Active // Fresh heartbeat + low CPU = probably just waiting for API
                }
            }
        }
    }
}

/// Polled status of a running arc.
#[derive(Debug, Clone)]
pub struct ArcStatus {
    pub arc_id: String,
    pub current_phase: String,
    pub last_tool: String,
    pub last_activity: Option<DateTime<Utc>>,
    pub phase_summary: PhaseSummary,
    pub phase_nav: Option<PhaseNavigation>,
    pub pr_url: Option<String>,
    pub is_stale: bool,
    pub completion: Option<ArcCompletion>,
    /// Schema version warning — None if compatible, Some(msg) if outside tested range.
    pub schema_warning: Option<String>,
    /// Activity state from multi-signal detection (None if detector not initialized).
    pub activity_state: Option<ActivityState>,
}

/// Summary of phase progress derived from checkpoint.json.
#[derive(Debug, Clone)]
pub struct PhaseSummary {
    pub completed: u32,
    pub total: u32,
    pub skipped: u32,
    pub current_phase_name: String,
}

/// Previous / current / next phase with timing info.
#[derive(Debug, Clone)]
pub struct PhaseNavigation {
    /// Previous completed phase name + duration.
    pub prev: Option<PhaseInfo>,
    /// Current in-progress phase name + elapsed time since started.
    pub current: Option<PhaseInfo>,
    /// Next pending phase name.
    pub next: Option<String>,
}

/// Info about a single phase: name + duration or elapsed.
#[derive(Debug, Clone)]
pub struct PhaseInfo {
    pub name: String,
    /// For completed: duration in seconds. For in_progress: elapsed since started_at.
    pub duration_secs: Option<i64>,
}

/// Canonical arc phase execution order.
/// Source: plugins/rune/skills/arc/references/arc-phase-constants.md
const PHASE_ORDER: &[&str] = &[
    "forge",
    "plan_review",
    "plan_refine",
    "verification",
    "semantic_verification",
    "design_extraction",
    "design_prototype",
    "task_decomposition",
    "work",
    "drift_review",
    "storybook_verification",
    "design_verification",
    "ux_verification",
    "gap_analysis",
    "codex_gap_analysis",
    "gap_remediation",
    "goldmask_verification",
    "code_review",
    "goldmask_correlation",
    "mend",
    "verify_mend",
    "design_iteration",
    "test",
    "test_coverage_critique",
    "deploy_verify",
    "pre_ship_validation",
    "release_quality_check",
    "ship",
    "bot_review_wait",
    "pr_comment_resolution",
    "merge",
];

/// Terminal states for an arc run.
#[derive(Debug, Clone)]
pub enum ArcCompletion {
    Merged,
    Shipped,
    Cancelled,
    Failed,
}

/// Discover a running arc by reading `<cwd>/.rune/arc-phase-loop.local.md`.
///
/// All arc state files live in the PROJECT directory:
///   - `<cwd>/.rune/arc-phase-loop.local.md`
///   - `<cwd>/.rune/arc/arc-*/checkpoint.json`
///   - `<cwd>/tmp/arc/arc-*/heartbeat.json`
///
/// config_dir is only for starting Claude Code, not for file paths.
pub fn discover_arc(
    cwd: &Path,
    plan_path: &Path,
    _launched_after: DateTime<Utc>,
    _expected_config_dir: Option<&str>,
    expected_claude_pid: Option<u32>,
) -> Option<ArcHandle> {
    let state = read_arc_loop_state(cwd)?;

    // Validate plan_file matches (normalize both to "plans/..." form)
    let plan_str = plan_path.display().to_string();
    let plan_relative = extract_plans_relative(&plan_str);
    let state_relative = extract_plans_relative(&state.plan_file);
    if plan_relative != state_relative {
        return None;
    }

    // Validate owner_pid if we have expected PID
    if let Some(expected_pid) = expected_claude_pid {
        if let Ok(state_pid) = state.owner_pid.parse::<u32>() {
            if state_pid != expected_pid {
                return None;
            }
        }
    }

    // Resolve checkpoint_path relative to cwd (all arc files are project-relative)
    let checkpoint_path = if state.checkpoint_path.starts_with('/') {
        PathBuf::from(&state.checkpoint_path)
    } else {
        cwd.join(&state.checkpoint_path)
    };

    // Verify checkpoint file exists
    if !checkpoint_path.exists() {
        return None;
    }

    // Read checkpoint to get arc_id
    let checkpoint = read_checkpoint(&checkpoint_path)?;
    let arc_id = checkpoint.id.clone();
    let heartbeat_path = cwd.join("tmp").join("arc").join(&arc_id).join("heartbeat.json");

    Some(ArcHandle {
        arc_id,
        checkpoint_path,
        heartbeat_path,
        plan_file: state.plan_file,
        config_dir: state.config_dir,
        owner_pid: state.owner_pid,
        session_id: state.session_id,
    })
}

/// Resolve a checkpoint_path from arc-phase-loop.local.md to an absolute path.
///
/// The checkpoint_path in the loop state file can be:
/// Extract the "plans/..." relative portion from a path string.
fn extract_plans_relative(path: &str) -> &str {
    if let Some(idx) = path.find("plans/") {
        &path[idx..]
    } else {
        path
    }
}

/// Try to parse and match a single checkpoint file against our criteria.
/// Strict 4-field matching: plan_file + config_dir + owner_pid + started_at.
/// Note: glob-based discovery was removed in favor of .rune/arc-phase-loop.local.md.
/// This function is retained for tests that validate checkpoint matching logic.
#[cfg(test)]
fn try_match_checkpoint(
    checkpoint_path: &Path,
    cwd: &Path,
    plan_path: &Path,
    launched_after: DateTime<Utc>,
    expected_config_dir: Option<&str>,
    expected_claude_pid: Option<u32>,
) -> Option<ArcHandle> {
    let contents = fs::read_to_string(checkpoint_path).ok()?;
    let checkpoint: Checkpoint = serde_json::from_str(&contents).ok()?;

    // 1. plan_file matches (normalize to relative "plans/..." form)
    let plan_str = plan_path.display().to_string();
    let plan_relative = extract_plans_relative(&plan_str);
    let checkpoint_relative = extract_plans_relative(&checkpoint.plan_file);
    if checkpoint_relative != plan_relative {
        return None;
    }

    // 2. config_dir matches (strict when both sides have a value)
    if let Some(expected) = expected_config_dir {
        if !checkpoint.config_dir.is_empty() && checkpoint.config_dir != expected {
            return None;
        }
    }

    // 3. owner_pid matches our Claude Code PID (strict when available)
    if let Some(expected_pid) = expected_claude_pid {
        if !checkpoint.owner_pid.is_empty() {
            if let Ok(cp) = checkpoint.owner_pid.parse::<u32>() {
                if cp != expected_pid {
                    return None;
                }
            }
        }
    }

    // 4. started_at is AFTER our launch time
    let started_at = DateTime::parse_from_rfc3339(&checkpoint.started_at).ok()?;
    if started_at.with_timezone(&Utc) <= launched_after {
        return None;
    }

    let arc_id = checkpoint.id.clone();
    let heartbeat_path = cwd.join("tmp").join("arc").join(&arc_id).join("heartbeat.json");

    Some(ArcHandle {
        arc_id,
        checkpoint_path: checkpoint_path.to_owned(),
        heartbeat_path,
        plan_file: checkpoint.plan_file,
        config_dir: checkpoint.config_dir,
        owner_pid: checkpoint.owner_pid,
        session_id: checkpoint.session_id,
    })
}

/// Poll the current status of a discovered arc.
///
/// Reads both checkpoint (phase progress) and heartbeat (liveness).
/// Returns `None` if the checkpoint file is missing/unreadable.
pub fn poll_arc_status(handle: &ArcHandle) -> Option<ArcStatus> {
    let checkpoint = read_checkpoint(&handle.checkpoint_path)?;
    let heartbeat = read_heartbeat(&handle.heartbeat_path);

    let schema_warning = checkpoint.schema_compat().warning();
    let phase_summary = compute_phase_summary(&checkpoint);
    let phase_nav = compute_phase_navigation(&checkpoint);
    let completion = check_completion(&checkpoint);

    let (current_phase, last_tool, last_activity, is_stale) = match &heartbeat {
        Some(hb) => {
            let activity = DateTime::parse_from_rfc3339(&hb.last_activity)
                .ok()
                .map(|dt| dt.with_timezone(&Utc));
            let stale = activity
                .map(|a| Utc::now().signed_duration_since(a).num_seconds() > 300)
                .unwrap_or(true);
            (
                hb.phase.clone(),
                hb.last_tool.clone(),
                activity,
                stale,
            )
        }
        None => (
            phase_summary.current_phase_name.clone(),
            String::new(),
            None,
            false, // No heartbeat yet — not stale, just undiscovered
        ),
    };

    Some(ArcStatus {
        arc_id: handle.arc_id.clone(),
        current_phase,
        last_tool,
        last_activity,
        phase_summary,
        phase_nav,
        pr_url: checkpoint.pr_url,
        is_stale,
        completion,
        schema_warning,
        activity_state: None, // Set by caller (app.rs) which owns the ActivityDetector
    })
}

/// Check if the arc has reached a terminal state.
fn check_completion(checkpoint: &Checkpoint) -> Option<ArcCompletion> {
    // Check merge phase
    if let Some(merge) = checkpoint.phases.get("merge") {
        if merge.status == "completed" {
            return Some(ArcCompletion::Merged);
        }
    }

    // Check ship phase (shipped without merge — e.g. PR created but not merged)
    if let Some(ship) = checkpoint.phases.get("ship") {
        if ship.status == "completed" {
            // Only "shipped" if merge hasn't started
            let merge_pending = checkpoint
                .phases
                .get("merge")
                .map(|m| m.status == "pending" || m.status.is_empty())
                .unwrap_or(true);
            if merge_pending {
                return Some(ArcCompletion::Shipped);
            }
        }
    }

    // Check for cancelled/failed — any phase with "cancelled" or "failed" status
    for phase in checkpoint.phases.values() {
        if phase.status == "cancelled" {
            return Some(ArcCompletion::Cancelled);
        }
        if phase.status == "failed" {
            return Some(ArcCompletion::Failed);
        }
    }

    None
}

/// Compute previous/current/next phase navigation with timing.
///
/// Returns meaningful navigation even between phase transitions:
/// - If a phase is in_progress → standard prev/current/next
/// - If no in_progress but phases completed → shows last completed as prev, next pending as next
/// - If all pending → shows first pending as next
fn compute_phase_navigation(checkpoint: &Checkpoint) -> Option<PhaseNavigation> {
    // Find current phase index in canonical order
    let current_name = checkpoint.phases.iter()
        .find(|(_, p)| p.status == "in_progress")
        .map(|(name, _)| name.clone());

    let current_idx = current_name.as_ref().and_then(|name| {
        PHASE_ORDER.iter().position(|&p| p == name)
    });

    // Build current phase info with elapsed time
    let current = current_name.as_ref().and_then(|name| {
        let phase = checkpoint.phases.get(name)?;
        let duration_secs = phase.started_at.as_ref().and_then(|started| {
            DateTime::parse_from_rfc3339(started).ok().map(|dt| {
                Utc::now().signed_duration_since(dt.with_timezone(&Utc)).num_seconds()
            })
        });
        Some(PhaseInfo {
            name: name.clone(),
            duration_secs,
        })
    });

    if let Some(ci) = current_idx {
        // Standard case: a phase is in_progress
        let prev = {
            let mut found = None;
            for i in (0..ci).rev() {
                let phase_name = PHASE_ORDER[i];
                if let Some(phase) = checkpoint.phases.get(phase_name) {
                    if phase.status == "completed" {
                        let duration_secs = compute_phase_duration(phase);
                        found = Some(PhaseInfo {
                            name: phase_name.to_string(),
                            duration_secs,
                        });
                        break;
                    }
                }
            }
            found
        };

        let next = PHASE_ORDER.iter().skip(ci + 1)
            .find(|&&p| {
                checkpoint.phases.get(p).is_some_and(|ph| ph.status == "pending" || ph.status.is_empty())
            })
            .map(|&p| p.to_string());

        Some(PhaseNavigation { prev, current, next })
    } else {
        // No in_progress phase — transitioning between phases or not yet started
        let last_completed_idx = PHASE_ORDER.iter().rposition(|&p| {
            checkpoint.phases.get(p).is_some_and(|ph| ph.status == "completed")
        });

        let prev = last_completed_idx.and_then(|idx| {
            let phase_name = PHASE_ORDER[idx];
            let phase = checkpoint.phases.get(phase_name)?;
            let duration_secs = compute_phase_duration(phase);
            Some(PhaseInfo {
                name: phase_name.to_string(),
                duration_secs,
            })
        });

        // Find first pending phase after last completed (or from start if none completed)
        let search_start = last_completed_idx.map_or(0, |i| i + 1);
        let next = PHASE_ORDER.iter().skip(search_start)
            .find(|&&p| {
                checkpoint.phases.get(p).is_some_and(|ph| ph.status == "pending" || ph.status.is_empty())
            })
            .map(|&p| p.to_string());

        // Only return if we have something meaningful to show
        if prev.is_some() || next.is_some() {
            Some(PhaseNavigation { prev, current: None, next })
        } else {
            None
        }
    }
}

/// Compute duration of a completed phase from started_at and completed_at.
fn compute_phase_duration(phase: &crate::checkpoint::PhaseStatus) -> Option<i64> {
    let started = phase.started_at.as_ref()?;
    let completed = phase.completed_at.as_ref()?;
    let start = DateTime::parse_from_rfc3339(started).ok()?;
    let end = DateTime::parse_from_rfc3339(completed).ok()?;
    Some(end.signed_duration_since(start).num_seconds())
}

/// Compute a summary of phase progress from checkpoint data.
fn compute_phase_summary(checkpoint: &Checkpoint) -> PhaseSummary {
    let mut completed = 0u32;
    let mut skipped = 0u32;
    let mut in_progress_name: Option<String> = None;

    for (name, phase) in &checkpoint.phases {
        match phase.status.as_str() {
            "completed" => completed += 1,
            "skipped" => skipped += 1,
            "in_progress" => in_progress_name = Some(name.clone()),
            _ => {}
        }
    }

    let total = checkpoint.phases.len() as u32;

    // Determine current phase name with smart fallback:
    // 1. If a phase is in_progress → use it
    // 2. If phases completed but none in_progress → transitioning to next pending
    // 3. If no phases completed → waiting for first phase
    let current_phase_name = if let Some(name) = in_progress_name {
        name
    } else if completed > 0 {
        // Find last completed phase in canonical order, then next pending
        let last_completed_idx = PHASE_ORDER.iter().rposition(|&p| {
            checkpoint.phases.get(p).is_some_and(|ph| ph.status == "completed")
        });
        if let Some(idx) = last_completed_idx {
            // Look for the next pending phase after last completed
            PHASE_ORDER.iter().skip(idx + 1)
                .find(|&&p| {
                    checkpoint.phases.get(p).is_some_and(|ph| ph.status == "pending" || ph.status.is_empty())
                })
                .map(|&p| format!("→ {}", p))
                .unwrap_or_else(|| format!("{} ✓", PHASE_ORDER[idx]))
        } else {
            "pending".to_string()
        }
    } else {
        // No completed phases — find first pending in canonical order
        PHASE_ORDER.iter()
            .find(|&&p| {
                checkpoint.phases.get(p).is_some_and(|ph| ph.status == "pending" || ph.status.is_empty())
            })
            .map(|&p| format!("→ {}", p))
            .unwrap_or_else(|| "pending".to_string())
    };

    PhaseSummary {
        completed,
        total,
        skipped,
        current_phase_name,
    }
}

/// Read and parse checkpoint.json, returning None on any error.
fn read_checkpoint(path: &Path) -> Option<Checkpoint> {
    let contents = fs::read_to_string(path).ok()?;
    serde_json::from_str(&contents).ok()
}

/// Read and parse heartbeat.json, returning None if missing or unreadable.
fn read_heartbeat(path: &Path) -> Option<Heartbeat> {
    let contents = fs::read_to_string(path).ok()?;
    serde_json::from_str(&contents).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_check_completion_merged() {
        let mut phases = std::collections::HashMap::new();
        phases.insert(
            "merge".to_string(),
            crate::checkpoint::PhaseStatus {
                status: "completed".to_string(),
                started_at: None,
                completed_at: None,
                team_name: None,
            },
        );
        let checkpoint = Checkpoint {
            id: "arc-123".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: Some("https://github.com/test/pull/1".into()),
            commits: vec![],
            started_at: "2026-03-16T20:00:00Z".into(),
        };

        match check_completion(&checkpoint) {
            Some(ArcCompletion::Merged) => {}
            other => panic!("expected Merged, got {other:?}"),
        }
    }

    #[test]
    fn test_check_completion_none_when_in_progress() {
        let mut phases = std::collections::HashMap::new();
        phases.insert(
            "work".to_string(),
            crate::checkpoint::PhaseStatus {
                status: "in_progress".to_string(),
                started_at: None,
                completed_at: None,
                team_name: None,
            },
        );
        let checkpoint = Checkpoint {
            id: "arc-456".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-16T20:00:00Z".into(),
        };

        assert!(check_completion(&checkpoint).is_none());
    }

    #[test]
    fn test_compute_phase_summary() {
        let mut phases = std::collections::HashMap::new();
        for name in ["forge", "plan-review", "work"] {
            phases.insert(
                name.to_string(),
                crate::checkpoint::PhaseStatus {
                    status: "completed".to_string(),
                    started_at: None,
                    completed_at: None,
                    team_name: None,
                },
            );
        }
        phases.insert(
            "code_review".to_string(),
            crate::checkpoint::PhaseStatus {
                status: "in_progress".to_string(),
                started_at: None,
                completed_at: None,
                team_name: None,
            },
        );
        phases.insert(
            "ship".to_string(),
            crate::checkpoint::PhaseStatus {
                status: "pending".to_string(),
                started_at: None,
                completed_at: None,
                team_name: None,
            },
        );

        let checkpoint = Checkpoint {
            id: "arc-789".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-16T20:00:00Z".into(),
        };

        let summary = compute_phase_summary(&checkpoint);
        assert_eq!(summary.completed, 3);
        assert_eq!(summary.total, 5);
        assert_eq!(summary.skipped, 0);
        assert_eq!(summary.current_phase_name, "code_review");
    }

    #[test]
    fn test_try_match_rejects_wrong_owner_pid() {
        // Create a temp checkpoint file with owner_pid = "12345"
        let dir = std::env::temp_dir().join("torrent-test-pid-match");
        let arc_dir = dir.join(".rune").join("arc").join("arc-test");
        std::fs::create_dir_all(&arc_dir).unwrap();

        let checkpoint_json = serde_json::json!({
            "id": "arc-test",
            "plan_file": "plans/test-plan.md",
            "config_dir": "/home/user/.claude",
            "owner_pid": "12345",
            "session_id": "abc-def-123",
            "phases": {},
            "started_at": "2026-03-17T12:00:00Z",
            "commits": []
        });
        let cp_path = arc_dir.join("checkpoint.json");
        std::fs::write(&cp_path, checkpoint_json.to_string()).unwrap();

        let plan_path = PathBuf::from("plans/test-plan.md");
        let before = DateTime::parse_from_rfc3339("2026-03-17T11:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        // Should reject: wrong PID (expected 99999, checkpoint has 12345)
        let result = try_match_checkpoint(
            &cp_path,
            &dir,
            &plan_path,
            before,
            Some("/home/user/.claude"),
            Some(99999),
        );
        assert!(result.is_none(), "should reject mismatched owner_pid");

        // Should accept: correct PID
        let result = try_match_checkpoint(
            &cp_path,
            &dir,
            &plan_path,
            before,
            Some("/home/user/.claude"),
            Some(12345),
        );
        assert!(result.is_some(), "should accept matching owner_pid");
        let handle = result.unwrap();
        assert_eq!(handle.session_id, "abc-def-123");

        // Should accept: no expected PID (graceful degradation)
        let result = try_match_checkpoint(
            &cp_path,
            &dir,
            &plan_path,
            before,
            Some("/home/user/.claude"),
            None,
        );
        assert!(result.is_some(), "should accept when no expected PID");

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_try_match_rejects_wrong_config_dir() {
        let dir = std::env::temp_dir().join("torrent-test-config-match");
        let arc_dir = dir.join(".rune").join("arc").join("arc-cfg");
        std::fs::create_dir_all(&arc_dir).unwrap();

        let checkpoint_json = serde_json::json!({
            "id": "arc-cfg",
            "plan_file": "plans/test.md",
            "config_dir": "/home/user/.claude-work",
            "owner_pid": "",
            "session_id": "",
            "phases": {},
            "started_at": "2026-03-17T12:00:00Z",
            "commits": []
        });
        let cp_path = arc_dir.join("checkpoint.json");
        std::fs::write(&cp_path, checkpoint_json.to_string()).unwrap();

        let plan_path = PathBuf::from("plans/test.md");
        let before = DateTime::parse_from_rfc3339("2026-03-17T11:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        // Should reject: wrong config_dir
        let result = try_match_checkpoint(
            &cp_path,
            &dir,
            &plan_path,
            before,
            Some("/home/user/.claude-personal"),
            None,
        );
        assert!(result.is_none(), "should reject mismatched config_dir");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── Arc Loop State Tests ─────────────────────────────────

    #[test]
    fn test_extract_frontmatter() {
        let content = "---\nactive: true\nplan: test\n---\nBody content";
        let fm = extract_frontmatter(content).unwrap();
        assert!(fm.contains("active: true"));
        assert!(fm.contains("plan: test"));
    }

    #[test]
    fn test_extract_frontmatter_no_markers() {
        assert!(extract_frontmatter("no frontmatter here").is_none());
    }

    #[test]
    fn test_parse_yaml_str() {
        let yaml = "active: true\nplan_file: plans/test.md\nowner_pid: 12345";
        assert_eq!(parse_yaml_str(yaml, "plan_file"), Some("plans/test.md".into()));
        assert_eq!(parse_yaml_str(yaml, "owner_pid"), Some("12345".into()));
        assert_eq!(parse_yaml_str(yaml, "nonexistent"), None);
    }

    #[test]
    fn test_parse_yaml_str_null() {
        let yaml = "cancel_reason: null\nempty_val: ";
        assert_eq!(parse_yaml_str(yaml, "cancel_reason"), None);
        assert_eq!(parse_yaml_str(yaml, "empty_val"), None);
    }

    #[test]
    fn test_parse_yaml_bool() {
        let yaml = "active: true\ncancelled: false";
        assert_eq!(parse_yaml_bool(yaml, "active"), Some(true));
        assert_eq!(parse_yaml_bool(yaml, "cancelled"), Some(false));
        assert_eq!(parse_yaml_bool(yaml, "missing"), None);
    }

    #[test]
    fn test_read_arc_loop_state_full() {
        let dir = std::env::temp_dir().join("torrent-test-loop-state");
        let rune_dir = dir.join(".rune");
        std::fs::create_dir_all(&rune_dir).unwrap();

        let content = "\
---
active: true
iteration: 2
max_iterations: 50
checkpoint_path: .rune/arc/arc-123/checkpoint.json
plan_file: plans/2026-03-16-feat-test-plan.md
branch: feat/test
arc_flags: plans/2026-03-16-feat-test-plan.md
config_dir: /Users/test/.claude-true
owner_pid: 78210
session_id: 2d3f5b8c-075a-4bb2-8128-1604852a2ebb
compact_pending: false
user_cancelled: false
cancel_reason: null
cancelled_at: null
stop_reason: null
---
";
        std::fs::write(rune_dir.join("arc-phase-loop.local.md"), content).unwrap();

        let state = read_arc_loop_state(&dir).unwrap();
        assert!(state.active);
        assert_eq!(state.iteration, 2);
        assert_eq!(state.max_iterations, 50);
        assert_eq!(state.checkpoint_path, ".rune/arc/arc-123/checkpoint.json");
        assert_eq!(state.plan_file, "plans/2026-03-16-feat-test-plan.md");
        assert_eq!(state.branch, "feat/test");
        assert_eq!(state.config_dir, "/Users/test/.claude-true");
        assert_eq!(state.owner_pid, "78210");
        assert_eq!(state.session_id, "2d3f5b8c-075a-4bb2-8128-1604852a2ebb");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_arc_loop_state_inactive() {
        let dir = std::env::temp_dir().join("torrent-test-loop-inactive");
        let rune_dir = dir.join(".rune");
        std::fs::create_dir_all(&rune_dir).unwrap();

        let content = "\
---
active: false
checkpoint_path: .rune/arc/arc-old/checkpoint.json
plan_file: plans/old.md
config_dir: /Users/test/.claude
owner_pid: 111
session_id: aaa-bbb
---
";
        std::fs::write(rune_dir.join("arc-phase-loop.local.md"), content).unwrap();

        assert!(read_arc_loop_state(&dir).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_arc_loop_state_missing_file() {
        let dir = std::env::temp_dir().join("torrent-test-loop-missing");
        std::fs::create_dir_all(&dir).unwrap();

        assert!(read_arc_loop_state(&dir).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_extract_plans_relative() {
        assert_eq!(
            extract_plans_relative("plans/2026-03-16-feat-test-plan.md"),
            "plans/2026-03-16-feat-test-plan.md"
        );
        assert_eq!(
            extract_plans_relative("/Users/test/repos/myapp/plans/test.md"),
            "plans/test.md"
        );
        assert_eq!(
            extract_plans_relative("no-plans-prefix.md"),
            "no-plans-prefix.md"
        );
    }

    #[test]
    fn test_discover_from_loop_state_with_checkpoint() {
        // dir = project root (cwd). Loop state at <dir>/.rune/
        let dir = std::env::temp_dir().join("torrent-test-loop-discover");
        let rune_dir = dir.join(".rune");
        let arc_dir = rune_dir.join("arc").join("arc-test-loop");
        std::fs::create_dir_all(&arc_dir).unwrap();

        // Create loop state at <cwd>/.rune/arc-phase-loop.local.md
        let config_dir = dir.join("config");
        let loop_content = format!("\
---
active: true
iteration: 0
max_iterations: 50
checkpoint_path: .rune/arc/arc-test-loop/checkpoint.json
plan_file: plans/test-plan.md
branch: feat/test
config_dir: {}
owner_pid: 99999
session_id: abc-def-123
---
", config_dir.display());
        std::fs::write(rune_dir.join("arc-phase-loop.local.md"), &loop_content).unwrap();

        // Create checkpoint file
        let checkpoint_json = serde_json::json!({
            "id": "arc-test-loop",
            "schema_version": 24,
            "plan_file": "plans/test-plan.md",
            "config_dir": config_dir.to_string_lossy(),
            "owner_pid": "99999",
            "session_id": "abc-def-123",
            "phases": {},
            "started_at": "2026-03-17T12:00:00Z",
            "commits": []
        });
        std::fs::write(arc_dir.join("checkpoint.json"), checkpoint_json.to_string()).unwrap();

        // Discover via discover_arc (cwd = dir)
        let plan_path = PathBuf::from("plans/test-plan.md");
        let before = DateTime::parse_from_rfc3339("2026-03-17T11:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let handle = discover_arc(&dir, &plan_path, before, None, Some(99999));
        assert!(handle.is_some(), "should discover via loop state");
        let h = handle.unwrap();
        assert_eq!(h.arc_id, "arc-test-loop");
        assert_eq!(h.session_id, "abc-def-123");
        assert_eq!(h.config_dir, config_dir.to_string_lossy());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_discover_arc_wrong_plan() {
        let dir = std::env::temp_dir().join("torrent-test-discover-wrong-plan");
        let rune_dir = dir.join(".rune");
        std::fs::create_dir_all(&rune_dir).unwrap();

        let loop_content = "\
---
active: true
checkpoint_path: .rune/arc/arc-x/checkpoint.json
plan_file: plans/other-plan.md
config_dir: /test
owner_pid: 111
session_id: xxx
---
";
        std::fs::write(rune_dir.join("arc-phase-loop.local.md"), loop_content).unwrap();

        let plan_path = PathBuf::from("plans/my-plan.md");
        let before = DateTime::parse_from_rfc3339("2026-03-17T11:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let handle = discover_arc(&dir, &plan_path, before, None, None);
        assert!(handle.is_none(), "should reject mismatched plan");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── .rune/ path tests ───────────────────────────────────

    #[test]
    fn test_rune_dir_path_construction() {
        // Verify .rune/ is used (not .claude/) for arc-phase-loop.local.md
        let dir = std::env::temp_dir().join("torrent-test-rune-path");
        // Clean up stale state from prior test runs
        let _ = std::fs::remove_dir_all(&dir);
        let rune_dir = dir.join(".rune");
        std::fs::create_dir_all(&rune_dir).unwrap();

        let expected_path = rune_dir.join("arc-phase-loop.local.md");
        // Nothing in .rune/ or .claude/ → should return None
        assert!(read_arc_loop_state(&dir).is_none());

        // Legacy fallback: write to .claude/ → should still be found (legacy support)
        let claude_dir = dir.join(".claude");
        std::fs::create_dir_all(&claude_dir).unwrap();
        std::fs::write(
            claude_dir.join("arc-phase-loop.local.md"),
            "---\nactive: true\ncheckpoint_path: old\nplan_file: p\nconfig_dir: c\nowner_pid: 1\nsession_id: s\n---\n",
        ).unwrap();
        assert!(read_arc_loop_state(&dir).is_some(), "legacy .claude/ fallback should work");

        // Write to .rune/ (correct) → should be found
        std::fs::write(
            &expected_path,
            "---\nactive: true\ncheckpoint_path: .rune/arc/arc-1/checkpoint.json\nplan_file: plans/x.md\nconfig_dir: /test\nowner_pid: 42\nsession_id: sid\n---\n",
        ).unwrap();
        let state = read_arc_loop_state(&dir);
        assert!(state.is_some());
        assert_eq!(state.unwrap().checkpoint_path, ".rune/arc/arc-1/checkpoint.json");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_checkpoint_path_relative_uses_rune() {
        // Verify checkpoint_path from loop state resolves under .rune/
        let dir = std::env::temp_dir().join("torrent-test-cp-rune-resolve");
        let rune_dir = dir.join(".rune");
        let arc_dir = rune_dir.join("arc").join("arc-rune");
        std::fs::create_dir_all(&arc_dir).unwrap();

        let loop_content = "\
---
active: true
checkpoint_path: .rune/arc/arc-rune/checkpoint.json
plan_file: plans/rune-test.md
config_dir: /test
owner_pid: 100
session_id: s1
---
";
        std::fs::write(rune_dir.join("arc-phase-loop.local.md"), loop_content).unwrap();

        let checkpoint_json = serde_json::json!({
            "id": "arc-rune",
            "plan_file": "plans/rune-test.md",
            "config_dir": "/test",
            "owner_pid": "100",
            "session_id": "s1",
            "phases": {},
            "started_at": "2026-03-18T00:00:00Z"
        });
        std::fs::write(arc_dir.join("checkpoint.json"), checkpoint_json.to_string()).unwrap();

        let plan_path = PathBuf::from("plans/rune-test.md");
        let before = DateTime::parse_from_rfc3339("2026-03-17T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let handle = discover_arc(&dir, &plan_path, before, None, Some(100));
        assert!(handle.is_some());
        let h = handle.unwrap();

        // Verify resolved path is under .rune/, not .claude/
        let cp_str = h.checkpoint_path.to_string_lossy();
        assert!(cp_str.contains(".rune/arc/"), "checkpoint should resolve under .rune/, got: {}", cp_str);
        assert!(!cp_str.contains(".claude/"), "checkpoint should NOT resolve under .claude/");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── Heartbeat deserialization ────────────────────────────

    #[test]
    fn test_heartbeat_deserialize() {
        let json = r#"{
            "arc_id": "arc-hb",
            "phase": "work",
            "last_tool": "Edit",
            "last_activity": "2026-03-18T12:00:00Z"
        }"#;
        let hb: Heartbeat = serde_json::from_str(json).unwrap();
        assert_eq!(hb.arc_id, "arc-hb");
        assert_eq!(hb.phase, "work");
        assert_eq!(hb.last_tool, "Edit");
    }

    #[test]
    fn test_heartbeat_deserialize_empty_defaults() {
        let json = r#"{}"#;
        let hb: Heartbeat = serde_json::from_str(json).unwrap();
        assert_eq!(hb.arc_id, "");
        assert_eq!(hb.phase, "");
    }

    // ── Completion edge cases ───────────────────────────────

    #[test]
    fn test_check_completion_shipped_without_merge() {
        let mut phases = std::collections::HashMap::new();
        phases.insert("ship".into(), crate::checkpoint::PhaseStatus {
            status: "completed".into(),
            started_at: None,
            completed_at: None,
            team_name: None,
        });
        phases.insert("merge".into(), crate::checkpoint::PhaseStatus {
            status: "pending".into(),
            started_at: None,
            completed_at: None,
            team_name: None,
        });

        let checkpoint = Checkpoint {
            id: "arc-ship".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-18T00:00:00Z".into(),
        };

        match check_completion(&checkpoint) {
            Some(ArcCompletion::Shipped) => {}
            other => panic!("expected Shipped, got {other:?}"),
        }
    }

    #[test]
    fn test_check_completion_cancelled() {
        let mut phases = std::collections::HashMap::new();
        phases.insert("work".into(), crate::checkpoint::PhaseStatus {
            status: "cancelled".into(),
            started_at: None,
            completed_at: None,
            team_name: None,
        });

        let checkpoint = Checkpoint {
            id: "arc-cancel".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-18T00:00:00Z".into(),
        };

        match check_completion(&checkpoint) {
            Some(ArcCompletion::Cancelled) => {}
            other => panic!("expected Cancelled, got {other:?}"),
        }
    }

    #[test]
    fn test_check_completion_failed() {
        let mut phases = std::collections::HashMap::new();
        phases.insert("test".into(), crate::checkpoint::PhaseStatus {
            status: "failed".into(),
            started_at: None,
            completed_at: None,
            team_name: None,
        });

        let checkpoint = Checkpoint {
            id: "arc-fail".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-18T00:00:00Z".into(),
        };

        match check_completion(&checkpoint) {
            Some(ArcCompletion::Failed) => {}
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    // ── Phase navigation ────────────────────────────────────

    #[test]
    fn test_phase_navigation_in_progress() {
        let mut phases = std::collections::HashMap::new();
        phases.insert("forge".into(), crate::checkpoint::PhaseStatus {
            status: "completed".into(),
            started_at: Some("2026-03-18T00:00:00Z".into()),
            completed_at: Some("2026-03-18T00:05:00Z".into()),
            team_name: None,
        });
        phases.insert("work".into(), crate::checkpoint::PhaseStatus {
            status: "in_progress".into(),
            started_at: Some("2026-03-18T00:06:00Z".into()),
            completed_at: None,
            team_name: None,
        });
        phases.insert("ship".into(), crate::checkpoint::PhaseStatus {
            status: "pending".into(),
            started_at: None,
            completed_at: None,
            team_name: None,
        });

        let checkpoint = Checkpoint {
            id: "arc-nav".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-18T00:00:00Z".into(),
        };

        let nav = compute_phase_navigation(&checkpoint).unwrap();
        assert_eq!(nav.prev.as_ref().unwrap().name, "forge");
        assert_eq!(nav.prev.as_ref().unwrap().duration_secs, Some(300)); // 5 min
        assert_eq!(nav.current.as_ref().unwrap().name, "work");
        assert_eq!(nav.next, Some("ship".into()));
    }

    #[test]
    fn test_phase_navigation_all_pending() {
        let mut phases = std::collections::HashMap::new();
        phases.insert("forge".into(), crate::checkpoint::PhaseStatus {
            status: "pending".into(),
            started_at: None,
            completed_at: None,
            team_name: None,
        });

        let checkpoint = Checkpoint {
            id: "arc-pend".into(),
            schema_version: Some(24),
            plan_file: "plan.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases,
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-18T00:00:00Z".into(),
        };

        let nav = compute_phase_navigation(&checkpoint);
        assert!(nav.is_some());
        let nav = nav.unwrap();
        assert!(nav.prev.is_none());
        assert!(nav.current.is_none());
        assert_eq!(nav.next, Some("forge".into()));
    }

    // ── YAML edge cases ─────────────────────────────────────

    #[test]
    fn test_parse_yaml_str_with_quotes() {
        let yaml = "checkpoint_path: \".rune/arc/arc-1/checkpoint.json\"";
        assert_eq!(
            parse_yaml_str(yaml, "checkpoint_path"),
            Some(".rune/arc/arc-1/checkpoint.json".into())
        );
    }

    #[test]
    fn test_parse_yaml_str_single_quotes() {
        let yaml = "session_id: 'abc-def-123'";
        assert_eq!(parse_yaml_str(yaml, "session_id"), Some("abc-def-123".into()));
    }

    #[test]
    fn test_parse_yaml_str_key_prefix_collision() {
        // "plan_file" should not match "plan"
        let yaml = "plan_file: plans/test.md";
        assert_eq!(parse_yaml_str(yaml, "plan_file"), Some("plans/test.md".into()));
        // "plan" alone should NOT match "plan_file:"
        // because strip_prefix("plan") on "plan_file: ..." gives "_file: ..."
        // and strip_prefix(':') on "_file: ..." returns None
        assert_eq!(parse_yaml_str(yaml, "plan"), None);
    }

    #[test]
    fn test_discover_arc_rejects_wrong_pid() {
        let dir = std::env::temp_dir().join("torrent-test-discover-wrong-pid");
        let rune_dir = dir.join(".rune");
        let arc_dir = rune_dir.join("arc").join("arc-pid");
        std::fs::create_dir_all(&arc_dir).unwrap();

        let loop_content = "\
---
active: true
checkpoint_path: .rune/arc/arc-pid/checkpoint.json
plan_file: plans/pid-test.md
config_dir: /test
owner_pid: 111
session_id: s
---
";
        std::fs::write(rune_dir.join("arc-phase-loop.local.md"), loop_content).unwrap();

        let checkpoint_json = serde_json::json!({
            "id": "arc-pid",
            "plan_file": "plans/pid-test.md",
            "config_dir": "/test",
            "owner_pid": "111",
            "session_id": "s",
            "phases": {},
            "started_at": "2026-03-18T00:00:00Z"
        });
        std::fs::write(arc_dir.join("checkpoint.json"), checkpoint_json.to_string()).unwrap();

        let plan_path = PathBuf::from("plans/pid-test.md");
        let before = DateTime::parse_from_rfc3339("2026-03-17T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        // Wrong PID → rejected
        let handle = discover_arc(&dir, &plan_path, before, None, Some(999));
        assert!(handle.is_none(), "should reject mismatched PID");

        // Correct PID → accepted
        let handle = discover_arc(&dir, &plan_path, before, None, Some(111));
        assert!(handle.is_some(), "should accept matching PID");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
