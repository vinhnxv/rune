//! Timeout detection and auto-recovery state machine.
//!
//! This module contains the timeout/recovery methods for `App`, split out from
//! `app.rs` for readability. The methods remain `impl App` because they need
//! mutable access to execution, messaging, polling, status, and UI state.
//!
//! ## State Machine Transitions
//!
//! ```text
//!   Running ──[phase timeout]──→ SIGTERM sent
//!     │                            │
//!     │                      [15s grace]
//!     │                            │
//!     │                            ▼
//!     │                      hard kill + determine_recovery_mode
//!     │                            │
//!     │               ┌────────────┼────────────┐
//!     │               ▼            ▼            ▼
//!     │           Evaluate      Resume        Retry
//!     │           (arc done)   (has phase)   (no arc)
//!     │               │            │            │
//!     │               ▼            ▼            ▼
//!     │           merge detect  cooldown     cooldown
//!     │                            │            │
//!     │                      [Phase 1: recreate session]
//!     │                            │
//!     │                      [12s init wait]
//!     │                            │
//!     │                      [Phase 2: send /arc or /arc --resume]
//!     │                            │
//!     └────────────────────────────┘
//! ```

use std::time::{Duration, Instant};

use chrono::Utc;

use crate::app::App;
use crate::monitor;
use crate::tmux::Tmux;
use crate::types::*;

/// Read an env var as u64, falling back to a default value.
fn env_or_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

impl App {
    /// Check if current phase has exceeded its timeout.
    /// Sends SIGTERM to Claude Code process, then after 15s grace period,
    /// hard-kills the tmux session and triggers auto-resume.
    pub(crate) fn check_phase_timeout(&mut self) {
        let run = match &mut self.execution.current_run {
            Some(r) => r,
            None => return,
        };

        // Skip if completion already detected (race guard)
        if run.merge_detected_at.is_some() {
            return;
        }

        // Check SIGTERM grace period first (15s after SIGTERM → hard kill)
        if let Some(triggered_at) = run.timeout_triggered_at {
            if triggered_at.elapsed() >= Duration::from_secs(15) {
                // Grace period expired — attempt auto-resume instead of failing
                let session = run.tmux_session.clone();
                let _ = Tmux::kill_session(&session);
                self.handle_timeout_resume();
            }
            return; // Waiting for grace period — don't re-check timeout
        }

        // Check if current phase has exceeded its timeout
        let (phase_name, started) = match (&run.current_phase_name, run.current_phase_started) {
            (Some(name), Some(started)) => (name.clone(), started),
            _ => return, // No phase tracked yet
        };

        let timeout = self.execution.phase_timeout_config.timeout_for(&phase_name);
        if started.elapsed() < timeout {
            return; // Not timed out yet
        }

        // Timeout exceeded — send SIGTERM to Claude Code process
        let pid_to_kill = run.claude_pid;
        run.timeout_triggered_at = Some(Instant::now());

        if let Some(pid) = pid_to_kill {
            // Guard: reject PIDs that would silently truncate when cast to i32.
            // libc::kill expects pid_t (i32), so PIDs > i32::MAX are invalid.
            if pid > i32::MAX as u32 {
                self.set_status(format!(
                    "Phase timeout: PID {} exceeds i32::MAX, killing tmux (phase: {})",
                    pid, phase_name,
                ));
                if let Some(run) = &self.execution.current_run {
                    let _ = Tmux::kill_session(&run.tmux_session);
                }
                self.handle_timeout_resume();
                return;
            }
            // SAFETY: libc::kill sends a signal to a process. We use SIGTERM (graceful).
            let ret = unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
            if ret != 0 {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::ESRCH) {
                    // Process already gone — skip 15s grace, go straight to tmux kill + resume
                    self.set_status(format!(
                        "Phase timeout: PID {} already exited, killing tmux (phase: {})",
                        pid, phase_name,
                    ));
                    if let Some(run) = &self.execution.current_run {
                        let _ = Tmux::kill_session(&run.tmux_session);
                    }
                    self.handle_timeout_resume();
                } else if err.raw_os_error() == Some(libc::EPERM) {
                    self.set_status(format!(
                        "Phase timeout: SIGTERM to PID {} denied (EPERM) (phase: {}, limit: {}m)",
                        pid, phase_name, timeout.as_secs() / 60,
                    ));
                } else {
                    self.set_status(format!(
                        "Phase timeout: SIGTERM to PID {} failed: {} (phase: {})",
                        pid, err, phase_name,
                    ));
                }
            } else {
                self.set_status(format!(
                    "Phase timeout: SIGTERM sent to PID {} (phase: {}, limit: {}m)",
                    pid, phase_name, timeout.as_secs() / 60,
                ));
            }
        } else {
            // No PID available — fall back to tmux kill + immediate resume
            self.set_status(format!(
                "Phase timeout: no PID, killing tmux (phase: {}, limit: {}m)",
                phase_name,
                timeout.as_secs() / 60,
            ));
            if let Some(ref run) = self.execution.current_run {
                let _ = Tmux::kill_session(&run.tmux_session);
            }
            self.handle_timeout_resume();
        }
    }

    /// Handle auto-resume after a phase timeout kill.
    /// Determines recovery mode (Retry vs Resume vs Evaluate) BEFORE session
    /// recreation resets `run.arc` and `run.last_status` to None.
    pub(crate) fn handle_timeout_resume(&mut self) {
        use crate::resume::RecoveryMode;

        let max_resumes = env_or_u64("TORRENT_MAX_RESUMES", 3) as u32;

        // Determine recovery mode BEFORE taking mutable borrow on resume_state.
        let mode = match &self.execution.current_run {
            Some(run) => Self::determine_recovery_mode(run),
            None => return,
        };

        let run = match &mut self.execution.current_run {
            Some(r) => r,
            None => return,
        };

        // Store mode on RunState so check_restart_cooldown Phase 2 can use it
        run.recovery_mode = Some(mode);
        run.session_recreated = false;

        let resume_state = match &mut run.resume_state {
            Some(s) => s,
            None => return,
        };

        match mode {
            RecoveryMode::Evaluate => {
                self.status_message = Some("Arc completed during timeout — evaluating".into());
                self.status_message_set_at = Some(Instant::now());
                if let Some(run) = &mut self.execution.current_run {
                    run.merge_detected_at = Some(Instant::now());
                }
                return;
            }
            RecoveryMode::Retry => {
                let max_retries = env_or_u64("TORRENT_MAX_RETRIES", 3) as u32;
                if resume_state.retry_count >= max_retries {
                    self.status_message = Some(format!(
                        "Pre-arc retry budget exhausted ({}/{}) — skipping plan",
                        resume_state.retry_count, max_retries
                    ));
                    self.status_message_set_at = Some(Instant::now());
                    let _ = resume_state.save();
                    self.cleanup_skipped_plan();
                    return;
                }
                resume_state.retry_count += 1;
                resume_state.record_restart(0, "pre_arc", "phase_timeout", RecoveryMode::Retry);
            }
            RecoveryMode::Resume => {
                let phase_name = run.current_phase_name.clone().unwrap_or_default();
                let phase_index = {
                    use std::hash::{Hash, Hasher};
                    let mut h = std::collections::hash_map::DefaultHasher::new();
                    phase_name.hash(&mut h);
                    (h.finish() % 1000) as u32
                };

                if resume_state.should_skip(phase_index, max_resumes) {
                    self.status_message = Some(format!(
                        "Phase {} stuck {} times — skipping plan",
                        phase_name, max_resumes
                    ));
                    self.status_message_set_at = Some(Instant::now());
                    let _ = resume_state.save();
                    self.cleanup_skipped_plan();
                    return;
                }

                resume_state.record_restart(phase_index, &phase_name, "phase_timeout", RecoveryMode::Resume);
                resume_state.resume_count += 1;
            }
        }

        // Rapid failure escalation: skip immediately if 3+ restarts in <30s
        if resume_state.should_skip_rapid() {
            let phase_name = run.current_phase_name.clone().unwrap_or_else(|| "pre_arc".into());
            self.status_message = Some(format!(
                "RAPID FAILURE: {} restarts in <30s on {} — skipping plan (systemic issue)",
                resume_state.total_restarts, phase_name
            ));
            self.status_message_set_at = Some(Instant::now());
            let _ = resume_state.save();
            self.cleanup_skipped_plan();
            return;
        }

        let _ = resume_state.save();

        // Escalating cooldown based on restart density
        let cooldown_secs = resume_state.effective_cooldown(
            env_or_u64("TORRENT_RESTART_COOLDOWN", 60)
        );
        run.restart_cooldown_until = Some(Instant::now() + Duration::from_secs(cooldown_secs));

        let phase_name = run.current_phase_name.clone().unwrap_or_else(|| "pre_arc".into());
        self.status_message = Some(format!(
            "{} timeout on {} — restarting in {}s (mode: {:?})",
            match mode { RecoveryMode::Retry => "Pre-arc", _ => "Phase" },
            phase_name, cooldown_secs, mode
        ));
        self.status_message_set_at = Some(Instant::now());
    }

    /// Determine recovery mode based on current RunState.
    /// Must be called BEFORE session recreation resets run.arc/last_status.
    pub(crate) fn determine_recovery_mode(run: &RunState) -> crate::resume::RecoveryMode {
        use crate::resume::RecoveryMode;

        if let Some(ref status) = run.last_status {
            if status.completion.is_some() {
                return RecoveryMode::Evaluate;
            }
            return RecoveryMode::Resume;
        }
        if run.arc.is_some() {
            return RecoveryMode::Resume;
        }
        RecoveryMode::Retry
    }

    /// Check if a restart cooldown has expired and execute the restart.
    ///
    /// Two-phase non-blocking state machine (PERF-001 FIX):
    /// Phase 1: Cooldown expires → create new tmux session, set init_wait deadline (12s)
    /// Phase 2: Init wait expires → send /arc --resume command
    pub(crate) fn check_restart_cooldown(&mut self) {
        let run = match &self.execution.current_run {
            Some(r) => r,
            None => return,
        };

        let cooldown_deadline = match run.restart_cooldown_until {
            Some(d) => d,
            None => return,
        };

        let now = Instant::now();
        if now < cooldown_deadline {
            let remaining = cooldown_deadline.duration_since(now).as_secs();
            if remaining > 0 {
                self.set_status(format!("Restarting in {}s...", remaining));
            }
            return;
        }

        let already_recreated = run.session_recreated;
        let plan_path = run.plan.path.clone();

        if !already_recreated {
            // Phase 1: Cooldown just expired — create session + set init wait
            let config_idx = run.config_idx;
            let config = match self.config_dirs.get(config_idx) {
                Some(c) => c.clone(),
                None => return,
            };
            let old_session = run.tmux_session.clone();
            let cwd = std::env::current_dir().unwrap_or_default();

            match crate::tmux::Tmux::recreate_session(
                &old_session, &cwd, &config.path, &self.claude_path, None
            ) {
                Ok(new_session_id) => {
                    if let Some(run) = &mut self.execution.current_run {
                        run.tmux_session = new_session_id.clone();
                        run.restart_cooldown_until = Some(Instant::now() + Duration::from_secs(12));
                        run.timeout_triggered_at = None;
                        run.current_phase_started = None;
                        run.launched_at = Instant::now();
                        run.arc = None;
                        run.last_status = None;
                        run.session_recreated = true;
                    }
                    self.execution.tmux_session_id = Some(new_session_id);
                    self.polling.reset(crate::polling::DISCOVERY);
                    self.set_status("Session recreated — waiting for Claude Code init...");
                }
                Err(e) => {
                    self.set_status(format!("Restart failed: {} — skipping plan", e));
                    self.cleanup_skipped_plan();
                }
            }
        } else {
            // Phase 2: Init wait expired — send command based on recovery mode
            let mode = run.recovery_mode.unwrap_or(crate::resume::RecoveryMode::Retry);
            let session = run.tmux_session.clone();

            let bp = if self.messaging.channels_enabled {
                self.execution.current_run.as_ref()
                    .and_then(|r| r.channel_state.as_ref())
                    .and_then(|cs| cs.bridge_port)
            } else {
                None
            };

            match mode {
                crate::resume::RecoveryMode::Retry => {
                    if Self::send_arc_prefer_bridge(&session, &plan_path, 3, bp, false).is_none() {
                        self.set_status("Failed to send /arc (retry)");
                    } else {
                        let transport = if bp.is_some() { "bridge" } else { "tmux" };
                        self.set_status("Retrying with fresh /arc");
                        self.push_bridge_message(BridgeMessage {
                            text: format!("/arc {} (retry) [{}]", plan_path.display(), transport),
                            timestamp: chrono::Local::now().time(),
                            kind: BridgeMessageKind::Sent,
                        });
                    }
                }
                crate::resume::RecoveryMode::Resume => {
                    if Self::send_arc_prefer_bridge(&session, &plan_path, 3, bp, true).is_none() {
                        self.set_status("Failed to send /arc --resume");
                    } else {
                        let transport = if bp.is_some() { "bridge" } else { "tmux" };
                        self.set_status("Resuming with /arc --resume");
                        self.push_bridge_message(BridgeMessage {
                            text: format!("/arc {} --resume (recovery) [{}]", plan_path.display(), transport),
                            timestamp: chrono::Local::now().time(),
                            kind: BridgeMessageKind::Sent,
                        });
                    }
                }
                crate::resume::RecoveryMode::Evaluate => {
                    self.set_status("Arc completed — evaluating result");
                    if let Some(run) = &mut self.execution.current_run {
                        run.merge_detected_at = Some(Instant::now());
                    }
                }
            }
            if let Some(run) = &mut self.execution.current_run {
                run.restart_cooldown_until = None;
            }
        }
    }

    /// Compute adaptive grace duration from runtime metrics (F4).
    /// Formula: base + (child_count * 2) + (cpu_percent * 0.5), clamped to [min, max].
    pub(crate) fn compute_grace_duration(&self) -> Duration {
        let legacy_secs: Option<u64> = std::env::var("GRACE_PERIOD_SECS")
            .ok()
            .and_then(|s| s.parse().ok());
        let has_new_vars = std::env::var("TORRENT_GRACE_BASE").is_ok()
            || std::env::var("TORRENT_GRACE_MIN").is_ok()
            || std::env::var("TORRENT_GRACE_MAX").is_ok();

        if let Some(secs) = legacy_secs {
            if !has_new_vars {
                return Duration::from_secs(secs);
            }
        }

        let base = env_or_u64("TORRENT_GRACE_BASE", 30);
        let min = env_or_u64("TORRENT_GRACE_MIN", 10);
        let max = env_or_u64("TORRENT_GRACE_MAX", 120);

        let child_count = self.execution.current_run
            .as_ref()
            .and_then(|r| r.last_status.as_ref())
            .and_then(|s| s.resource.as_ref())
            .map(|r| r.child_count as u64)
            .unwrap_or(0);

        let cpu = self.execution.current_run
            .as_ref()
            .and_then(|r| r.last_status.as_ref())
            .and_then(|s| s.resource.as_ref())
            .map(|r| r.cpu_percent.clamp(0.0, 100.0))
            .unwrap_or(0.0);

        let secs = base
            .saturating_add(child_count.saturating_mul(2))
            .saturating_add((cpu * 0.5) as u64);
        Duration::from_secs(secs.clamp(min, max))
    }

    /// Check if grace period has elapsed after merge detection (F4).
    pub(crate) fn check_grace_period(&mut self, now: Instant) {
        // Compute and cache grace duration on first call after merge detection
        let grace_duration = if let Some(ref run) = self.execution.current_run {
            if run.merge_detected_at.is_some() && run.grace_duration.is_none() {
                let computed = self.compute_grace_duration();
                if let Some(ref mut run) = self.execution.current_run {
                    run.grace_duration = Some(computed);
                }
                computed
            } else {
                run.grace_duration.unwrap_or_else(|| Duration::from_secs(30))
            }
        } else {
            return;
        };

        // Handle skip: check if fixed skip deadline has passed
        let skip_triggered = self.execution.current_run
            .as_ref()
            .and_then(|r| r.grace_skip_at)
            .map(|deadline| now >= deadline)
            .unwrap_or(false);

        let should_complete = skip_triggered || self
            .execution.current_run
            .as_ref()
            .and_then(|r| r.merge_detected_at)
            .map(|detected| now.duration_since(detected) >= grace_duration)
            .unwrap_or(false);

        if should_complete {
            if let Some(run) = self.execution.current_run.take() {
                let _ = Tmux::kill_session(&run.tmux_session);
                self.execution.tmux_session_id = None;

                let result = if let Some(status) = &run.last_status {
                    let pr = status.pr_url.clone();
                    match &status.completion {
                        Some(monitor::ArcCompletion::Shipped) => ArcCompletion::Shipped { pr_url: pr },
                        Some(monitor::ArcCompletion::Failed) => ArcCompletion::Failed {
                            reason: "arc reported failure".into(),
                        },
                        Some(monitor::ArcCompletion::Cancelled) => ArcCompletion::Cancelled {
                            reason: Some("arc cancelled".into()),
                        },
                        _ => ArcCompletion::Merged { pr_url: pr },
                    }
                } else {
                    ArcCompletion::Merged { pr_url: None }
                };

                let (phases_completed, phases_total, phases_skipped) =
                    run.last_status.as_ref()
                        .map(|s| (s.phase_summary.completed, s.phase_summary.total, s.phase_summary.skipped))
                        .unwrap_or((0, 0, 0));
                let config_dir = self.config_dirs.get(run.config_idx)
                    .map(|c| c.path.display().to_string())
                    .unwrap_or_else(|| "~/.claude".to_string());

                let arc_id = run.arc_id();
                let duration = run.arc_duration();
                let resume_restarts = run.resume_state.as_ref().and_then(|rs| {
                    if rs.total_restarts == 0 { return None; }
                    let events: Vec<crate::log::RestartEvent> = rs.phase_retries.iter()
                        .flat_map(|(&_idx, &count)| {
                            (0..count).map(move |i| crate::log::RestartEvent {
                                iteration: i,
                                timestamp: rs.last_restart_at.unwrap_or_else(Utc::now),
                                reason: rs.last_restart_reason.clone(),
                            })
                        })
                        .take(crate::log::MAX_RESTARTS)
                        .collect();
                    if events.is_empty() { None } else { Some(events) }
                });
                let completed = CompletedRun {
                    plan: run.plan,
                    result,
                    duration,
                    arc_id,
                    resume_restarts,
                };

                let (status, urgency) = crate::log::classify_completion(&completed.result);
                let final_outcome = match (&status, &urgency) {
                    (crate::log::RunStatus::Completed, crate::log::UrgencyTier::Green) => "completed",
                    (crate::log::RunStatus::Completed, _) => "completed_with_restarts",
                    (crate::log::RunStatus::Skipped, _) => "skipped",
                    (crate::log::RunStatus::Failed, _) => "failed",
                };
                let entry = crate::log::RunLogEntry {
                    timestamp: Utc::now(),
                    plan: completed.plan.name.clone(),
                    plan_file: completed.plan.path.display().to_string(),
                    config_dir,
                    arc_id: completed.arc_id.clone(),
                    status,
                    urgency,
                    phases_completed,
                    phases_total,
                    phases_skipped,
                    wallclock_seconds: completed.duration.as_secs(),
                    pr_url: match &completed.result {
                        ArcCompletion::Merged { pr_url } | ArcCompletion::Shipped { pr_url } => {
                            pr_url.clone()
                        }
                        _ => None,
                    },
                    error: match &completed.result {
                        ArcCompletion::Failed { reason } => Some(reason.clone()),
                        _ => None,
                    },
                    final_outcome: final_outcome.to_string(),
                    restarts: completed.resume_restarts.clone().unwrap_or_default(),
                };
                if let Err(e) = crate::log::append_run_log(&entry) {
                    tlog!(WARN, "failed to write run log: {}", e);
                }

                let was_success = matches!(
                    &completed.result,
                    ArcCompletion::Merged { .. } | ArcCompletion::Shipped { .. }
                );
                self.execution.completed_runs.push(completed);

                if was_success && !self.execution.queue.is_empty() {
                    let cooldown_secs = env_or_u64("TORRENT_INTER_PLAN_COOLDOWN", 300);
                    if cooldown_secs > 0 {
                        self.execution.inter_plan_cooldown_until =
                            Some(Instant::now() + Duration::from_secs(cooldown_secs));
                    }
                }

                let total = self.queue_total_items();
                if total > 0 && self.queue_cursor >= total {
                    self.queue_cursor = total - 1;
                }
            }
        }
    }

    /// Clean up a plan that has been skipped (exhausted retries or restart failure).
    pub(crate) fn cleanup_skipped_plan(&mut self) {
        if let Some(run) = self.execution.current_run.take() {
            let _ = crate::tmux::Tmux::kill_session(&run.tmux_session);
            let cwd = std::env::current_dir().unwrap_or_default();
            let loop_file = cwd.join(".rune").join("arc-phase-loop.local.md");
            let _ = std::fs::remove_file(&loop_file);

            let arc_id = run.arc_id();
            let duration = run.arc_duration();
            let phase = run
                .current_phase_name
                .as_deref()
                .unwrap_or("unknown")
                .to_string();
            self.execution.completed_runs.push(CompletedRun {
                plan: run.plan,
                result: ArcCompletion::Failed {
                    reason: format!("skipped: phase {} exceeded retry budget", phase),
                },
                duration,
                arc_id,
                resume_restarts: None,
            });
        }
        self.execution.tmux_session_id = None;
        let total = self.queue_total_items();
        if total > 0 && self.queue_cursor >= total {
            self.queue_cursor = total - 1;
        }
    }
}
