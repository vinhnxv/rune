//! Auto-resume state management for torrent watchdog.
//!
//! Tracks per-plan retry state across restarts, with strategy-specific backoff
//! durations. State is persisted to `.torrent/state/{hash}.json` using atomic
//! writes (tmp file + rename) to prevent corruption on crash.

use chrono::{DateTime, Utc};
use color_eyre::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

/// Retry strategy variants, each with its own backoff curve and max retries.
///
/// The strategy is chosen based on the failure signal detected by the watchdog:
/// - Phase-level failures use `PhaseTimeout`
/// - API errors map to `ApiOverload`, `RateLimit`, or `TokenAuth`
/// - Billing failures and explicit skips are terminal (zero retries)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RetryStrategy {
    PhaseTimeout,
    ApiOverload,
    RateLimit,
    TokenAuth,
    BillingError,
    SkipImmediate,
}

/// Per-plan resume state, persisted across restarts.
///
/// Uses phase INDEX (u32) as the key rather than phase NAME (String) because
/// the arc phase loop identifies phases by their sequential position. Names
/// can change between plan revisions, but indices remain stable within a run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResumeState {
    pub plan_file: String,
    pub plan_hash: String,
    /// Maps phase index → retry count. Using index (not name) because the arc
    /// loop tracks progress by position, and names may vary across plan versions.
    pub phase_retries: HashMap<u32, u32>,
    pub api_retries: ApiRetryState,
    pub total_restarts: u32,
    pub last_restart_at: Option<DateTime<Utc>>,
    pub last_restart_reason: Option<String>,
    pub last_restart_phase: Option<String>,
    pub deferred_until: Option<DateTime<Utc>>,
    /// Timestamp of the first restart in this session (for rapid failure detection).
    /// If 3+ restarts occur within 5 minutes of this timestamp, it's a rapid failure.
    #[serde(default)]
    pub first_restart_at: Option<DateTime<Utc>>,
}

/// Tracks API-level retry counts and timestamps, separate from phase retries.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ApiRetryState {
    pub overload_count: u32,
    pub overload_last_at: Option<DateTime<Utc>>,
    pub auth_count: u32,
    pub auth_last_at: Option<DateTime<Utc>>,
}

impl RetryStrategy {
    /// Returns the backoff duration for the given attempt number.
    ///
    /// Each strategy uses a different curve:
    /// - `PhaseTimeout`: flat 30s (quick retry, phase may succeed on re-run)
    /// - `ApiOverload`: escalating minutes [15, 30, 60, 120, 180, 240] — gives
    ///   the API time to recover from sustained load
    /// - `RateLimit`: respects `retry_after` header when present (min 60s),
    ///   otherwise [15, 30, 60, 60] minutes
    /// - `TokenAuth`: [15, 30, 30] minutes — auth issues rarely self-heal,
    ///   but token rotation or refresh may fix them
    /// - `BillingError` / `SkipImmediate`: zero — no point retrying
    pub fn backoff_duration(&self, attempt: u32, retry_after: Option<u64>) -> Duration {
        match self {
            RetryStrategy::PhaseTimeout => Duration::from_secs(30),
            RetryStrategy::ApiOverload => {
                let minutes = [15, 30, 60, 120, 180, 240];
                let idx = (attempt as usize).min(5);
                Duration::from_secs(minutes[idx] * 60)
            }
            RetryStrategy::RateLimit => {
                if let Some(secs) = retry_after {
                    // Respect server's retry-after header, but floor at 60s
                    Duration::from_secs(secs.max(60))
                } else {
                    let minutes = [15, 30, 60, 60];
                    let idx = (attempt as usize).min(3);
                    Duration::from_secs(minutes[idx] * 60)
                }
            }
            RetryStrategy::TokenAuth => {
                let minutes = [15, 30, 30];
                let idx = (attempt as usize).min(2);
                Duration::from_secs(minutes[idx] * 60)
            }
            RetryStrategy::BillingError | RetryStrategy::SkipImmediate => Duration::ZERO,
        }
    }

    /// Maximum number of retries before giving up on this strategy.
    pub fn max_retries(&self) -> u32 {
        match self {
            RetryStrategy::PhaseTimeout => 3,
            RetryStrategy::ApiOverload => 6,
            RetryStrategy::RateLimit => 4,
            RetryStrategy::TokenAuth => 3,
            RetryStrategy::BillingError | RetryStrategy::SkipImmediate => 0,
        }
    }

    /// Whether this failure should stop the entire batch (not just this plan).
    #[allow(dead_code)]
    pub fn should_stop_batch(&self) -> bool {
        matches!(self, RetryStrategy::BillingError)
    }

    /// Whether this plan should be skipped immediately (no retry).
    #[allow(dead_code)]
    pub fn should_skip_plan(&self) -> bool {
        matches!(self, RetryStrategy::SkipImmediate)
    }
}

impl ResumeState {
    /// Load resume state for a plan file from `.torrent/state/{hash}.json`.
    /// Returns a default state if the file is missing or unparseable.
    pub fn load(plan_file: &str) -> Self {
        let hash = Self::plan_hash(plan_file);
        let path = state_path(&hash);

        match fs::read_to_string(&path) {
            Ok(contents) => serde_json::from_str(&contents).unwrap_or_else(|_| Self::default_for(plan_file, &hash)),
            Err(_) => Self::default_for(plan_file, &hash),
        }
    }

    /// Persist state atomically: write to a tmp file, then rename.
    /// This prevents corruption if the process is killed mid-write.
    pub fn save(&self) -> Result<()> {
        let dir = PathBuf::from(".torrent/state");
        fs::create_dir_all(&dir)?;

        let path = state_path(&self.plan_hash);
        let tmp_path = path.with_extension("json.tmp");

        let json = serde_json::to_string_pretty(self)?;
        let mut file = fs::File::create(&tmp_path)?;
        file.write_all(json.as_bytes())?;
        file.sync_all()?;

        fs::rename(&tmp_path, &path)?;
        Ok(())
    }

    /// Check if a phase has exceeded its retry budget.
    pub fn should_skip(&self, phase_index: u32, max_retries: u32) -> bool {
        self.phase_retries
            .get(&phase_index)
            .map_or(false, |&count| count >= max_retries)
    }

    /// Record a restart event: bump counters and update timestamps.
    pub fn record_restart(&mut self, phase_index: u32, phase_name: &str, reason: &str) {
        *self.phase_retries.entry(phase_index).or_insert(0) += 1;
        self.total_restarts += 1;
        let now = Utc::now();
        if self.first_restart_at.is_none() {
            self.first_restart_at = Some(now);
        }
        self.last_restart_at = Some(now);
        self.last_restart_reason = Some(reason.to_string());
        self.last_restart_phase = Some(phase_name.to_string());
    }

    /// Check for rapid failure: 3+ restarts within 5 minutes of the first restart.
    /// Returns true if all retries are burning through too fast (likely a systemic issue).
    pub fn is_rapid_failure(&self) -> bool {
        if self.total_restarts < 3 {
            return false;
        }
        match (self.first_restart_at, self.last_restart_at) {
            (Some(first), Some(last)) => {
                let elapsed = last.signed_duration_since(first);
                elapsed.num_seconds() < 300 // 5 minutes
            }
            _ => false,
        }
    }

    /// Simple hash of the plan filename — first 8 hex chars of a basic hash.
    /// Not cryptographic; just needs to be stable and filesystem-safe.
    pub fn plan_hash(plan_file: &str) -> String {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        plan_file.hash(&mut hasher);
        format!("{:016x}", hasher.finish())[..8].to_string()
    }

    fn default_for(plan_file: &str, hash: &str) -> Self {
        Self {
            plan_file: plan_file.to_string(),
            plan_hash: hash.to_string(),
            phase_retries: HashMap::new(),
            api_retries: ApiRetryState::default(),
            total_restarts: 0,
            last_restart_at: None,
            last_restart_reason: None,
            last_restart_phase: None,
            deferred_until: None,
            first_restart_at: None,
        }
    }
}

/// Returns the path to a state file given a plan hash.
fn state_path(hash: &str) -> PathBuf {
    PathBuf::from(format!(".torrent/state/{}.json", hash))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_phase_timeout_backoff() {
        let s = RetryStrategy::PhaseTimeout;
        assert_eq!(s.backoff_duration(0, None), Duration::from_secs(30));
        assert_eq!(s.backoff_duration(5, None), Duration::from_secs(30));
    }

    #[test]
    fn test_api_overload_escalation() {
        let s = RetryStrategy::ApiOverload;
        assert_eq!(s.backoff_duration(0, None), Duration::from_secs(15 * 60));
        assert_eq!(s.backoff_duration(3, None), Duration::from_secs(120 * 60));
        // Clamped at index 5
        assert_eq!(s.backoff_duration(99, None), Duration::from_secs(240 * 60));
    }

    #[test]
    fn test_rate_limit_respects_retry_after() {
        let s = RetryStrategy::RateLimit;
        assert_eq!(s.backoff_duration(0, Some(120)), Duration::from_secs(120));
        // Floor at 60s
        assert_eq!(s.backoff_duration(0, Some(10)), Duration::from_secs(60));
        // Without header, uses table
        assert_eq!(s.backoff_duration(0, None), Duration::from_secs(15 * 60));
    }

    #[test]
    fn test_billing_is_terminal() {
        let s = RetryStrategy::BillingError;
        assert_eq!(s.max_retries(), 0);
        assert!(s.should_stop_batch());
        assert!(!s.should_skip_plan());
    }

    #[test]
    fn test_skip_immediate() {
        let s = RetryStrategy::SkipImmediate;
        assert_eq!(s.max_retries(), 0);
        assert!(!s.should_stop_batch());
        assert!(s.should_skip_plan());
    }

    #[test]
    fn test_plan_hash_stable() {
        let h1 = ResumeState::plan_hash("plans/feat-auth.md");
        let h2 = ResumeState::plan_hash("plans/feat-auth.md");
        assert_eq!(h1, h2);
        assert_eq!(h1.len(), 8);
    }

    #[test]
    fn test_record_restart_increments() {
        let mut state = ResumeState::load("test-plan.md");
        state.record_restart(2, "forge", "phase_timeout");
        state.record_restart(2, "forge", "phase_timeout");
        assert_eq!(state.phase_retries[&2], 2);
        assert_eq!(state.total_restarts, 2);
        assert!(state.should_skip(2, 2)); // 2 >= 2
        assert!(!state.should_skip(2, 3)); // 2 < 3
    }
}
