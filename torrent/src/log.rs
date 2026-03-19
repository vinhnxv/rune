//! Structured JSONL run logging for torrent.
//!
//! Appends one JSON object per line to `.torrent/logs/runs.jsonl`.
//! Supports automatic log rotation (max 5 rotated files, 10 MB threshold).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

/// Maximum number of restart events recorded per log entry.
pub const MAX_RESTARTS: usize = 10;

/// Log rotation threshold in bytes (10 MB).
const ROTATION_THRESHOLD: u64 = 10 * 1024 * 1024;

/// Maximum number of rotated log files to keep.
const MAX_ROTATIONS: usize = 5;

/// Outcome status of an arc run.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Completed,
    Skipped,
    Failed,
}

/// Urgency tier indicating the severity/priority of a run outcome.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UrgencyTier {
    Green,
    Yellow,
    Orange,
    Red,
}

/// A restart event that occurred during an arc run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RestartEvent {
    /// Iteration number of the restart.
    pub iteration: u32,
    /// Timestamp when the restart occurred.
    pub timestamp: DateTime<Utc>,
    /// Reason for the restart, if known.
    pub reason: Option<String>,
}

/// A single structured log entry for a completed arc run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunLogEntry {
    /// Timestamp when the run completed.
    pub timestamp: DateTime<Utc>,
    /// Short plan name (e.g., "feat-user-auth").
    pub plan: String,
    /// Full path to the plan file.
    pub plan_file: String,
    /// Config directory used for this run.
    pub config_dir: String,
    /// Unique arc identifier, if available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arc_id: Option<String>,
    /// Outcome status of the run.
    pub status: RunStatus,
    /// Urgency tier for the outcome.
    pub urgency: UrgencyTier,
    /// Number of phases completed.
    pub phases_completed: u32,
    /// Total number of phases.
    pub phases_total: u32,
    /// Number of phases skipped.
    pub phases_skipped: u32,
    /// Wall-clock duration of the run in seconds.
    pub wallclock_seconds: u64,
    /// PR URL if the run produced one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr_url: Option<String>,
    /// Failure reason, if the run failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Final outcome description.
    pub final_outcome: String,
    /// Restart events that occurred during the run (capped at 10).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub restarts: Vec<RestartEvent>,
}

/// Aggregated summary of a batch of runs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchSummary {
    /// Timestamp when the batch summary was written.
    pub timestamp: DateTime<Utc>,
    /// Total number of runs in the batch.
    pub total_runs: usize,
    /// Number of runs that completed successfully.
    pub completed: usize,
    /// Number of runs that were skipped.
    pub skipped: usize,
    /// Number of runs that failed.
    pub failed: usize,
    /// Total wall-clock duration across all runs in seconds.
    pub total_duration_secs: u64,
    /// The highest urgency tier seen across all runs.
    pub worst_urgency: UrgencyTier,
}

/// Returns the log directory path.
///
/// Checks `TORRENT_LOG_DIR` env var first, defaults to `.torrent/logs`.
pub fn log_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("TORRENT_LOG_DIR") {
        PathBuf::from(dir)
    } else {
        PathBuf::from(".torrent/logs")
    }
}

/// Ensures the log directory exists, creating it if necessary.
pub fn ensure_log_dir() -> std::io::Result<()> {
    fs::create_dir_all(log_dir())
}

/// Appends a run log entry as a single JSON line to `runs.jsonl`.
///
/// Creates the log file and directory if they don't exist.
/// Performs log rotation after writing if the file exceeds 10 MB.
pub fn append_run_log(entry: &RunLogEntry) -> std::io::Result<()> {
    ensure_log_dir()?;

    let path = log_dir().join("runs.jsonl");
    let json = serde_json::to_string(entry)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)?;

    // Single write_all call for atomicity on most filesystems
    file.write_all(format!("{}\n", json).as_bytes())?;

    rotate_if_needed(&path)?;
    Ok(())
}

/// Writes a batch summary computed from a slice of completed runs.
///
/// Aggregates counts and durations, determines worst urgency tier,
/// and appends the summary as a JSON line to `batch.jsonl`.
pub fn write_batch_summary(runs: &[crate::app::CompletedRun]) -> std::io::Result<()> {
    if runs.is_empty() {
        return Ok(());
    }

    ensure_log_dir()?;

    let mut completed = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;
    let mut total_duration_secs = 0u64;
    let mut worst = UrgencyTier::Green;

    for run in runs {
        let (status, urgency) = classify_completion(&run.result);
        match status {
            RunStatus::Completed => completed += 1,
            RunStatus::Skipped => skipped += 1,
            RunStatus::Failed => failed += 1,
        }
        total_duration_secs += run.duration.as_secs();

        if urgency_rank(&urgency) > urgency_rank(&worst) {
            worst = urgency;
        }
    }

    let summary = BatchSummary {
        timestamp: Utc::now(),
        total_runs: runs.len(),
        completed,
        skipped,
        failed,
        total_duration_secs,
        worst_urgency: worst,
    };

    let path = log_dir().join("batch.jsonl");
    let json = serde_json::to_string(&summary)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)?;

    file.write_all(format!("{}\n", json).as_bytes())?;

    rotate_if_needed(&path)?;
    Ok(())
}

/// Maps an `ArcCompletion` variant to a `(RunStatus, UrgencyTier)` pair.
pub fn classify_completion(result: &crate::app::ArcCompletion) -> (RunStatus, UrgencyTier) {
    use crate::app::ArcCompletion;
    match result {
        ArcCompletion::Merged { .. } => (RunStatus::Completed, UrgencyTier::Green),
        ArcCompletion::Shipped { .. } => (RunStatus::Completed, UrgencyTier::Green),
        ArcCompletion::Cancelled { .. } => (RunStatus::Skipped, UrgencyTier::Yellow),
        ArcCompletion::Failed { .. } => (RunStatus::Failed, UrgencyTier::Red),
    }
}

/// Returns a numeric rank for urgency comparison (higher = more severe).
fn urgency_rank(tier: &UrgencyTier) -> u8 {
    match tier {
        UrgencyTier::Green => 0,
        UrgencyTier::Yellow => 1,
        UrgencyTier::Orange => 2,
        UrgencyTier::Red => 3,
    }
}

/// Rotates a log file if it exceeds the size threshold.
///
/// Keeps up to 5 rotated files: `runs.jsonl.1` (newest) through
/// `runs.jsonl.5` (oldest). Files beyond `.5` are discarded.
fn rotate_if_needed(path: &Path) -> std::io::Result<()> {
    let metadata = match fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return Ok(()),
    };

    if metadata.len() < ROTATION_THRESHOLD {
        return Ok(());
    }

    // Shift existing rotated files: .4→.5, .3→.4, .2→.3, .1→.2
    let path_str = path.to_string_lossy();
    for i in (1..MAX_ROTATIONS).rev() {
        let from = format!("{}.{}", path_str, i);
        let to = format!("{}.{}", path_str, i + 1);
        if Path::new(&from).exists() {
            fs::rename(&from, &to)?;
        }
    }

    // Move current file to .1
    let rotated = format!("{}.1", path_str);
    fs::rename(path, &rotated)?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::ArcCompletion;

    #[test]
    fn test_classify_merged() {
        let (status, urgency) = classify_completion(&ArcCompletion::Merged { pr_url: None });
        assert_eq!(status, RunStatus::Completed);
        assert_eq!(urgency, UrgencyTier::Green);
    }

    #[test]
    fn test_classify_failed() {
        let (status, urgency) = classify_completion(&ArcCompletion::Failed {
            reason: "timeout".into(),
        });
        assert_eq!(status, RunStatus::Failed);
        assert_eq!(urgency, UrgencyTier::Red);
    }

    #[test]
    fn test_classify_cancelled() {
        let (status, urgency) = classify_completion(&ArcCompletion::Cancelled {
            reason: Some("user".into()),
        });
        assert_eq!(status, RunStatus::Skipped);
        assert_eq!(urgency, UrgencyTier::Yellow);
    }

    #[test]
    fn test_urgency_ordering() {
        assert!(urgency_rank(&UrgencyTier::Red) > urgency_rank(&UrgencyTier::Green));
        assert!(urgency_rank(&UrgencyTier::Orange) > urgency_rank(&UrgencyTier::Yellow));
    }

    #[test]
    fn test_log_entry_serialization() {
        let entry = RunLogEntry {
            timestamp: Utc::now(),
            plan: "test-plan".into(),
            plan_file: "plans/test-plan.md".into(),
            config_dir: "~/.claude".into(),
            arc_id: Some("abc-123".into()),
            status: RunStatus::Completed,
            urgency: UrgencyTier::Green,
            phases_completed: 12,
            phases_total: 15,
            phases_skipped: 3,
            wallclock_seconds: 120,
            pr_url: Some("https://github.com/test/pr/1".into()),
            error: None,
            final_outcome: "completed".into(),
            restarts: vec![],
        };
        let json = serde_json::to_string(&entry).unwrap();
        assert!(json.contains("\"status\":\"completed\""));
        assert!(json.contains("\"urgency\":\"green\""));
        assert!(!json.contains("\"error\"")); // skip_serializing_if = None
        assert!(!json.contains("\"restarts\"")); // skip_serializing_if = empty
    }

    #[test]
    fn test_max_restarts_cap() {
        let mut restarts: Vec<RestartEvent> = (0..15)
            .map(|i| RestartEvent {
                iteration: i,
                timestamp: Utc::now(),
                reason: None,
            })
            .collect();
        restarts.truncate(MAX_RESTARTS);
        assert_eq!(restarts.len(), MAX_RESTARTS);
    }
}
