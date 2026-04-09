//! Execution orchestration engine for arc plan runs.
//!
//! `ExecutionEngine` owns the runtime state for plan execution: the work queue,
//! current run, completed runs, and timing configuration. Methods on this struct
//! implement pure execution logic that doesn't require access to UI state.
//!
//! Cross-cutting orchestration methods (`tick_execution`, `launch_next_plan`) remain
//! on `App` and delegate to `ExecutionEngine` via split borrows — Rust allows
//! simultaneous `&mut self.execution` + `&self.config_dirs` because they're separate fields.

use std::collections::VecDeque;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::Utc;
use color_eyre::{eyre::eyre, Result};

use crate::monitor;
use crate::scanner::PlanFile;
use crate::tmux::Tmux;
use crate::types::*;

/// Core execution state for arc plan runs.
pub(crate) struct ExecutionEngine {
    pub queue: VecDeque<QueueEntry>,
    pub current_run: Option<RunState>,
    pub completed_runs: Vec<CompletedRun>,
    pub tmux_session_id: Option<String>,
    pub inter_plan_cooldown_until: Option<Instant>,
    pub launched_wall_clock: Option<chrono::DateTime<Utc>>,
    pub phase_timeout_config: PhaseTimeoutConfig,
}

impl ExecutionEngine {
    /// Create a new execution engine with default state.
    pub(crate) fn new(phase_timeout_config: PhaseTimeoutConfig) -> Self {
        Self {
            queue: VecDeque::new(),
            current_run: None,
            completed_runs: Vec::new(),
            tmux_session_id: None,
            inter_plan_cooldown_until: None,
            launched_wall_clock: None,
            phase_timeout_config,
        }
    }

    /// Total items visible in the Running view queue area:
    /// current run (if any) + remaining queue entries + completed runs.
    pub(crate) fn queue_total_items(&self) -> usize {
        let running = if self.current_run.is_some() { 1 } else { 0 };
        running + self.queue.len() + self.completed_runs.len()
    }

    /// Skip the current plan — cancel and move to completed.
    /// Returns the new total item count for UI cursor clamping.
    pub(crate) fn skip_current_plan(&mut self) -> usize {
        if let Some(run) = self.current_run.take() {
            let _ = Tmux::kill_session(&run.tmux_session);
            let arc_id = run.arc_id();
            let duration = run.arc_duration();
            self.completed_runs.push(CompletedRun {
                plan: run.plan,
                result: ArcCompletion::Cancelled {
                    reason: Some("skipped by user".into()),
                },
                duration,
                arc_id,
                resume_restarts: None,
            });
            self.tmux_session_id = None;
        }
        self.queue_total_items()
    }

    /// Kill the current session and clear the entire queue.
    pub(crate) fn kill_current_session(&mut self) {
        if let Some(session_id) = &self.tmux_session_id {
            let _ = Tmux::kill_session(session_id);
        }
        if let Some(run) = self.current_run.take() {
            let arc_id = run.arc_id();
            let duration = run.arc_duration();
            self.completed_runs.push(CompletedRun {
                plan: run.plan,
                result: ArcCompletion::Failed {
                    reason: "killed by user".into(),
                },
                duration,
                arc_id,
                resume_restarts: None,
            });
        }
        self.tmux_session_id = None;
        self.queue.clear();
    }

    /// Check if a plan already has an active checkpoint from a previous session.
    pub(crate) fn check_existing_checkpoint(plan: &PlanFile) -> bool {
        let cwd = std::env::current_dir().unwrap_or_default();
        match monitor::read_arc_loop_state(&cwd) {
            Some(state) => {
                let plan_str = plan.path.display().to_string();
                crate::app::plans_match(&plan_str, &state.plan_file)
            }
            None => false,
        }
    }
}

// ── launch_next_plan sub-functions ────────────────────────────

/// Step 1: Git checkout main + pull. Returns Ok(()) on success, Err with status message on failure.
pub(crate) fn checkout_plan_branch() -> Result<()> {
    let checkout = Command::new("git")
        .args(["checkout", "main"])
        .output();
    if checkout.as_ref().map_or(true, |o| !o.status.success()) {
        return Err(eyre!("git checkout main failed — clean up working tree"));
    }
    let pull = Command::new("git")
        .args(["pull", "--ff-only"])
        .output();
    if pull.as_ref().map_or(true, |o| !o.status.success()) {
        return Err(eyre!("git pull failed — retrying..."));
    }
    Ok(())
}

/// Step 3: Create a tmux session in the given working directory.
/// Returns the session ID on success.
pub(crate) fn create_tmux_session(cwd: &Path) -> Result<String> {
    let session_id = Tmux::generate_session_id();
    if let Err(e) = Tmux::create_session(&session_id, cwd) {
        return Err(eyre!("tmux failed: {e}"));
    }
    Ok(session_id)
}

/// Step 5.5-5.6: Detect Claude Code PID by finding child of tmux pane shell.
/// Polls up to 3 times with 2s delay between attempts.
pub(crate) fn detect_claude_pid(session_id: &str) -> (Option<u32>, Option<u32>) {
    let tmux_pane_pid = Tmux::get_pane_pid(session_id).ok();
    let claude_pid = tmux_pane_pid.and_then(|ppid| {
        for _ in 0..3 {
            if let Some(pid) = Tmux::get_claude_pid(ppid) {
                return Some(pid);
            }
            std::thread::sleep(Duration::from_secs(2));
        }
        None
    });
    (tmux_pane_pid, claude_pid)
}

/// Clean stale arc state from a previous run.
pub(crate) fn clean_stale_arc_state() {
    let cwd = std::env::current_dir().unwrap_or_default();
    let stale_loop = cwd.join(".rune").join("arc-phase-loop.local.md");
    if stale_loop.exists() {
        let _ = std::fs::remove_file(&stale_loop);
    }
    let legacy_loop = cwd.join(".claude").join("arc-phase-loop.local.md");
    if legacy_loop.exists() {
        let _ = std::fs::remove_file(&legacy_loop);
    }
}
