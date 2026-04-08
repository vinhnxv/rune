//! Polling scheduler for non-blocking timer-based checks.
//!
//! `PollingScheduler` consolidates 7 independent `Option<Instant>` timer fields
//! into a single struct with a generic `should_poll(name, interval)` +
//! `mark_polled(name)` API. This eliminates repeated boilerplate in `tick_execution`.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// Non-blocking polling scheduler with named timers.
pub struct PollingScheduler {
    timers: HashMap<&'static str, Instant>,
}

// Timer name constants.
pub const DISCOVERY: &str = "discovery";
pub const HEARTBEAT: &str = "heartbeat";
pub const CHECKPOINT: &str = "checkpoint";
pub const LOOP_STATE: &str = "loop_state";
pub const ACTIVE_ARCS_PRUNE: &str = "active_arcs_prune";
pub const DIAGNOSTIC: &str = "diagnostic";
pub const CHANNEL: &str = "channel";

impl PollingScheduler {
    /// Create a new scheduler with no timers set (all polls fire immediately).
    pub fn new() -> Self {
        Self {
            timers: HashMap::new(),
        }
    }

    /// Check if enough time has elapsed since the last poll for `name`.
    /// Returns `true` if never polled or if `interval` has passed.
    pub fn should_poll(&self, name: &'static str, interval: Duration) -> bool {
        self.timers
            .get(name)
            .map(|t| t.elapsed() >= interval)
            .unwrap_or(true)
    }

    /// Record that `name` was just polled at `now`.
    pub fn mark_polled(&mut self, name: &'static str, now: Instant) {
        self.timers.insert(name, now);
    }

    /// Reset a specific timer so its next poll fires immediately.
    pub fn reset(&mut self, name: &'static str) {
        self.timers.remove(name);
    }

    /// Reset multiple timers at once.
    pub fn reset_many(&mut self, names: &[&'static str]) {
        for name in names {
            self.timers.remove(*name);
        }
    }
}
