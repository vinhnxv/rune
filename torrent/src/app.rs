use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::Utc;
use color_eyre::eyre::eyre;
use color_eyre::Result;

use crate::monitor;
use crate::scanner::{ConfigDir, PlanFile};
use crate::tmux::Tmux;

/// Top-level application state.
pub struct App {
    // Selection view
    pub config_dirs: Vec<ConfigDir>,
    pub selected_config: usize,
    pub plans: Vec<PlanFile>,
    pub selected_plans: Vec<usize>, // ordered indices — execution order
    pub active_panel: Panel,

    // Execution view
    pub view: AppView,
    pub queue: VecDeque<usize>,
    pub current_run: Option<RunState>,
    pub completed_runs: Vec<CompletedRun>,
    pub tmux_session_id: Option<String>,

    // UI state
    pub config_cursor: usize,
    pub plan_cursor: usize,

    // Polling timers (non-blocking, checked on each tick)
    pub last_discovery_poll: Option<Instant>,
    pub last_heartbeat_poll: Option<Instant>,
    pub last_checkpoint_poll: Option<Instant>,
    pub launched_wall_clock: Option<chrono::DateTime<Utc>>,

    // Status message for display in UI
    pub status_message: Option<String>,

    // Whether we should quit
    pub should_quit: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppView {
    Selection,
    Running,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Panel {
    ConfigList,
    PlanList,
}

/// State of the currently executing arc run.
pub struct RunState {
    pub plan: PlanFile,
    pub plan_index: usize,   // 1-indexed position in selected_plans
    pub total_plans: usize,
    pub tmux_session: String,
    pub launched_at: Instant,
    pub arc: Option<ArcHandle>,
    pub last_status: Option<ArcStatus>,
    pub merge_detected_at: Option<Instant>,
}

/// Handle to a discovered arc checkpoint + heartbeat pair.
pub struct ArcHandle {
    pub arc_id: String,
    pub checkpoint_path: PathBuf,
    pub heartbeat_path: PathBuf,
    pub plan_file: String,
    pub config_dir: String,
    pub owner_pid: String,
}

/// Polled status of a running arc.
#[derive(Clone)]
pub struct ArcStatus {
    pub arc_id: String,
    pub current_phase: String,
    pub last_tool: String,
    pub last_activity: String,
    pub phase_summary: PhaseSummary,
    pub pr_url: Option<String>,
    pub is_stale: bool,
}

#[derive(Clone)]
pub struct PhaseSummary {
    pub completed: u32,
    pub total: u32,
    pub skipped: u32,
    pub current_phase_name: String,
}

/// Result of a completed arc run.
pub struct CompletedRun {
    pub plan: PlanFile,
    pub arc_id: String,
    pub result: ArcCompletion,
    pub pr_url: Option<String>,
    pub duration: Duration,
}

#[derive(Debug, Clone)]
pub enum ArcCompletion {
    Merged { pr_url: Option<String> },
    Shipped { pr_url: Option<String> },
    Cancelled { reason: Option<String> },
    Failed { reason: String },
}

/// Actions dispatched from keybinding handler.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    // Selection view
    Quit,
    RunSelected,
    ToggleAll,
    SwitchPanel,
    SelectConfig,
    TogglePlan,
    MoveUp,
    MoveDown,
    // Running view
    AttachTmux,
    SkipPlan,
    KillSession,
    // No-op
    None,
}

impl App {
    pub fn new() -> Result<Self> {
        let config_dirs = crate::scanner::scan_config_dirs()?;
        let cwd = std::env::current_dir()?;
        let plans = crate::scanner::scan_plans(&cwd)?;

        Ok(Self {
            config_dirs,
            selected_config: 0,
            plans,
            selected_plans: Vec::new(),
            active_panel: Panel::ConfigList,
            view: AppView::Selection,
            queue: VecDeque::new(),
            current_run: None,
            completed_runs: Vec::new(),
            tmux_session_id: None,
            config_cursor: 0,
            plan_cursor: 0,
            last_discovery_poll: None,
            last_heartbeat_poll: None,
            last_checkpoint_poll: None,
            launched_wall_clock: None,
            status_message: None,
            should_quit: false,
        })
    }

    /// Switch active panel between config list and plan list.
    pub fn switch_panel(&mut self) {
        self.active_panel = match self.active_panel {
            Panel::ConfigList => Panel::PlanList,
            Panel::PlanList => Panel::ConfigList,
        };
    }

    /// Move cursor up in the active panel.
    pub fn move_up(&mut self) {
        match self.active_panel {
            Panel::ConfigList => {
                if self.config_cursor > 0 {
                    self.config_cursor -= 1;
                }
            }
            Panel::PlanList => {
                if self.plan_cursor > 0 {
                    self.plan_cursor -= 1;
                }
            }
        }
    }

    /// Move cursor down in the active panel.
    pub fn move_down(&mut self) {
        match self.active_panel {
            Panel::ConfigList => {
                if self.config_cursor + 1 < self.config_dirs.len() {
                    self.config_cursor += 1;
                }
            }
            Panel::PlanList => {
                if self.plan_cursor + 1 < self.plans.len() {
                    self.plan_cursor += 1;
                }
            }
        }
    }

    /// Select the config dir at the current cursor position.
    pub fn select_config(&mut self) {
        if !self.config_dirs.is_empty() {
            self.selected_config = self.config_cursor;
        }
    }

    /// Toggle a plan at the current cursor — ordered multi-select.
    /// Selection order determines execution order.
    pub fn toggle_plan(&mut self) {
        if self.plans.is_empty() {
            return;
        }
        let idx = self.plan_cursor;
        if let Some(pos) = self.selected_plans.iter().position(|&i| i == idx) {
            // Already selected — remove it (reorders remaining)
            self.selected_plans.remove(pos);
        } else {
            // Not selected — add to end (becomes last in execution order)
            self.selected_plans.push(idx);
        }
    }

    /// Toggle all plans. If any are selected, deselect all. Otherwise select all in file order.
    pub fn toggle_all(&mut self) {
        if self.selected_plans.is_empty() {
            self.selected_plans = (0..self.plans.len()).collect();
        } else {
            self.selected_plans.clear();
        }
    }

    /// Get the execution order number (1-indexed) for a plan index, or None if not selected.
    pub fn plan_order(&self, plan_index: usize) -> Option<usize> {
        self.selected_plans
            .iter()
            .position(|&i| i == plan_index)
            .map(|pos| pos + 1)
    }

    /// Transition to Running view — populate the execution queue.
    pub fn start_run(&mut self) {
        self.view = AppView::Running;
        self.queue = self.selected_plans.iter().copied().collect();
    }

    /// Print a summary to stdout after terminal is restored.
    pub fn print_quit_summary(&self) {
        let total = self.selected_plans.len();
        let completed = self.completed_runs.len();

        if total == 0 {
            return;
        }

        println!();
        if let Some(ref session_id) = self.tmux_session_id {
            println!(
                "Torrent — exiting (tmux session {} still running)",
                session_id
            );
        } else {
            println!("Torrent — exiting");
        }
        println!();
        println!("Completed: {}/{} plans", completed, total);

        // Show completed runs
        for run in &self.completed_runs {
            let result_str = match &run.result {
                ArcCompletion::Merged { pr_url } => {
                    let url = pr_url.as_deref().unwrap_or("");
                    format!("{} merged", url)
                }
                ArcCompletion::Shipped { pr_url } => {
                    let url = pr_url.as_deref().unwrap_or("");
                    format!("{} shipped", url)
                }
                ArcCompletion::Cancelled { reason } => {
                    let r = reason.as_deref().unwrap_or("cancelled");
                    format!("{}", r)
                }
                ArcCompletion::Failed { reason } => {
                    format!("failed: {}", reason)
                }
            };
            let mins = run.duration.as_secs() / 60;
            println!("  ✓ {:<30} {:<30} ({}m)", run.plan.name, result_str, mins);
        }

        // Show current run
        if let Some(ref run) = self.current_run {
            let phase = run
                .last_status
                .as_ref()
                .map(|s| s.current_phase.as_str())
                .unwrap_or("starting");
            println!("  ▶ {:<30} {} phase  (running)", run.plan.name, phase);
        }

        // Show pending plans in queue
        for &idx in &self.queue {
            if let Some(plan) = self.plans.get(idx) {
                println!("  ○ {:<30} pending", plan.name);
            }
        }

        // Show reattach hint
        if let Some(ref session_id) = self.tmux_session_id {
            println!();
            println!("Reattach: tmux attach -t {}", session_id);
        }
    }

    /// Dispatch an action (from keybinding handler).
    pub fn handle_action(&mut self, action: Action) -> Result<()> {
        match action {
            Action::Quit => self.should_quit = true,
            Action::SwitchPanel => self.switch_panel(),
            Action::MoveUp => self.move_up(),
            Action::MoveDown => self.move_down(),
            Action::SelectConfig => self.select_config(),
            Action::TogglePlan => self.toggle_plan(),
            Action::ToggleAll => self.toggle_all(),
            Action::RunSelected => {
                if !self.selected_plans.is_empty() && !self.config_dirs.is_empty() {
                    self.start_run();
                }
            }
            Action::AttachTmux => {
                if let Some(session_id) = &self.tmux_session_id {
                    let sid = session_id.clone();
                    // Attach blocks — TUI suspends until user detaches (Ctrl-B D)
                    let _ = Tmux::attach(&sid);
                }
            }
            Action::SkipPlan => self.skip_current_plan(),
            Action::KillSession => self.kill_current_session(),
            Action::None => {}
        }
        Ok(())
    }

    /// Skip the current plan — kill tmux, move to next.
    fn skip_current_plan(&mut self) {
        if let Some(run) = self.current_run.take() {
            let _ = Tmux::kill_session(&run.tmux_session);
            self.completed_runs.push(CompletedRun {
                plan: run.plan,
                arc_id: run.arc.map(|a| a.arc_id).unwrap_or_default(),
                result: ArcCompletion::Cancelled {
                    reason: Some("skipped by user".into()),
                },
                pr_url: None,
                duration: run.launched_at.elapsed(),
            });
            self.tmux_session_id = None;
        }
    }

    /// Kill the current tmux session and stop all execution.
    fn kill_current_session(&mut self) {
        if let Some(session_id) = &self.tmux_session_id {
            let _ = Tmux::kill_session(session_id);
        }
        if let Some(run) = self.current_run.take() {
            self.completed_runs.push(CompletedRun {
                plan: run.plan,
                arc_id: run.arc.map(|a| a.arc_id).unwrap_or_default(),
                result: ArcCompletion::Failed {
                    reason: "killed by user".into(),
                },
                pr_url: None,
                duration: run.launched_at.elapsed(),
            });
        }
        self.tmux_session_id = None;
        self.queue.clear();
    }

    /// Main execution tick — called every ~1s from the event loop.
    ///
    /// Handles: launching new plans, discovery polling, heartbeat/checkpoint
    /// polling, completion detection with grace period.
    pub fn tick_execution(&mut self) -> Result<()> {
        if self.view != AppView::Running {
            return Ok(());
        }

        let now = Instant::now();

        if self.current_run.is_none() {
            // No arc running — start next plan from queue
            if let Some(plan_idx) = self.queue.pop_front() {
                self.launch_next_plan(plan_idx)?;
            }
            return Ok(());
        }

        // Arc running — poll for discovery or status
        let has_arc = self.current_run.as_ref().unwrap().arc.is_some();

        if !has_arc {
            // Discovery polling (every 10s)
            let should_poll = self
                .last_discovery_poll
                .map(|t| now.duration_since(t) >= Duration::from_secs(10))
                .unwrap_or(true);

            if should_poll {
                self.poll_discovery();
                self.last_discovery_poll = Some(now);
            }
        } else {
            // Heartbeat polling (every 5s)
            let should_poll_hb = self
                .last_heartbeat_poll
                .map(|t| now.duration_since(t) >= Duration::from_secs(5))
                .unwrap_or(true);

            if should_poll_hb {
                self.poll_status();
                self.last_heartbeat_poll = Some(now);
            }

            // Check grace period completion
            self.check_grace_period(now);
        }

        Ok(())
    }

    /// Launch the next plan: git checkout main, create tmux session, send /arc.
    fn launch_next_plan(&mut self, plan_idx: usize) -> Result<()> {
        let plan = self.plans.get(plan_idx).cloned().ok_or_else(|| {
            eyre!("plan index {plan_idx} out of bounds")
        })?;
        let config = self.config_dirs.get(self.selected_config).ok_or_else(|| {
            eyre!("no config dir selected")
        })?;

        // Step 1: git checkout main + pull (blocking, before tmux)
        let checkout = Command::new("git")
            .args(["checkout", "main"])
            .status();
        if checkout.map_or(true, |s| !s.success()) {
            self.status_message = Some("git checkout main failed — clean up working tree".into());
            // Re-queue the plan for retry after user fixes
            self.queue.push_front(plan_idx);
            return Ok(());
        }
        let pull = Command::new("git")
            .args(["pull", "--ff-only"])
            .status();
        if pull.map_or(true, |s| !s.success()) {
            self.status_message = Some("git pull --ff-only failed — try git pull --rebase manually".into());
            // Continue anyway — local main may be slightly behind but usable
        }

        // Step 2: Record wall-clock time BEFORE launch (for discovery matching)
        self.launched_wall_clock = Some(Utc::now());

        // Step 3: Create fresh tmux session
        let session_id = Tmux::generate_session_id();
        if let Err(e) = Tmux::create_session(&config.path, &session_id) {
            self.status_message = Some(format!("tmux session failed: {e} — skipping plan"));
            return Ok(()); // Skip this plan, next tick will try next in queue
        }
        self.tmux_session_id = Some(session_id.clone());

        // Step 4: Wait for Claude Code to fully initialize (10s)
        // Claude Code needs ~8-10s to start up in a tmux session.
        // Too short causes send-keys to fail (message sent before CLI is ready).
        std::thread::sleep(Duration::from_secs(10));

        // Step 5: Send /arc command with retry
        // If first attempt fails (Claude still loading), wait and retry once.
        if let Err(e) = Tmux::send_arc_command(&session_id, &plan.path) {
            self.status_message = Some(format!("send-keys failed, retrying in 5s: {e}"));
            std::thread::sleep(Duration::from_secs(5));
            if let Err(e2) = Tmux::send_arc_command(&session_id, &plan.path) {
                self.status_message = Some(format!("send-keys failed after retry: {e2}"));
                // Don't abort — session is created, user can attach and send manually
            }
        }

        let total = self.selected_plans.len();
        self.current_run = Some(RunState {
            plan,
            plan_index: self.completed_runs.len() + 1,
            total_plans: total,
            tmux_session: session_id,
            launched_at: Instant::now(),
            arc: None,
            last_status: None,
            merge_detected_at: None,
        });

        // Reset poll timers
        self.last_discovery_poll = None;
        self.last_heartbeat_poll = None;
        self.last_checkpoint_poll = None;

        Ok(())
    }

    /// Poll for arc discovery — scan .claude/arc/ for matching checkpoint.
    fn poll_discovery(&mut self) {
        let launched_after = match self.launched_wall_clock {
            Some(t) => t,
            None => return,
        };

        let run = match &self.current_run {
            Some(r) => r,
            None => return,
        };

        let cwd = std::env::current_dir().unwrap_or_default();
        if let Some(handle) = monitor::discover_arc(&cwd, &run.plan.path, launched_after) {
            // Convert monitor::ArcHandle to app::ArcHandle
            if let Some(run) = &mut self.current_run {
                run.arc = Some(ArcHandle {
                    arc_id: handle.arc_id,
                    checkpoint_path: handle.checkpoint_path,
                    heartbeat_path: handle.heartbeat_path,
                    plan_file: handle.plan_file,
                    config_dir: handle.config_dir,
                    owner_pid: handle.owner_pid,
                });
            }
        }
    }

    /// Poll arc status (heartbeat + checkpoint) and update display state.
    fn poll_status(&mut self) {
        let run = match &mut self.current_run {
            Some(r) => r,
            None => return,
        };

        let arc = match &run.arc {
            Some(a) => a,
            None => return,
        };

        // Build a monitor::ArcHandle for the poll call
        let monitor_handle = monitor::ArcHandle {
            arc_id: arc.arc_id.clone(),
            checkpoint_path: arc.checkpoint_path.clone(),
            heartbeat_path: arc.heartbeat_path.clone(),
            plan_file: arc.plan_file.clone(),
            config_dir: arc.config_dir.clone(),
            owner_pid: arc.owner_pid.clone(),
        };

        if let Some(status) = monitor::poll_arc_status(&monitor_handle) {
            // Check for completion — start grace period
            if status.completion.is_some() && run.merge_detected_at.is_none() {
                run.merge_detected_at = Some(Instant::now());
            }

            // Convert monitor::ArcStatus to app::ArcStatus
            run.last_status = Some(ArcStatus {
                arc_id: status.arc_id,
                current_phase: status.current_phase,
                last_tool: status.last_tool,
                last_activity: status
                    .last_activity
                    .map(|dt| dt.to_rfc3339())
                    .unwrap_or_default(),
                phase_summary: PhaseSummary {
                    completed: status.phase_summary.completed,
                    total: status.phase_summary.total,
                    skipped: status.phase_summary.skipped,
                    current_phase_name: status.phase_summary.current_phase_name,
                },
                pr_url: status.pr_url,
                is_stale: status.is_stale,
            });
        }
    }

    /// Check if grace period has elapsed after merge detection.
    fn check_grace_period(&mut self, now: Instant) {
        let grace_duration = Duration::from_secs(240); // 4 minutes

        let should_complete = self
            .current_run
            .as_ref()
            .and_then(|r| r.merge_detected_at)
            .map(|detected| now.duration_since(detected) >= grace_duration)
            .unwrap_or(false);

        if should_complete {
            if let Some(run) = self.current_run.take() {
                // Kill the tmux session
                let _ = Tmux::kill_session(&run.tmux_session);
                self.tmux_session_id = None;

                // Determine completion type from last status
                let (result, pr_url) = if let Some(status) = &run.last_status {
                    (
                        ArcCompletion::Merged {
                            pr_url: status.pr_url.clone(),
                        },
                        status.pr_url.clone(),
                    )
                } else {
                    (ArcCompletion::Merged { pr_url: None }, None)
                };

                self.completed_runs.push(CompletedRun {
                    plan: run.plan,
                    arc_id: run.arc.map(|a| a.arc_id).unwrap_or_default(),
                    result,
                    pr_url,
                    duration: run.launched_at.elapsed(),
                });
            }
        }
    }
}
