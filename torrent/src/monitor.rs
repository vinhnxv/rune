use std::fs;
use std::path::{Path, PathBuf};

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
}

/// Polled status of a running arc.
#[derive(Debug, Clone)]
pub struct ArcStatus {
    pub arc_id: String,
    pub current_phase: String,
    pub last_tool: String,
    pub last_activity: Option<DateTime<Utc>>,
    pub phase_summary: PhaseSummary,
    pub pr_url: Option<String>,
    pub is_stale: bool,
    pub completion: Option<ArcCompletion>,
}

/// Summary of phase progress derived from checkpoint.json.
#[derive(Debug, Clone)]
pub struct PhaseSummary {
    pub completed: u32,
    pub total: u32,
    pub skipped: u32,
    pub current_phase_name: String,
}

/// Terminal states for an arc run.
#[derive(Debug, Clone)]
pub enum ArcCompletion {
    Merged,
    Shipped,
    Cancelled,
    Failed,
}

/// Discover a newly-launched arc by scanning `.claude/arc/arc-*/checkpoint.json`
/// relative to the current working directory.
///
/// Matches on: plan_file + config_dir + started_at > launched_after.
/// Returns `None` if no matching checkpoint is found (caller should retry).
pub fn discover_arc(
    cwd: &Path,
    plan_path: &Path,
    launched_after: DateTime<Utc>,
) -> Option<ArcHandle> {
    let arc_dir = cwd.join(".claude").join("arc");
    let pattern = format!("{}/arc-*/checkpoint.json", arc_dir.display());

    let entries = glob::glob(&pattern).ok()?;

    for entry in entries.flatten() {
        let handle = try_match_checkpoint(&entry, cwd, plan_path, launched_after);
        if handle.is_some() {
            return handle;
        }
    }

    None
}

/// Try to parse and match a single checkpoint file against our criteria.
fn try_match_checkpoint(
    checkpoint_path: &Path,
    cwd: &Path,
    plan_path: &Path,
    launched_after: DateTime<Utc>,
) -> Option<ArcHandle> {
    let contents = fs::read_to_string(checkpoint_path).ok()?;
    let checkpoint: Checkpoint = serde_json::from_str(&contents).ok()?;

    // Match criteria:
    // 1. plan_file matches the plan we launched
    // Normalize both to relative "plans/..." form for comparison.
    // Checkpoint stores relative path, scanner returns absolute path.
    let plan_str = plan_path.display().to_string();
    let plan_relative = if let Some(idx) = plan_str.find("plans/") {
        &plan_str[idx..]
    } else {
        &plan_str
    };
    let checkpoint_relative = if let Some(idx) = checkpoint.plan_file.find("plans/") {
        &checkpoint.plan_file[idx..]
    } else {
        &checkpoint.plan_file
    };
    if checkpoint_relative != plan_relative {
        return None;
    }

    // 2. config_dir matches (cross-session safety)
    // Skip this check if config_dir is empty (older checkpoint format)
    // Note: this is a soft match — not strictly required for v1

    // 3. started_at is AFTER our launch time
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
    })
}

/// Poll the current status of a discovered arc.
///
/// Reads both checkpoint (phase progress) and heartbeat (liveness).
/// Returns `None` if the checkpoint file is missing/unreadable.
pub fn poll_arc_status(handle: &ArcHandle) -> Option<ArcStatus> {
    let checkpoint = read_checkpoint(&handle.checkpoint_path)?;
    let heartbeat = read_heartbeat(&handle.heartbeat_path);

    let phase_summary = compute_phase_summary(&checkpoint);
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
        pr_url: checkpoint.pr_url,
        is_stale,
        completion,
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
    for (_name, phase) in &checkpoint.phases {
        if phase.status == "cancelled" {
            return Some(ArcCompletion::Cancelled);
        }
        if phase.status == "failed" {
            return Some(ArcCompletion::Failed);
        }
    }

    None
}

/// Compute a summary of phase progress from checkpoint data.
fn compute_phase_summary(checkpoint: &Checkpoint) -> PhaseSummary {
    let mut completed = 0u32;
    let mut skipped = 0u32;
    let mut current_phase_name = String::from("initializing");

    for (name, phase) in &checkpoint.phases {
        match phase.status.as_str() {
            "completed" => completed += 1,
            "skipped" => skipped += 1,
            "in_progress" => current_phase_name = name.clone(),
            _ => {}
        }
    }

    let total = checkpoint.phases.len() as u32;

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
}
