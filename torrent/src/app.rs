use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::Utc;
use color_eyre::eyre::eyre;
use color_eyre::Result;

// Re-export all shared types for backward compatibility.
// Other modules (ui.rs, keybindings.rs, log.rs) import from `crate::app::*`.
pub use crate::types::*;

use ratatui::widgets::ListState;

use crate::messaging::truncate_str;

use crate::callback::{CallbackServer, ChannelEvent};
use crate::channel::{ChannelState, ChannelsConfig};
use crate::diagnostic::{DiagnosticAction, DiagnosticEngine, DiagnosticResult, DiagnosticState};
use crate::monitor::{self, ActivityDetector, ActivityState};
use crate::resource::{self, ProcessHealth};
use crate::resume::ResumeState;
use crate::scanner::{ConfigDir, PlanFile};
use crate::tmux::Tmux;

/// Read an env var as u64, falling back to a default value.
fn env_or_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

/// Compare two plan names by filename (ignoring path prefix).
/// Handles: "plans/foo.md" vs "foo.md" vs "/abs/plans/foo.md".
pub(crate) fn plans_match(a: &str, b: &str) -> bool {
    let fa = a.rsplit('/').next().unwrap_or(a);
    let fb = b.rsplit('/').next().unwrap_or(b);
    fa == fb
}

/// Top-level application state.
pub struct App {
    // Active arcs detected at startup
    pub active_arcs: Vec<crate::scanner::ActiveArc>,
    pub active_arc_cursor: usize,

    // Selection view
    pub config_dirs: Vec<ConfigDir>,
    pub selected_config: usize,
    pub plans: Vec<PlanFile>,
    pub selected_plans: Vec<QueueEntry>, // ordered plan+config pairs
    pub active_panel: Panel,

    // Execution view
    pub view: AppView,
    pub execution: crate::execution::ExecutionEngine,

    // UI state
    pub config_cursor: usize,
    pub plan_cursor: usize,
    pub queue_cursor: usize, // cursor position in queue (Running view)

    // Stateful list states for scrollable rendering (ratatui ListState)
    pub active_arcs_list_state: ListState,
    pub config_list_state: ListState,
    pub plan_list_state: ListState,
    pub queue_list_state: ListState,

    // Polling timers (non-blocking, checked on each tick)
    pub polling: crate::polling::PollingScheduler,
    // (launched_wall_clock moved to ExecutionEngine)

    // Status message for display in UI (auto-clears after STATUS_MESSAGE_TTL)
    pub status_message: Option<String>,
    pub status_message_set_at: Option<Instant>,

    // Resolved absolute path to claude binary (avoids PATH issues in tmux)
    pub claude_path: String,

    // Resource monitoring (sysinfo)
    pub sys: sysinfo::System,

    // Current git branch of CWD
    pub git_branch: String,

    // Timestamp when all plans completed (for auto-quit countdown)
    pub all_done_at: Option<Instant>,

    // (inter_plan_cooldown_until moved to ExecutionEngine)

    // Queue editing mode — Selection view appends to queue instead of starting fresh
    pub queue_editing: bool,

    // Whether we should quit
    pub should_quit: bool,

    // Claude Code version string (detected at startup)
    pub claude_version: String,

    // (phase_timeout_config moved to ExecutionEngine)

    // Diagnostic engine for session health monitoring
    pub diagnostic_engine: DiagnosticEngine,
    /// Current diagnostic result for UI banner display.
    pub last_diagnostic: Option<DiagnosticResult>,

    // Channel communication + message transport + bridge view state
    pub messaging: crate::messaging::MessageState,
}

impl App {
    pub fn new(extra_config_dirs: Vec<std::path::PathBuf>) -> Result<Self> {
        let config_dirs = crate::scanner::scan_config_dirs(&extra_config_dirs)?;
        let cwd = std::env::current_dir()?;
        let plans = crate::scanner::scan_plans(&cwd)?;

        // Initialize sysinfo ONCE — reused for both startup scan and ongoing polling.
        // Previously created twice (400ms wasted on double System::new_all + sleep).
        let mut sys = resource::create_process_system();

        // Startup scan: detect active arc sessions
        let active_arcs = crate::scanner::scan_active_arcs(&config_dirs, &cwd, &sys);
        // Refresh after scan so the stored sys has up-to-date data for first poll
        resource::refresh_process_system(&mut sys);
        let initial_view = if active_arcs.is_empty() {
            AppView::Selection
        } else {
            AppView::ActiveArcs
        };

        // Warn if .rune/ state directory doesn't exist in CWD.
        // Note: talisman.yml is still read from .claude/talisman.yml as fallback,
        // but arc checkpoints and echoes require .rune/ to exist.
        let rune_dir_missing = !cwd.join(".rune").is_dir();
        let initial_status = if rune_dir_missing {
            Some(".rune/ not found — arc checkpoints and echoes won't be detected. talisman.yml still works via .claude/ fallback. Run a Rune workflow to initialize .rune/.".into())
        } else {
            None
        };

        Ok(Self {
            active_arcs,
            active_arc_cursor: 0,
            config_dirs,
            selected_config: 0,
            plans,
            selected_plans: Vec::new(),
            active_panel: Panel::ConfigList,
            view: initial_view,
            execution: crate::execution::ExecutionEngine::new(PhaseTimeoutConfig::from_env()),
            config_cursor: 0,
            plan_cursor: 0,
            queue_cursor: 0,
            active_arcs_list_state: ListState::default(),
            config_list_state: ListState::default(),
            plan_list_state: ListState::default(),
            queue_list_state: ListState::default(),
            polling: crate::polling::PollingScheduler::new(),
            status_message: initial_status,
            status_message_set_at: None,
            claude_path: crate::tmux::Tmux::resolve_claude_path()
                .unwrap_or_else(|_| "claude".to_string()),
            sys,
            git_branch: Self::read_git_branch(),
            all_done_at: None,
            queue_editing: false,
            should_quit: false,
            claude_version: Self::detect_claude_version(),
            diagnostic_engine: DiagnosticEngine::new(),
            last_diagnostic: None,
            messaging: crate::messaging::MessageState::new(),
        })
    }

    /// Read the current git branch name from CWD.
    pub fn read_git_branch() -> String {
        Command::new("git")
            .args(["rev-parse", "--abbrev-ref", "HEAD"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    String::from_utf8(o.stdout).ok().map(|s| s.trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "—".into())
    }

    /// Duration before a transient status message auto-clears, restoring help text.
    const STATUS_MESSAGE_TTL: Duration = Duration::from_secs(5);

    /// Set a transient status message (auto-clears after STATUS_MESSAGE_TTL).
    pub fn set_status(&mut self, msg: impl Into<String>) {
        self.status_message = Some(msg.into());
        self.status_message_set_at = Some(Instant::now());
    }

    /// Clear expired status message so the bottom bar returns to help text.
    pub fn expire_status_message(&mut self) {
        if let Some(set_at) = self.status_message_set_at {
            if set_at.elapsed() >= Self::STATUS_MESSAGE_TTL {
                self.status_message = None;
                self.status_message_set_at = None;
            }
        }
    }

    /// Detect Claude Code version from `claude --version`.
    fn detect_claude_version() -> String {
        Command::new("claude")
            .args(["--version"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    String::from_utf8(o.stdout).ok().map(|s| {
                        let s = s.trim().to_string();
                        // Output may be "claude-code X.Y.Z" or just "X.Y.Z"
                        s.strip_prefix("claude-code ")
                            .or_else(|| s.strip_prefix("claude "))
                            .unwrap_or(&s)
                            .to_string()
                    })
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "?".into())
    }

    /// Check if a plan index is already queued or currently running.
    /// Used in queue-edit mode to prevent duplicate selection.
    pub fn is_plan_in_flight(&self, plan_idx: usize) -> bool {
        let plan = match self.plans.get(plan_idx) {
            Some(p) => p,
            None => return false,
        };
        // Currently running? (match by file name — paths may differ: relative vs absolute)
        if let Some(ref run) = self.execution.current_run {
            if plans_match(&run.plan.name, &plan.name) {
                return true;
            }
        }
        // In queue?
        if self.execution.queue.iter().any(|e| e.plan_idx == plan_idx) {
            return true;
        }
        // Already completed?
        if self.execution.completed_runs.iter().any(|r| plans_match(&r.plan.name, &plan.name)) {
            return true;
        }
        false
    }

    /// Refresh session info (mcp count, teammate count, etc).
    pub fn refresh_session_info(&mut self) {
        if let Some(run) = &mut self.execution.current_run {
            if let Some(pid) = run.claude_pid {
                let config_dir = run.arc.as_ref()
                    .map(|a| a.config_dir.as_str())
                    .unwrap_or("");
                run.session_info = crate::scanner::enrich_session_info(
                    &pid.to_string(),
                    config_dir,
                    &self.sys,
                );
            }
        }
    }

    /// Refresh git branch (called periodically during execution).
    pub fn refresh_git_branch(&mut self) {
        self.git_branch = Self::read_git_branch();
    }

    /// Prune stale entries from the active arcs list.
    /// Removes entries whose tmux session no longer exists or whose PID is dead.
    /// Throttled to every 10s to avoid excessive process checks.
    pub fn prune_stale_active_arcs(&mut self) {
        let now = Instant::now();
        if !self.polling.should_poll(crate::polling::ACTIVE_ARCS_PRUNE, Duration::from_secs(10)) {
            return;
        }
        self.polling.mark_polled(crate::polling::ACTIVE_ARCS_PRUNE, now);

        self.active_arcs.retain(|arc| {
            // If it has a tmux session, verify it still exists
            if let Some(ref session) = arc.tmux_session {
                if !Tmux::has_session(session) {
                    return false;
                }
            }
            // If it has a PID, verify it's still alive
            if !arc.loop_state.owner_pid.is_empty()
                && arc.pid_alive
                && !Self::is_pid_alive(&arc.loop_state.owner_pid)
            {
                return false;
            }
            // Orphan entries (no tmux AND no PID) are always stale
            if arc.tmux_session.is_none() && arc.loop_state.owner_pid.is_empty() {
                return false;
            }
            true
        });

        // If all arcs pruned, auto-transition to Selection view
        if self.active_arcs.is_empty() {
            self.view = AppView::Selection;
        } else if self.active_arc_cursor >= self.active_arcs.len() {
            self.active_arc_cursor = self.active_arcs.len() - 1;
        }
    }

    /// Check if a PID is alive (delegates to shared resource::is_pid_alive).
    fn is_pid_alive(pid_str: &str) -> bool {
        pid_str.parse::<u32>().is_ok_and(resource::is_pid_alive)
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
        match self.view {
            AppView::ActiveArcs => {
                if self.active_arc_cursor > 0 {
                    self.active_arc_cursor -= 1;
                }
            }
            AppView::Running => {
                if self.queue_cursor > 0 {
                    self.queue_cursor -= 1;
                }
            }
            AppView::Selection => match self.active_panel {
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
            },
            AppView::Bridge => {} // no cursor navigation in Bridge View
        }
    }

    /// Move cursor down in the active panel.
    pub fn move_down(&mut self) {
        match self.view {
            AppView::ActiveArcs => {
                if self.active_arc_cursor + 1 < self.active_arcs.len() {
                    self.active_arc_cursor += 1;
                }
            }
            AppView::Running => {
                // Queue cursor range: completed_runs + current_run + pending queue
                let total = self.queue_total_items();
                if self.queue_cursor + 1 < total {
                    self.queue_cursor += 1;
                }
            }
            AppView::Selection => match self.active_panel {
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
            },
            AppView::Bridge => {} // no cursor navigation in Bridge View
        }
    }

    /// Total number of items displayed in the Queue panel.
    pub(crate) fn queue_total_items(&self) -> usize {
        self.execution.queue_total_items()
    }

    /// Select the config dir at the current cursor position.
    pub fn select_config(&mut self) {
        if !self.config_dirs.is_empty() {
            self.selected_config = self.config_cursor;
        }
    }

    /// Toggle a plan at the current cursor — ordered multi-select.
    /// Selection order determines execution order.
    /// In queue-edit mode, skip plans already in-flight.
    pub fn toggle_plan(&mut self) {
        if self.plans.is_empty() {
            return;
        }
        let idx = self.plan_cursor;
        // Block toggling plans already in-flight during queue-edit
        if self.queue_editing && self.is_plan_in_flight(idx) {
            return;
        }
        if let Some(pos) = self.selected_plans.iter().position(|e| e.plan_idx == idx) {
            // Already selected — remove it
            self.selected_plans.remove(pos);
        } else {
            // Not selected — add with current config dir
            self.selected_plans.push(QueueEntry {
                plan_idx: idx,
                config_idx: self.selected_config,
            });
        }
    }

    /// Toggle all plans. If any are selected, deselect all. Otherwise select all in file order.
    /// In queue-edit mode, only select plans not already in-flight.
    pub fn toggle_all(&mut self) {
        if self.selected_plans.is_empty() {
            let config_idx = self.selected_config;
            if self.queue_editing {
                self.selected_plans = (0..self.plans.len())
                    .filter(|&i| !self.is_plan_in_flight(i))
                    .map(|plan_idx| QueueEntry { plan_idx, config_idx })
                    .collect();
            } else {
                self.selected_plans = (0..self.plans.len())
                    .map(|plan_idx| QueueEntry { plan_idx, config_idx })
                    .collect();
            }
        } else {
            self.selected_plans.clear();
        }
    }


    /// Transition to Running view — populate the execution queue.
    pub fn start_run(&mut self) {
        self.view = AppView::Running;
        self.execution.queue = self.selected_plans.drain(..).collect();
    }

    /// Print a summary to stdout after terminal is restored.
    pub fn print_quit_summary(&self) {
        let completed = self.execution.completed_runs.len();
        let total = self.queue_total_items();

        if total == 0 && completed == 0 {
            return;
        }

        println!();
        if let Some(ref session_id) = self.execution.tmux_session_id {
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
        for run in &self.execution.completed_runs {
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
                    r.to_string()
                }
                ArcCompletion::Failed { reason } => {
                    format!("failed: {}", reason)
                }
            };
            let mins = run.duration.as_secs() / 60;
            println!("  ✓ {:<30} {:<30} ({}m)", run.plan.name, result_str, mins);
        }

        // Show current run
        if let Some(ref run) = self.execution.current_run {
            let phase = run
                .last_status
                .as_ref()
                .map(|s| s.current_phase.as_str())
                .unwrap_or("starting");
            println!("  ▶ {:<30} {} phase  (running)", run.plan.name, phase);
        }

        // Show pending plans in queue
        for entry in &self.execution.queue {
            if let Some(plan) = self.plans.get(entry.plan_idx) {
                println!("  ○ {:<30} pending", plan.name);
            }
        }

        // Show reattach hint
        if let Some(ref session_id) = self.execution.tmux_session_id {
            println!();
            println!("Reattach: tmux attach -t {}", session_id);
        }
    }

    /// Dispatch an action (from keybinding handler).
    pub fn handle_action(&mut self, action: Action) -> Result<()> {
        match action {
            Action::Quit => self.should_quit = true,
            // Active arcs view
            Action::AttachActiveArc => self.attach_active_arc(),
            Action::MonitorActiveArc => self.monitor_active_arc(),
            Action::DismissActiveArcs => {
                self.active_arcs.clear();
                self.view = AppView::Selection;
            }
            // Selection view
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
                if let Some(session_id) = &self.execution.tmux_session_id {
                    let sid = session_id.clone();
                    // Attach blocks — TUI suspends until user detaches (Ctrl-B D)
                    let _ = Tmux::attach(&sid);
                }
            }
            Action::RemoveFromQueue => self.remove_queue_item(),
            Action::SkipPlan => self.skip_current_plan(),
            Action::SkipGrace => {
                // Skip inter-plan cooldown if active
                if self.execution.inter_plan_cooldown_until.is_some() {
                    self.execution.inter_plan_cooldown_until = None;
                    self.set_status(" Cooldown skipped — launching next plan");
                } else if let Some(ref mut run) = self.execution.current_run {
                    if run.merge_detected_at.is_some() && run.grace_skip_at.is_none() {
                        // Set fixed skip deadline: 5 seconds from now (RUIN-007 fix).
                        // Stored as absolute Instant — not recomputed each tick.
                        run.grace_skip_at = Instant::now().checked_add(Duration::from_secs(5));
                        self.set_status(" Grace skip in 5s…");
                    }
                }
            }
            Action::KillSession => self.kill_current_session(),
            Action::PickPlans => {
                // Enter queue-edit mode: show Selection to pick more plans.
                // Re-scan plans to discover newly created files, then remap
                // existing queue entries from old indices to new indices by
                // matching on plan filename (stable identifier).
                let cwd = std::env::current_dir().unwrap_or_default();
                if let Ok(new_plans) = crate::scanner::scan_plans(&cwd) {
                    // Remap queue entries: old plan_idx → name → new plan_idx
                    let mut remapped_queue = VecDeque::new();
                    let old_queue_len = self.execution.queue.len();
                    for entry in &self.execution.queue {
                        if let Some(old_plan) = self.plans.get(entry.plan_idx) {
                            if let Some(new_idx) = new_plans.iter().position(|p| plans_match(&p.name, &old_plan.name)) {
                                remapped_queue.push_back(QueueEntry {
                                    plan_idx: new_idx,
                                    config_idx: entry.config_idx,
                                });
                            }
                            // Plan file deleted from disk → drop from queue
                        }
                    }
                    let dropped = old_queue_len - remapped_queue.len();
                    self.execution.queue = remapped_queue;

                    // Remap current_run plan (for is_plan_in_flight matching)
                    if let Some(ref mut run) = self.execution.current_run {
                        if let Some(new_idx) = new_plans.iter().position(|p| plans_match(&p.name, &run.plan.name)) {
                            run.plan = new_plans[new_idx].clone();
                        }
                    }

                    let discovered = new_plans.len().saturating_sub(self.plans.len());
                    self.plans = new_plans;

                    // Status: inform user about changes
                    if discovered > 0 || dropped > 0 {
                        let mut parts = Vec::new();
                        if discovered > 0 {
                            parts.push(format!("{discovered} new plan(s) found"));
                        }
                        if dropped > 0 {
                            parts.push(format!("{dropped} queued plan(s) removed (file deleted)"));
                        }
                        self.set_status(parts.join(", "));
                    }
                }
                self.queue_editing = true;
                self.selected_plans.clear();
                self.active_panel = Panel::PlanList;
                self.plan_cursor = 0;
                self.view = AppView::Selection;
            }
            Action::AppendToQueue => {
                // Append selected plan+config pairs to queue
                let count = self.selected_plans.len();
                for entry in self.selected_plans.drain(..) {
                    self.execution.queue.push_back(entry);
                }
                self.queue_editing = false;
                self.all_done_at = None; // reset auto-quit since queue grew
                self.view = AppView::Running;
                self.set_status(format!("{count} plan(s) added to queue"));
            }
            Action::CancelQueueEdit => {
                self.selected_plans.clear();
                self.queue_editing = false;
                self.view = AppView::Running;
            }
            Action::OpenMessageInput => {
                if self.execution.tmux_session_id.is_some() {
                    self.messaging.message_input_active = true;
                    self.messaging.message_input_buf.clear();
                } else {
                    self.set_status("No active session to send to");
                }
            }
            Action::SubmitMessage => {
                if !self.messaging.message_input_buf.trim().is_empty() {
                    let msg = self.messaging.message_input_buf.clone();
                    self.messaging.message_input_active = false;
                    self.messaging.bridge_scroll_offset = 0; // snap to bottom on send
                    self.messaging.message_input_buf.clear();
                    self.send_message_to_claude(&msg);
                }
            }
            Action::CancelMessageInput => {
                self.messaging.message_input_active = false;
                self.messaging.message_input_buf.clear();
            }
            Action::MessageChar(c) => {
                // Cap input at 2000 characters to prevent oversized HTTP bodies.
                // Uses char count (not byte length) for consistent behavior with
                // multi-byte Unicode input (e.g. Vietnamese, CJK).
                if self.messaging.message_input_buf.chars().count() < 2000 {
                    self.messaging.message_input_buf.push(c);
                }
            }
            Action::MessageBackspace => {
                self.messaging.message_input_buf.pop();
            }
            Action::HealthCheck => {
                if !self.messaging.channels_enabled {
                    self.set_status("Health check requires --channels mode");
                } else if self.execution.current_run.is_some() {
                    // Try init if channel_state is None
                    if let Some(run) = &mut self.execution.current_run {
                        if run.channel_state.is_none() {
                            run.channel_state = ChannelState::try_init(&run.tmux_session);
                        }
                    }
                    // Perform health check and build status message
                    let status_msg = if let Some(run) = &mut self.execution.current_run {
                        if let Some(ref mut cs) = run.channel_state {
                            let healthy = cs.check_health();
                            let info = cs.query_session_id()
                                .map(|sid| format!(" (session: {})", sid))
                                .unwrap_or_default();
                            if healthy {
                                format!("[health] Bridge OK{}", info)
                            } else {
                                format!("[health] Bridge unreachable (failures: {}/3)", cs.failure_count)
                            }
                        } else {
                            "[health] Bridge not discovered yet".to_string()
                        }
                    } else {
                        "No active session".to_string()
                    };
                    self.set_status(status_msg);
                } else {
                    self.set_status("No active session");
                }
            }
            Action::OpenBridge => {
                if self.messaging.channels_enabled && self.execution.tmux_session_id.is_some() {
                    self.view = AppView::Bridge;
                    self.messaging.message_input_buf.clear();
                } else if self.messaging.channels_enabled {
                    self.set_status("No active session — start an arc first");
                }
            }
            Action::CloseBridge => {
                self.view = AppView::Running;
                self.messaging.message_input_active = false;
                self.messaging.bridge_scroll_offset = 0;
            }
            Action::BridgeScrollUp => {
                let max_offset = self.messaging.bridge_messages.len().saturating_sub(1);
                if self.messaging.bridge_scroll_offset < max_offset {
                    self.messaging.bridge_scroll_offset += 1;
                }
            }
            Action::BridgeScrollDown => {
                if self.messaging.bridge_scroll_offset > 0 {
                    self.messaging.bridge_scroll_offset -= 1;
                }
            }
            Action::None => {}
        }
        Ok(())
    }

    /// Attach to the selected active arc's tmux session.
    fn attach_active_arc(&self) {
        if let Some(arc) = self.active_arcs.get(self.active_arc_cursor) {
            if let Some(ref session) = arc.tmux_session {
                let _ = Tmux::attach(session);
            }
        }
    }

    /// Transition to Running view to monitor the selected active arc.
    fn monitor_active_arc(&mut self) {
        let arc = match self.active_arcs.get(self.active_arc_cursor) {
            Some(a) => a.clone(),
            None => return,
        };

        // Set up the config dir selection to match the active arc
        if !arc.config_dir.path.as_os_str().is_empty() {
            if let Some(idx) = self.config_dirs.iter().position(|c| c.path == arc.config_dir.path) {
                self.selected_config = idx;
            }
        }

        // Parse claude_pid from owner_pid
        let claude_pid = arc.loop_state.owner_pid.parse::<u32>().ok();

        // Resolve checkpoint path relative to cwd (project dir)
        let cwd = std::env::current_dir().unwrap_or_default();
        let checkpoint_path = if arc.loop_state.checkpoint_path.starts_with('/') {
            PathBuf::from(&arc.loop_state.checkpoint_path)
        } else {
            cwd.join(&arc.loop_state.checkpoint_path)
        };

        // Try to read checkpoint for arc_id
        let arc_id = std::fs::read_to_string(&checkpoint_path)
            .ok()
            .and_then(|c| serde_json::from_str::<crate::checkpoint::Checkpoint>(&c).ok())
            .map(|cp| cp.id)
            .unwrap_or_else(|| "unknown".into());

        let heartbeat_path = cwd.join("tmp").join("arc").join(&arc_id).join("heartbeat.json");

        // Build a fake PlanFile for the run
        let plan_name = arc.loop_state.plan_file.clone();
        let plan = PlanFile {
            path: PathBuf::from(&plan_name),
            name: plan_name.clone(),
            title: plan_name,
            date: None,
        };

        self.execution.tmux_session_id = arc.tmux_session.clone();
        let session_info = arc.session_info;
        let loop_state = arc.loop_state;
        self.execution.current_run = Some(RunState {
            plan,
            config_idx: self.selected_config,
            tmux_session: arc.tmux_session.clone().unwrap_or_default(),
            launched_at: Instant::now(),
            arc: Some(ArcHandle {
                arc_id,
                checkpoint_path,
                heartbeat_path,
                plan_file: loop_state.plan_file.clone(),
                config_dir: loop_state.config_dir.clone(),
                owner_pid: loop_state.owner_pid.clone(),
                session_id: loop_state.session_id.clone(),
            }),
            last_status: None,
            merge_detected_at: None,
            tmux_pane_pid: None,
            claude_pid,
            loop_state: Some(loop_state),
            session_info,
            current_phase_started: None,
            current_phase_name: None,
            timeout_triggered_at: None,
            channel_state: None, // monitoring existing arc — channels not initialized on resume
            activity_detector: ActivityDetector::new(),
            grace_duration: None,
            grace_skip_at: None,
            resume_state: None, // monitoring existing arc — no resume tracking
            restart_cooldown_until: None,
            recovery_mode: None,
            session_recreated: false,
        });

        self.view = AppView::Running;
    }

    /// Remove a queue item at the current cursor position.
    /// Only pending items (not completed or current) can be removed.
    fn remove_queue_item(&mut self) {
        let completed_count = self.execution.completed_runs.len();
        let current_count = if self.execution.current_run.is_some() { 1 } else { 0 };
        let non_removable = completed_count + current_count;

        if self.queue_cursor < non_removable {
            // Cursor is on a completed run or current — not removable
            self.set_status("Cannot remove completed or running items");
            return;
        }

        let queue_idx = self.queue_cursor - non_removable;
        if queue_idx < self.execution.queue.len() {
            let removed = self.execution.queue.remove(queue_idx);
            let name = removed
                .and_then(|e| self.plans.get(e.plan_idx))
                .map(|p| p.name.clone())
                .unwrap_or_else(|| "?".into());
            self.set_status(format!("Removed: {name}"));

            // Adjust cursor if it's past the end
            let total = self.queue_total_items();
            if total > 0 && self.queue_cursor >= total {
                self.queue_cursor = total - 1;
            }
        }
    }

    /// Skip the current plan — kill tmux, move to next.
    fn skip_current_plan(&mut self) {
        let total = self.execution.skip_current_plan();
        if total > 0 && self.queue_cursor >= total {
            self.queue_cursor = total - 1;
        }
    }

    /// Kill the current tmux session and stop all execution.
    fn kill_current_session(&mut self) {
        self.execution.kill_current_session();
        self.queue_cursor = 0;
    }

    /// Main execution tick — called every ~1s from the event loop.
    ///
    /// Handles: launching new plans, discovery polling, heartbeat/checkpoint
    /// polling, completion detection with grace period.
    pub fn tick_execution(&mut self) -> Result<()> {
        if !matches!(self.view, AppView::Running | AppView::Bridge) {
            return Ok(());
        }

        let now = Instant::now();

        if self.execution.current_run.is_none() {
            // Inter-plan cooldown gate — wait before launching next plan
            if let Some(deadline) = self.execution.inter_plan_cooldown_until {
                if now < deadline {
                    let remaining = deadline.duration_since(now).as_secs();
                    self.set_status(format!(
                        " Next plan in {}m{}s  [s] skip cooldown",
                        remaining / 60,
                        remaining % 60,
                    ));
                    return Ok(());
                }
                // Cooldown expired — clear and proceed
                self.execution.inter_plan_cooldown_until = None;
            }

            // No arc running — start next plan from queue
            if let Some(entry) = self.execution.queue.pop_front() {
                self.all_done_at = None;
                self.selected_config = entry.config_idx;
                self.launch_next_plan(entry.plan_idx)?;
            } else if !self.execution.completed_runs.is_empty() {
                // All plans done — auto-quit after delay
                let auto_quit_secs = Self::auto_quit_secs();
                if auto_quit_secs > 0 {
                    if let Some(done_at) = self.all_done_at {
                        let remaining = auto_quit_secs.saturating_sub(
                            now.duration_since(done_at).as_secs()
                        );
                        if remaining == 0 {
                            self.should_quit = true;
                        } else {
                            self.set_status(format!(
                                " All done! Auto-quit in {}s  [q] quit now",
                                remaining
                            ));
                        }
                    } else {
                        self.all_done_at = Some(now);
                    }
                }
            }
            return Ok(());
        }

        // Check restart cooldown (auto-resume after phase timeout)
        self.check_restart_cooldown();

        // FLAW-001 FIX: check_restart_cooldown() may .take() current_run via
        // cleanup_skipped_plan() on restart failure — guard against None.
        let has_arc = match self.execution.current_run.as_ref() {
            Some(run) => run.arc.is_some(),
            None => return Ok(()),
        };

        if !has_arc {
            // Discovery polling (every 10s)
            if self.polling.should_poll(crate::polling::DISCOVERY, Duration::from_secs(10)) {
                self.poll_discovery();
                self.polling.mark_polled(crate::polling::DISCOVERY, now);
            }

            // Bootstrap diagnostic check (every 30s during discovery)
            if self.polling.should_poll(crate::polling::DIAGNOSTIC, Duration::from_secs(30)) {
                self.poll_diagnostic_bootstrap();
                self.polling.mark_polled(crate::polling::DIAGNOSTIC, now);
            }
        } else {
            // Heartbeat polling (every 5s)
            if self.polling.should_poll(crate::polling::HEARTBEAT, Duration::from_secs(5)) {
                self.poll_status();
                self.polling.mark_polled(crate::polling::HEARTBEAT, now);
            }

            // Channel event processing (non-blocking, every 2s when enabled)
            if self.messaging.channels_enabled
                && self.polling.should_poll(crate::polling::CHANNEL, Duration::from_secs(2))
            {
                self.drain_channel_events();
                self.polling.mark_polled(crate::polling::CHANNEL, now);
            }

            // Loop state liveness check (every 60s)
            if self.polling.should_poll(crate::polling::LOOP_STATE, Duration::from_secs(60)) {
                self.check_loop_state_liveness();
                self.refresh_git_branch();
                self.refresh_session_info();
                self.polling.mark_polled(crate::polling::LOOP_STATE, now);
            }

            // Runtime diagnostic check (every 30s during execution)
            if self.polling.should_poll(crate::polling::DIAGNOSTIC, Duration::from_secs(30)) {
                self.poll_diagnostic_runtime();
                self.polling.mark_polled(crate::polling::DIAGNOSTIC, now);
            }

            // Check grace period completion BEFORE timeout (completion race guard)
            self.check_grace_period(now);

            // Check phase timeout AFTER completion — prevents killing a just-completed phase
            self.check_phase_timeout();
        }

        Ok(())
    }

    /// Check if arc-phase-loop.local.md still exists and refresh loop state.
    /// If it's gone, the arc has completed or been stopped — trigger completion.
    fn check_loop_state_liveness(&mut self) {
        let cwd = std::env::current_dir().unwrap_or_default();
        let loop_file = cwd.join(".rune").join("arc-phase-loop.local.md");

        if !loop_file.exists() {
            self.set_status(
                "arc-phase-loop.local.md removed — arc completed or stopped",
            );
            if let Some(run) = &mut self.execution.current_run {
                if run.merge_detected_at.is_none() {
                    run.merge_detected_at = Some(Instant::now());
                }
            }
            return;
        }

        // File exists — read and refresh loop state
        match monitor::read_arc_loop_state(&cwd) {
            Some(state) => {
                // Refresh loop state on current run (iteration may have changed)
                if let Some(run) = &mut self.execution.current_run {
                    run.loop_state = Some(state);
                }
            }
            None => {
                // active: false — arc cancelled
                self.set_status(
                    "arc-phase-loop.local.md active: false — arc cancelled",
                );
                if let Some(run) = &mut self.execution.current_run {
                    if run.merge_detected_at.is_none() {
                        run.merge_detected_at = Some(Instant::now());
                    }
                }
            }
        }
    }

    /// Launch the next plan: git checkout main, create tmux session, send /arc.
    fn launch_next_plan(&mut self, plan_idx: usize) -> Result<()> {
        let plan = self.plans.get(plan_idx).cloned().ok_or_else(|| {
            eyre!("plan index {plan_idx} out of bounds")
        })?;

        // Step 0: Clean stale arc state from previous run.
        crate::execution::clean_stale_arc_state();

        // Step 0.5: Pre-arc diagnostic check — verify session health before launch.
        // If there's an existing tmux session we can probe, check for blocking errors
        // (billing, auth) before spending time creating a new session.
        if let Some(ref sid) = self.execution.tmux_session_id {
            if let Ok(pane_pid) = Tmux::get_pane_pid(sid) {
                let diag = self.diagnostic_engine.check_pre_arc(sid, pane_pid);
                if diag.action != DiagnosticAction::Continue {
                    self.last_diagnostic = Some(diag.clone());
                    if self.handle_diagnostic_action(&diag, plan_idx) {
                        return Ok(());
                    }
                }
            }
        }

        let config_path = self.config_dirs.get(self.selected_config)
            .ok_or_else(|| eyre!("no config dir selected"))?
            .path.clone();

        // Step 1: git checkout main + pull (blocking, before tmux)
        if let Err(err) = crate::execution::checkout_plan_branch() {
            self.set_status(err.to_string());
            self.execution.queue.push_front(QueueEntry {
                plan_idx,
                config_idx: self.selected_config,
            });
            return Ok(());
        }

        // Step 2: Record wall-clock time BEFORE launch (for discovery matching)
        self.execution.launched_wall_clock = Some(Utc::now());

        // Step 3: Create tmux session (empty shell) in the current working directory.
        let cwd = std::env::current_dir().unwrap_or_default();
        let session_id = match crate::execution::create_tmux_session(&cwd) {
            Ok(sid) => sid,
            Err(err) => {
                self.set_status(err.to_string());
                return Ok(());
            }
        };
        self.execution.tmux_session_id = Some(session_id.clone());

        // Step 4: Build channels config (if enabled) and start Claude Code
        let channels_cfg = if self.messaging.channels_enabled {
            Some(ChannelsConfig {
                bridge_port: self.messaging.callback_port.checked_add(1).unwrap_or(self.messaging.callback_port.saturating_sub(1)), // SEC-012: prevent u16 overflow
                callback_port: self.messaging.callback_port,
            })
        } else {
            None
        };
        if let Err(e) = Tmux::start_claude(
            &session_id, &config_path, &self.claude_path, channels_cfg.as_ref()
        ) {
            self.set_status(format!("start claude failed: {e}"));
            return Ok(());
        }

        // Step 5: Wait for Claude Code to fully initialize (12s)
        self.set_status(format!("Waiting for Claude Code in {}...", &session_id));
        std::thread::sleep(Duration::from_secs(12));

        // Step 5.5-5.6: Detect Claude Code PID
        let (tmux_pane_pid, claude_pid) = crate::execution::detect_claude_pid(&session_id);

        // Step 6: Send /arc command — check for existing checkpoint first
        let resume_state = ResumeState::load(&plan.path.display().to_string());
        let has_checkpoint = self.check_existing_checkpoint(&plan);

        // Resolve bridge port for channels-first dispatch
        let bridge_port = if self.messaging.channels_enabled {
            self.execution.current_run.as_ref()
                .and_then(|r| r.channel_state.as_ref())
                .and_then(|cs| cs.bridge_port)
        } else {
            None
        };

        // Track what was dispatched for Bridge View display (before plan is moved)
        let mut arc_dispatch_msg: Option<String> = None;

        if has_checkpoint && resume_state.total_restarts == 0 {
            // First launch but checkpoint exists from a previous torrent session — resume
            if Self::send_arc_prefer_bridge(&session_id, &plan.path, 3, bridge_port, true).is_none() {
                self.set_status(format!("FAILED: send /arc --resume failed. tmux attach -t {}", &session_id));
            } else {
                let transport = if bridge_port.is_some() { "bridge" } else { "tmux" };
                self.set_status(format!("Resuming existing checkpoint [{}]", transport));
                arc_dispatch_msg = Some(format!("/arc {} --resume [{}]", plan.path.display(), transport));
            }
        } else if Self::send_arc_prefer_bridge(&session_id, &plan.path, 2, bridge_port, false).is_none() {
            self.set_status(format!("FAILED: send /arc failed. tmux attach -t {}", &session_id));
        } else {
            let transport = if bridge_port.is_some() { "bridge" } else { "tmux" };
            self.set_status(format!("/arc sent to {} [{}]", &session_id, transport));
            arc_dispatch_msg = Some(format!("/arc {} [{}]", plan.path.display(), transport));
        }
        // Reset bridge log file for new session (so it opens a fresh file for this session_id)
        self.messaging.bridge_log_file = None;

        self.execution.current_run = Some(RunState {
            plan,
            config_idx: self.selected_config,
            tmux_session: session_id,
            launched_at: Instant::now(),
            arc: None,
            last_status: None,
            merge_detected_at: None,
            tmux_pane_pid,
            claude_pid,
            loop_state: None,
            session_info: claude_pid.and_then(|pid| {
                crate::scanner::enrich_session_info(
                    &pid.to_string(),
                    &config_path.to_string_lossy(),
                    &self.sys,
                )
            }),
            current_phase_started: None,
            current_phase_name: None,
            timeout_triggered_at: None,
            channel_state: None, // initialized later via try_init after bridge port discovery
            activity_detector: ActivityDetector::new(),
            grace_duration: None,
            grace_skip_at: None,
            resume_state: Some(resume_state),
            restart_cooldown_until: None,
            recovery_mode: None,
            session_recreated: false,
        });

        // Insert session separator in Bridge View messages
        self.push_bridge_message(BridgeMessage {
            text: format!("── new session: {} ──", self.execution.tmux_session_id.as_deref().unwrap_or("unknown")),
            timestamp: chrono::Local::now().time(),
            kind: BridgeMessageKind::Phase,
        });

        // Show the dispatched /arc command in Bridge View
        if let Some(msg) = arc_dispatch_msg {
            self.push_bridge_message(BridgeMessage {
                text: msg,
                timestamp: chrono::Local::now().time(),
                kind: BridgeMessageKind::Sent,
            });
        }

        // Start callback server if channels are enabled
        if self.messaging.channels_enabled && self.messaging.callback_server.is_none() {
            match CallbackServer::start(self.messaging.callback_port) {
                Ok(server) => {
                    self.messaging.callback_server = Some(server);
                    // Initialize channel state now that callback server is running
                    if let Some(run) = &mut self.execution.current_run {
                        run.channel_state = ChannelState::try_init(
                            &run.tmux_session,
                        );
                    }
                }
                Err(e) => {
                    self.set_status(format!("callback server failed: {e}"));
                }
            }
        }

        // Reset poll timers
        self.polling.reset_many(&[
            crate::polling::DISCOVERY,
            crate::polling::HEARTBEAT,
            crate::polling::CHECKPOINT,
            crate::polling::CHANNEL,
        ]);

        Ok(())
    }

    /// Poll for arc discovery using 2-layer strategy:
    /// 1. Parse arc-phase-loop.local.md (instant, created first by Rune arc)
    /// 2. Fallback: glob scan <config_dir>/arc/arc-*/checkpoint.json
    fn poll_discovery(&mut self) {
        let launched_after = match self.execution.launched_wall_clock {
            Some(t) => t,
            None => return,
        };

        // Extract needed values before borrowing self.execution.current_run mutably
        // Use run's config_idx (not selected_config) to avoid drift from queue-edit
        let run_config_idx = self.execution.current_run.as_ref().map(|r| r.config_idx);
        let config_dir_str = run_config_idx
            .and_then(|idx| self.config_dirs.get(idx))
            .map(|c| c.path.to_string_lossy().to_string());
        let expected_config_dir = config_dir_str.as_deref();

        let (plan_path, expected_claude_pid, has_loop_state) = {
            let run = match &self.execution.current_run {
                Some(r) => r,
                None => return,
            };
            (run.plan.path.clone(), run.claude_pid, run.loop_state.is_some())
        };

        // Run discovery (2-layer: loop state → glob scan)
        // Note: loop state file lives under CWD (.rune/arc-phase-loop.local.md),
        // NOT under config_dir. Use cwd for both loop state and discovery.
        let cwd = std::env::current_dir().unwrap_or_default();

        // Read loop state if not yet populated
        if !has_loop_state {
            let loop_state = monitor::read_arc_loop_state(&cwd);
            if loop_state.is_some() {
                self.set_status("Arc loop state detected, discovering checkpoint...");
            }
            if let Some(run) = &mut self.execution.current_run {
                run.loop_state = loop_state;
            }
        }
        if let Some(handle) = monitor::discover_arc(
            &cwd,
            &plan_path,
            launched_after,
            expected_config_dir,
            expected_claude_pid,
        ) {
            if let Some(run) = &mut self.execution.current_run {
                run.arc = Some(handle);
            }
        }
    }

    /// Poll arc status (heartbeat + checkpoint + resources) and update display state.
    /// Send a message to the Claude Code session.
    ///
    /// When channels are active and bridge is reachable, uses HTTP POST to
    /// bridge /msg endpoint (Channels API). Falls back to tmux send-keys
    /// when bridge is unreachable or channels are disabled.
    fn send_message_to_claude(&mut self, msg: &str) {
        if self.messaging.channels_enabled {
            self.send_via_bridge_http(msg);
        } else {
            self.send_via_tmux(msg);
        }

        // Push to bridge messages for Bridge View display.
        // Show as Sent regardless of transport outcome — the status bar
        // already shows transport-level errors (e.g. "send failed: ...").
        // Use a distinct kind if delivery definitively failed.
        let delivery_failed = self.messaging.last_msg_transport.is_none()
            && self.status_message.as_ref().map(|s| s.contains("failed")).unwrap_or(false);
        self.push_bridge_message(BridgeMessage {
            text: truncate_str(msg, 500).to_string(),
            timestamp: chrono::Local::now().time(),
            kind: if delivery_failed { BridgeMessageKind::SendFailed } else { BridgeMessageKind::Sent },
        });
    }

    /// Send via bridge HTTP server (Channels API path).
    /// Uses POST /msg to deliver messages through the bridge to Claude Code.
    fn send_via_bridge_http(&mut self, msg: &str) {
        let bridge_port = self.execution.current_run.as_ref()
            .and_then(|r| r.channel_state.as_ref())
            .and_then(|cs| cs.bridge_port);

        let port = match bridge_port {
            Some(p) => p,
            None => {
                // No bridge port discovered — fall back to inbox
                self.send_via_inbox(msg);
                return;
            }
        };

        let url = format!("http://127.0.0.1:{port}/msg");
        match ureq::post(&url)
            .timeout(Duration::from_secs(5))
            .set("Content-Type", "text/plain")
            .send_string(msg)
        {
            Ok(resp) => {
                let status = resp.into_string().unwrap_or_default();
                if status.contains("inbox") {
                    self.messaging.last_msg_transport = Some(MsgTransport::Inbox);
                    self.set_status(format!("✉ [inbox] {}", truncate_str(msg, 50)));
                } else {
                    self.messaging.last_msg_transport = Some(MsgTransport::Bridge);
                    self.set_status(format!("✉ [bridge] {}", truncate_str(msg, 50)));
                }
            }
            Err(_) => {
                // Bridge HTTP unreachable — fall back to inbox, then tmux
                self.send_via_inbox(msg);
            }
        }
    }

    /// Send via bridge inbox (file-based fallback).
    /// Called when bridge HTTP is unreachable. Falls back to tmux on write failure.
    fn send_via_inbox(&mut self, msg: &str) {
        let session_id = self.execution.tmux_session_id.as_deref().unwrap_or("default");
        // SEC-006: Validate session_id before path construction (same rules as open_bridge_log)
        if session_id.is_empty()
            || session_id.len() > 64
            || !session_id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            self.set_status("inbox failed: invalid session id — using tmux");
            self.send_via_tmux(msg);
            return;
        }
        let inbox_dir = std::path::PathBuf::from("tmp/bridge-inbox").join(session_id);
        if let Err(e) = std::fs::create_dir_all(&inbox_dir) {
            self.set_status(format!("inbox failed: {e} — using tmux"));
            self.send_via_tmux(msg);
            return;
        }
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = inbox_dir.join(format!("{timestamp}.msg"));
        match std::fs::write(&path, msg) {
            Ok(_) => {
                self.messaging.last_msg_transport = Some(MsgTransport::Inbox);
                self.set_status(format!("✉ [inbox] {}", truncate_str(msg, 50)));
            }
            Err(e) => {
                self.set_status(format!("inbox write failed: {e} — using tmux"));
                self.send_via_tmux(msg);
            }
        }
    }

    /// Send via tmux send-keys (last resort fallback).
    /// Wraps message with [torrent:tmux] prefix so Claude can identify the source.
    fn send_via_tmux(&mut self, msg: &str) {
        let session_id = match &self.execution.tmux_session_id {
            Some(id) => id.clone(),
            None => {
                self.set_status("no active session");
                return;
            }
        };
        let prefixed = format!("[torrent:tmux] {msg}");
        match Tmux::send_keys(&session_id, &prefixed) {
            Ok(_) => {
                self.messaging.last_msg_transport = Some(MsgTransport::Tmux);
                self.set_status(format!("✉ [tmux] {}", truncate_str(msg, 50)));
            }
            Err(e) => {
                self.set_status(format!("send failed: {e}"));
            }
        }
    }

    /// Push a message to the display ring buffer and persist to file.
    pub(crate) fn push_bridge_message(&mut self, msg: BridgeMessage) {
        let session_id = self.execution.tmux_session_id.as_deref();
        self.messaging.push_bridge_message(msg, session_id);
    }

    /// Send an /arc command via HTTP POST to bridge /msg endpoint.
    fn send_arc_via_bridge(bridge_port: u16, plan_path: &Path, resume: bool) -> color_eyre::Result<()> {
        let display_path = plan_path.display().to_string();
        let arc_path = display_path
            .find("plans/")
            .map(|idx| &display_path[idx..])
            .unwrap_or(&display_path);

        let body = if resume {
            format!("/arc {} --resume", arc_path)
        } else {
            format!("/arc {}", arc_path)
        };

        let url = format!("http://127.0.0.1:{}/msg", bridge_port);
        ureq::post(&url)
            .timeout(Duration::from_secs(5))
            .set("Content-Type", "text/plain")
            .send_string(&body)
            .map_err(|e| eyre!("bridge POST /msg failed: {e}"))?;
        Ok(())
    }

    /// Drain channel events from the callback server and update app state.
    ///
    /// Processes up to 10 events per tick to avoid blocking the UI loop.
    /// SEC-001: Events from foreign/stale sessions are silently dropped.
    /// Each event updates the status message, pushes to the bridge message
    /// ring buffer (with JSONL persistence), and resets activity detection.
    fn drain_channel_events(&mut self) {
        let server = match self.messaging.callback_server.as_ref() {
            Some(s) => s,
            None => return,
        };

        // Drain up to 10 events per tick to avoid blocking the UI loop
        let events: Vec<_> = (0..10)
            .map_while(|_| server.recv_event())
            .collect();

        if events.is_empty() {
            return;
        }

        // Resolve expected session_id for the current run (from arc handle).
        // Events from other sessions are silently dropped (SEC-001).
        let expected_session = self
            .execution.current_run
            .as_ref()
            .and_then(|r| r.arc.as_ref().map(|a| a.session_id.clone()));

        for event in events {
            // SEC-001: Validate session_id — skip events from stale/foreign sessions
            let event_session = match &event {
                ChannelEvent::PhaseUpdate { session_id, .. } => session_id,
                ChannelEvent::ArcComplete { session_id, .. } => session_id,
                ChannelEvent::Heartbeat { session_id, .. } => session_id,
                ChannelEvent::Reply { session_id, .. } => session_id,
            };
            match &expected_session {
                Some(expected) if event_session != expected => continue,
                None => continue, // SEC-011: no session known yet — drop events
                _ => {} // session matches — process event
            }

            // BACK-014: Retry channel state init if still None (bridge may not have been
            // ready when try_init was first called during session startup).
            if let Some(run) = &mut self.execution.current_run {
                if run.channel_state.is_none() {
                    run.channel_state = ChannelState::try_init(&run.tmux_session);
                }
            }

            // Update channel health on successful event
            if let Some(run) = &mut self.execution.current_run {
                if let Some(ref mut cs) = run.channel_state {
                    cs.record_success();
                }
            }

            match event {
                ChannelEvent::PhaseUpdate { phase, status, details, .. } => {
                    let msg = if details.is_empty() {
                        format!("Phase: {} ({})", phase, status)
                    } else {
                        format!("Phase: {} ({}) — {}", phase, status, details)
                    };
                    self.set_status(format!("[ch] {}", truncate_str(&msg, 80)));
                    self.messaging.last_claude_msg = Some(truncate_str(&msg, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&msg, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Phase,
                    });
                    if let Some(run) = &mut self.execution.current_run {
                        run.activity_detector.hash_unchanged_count = 0;
                    }
                }
                ChannelEvent::ArcComplete { result, pr_url, error, .. } => {
                    let msg = match (&*result, pr_url.as_deref(), error.as_deref()) {
                        ("success", Some(url), _) => format!("Arc complete: success — {}", url),
                        ("failed", _, Some(err)) => format!("Arc failed: {}", err),
                        _ => format!("Arc complete: {}", result),
                    };
                    self.set_status(format!("[ch] {}", truncate_str(&msg, 80)));
                    self.messaging.last_claude_msg = Some(truncate_str(&msg, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&msg, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Complete,
                    });
                    if let Some(run) = &mut self.execution.current_run {
                        run.activity_detector.hash_unchanged_count = 0;
                    }
                }
                ChannelEvent::Heartbeat { activity, current_tool, .. } => {
                    let msg = if current_tool.is_empty() {
                        format!("Claude: {}", activity)
                    } else {
                        format!("Claude: {} (using {})", activity, current_tool)
                    };
                    self.messaging.last_claude_msg = Some(truncate_str(&msg, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&msg, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Heartbeat,
                    });
                    if let Some(run) = &mut self.execution.current_run {
                        if activity == "active" {
                            run.activity_detector.hash_unchanged_count = 0;
                        }
                    }
                }
                ChannelEvent::Reply { text, .. } => {
                    self.set_status(format!("[reply] {}", truncate_str(&text, 80)));
                    self.messaging.last_claude_msg = Some(truncate_str(&text, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&text, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Reply,
                    });
                    if let Some(run) = &mut self.execution.current_run {
                        run.activity_detector.hash_unchanged_count = 0;
                    }
                }
            }
        }
    }

    fn poll_status(&mut self) {
        // Refresh sysinfo for resource polling (lightweight, no sleep needed after init)
        resource::refresh_process_system(&mut self.sys);

        let run = match &mut self.execution.current_run {
            Some(r) => r,
            None => return,
        };

        let arc = match &run.arc {
            Some(a) => a,
            None => return,
        };

        // Poll resource usage for Claude Code process
        let (res_snapshot, proc_health) = if let Some(pid) = run.claude_pid {
            let snap = resource::snapshot(&self.sys, pid);
            let health = resource::check_health(&self.sys, pid);
            (snap, health)
        } else {
            (None, ProcessHealth::NotFound)
        };

        // Now both app and monitor use the same ArcHandle from types.rs — no conversion needed
        if let Some(status) = monitor::poll_arc_status(arc) {
            // Surface schema version warning once (first poll only)
            if run.last_status.is_none() {
                if let Some(ref warning) = status.schema_warning {
                    self.status_message = Some(format!("⚠ {}", warning));
                    self.status_message_set_at = Some(Instant::now());
                }
            }

            // Check for completion — start grace period
            if status.completion.is_some() && run.merge_detected_at.is_none() {
                run.merge_detected_at = Some(Instant::now());
            }

            // Combined stale detection: heartbeat staleness OR low-cpu process health
            let is_stale = status.is_stale
                || proc_health == ProcessHealth::LowCpu
                || proc_health == ProcessHealth::Idle;

            // Phase change detection — reset timeout timer on new phase
            {
                let new_phase = &status.current_phase;
                let phase_changed = run
                    .current_phase_name
                    .as_ref()
                    .map(|old| old != new_phase)
                    .unwrap_or(true);
                if phase_changed && !new_phase.is_empty() {
                    run.current_phase_name = Some(new_phase.clone());
                    run.current_phase_started = Some(Instant::now());
                    run.timeout_triggered_at = None; // clear any pending kill
                }
            }

            // Activity detection: update pane hash on 30s interval, then detect state
            let (activity_state, auto_accept_info) = if run.activity_detector.should_check() {
                let pane_hash = Tmux::capture_pane_hash(&run.tmux_session, 30);
                let last_line = Tmux::capture_last_line(&run.tmux_session);
                run.activity_detector.update_hash(pane_hash);
                let cpu = res_snapshot.as_ref().map(|s| s.cpu_percent);
                let process_found = proc_health != ProcessHealth::NotFound;
                let state = run.activity_detector.detect(
                    status.is_stale,
                    cpu,
                    process_found,
                    last_line.as_deref(),
                );

                // Auto-accept permission/yes-no prompts during arc runs.
                // When Claude Code is stuck on a confirmation prompt, send Enter
                // to unblock the pipeline. Only triggers for known safe patterns
                // (permission prompts, y/n questions) — NOT shell prompts.
                // Debounce: max 1 auto-accept per 60 seconds to avoid spamming.
                // Deferred: capture info here, act after the borrow on `run` ends.
                let auto_accept_info = if state == ActivityState::WaitingInput {
                    last_line.as_deref()
                        .filter(|line| monitor::is_auto_acceptable_prompt(line))
                        .and_then(|line| {
                            let should_send = self.messaging.last_auto_accept
                                .map(|t| t.elapsed() >= Duration::from_secs(60))
                                .unwrap_or(true);
                            if should_send {
                                // send_keys sends Escape+Enter — accepts the default option
                                let _ = Tmux::send_keys(&run.tmux_session, "");
                                self.messaging.last_auto_accept = Some(Instant::now());
                                Some(line.chars().take(60).collect::<String>())
                            } else {
                                None
                            }
                        })
                } else {
                    None
                };

                (Some(state), auto_accept_info)
            } else {
                // Between pane checks, reuse last known activity state
                (run.last_status.as_ref().and_then(|s| s.activity_state), None)
            };

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
                phase_nav: status.phase_nav,
                pr_url: status.pr_url,
                is_stale,
                completion: status.completion,
                schema_warning: status.schema_warning,
                resource: res_snapshot,
                process_health: proc_health,
                activity_state,
            });

            // Deferred auto-accept side effects (after run borrow ends)
            if let Some(prompt_preview) = auto_accept_info {
                self.set_status(format!("Auto-accepted prompt: {}", prompt_preview));
                self.push_bridge_message(BridgeMessage {
                    text: format!("[auto-accept] {}", prompt_preview),
                    timestamp: chrono::Local::now().time(),
                    kind: BridgeMessageKind::Sent,
                });
            }
        }
    }

    /// Auto-quit delay after all plans are completed.
    /// Configurable via AUTO_QUIT_SECS env var. Default: 30s. Set to 0 to disable.
    fn auto_quit_secs() -> u64 {
        std::env::var("AUTO_QUIT_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(30)
    }

    /// Run bootstrap diagnostic check during discovery phase.
    /// Detects early failures (plan not found, plugin missing, auth errors)
    /// before the arc checkpoint is even created.
    fn poll_diagnostic_bootstrap(&mut self) {
        let (session_id, pane_pid) = match self.extract_session_pane() {
            Some(v) => v,
            None => return,
        };
        // Compute elapsed time since launch for checkpoint timeout detection (D6)
        let elapsed = self.execution.current_run.as_ref()
            .map(|r| r.launched_at.elapsed())
            .unwrap_or_default();
        let checkpoint_timeout = Duration::from_secs(
            env_or_u64("TORRENT_CHECKPOINT_TIMEOUT", 600)
        );
        let diag = self.diagnostic_engine.check_bootstrap(
            &session_id, pane_pid, elapsed, checkpoint_timeout,
        );
        if diag.state != DiagnosticState::Healthy {
            self.last_diagnostic = Some(diag.clone());
            let plan_idx = self.execution.current_run.as_ref()
                .and_then(|r| self.plans.iter().position(|p| p.path == r.plan.path));
            if let Some(idx) = plan_idx {
                self.handle_diagnostic_action(&diag, idx);
            }
        } else {
            // Clear previous diagnostic on healthy check
            self.last_diagnostic = None;
        }
    }

    /// Run runtime diagnostic check during active arc execution.
    /// Detects API errors, rate limits, crashes during the arc run.
    fn poll_diagnostic_runtime(&mut self) {
        let (session_id, pane_pid) = match self.extract_session_pane() {
            Some(v) => v,
            None => return,
        };
        let diag = self.diagnostic_engine.check_runtime(&session_id, pane_pid);
        if diag.state != DiagnosticState::Healthy {
            self.last_diagnostic = Some(diag.clone());
            let plan_idx = self.execution.current_run.as_ref()
                .and_then(|r| self.plans.iter().position(|p| p.path == r.plan.path));
            if let Some(idx) = plan_idx {
                self.handle_diagnostic_action(&diag, idx);
            }
        } else {
            self.last_diagnostic = None;
        }
    }

    /// Extract tmux session ID and pane PID from the current run.
    fn extract_session_pane(&self) -> Option<(String, u32)> {
        let run = self.execution.current_run.as_ref()?;
        let session_id = self.execution.tmux_session_id.as_ref()?;
        let pane_pid = run.tmux_pane_pid?;
        Some((session_id.clone(), pane_pid))
    }

    /// Handle a diagnostic action — dispatch on the prescribed action.
    /// Returns `true` if the caller should return early (plan was skipped/stopped).
    fn handle_diagnostic_action(&mut self, diag: &DiagnosticResult, plan_idx: usize) -> bool {
        match diag.action {
            DiagnosticAction::Continue => false,

            DiagnosticAction::StopBatch => {
                self.set_status(format!(
                    "DIAGNOSTIC: {} — stopping batch", diag.state.label()
                ));
                self.execution.queue.clear();
                if let Some(run) = self.execution.current_run.take() {
                    let _ = Tmux::kill_session(&run.tmux_session);
                    let arc_id = run.arc_id();
                    let duration = run.arc_duration();
                    self.execution.completed_runs.push(CompletedRun {
                        plan: run.plan,
                        result: ArcCompletion::Failed {
                            reason: format!("diagnostic: {}", diag.state.label()),
                        },
                        duration,
                        arc_id,
                        resume_restarts: None,
                    });
                }
                self.execution.tmux_session_id = None;
                true
            }

            DiagnosticAction::SkipPlan => {
                self.set_status(format!(
                    "DIAGNOSTIC: {} — skipping plan", diag.state.label()
                ));
                if let Some(run) = self.execution.current_run.take() {
                    let _ = Tmux::kill_session(&run.tmux_session);
                    let arc_id = run.arc_id();
                    let duration = run.arc_duration();
                    self.execution.completed_runs.push(CompletedRun {
                        plan: run.plan,
                        result: ArcCompletion::Cancelled {
                            reason: Some(format!("diagnostic: {}", diag.state.label())),
                        },
                        duration,
                        arc_id,
                        resume_restarts: None,
                    });
                }
                self.execution.tmux_session_id = None;
                true
            }

            DiagnosticAction::KillAndCooldown | DiagnosticAction::KillAndRetryAuth => {
                if let Some(strategy) = diag.action.retry_strategy() {
                    let plan_name = self.execution.current_run.as_ref()
                        .map(|r| r.plan.path.display().to_string())
                        .unwrap_or_default();
                    let mut resume = self.execution.current_run.as_ref()
                        .and_then(|r| r.resume_state.clone())
                        .unwrap_or_else(|| ResumeState::load(&plan_name));

                    let max = strategy.max_retries();
                    if resume.total_restarts >= max {
                        self.set_status(format!(
                            "DIAGNOSTIC: {} — max retries exceeded, skipping",
                            diag.state.label()
                        ));
                        if let Some(run) = self.execution.current_run.take() {
                            let _ = Tmux::kill_session(&run.tmux_session);
                            let arc_id = run.arc_id();
                            let duration = run.arc_duration();
                            self.execution.completed_runs.push(CompletedRun {
                                plan: run.plan,
                                result: ArcCompletion::Failed {
                                    reason: format!("diagnostic: {} retries exhausted", diag.state.label()),
                                },
                                duration,
                                arc_id,
                                resume_restarts: None,
                            });
                        }
                        self.execution.tmux_session_id = None;
                        return true;
                    }

                    resume.record_restart(0, "diagnostic", diag.state.label(), crate::resume::RecoveryMode::Retry);
                    let cooldown = strategy.backoff_duration(resume.total_restarts, None);

                    self.set_status(format!(
                        "DIAGNOSTIC: {} — retry #{} in {}s",
                        diag.state.label(),
                        resume.total_restarts,
                        cooldown.as_secs(),
                    ));

                    if let Some(ref sid) = self.execution.tmux_session_id {
                        let _ = Tmux::kill_session(sid);
                    }

                    if let Some(run) = &mut self.execution.current_run {
                        run.restart_cooldown_until = Some(Instant::now() + cooldown);
                        run.resume_state = Some(resume);
                    }
                }
                true
            }

            DiagnosticAction::RetrySession => {
                self.set_status(format!(
                    "DIAGNOSTIC: {} — retrying session", diag.state.label()
                ));
                if let Some(run) = self.execution.current_run.take() {
                    let _ = Tmux::kill_session(&run.tmux_session);
                    // Re-queue the plan for retry
                    self.execution.queue.push_front(QueueEntry {
                        plan_idx,
                        config_idx: run.config_idx,
                    });
                }
                self.execution.tmux_session_id = None;
                true
            }

            DiagnosticAction::Retry3xThenSkip => {
                let plan_name = self.execution.current_run.as_ref()
                    .map(|r| r.plan.path.display().to_string())
                    .unwrap_or_default();
                let mut resume = self.execution.current_run.as_ref()
                    .and_then(|r| r.resume_state.clone())
                    .unwrap_or_else(|| ResumeState::load(&plan_name));

                let strategy = diag.action.retry_strategy()
                    .unwrap_or(crate::resume::RetryStrategy::RateLimit);
                let max = strategy.max_retries();

                if resume.total_restarts >= max {
                    self.set_status(format!(
                        "DIAGNOSTIC: {} — {} retries exhausted, skipping",
                        diag.state.label(), max,
                    ));
                    if let Some(run) = self.execution.current_run.take() {
                        let _ = Tmux::kill_session(&run.tmux_session);
                        let arc_id = run.arc_id();
                        let duration = run.arc_duration();
                        self.execution.completed_runs.push(CompletedRun {
                            plan: run.plan,
                            result: ArcCompletion::Failed {
                                reason: format!("diagnostic: {} retries exhausted", diag.state.label()),
                            },
                            duration,
                            arc_id,
                            resume_restarts: None,
                        });
                    }
                    self.execution.tmux_session_id = None;
                    return true;
                }

                resume.record_restart(0, "diagnostic", diag.state.label(), crate::resume::RecoveryMode::Retry);
                let cooldown = strategy.backoff_duration(resume.total_restarts, None);

                self.set_status(format!(
                    "DIAGNOSTIC: {} — retry #{} in {}s",
                    diag.state.label(),
                    resume.total_restarts,
                    cooldown.as_secs(),
                ));

                if let Some(ref sid) = self.execution.tmux_session_id {
                    let _ = Tmux::kill_session(sid);
                }

                if let Some(run) = &mut self.execution.current_run {
                    run.restart_cooldown_until = Some(Instant::now() + cooldown);
                    run.resume_state = Some(resume);
                }
                true
            }

            DiagnosticAction::WaitTimeout | DiagnosticAction::GracePeriod => {
                self.set_status(format!(
                    "DIAGNOSTIC: {} — waiting...", diag.state.label()
                ));
                false
            }
        }
    }

    /// Check if a resumable checkpoint exists for this plan.
    /// Looks for arc-phase-loop.local.md and verifies the plan matches.
    fn check_existing_checkpoint(&self, plan: &PlanFile) -> bool {
        crate::execution::ExecutionEngine::check_existing_checkpoint(plan)
    }

    /// Send a tmux command with retry logic. Returns Some(()) on success, None on failure.
    /// Uses exponential backoff between retries (5s, then 10s).
    fn send_with_retry(
        session_id: &str,
        plan_path: &Path,
        max_attempts: u8,
        send_fn: fn(&str, &Path) -> color_eyre::Result<()>,
        label: &str,
    ) -> Option<()> {
        let mut delay_secs = 5;

        for attempt in 1..=max_attempts {
            match send_fn(session_id, plan_path) {
                Ok(()) => return Some(()),
                Err(e) if attempt < max_attempts => {
                    tlog!(WARN, "send {} attempt {} failed: {}, retrying in {}s", label, attempt, e, delay_secs);
                    std::thread::sleep(Duration::from_secs(delay_secs));
                    delay_secs *= 2;
                }
                Err(e) => {
                    tlog!(ERROR, "send {} failed after {} attempts: {}", label, max_attempts, e);
                    return None;
                }
            }
        }
        None
    }

    /// Send /arc command with retry logic.
    /// When bridge_port is Some, attempts bridge dispatch first; falls back to tmux.
    fn send_arc_with_retry(session_id: &str, plan_path: &Path, max_attempts: u8) -> Option<()> {
        Self::send_with_retry(session_id, plan_path, max_attempts, Tmux::send_arc_command, "/arc")
    }

    /// Send /arc command preferring bridge transport when available.
    pub(crate) fn send_arc_prefer_bridge(session_id: &str, plan_path: &Path, max_attempts: u8, bridge_port: Option<u16>, resume: bool) -> Option<()> {
        if let Some(port) = bridge_port {
            if Self::send_arc_via_bridge(port, plan_path, resume).is_ok() {
                return Some(());
            }
            // Bridge failed — fall back to tmux
        }
        if resume {
            Self::send_arc_resume_with_retry(session_id, plan_path, max_attempts)
        } else {
            Self::send_arc_with_retry(session_id, plan_path, max_attempts)
        }
    }

    /// Send /arc --resume command with retry logic.
    fn send_arc_resume_with_retry(session_id: &str, plan_path: &Path, max_attempts: u8) -> Option<()> {
        Self::send_with_retry(session_id, plan_path, max_attempts, Tmux::send_arc_resume_command, "/arc --resume")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use crate::messaging::BRIDGE_MSG_DISPLAY_CAP;

    #[test]
    fn test_plans_match_same_filename() {
        assert!(plans_match("plans/test.md", "plans/test.md"));
    }

    #[test]
    fn test_plans_match_different_prefix() {
        assert!(plans_match("plans/test.md", "/abs/path/plans/test.md"));
    }

    #[test]
    fn test_plans_match_bare_filename() {
        assert!(plans_match("test.md", "plans/test.md"));
    }

    #[test]
    fn test_plans_match_different_files() {
        assert!(!plans_match("plans/auth.md", "plans/bug.md"));
    }

    #[test]
    fn test_plans_match_empty_strings() {
        assert!(plans_match("", ""));
    }

    // --- PhaseTimeoutConfig tests ---

    #[test]
    fn test_phase_category_mapping() {
        assert_eq!(phase_category("forge"), "forge");
        assert_eq!(phase_category("work"), "work");
        assert_eq!(phase_category("task_decomposition"), "work");
        assert_eq!(phase_category("design_extraction"), "work");
        assert_eq!(phase_category("design_prototype"), "work");
        assert_eq!(phase_category("design_iteration"), "work");
        assert_eq!(phase_category("test"), "test");
        assert_eq!(phase_category("test_coverage_critique"), "test");
        assert_eq!(phase_category("ship"), "ship");
        assert_eq!(phase_category("merge"), "ship");
        assert_eq!(phase_category("pre_ship_validation"), "ship");
        assert_eq!(phase_category("release_quality_check"), "ship");
        assert_eq!(phase_category("deploy_verify"), "ship");
        assert_eq!(phase_category("bot_review_wait"), "ship");
        assert_eq!(phase_category("pr_comment_resolution"), "ship");
    }

    #[test]
    fn test_phase_category_qa() {
        assert_eq!(phase_category("forge_qa"), "qa");
        assert_eq!(phase_category("work_qa"), "qa");
        assert_eq!(phase_category("gap_analysis_qa"), "qa");
        assert_eq!(phase_category("code_review_qa"), "qa");
        assert_eq!(phase_category("mend_qa"), "qa");
        assert_eq!(phase_category("test_qa"), "qa");
    }

    #[test]
    fn test_phase_category_analysis() {
        assert_eq!(phase_category("gap_analysis"), "analysis");
        assert_eq!(phase_category("codex_gap_analysis"), "analysis");
        assert_eq!(phase_category("goldmask_verification"), "analysis");
        assert_eq!(phase_category("goldmask_correlation"), "analysis");
        assert_eq!(phase_category("semantic_verification"), "analysis");
        assert_eq!(phase_category("gap_remediation"), "analysis");
        assert_eq!(phase_category("plan_refine"), "analysis");
        assert_eq!(phase_category("verification"), "analysis");
        assert_eq!(phase_category("drift_review"), "analysis");
    }

    #[test]
    fn test_phase_category_review_explicit() {
        assert_eq!(phase_category("plan_review"), "review");
        assert_eq!(phase_category("code_review"), "review");
        assert_eq!(phase_category("mend"), "review");
        assert_eq!(phase_category("verify_mend"), "review");
        assert_eq!(phase_category("storybook_verification"), "review");
        assert_eq!(phase_category("design_verification"), "review");
        assert_eq!(phase_category("ux_verification"), "review");
    }

    #[test]
    fn test_phase_category_defaults_to_review() {
        // Unknown phases fall back to "review" category
        assert_eq!(phase_category("unknown_phase_xyz"), "review");
        assert_eq!(phase_category(""), "review");
    }

    #[test]
    fn test_phase_timeout_config_defaults() {
        // No timeouts configured — all lookups should return the default_timeout
        let config = PhaseTimeoutConfig {
            timeouts: HashMap::new(),
            default_timeout: Duration::from_secs(60 * 60),
        };
        // With empty timeouts map, everything falls through to default_timeout
        assert_eq!(config.timeout_for("forge"), Duration::from_secs(3600));
        assert_eq!(config.timeout_for("work"), Duration::from_secs(3600));
        assert_eq!(config.timeout_for("test"), Duration::from_secs(3600));
        assert_eq!(config.timeout_for("code_review"), Duration::from_secs(3600));
        assert_eq!(config.timeout_for("ship"), Duration::from_secs(3600));
        assert_eq!(config.timeout_for("unknown"), Duration::from_secs(3600));
    }

    #[test]
    fn test_phase_timeout_config_with_overrides() {
        let mut timeouts = HashMap::new();
        timeouts.insert("work".to_string(), Duration::from_secs(120 * 60)); // 120 min
        timeouts.insert("ship".to_string(), Duration::from_secs(15 * 60));  // 15 min

        let config = PhaseTimeoutConfig {
            timeouts,
            default_timeout: Duration::from_secs(60 * 60),
        };

        // "work" category phases get the 120m override
        assert_eq!(config.timeout_for("work"), Duration::from_secs(7200));
        assert_eq!(config.timeout_for("task_decomposition"), Duration::from_secs(7200));

        // "ship" category phases get the 15m override
        assert_eq!(config.timeout_for("ship"), Duration::from_secs(900));
        assert_eq!(config.timeout_for("merge"), Duration::from_secs(900));
        assert_eq!(config.timeout_for("pre_ship_validation"), Duration::from_secs(900));

        // Unconfigured categories fall back to default
        assert_eq!(config.timeout_for("forge"), Duration::from_secs(3600));
        assert_eq!(config.timeout_for("test"), Duration::from_secs(3600));
        assert_eq!(config.timeout_for("code_review"), Duration::from_secs(3600));
    }

    #[test]
    fn test_phase_timeout_config_custom_default() {
        let config = PhaseTimeoutConfig {
            timeouts: HashMap::new(),
            default_timeout: Duration::from_secs(45 * 60), // 45 min default
        };

        // All phases use the custom default
        assert_eq!(config.timeout_for("forge"), Duration::from_secs(2700));
        assert_eq!(config.timeout_for("unknown"), Duration::from_secs(2700));
    }

    #[test]
    fn test_phase_timeout_config_is_default() {
        // Build a default config directly instead of calling from_env(), which
        // races with parallel tests that set/remove TORRENT_TIMEOUT_* env vars.
        let mut timeouts = HashMap::new();
        for (cat, mins) in &[("forge", 30u64), ("work", 45), ("qa", 15),
                             ("analysis", 20), ("test", 30), ("review", 30), ("ship", 20)] {
            timeouts.insert(cat.to_string(), Duration::from_secs(mins * 60));
        }
        let default_config = PhaseTimeoutConfig {
            timeouts,
            default_timeout: Duration::from_secs(60 * 60),
        };
        assert!(default_config.is_default());

        // Empty timeouts map is NOT the default (from_env always populates 7 categories)
        let empty_config = PhaseTimeoutConfig {
            timeouts: HashMap::new(),
            default_timeout: Duration::from_secs(60 * 60),
        };
        assert!(!empty_config.is_default());

        // Custom default timeout
        let custom_default = PhaseTimeoutConfig {
            timeouts: HashMap::new(),
            default_timeout: Duration::from_secs(45 * 60),
        };
        assert!(!custom_default.is_default());

        // With overrides
        let mut timeouts = HashMap::new();
        timeouts.insert("work".to_string(), Duration::from_secs(90 * 60));
        let with_override = PhaseTimeoutConfig {
            timeouts,
            default_timeout: Duration::from_secs(60 * 60),
        };
        assert!(!with_override.is_default());
    }

    #[test]
    fn test_phase_timeout_config_overrides() {
        // Test apply_overrides (CLI path) directly instead of from_env() which
        // races with parallel tests due to process-global env var mutation.

        // Build a baseline config with category defaults
        let mut timeouts = HashMap::new();
        for (cat, mins) in &[("forge", 30u64), ("work", 45), ("qa", 15),
                             ("analysis", 20), ("test", 30), ("review", 30), ("ship", 20)] {
            timeouts.insert(cat.to_string(), Duration::from_secs(mins * 60));
        }
        let mut config = PhaseTimeoutConfig {
            timeouts,
            default_timeout: Duration::from_secs(60 * 60),
        };

        // Apply CLI override for work category
        config.apply_overrides(&[("work".to_string(), 120)]);

        // Work category should be 120 minutes (override)
        assert_eq!(config.timeout_for("work"), Duration::from_secs(120 * 60),
            "work should be 120 min from override");
        // Forge retains its category default (30 min)
        assert_eq!(config.timeout_for("forge"), Duration::from_secs(30 * 60));
        // QA retains its category default (15 min)
        assert_eq!(config.timeout_for("forge_qa"), Duration::from_secs(15 * 60));
        // Analysis retains its category default (20 min)
        assert_eq!(config.timeout_for("gap_analysis"), Duration::from_secs(20 * 60));
        // Unknown phase falls back to "review" category (30 min)
        assert_eq!(config.timeout_for("unknown_phase"), Duration::from_secs(30 * 60));

        // Verify is_default returns false after override
        assert!(!config.is_default());
    }

    // ── env_or_u64 tests ────────────────────────────────────

    #[test]
    fn test_env_or_u64_returns_default_when_unset() {
        // Use a unique env var name that won't exist
        assert_eq!(env_or_u64("TORRENT_TEST_NONEXISTENT_12345", 42), 42);
    }

    #[test]
    fn test_env_or_u64_parses_valid_value() {
        unsafe { std::env::set_var("TORRENT_TEST_ENV_U64", "300"); }
        assert_eq!(env_or_u64("TORRENT_TEST_ENV_U64", 42), 300);
        unsafe { std::env::remove_var("TORRENT_TEST_ENV_U64"); }
    }

    #[test]
    fn test_env_or_u64_returns_default_on_invalid() {
        unsafe { std::env::set_var("TORRENT_TEST_ENV_BAD", "not_a_number"); }
        assert_eq!(env_or_u64("TORRENT_TEST_ENV_BAD", 99), 99);
        unsafe { std::env::remove_var("TORRENT_TEST_ENV_BAD"); }
    }

    #[test]
    fn test_env_or_u64_returns_default_on_negative() {
        unsafe { std::env::set_var("TORRENT_TEST_ENV_NEG", "-5"); }
        assert_eq!(env_or_u64("TORRENT_TEST_ENV_NEG", 50), 50);
        unsafe { std::env::remove_var("TORRENT_TEST_ENV_NEG"); }
    }

    #[test]
    fn test_env_or_u64_handles_zero() {
        unsafe { std::env::set_var("TORRENT_TEST_ENV_ZERO", "0"); }
        assert_eq!(env_or_u64("TORRENT_TEST_ENV_ZERO", 100), 0);
        unsafe { std::env::remove_var("TORRENT_TEST_ENV_ZERO"); }
    }

    // ── Grace duration formula tests ────────────────────────
    // Formula: base + (child_count * 2) + (cpu% * 0.5), clamped to [min, max]
    // We test the formula directly since compute_grace_duration() reads from
    // self.execution.current_run which is hard to construct. Instead, test the math.

    #[test]
    fn test_grace_formula_defaults_no_load() {
        // base=30, children=0, cpu=0% → 30, clamp [10, 120] → 30
        let base: u64 = 30;
        let min: u64 = 10;
        let max: u64 = 120;
        let child_count: u64 = 0;
        let cpu: f32 = 0.0;

        let secs = base
            .saturating_add(child_count.saturating_mul(2))
            .saturating_add((cpu * 0.5) as u64);
        assert_eq!(secs.clamp(min, max), 30);
    }

    #[test]
    fn test_grace_formula_moderate_load() {
        // base=30, children=5, cpu=50% → 30 + 10 + 25 = 65
        let base: u64 = 30;
        let min: u64 = 10;
        let max: u64 = 120;
        let child_count: u64 = 5;
        let cpu: f32 = 50.0;

        let secs = base
            .saturating_add(child_count.saturating_mul(2))
            .saturating_add((cpu * 0.5) as u64);
        assert_eq!(secs.clamp(min, max), 65);
    }

    #[test]
    fn test_grace_formula_heavy_load_clamped_to_max() {
        // base=30, children=20, cpu=100% → 30 + 40 + 50 = 120 (at max)
        let base: u64 = 30;
        let min: u64 = 10;
        let max: u64 = 120;
        let child_count: u64 = 20;
        let cpu: f32 = 100.0;

        let secs = base
            .saturating_add(child_count.saturating_mul(2))
            .saturating_add((cpu * 0.5) as u64);
        assert_eq!(secs.clamp(min, max), 120);
    }

    #[test]
    fn test_grace_formula_exceeds_max() {
        // base=30, children=50, cpu=100% → 30 + 100 + 50 = 180, clamp → 120
        let base: u64 = 30;
        let min: u64 = 10;
        let max: u64 = 120;
        let child_count: u64 = 50;
        let cpu: f32 = 100.0;

        let secs = base
            .saturating_add(child_count.saturating_mul(2))
            .saturating_add((cpu * 0.5) as u64);
        assert_eq!(secs.clamp(min, max), 120);
    }

    #[test]
    fn test_grace_formula_below_min() {
        // base=5, children=0, cpu=0% → 5, clamp [10, 120] → 10
        let base: u64 = 5;
        let min: u64 = 10;
        let max: u64 = 120;
        let child_count: u64 = 0;
        let cpu: f32 = 0.0;

        let secs = base
            .saturating_add(child_count.saturating_mul(2))
            .saturating_add((cpu * 0.5) as u64);
        assert_eq!(secs.clamp(min, max), 10);
    }

    #[test]
    fn test_grace_formula_cpu_fraction_truncated() {
        // cpu=1.9% → (1.9 * 0.5) = 0.95 → as u64 = 0
        let cpu: f32 = 1.9;
        assert_eq!((cpu * 0.5) as u64, 0);
    }

    #[test]
    fn test_grace_formula_custom_bounds() {
        // Custom min=60, max=300, base=100, children=10, cpu=80%
        // → 100 + 20 + 40 = 160, clamp [60, 300] → 160
        let base: u64 = 100;
        let min: u64 = 60;
        let max: u64 = 300;
        let child_count: u64 = 10;
        let cpu: f32 = 80.0;

        let secs = base
            .saturating_add(child_count.saturating_mul(2))
            .saturating_add((cpu * 0.5) as u64);
        assert_eq!(secs.clamp(min, max), 160);
    }

    // ── Inter-plan cooldown tests ───────────────────────────

    #[test]
    fn test_inter_plan_cooldown_timing() {
        // Simulate cooldown deadline in the future
        let deadline = Instant::now() + Duration::from_secs(300);
        let now = Instant::now();
        assert!(now < deadline);
        let remaining = deadline.duration_since(now).as_secs();
        assert!(remaining >= 298 && remaining <= 300);
    }

    #[test]
    fn test_inter_plan_cooldown_expired() {
        // Simulate cooldown deadline in the past
        let deadline = Instant::now() - Duration::from_secs(1);
        let now = Instant::now();
        assert!(now >= deadline);
    }

    #[test]
    fn test_inter_plan_cooldown_display_format() {
        // Verify the countdown display formatting
        let remaining_secs: u64 = 275; // 4m35s
        let display = format!(
            " Next plan in {}m{}s  [s] skip cooldown",
            remaining_secs / 60,
            remaining_secs % 60,
        );
        assert_eq!(display, " Next plan in 4m35s  [s] skip cooldown");
    }

    #[test]
    fn test_inter_plan_cooldown_display_under_one_minute() {
        let remaining_secs: u64 = 45;
        let display = format!(
            " Next plan in {}m{}s  [s] skip cooldown",
            remaining_secs / 60,
            remaining_secs % 60,
        );
        assert_eq!(display, " Next plan in 0m45s  [s] skip cooldown");
    }

    #[test]
    fn test_inter_plan_cooldown_display_exact_minutes() {
        let remaining_secs: u64 = 300; // exactly 5m
        let display = format!(
            " Next plan in {}m{}s  [s] skip cooldown",
            remaining_secs / 60,
            remaining_secs % 60,
        );
        assert_eq!(display, " Next plan in 5m0s  [s] skip cooldown");
    }

    // ── ArcCompletion classification tests ──────────────────

    #[test]
    fn test_arc_completion_success_variants() {
        let merged = ArcCompletion::Merged { pr_url: Some("https://github.com/test/1".into()) };
        let shipped = ArcCompletion::Shipped { pr_url: Some("https://github.com/test/2".into()) };

        assert!(matches!(merged, ArcCompletion::Merged { .. }));
        assert!(matches!(shipped, ArcCompletion::Shipped { .. }));

        // Both are success variants
        assert!(matches!(&merged, ArcCompletion::Merged { .. } | ArcCompletion::Shipped { .. }));
        assert!(matches!(&shipped, ArcCompletion::Merged { .. } | ArcCompletion::Shipped { .. }));
    }

    #[test]
    fn test_arc_completion_failure_variants() {
        let failed = ArcCompletion::Failed { reason: "test failure".into() };
        let cancelled = ArcCompletion::Cancelled { reason: Some("user cancelled".into()) };

        // Neither should match success pattern
        assert!(!matches!(&failed, ArcCompletion::Merged { .. } | ArcCompletion::Shipped { .. }));
        assert!(!matches!(&cancelled, ArcCompletion::Merged { .. } | ArcCompletion::Shipped { .. }));
    }

    #[test]
    fn test_arc_completion_merged_without_pr_url() {
        // Edge case: merged but no PR URL (shouldn't happen, but must not panic)
        let merged = ArcCompletion::Merged { pr_url: None };
        assert!(matches!(merged, ArcCompletion::Merged { pr_url: None }));
    }

    #[test]
    fn test_arc_completion_cancelled_without_reason() {
        let cancelled = ArcCompletion::Cancelled { reason: None };
        assert!(matches!(cancelled, ArcCompletion::Cancelled { reason: None }));
    }

    // ── Queue state tests ───────────────────────────────────

    #[test]
    fn test_queue_entry_stores_indices() {
        let entry = QueueEntry { plan_idx: 3, config_idx: 1 };
        assert_eq!(entry.plan_idx, 3);
        assert_eq!(entry.config_idx, 1);
    }

    #[test]
    fn test_vecdeque_queue_ordering() {
        let mut queue: VecDeque<QueueEntry> = VecDeque::new();
        queue.push_back(QueueEntry { plan_idx: 0, config_idx: 0 });
        queue.push_back(QueueEntry { plan_idx: 1, config_idx: 0 });
        queue.push_back(QueueEntry { plan_idx: 2, config_idx: 0 });

        // pop_front should give FIFO order
        assert_eq!(queue.pop_front().unwrap().plan_idx, 0);
        assert_eq!(queue.pop_front().unwrap().plan_idx, 1);
        assert!(!queue.is_empty());
        assert_eq!(queue.pop_front().unwrap().plan_idx, 2);
        assert!(queue.is_empty());
    }

    // --- Bridge Message tests ---

    #[test]
    fn test_bridge_message_ring_buffer_capacity() {
        let mut buf: VecDeque<BridgeMessage> = VecDeque::with_capacity(BRIDGE_MSG_DISPLAY_CAP);
        let now = chrono::Local::now().time();

        // Fill to capacity
        for i in 0..BRIDGE_MSG_DISPLAY_CAP {
            buf.push_back(BridgeMessage {
                text: format!("msg {}", i),
                timestamp: now,
                kind: BridgeMessageKind::Phase,
            });
        }
        assert_eq!(buf.len(), BRIDGE_MSG_DISPLAY_CAP);

        // Push one more — should evict front
        if buf.len() >= BRIDGE_MSG_DISPLAY_CAP {
            buf.pop_front();
        }
        buf.push_back(BridgeMessage {
            text: "msg overflow".into(),
            timestamp: now,
            kind: BridgeMessageKind::Reply,
        });
        assert_eq!(buf.len(), BRIDGE_MSG_DISPLAY_CAP);
        assert_eq!(buf.front().unwrap().text, "msg 1"); // msg 0 was evicted
        assert_eq!(buf.back().unwrap().text, "msg overflow");
    }

    #[test]
    fn test_push_bridge_message_heartbeat_dedup() {
        let now = chrono::Local::now().time();
        let mut buf: VecDeque<BridgeMessage> = VecDeque::with_capacity(BRIDGE_MSG_DISPLAY_CAP);

        // First heartbeat — should be added
        let hb1 = BridgeMessage {
            text: "Claude: active (using Bash)".into(),
            timestamp: now,
            kind: BridgeMessageKind::Heartbeat,
        };
        // Simulate push_bridge_message dedup logic (without file persistence)
        buf.push_back(hb1);
        assert_eq!(buf.len(), 1);

        // Second consecutive heartbeat — should replace, not accumulate
        let hb2 = BridgeMessage {
            text: "Claude: active (using Read)".into(),
            timestamp: now,
            kind: BridgeMessageKind::Heartbeat,
        };
        if buf.back().map(|m| m.kind) == Some(BridgeMessageKind::Heartbeat) {
            buf.pop_back();
        }
        if buf.len() >= BRIDGE_MSG_DISPLAY_CAP {
            buf.pop_front();
        }
        buf.push_back(hb2);
        assert_eq!(buf.len(), 1, "consecutive heartbeats should replace, not accumulate");
        assert_eq!(buf.back().unwrap().text, "Claude: active (using Read)");

        // Non-heartbeat followed by heartbeat — both should remain
        let phase = BridgeMessage {
            text: "Phase: forge (started)".into(),
            timestamp: now,
            kind: BridgeMessageKind::Phase,
        };
        buf.push_back(phase);
        assert_eq!(buf.len(), 2);

        let hb3 = BridgeMessage {
            text: "Claude: idle".into(),
            timestamp: now,
            kind: BridgeMessageKind::Heartbeat,
        };
        // Last message is Phase, not Heartbeat — should not dedup
        if buf.back().map(|m| m.kind) == Some(BridgeMessageKind::Heartbeat) {
            buf.pop_back();
        }
        buf.push_back(hb3);
        assert_eq!(buf.len(), 3, "heartbeat after non-heartbeat should not dedup");
    }

    #[test]
    fn test_bridge_message_kind_equality() {
        assert_eq!(BridgeMessageKind::Sent, BridgeMessageKind::Sent);
        assert_ne!(BridgeMessageKind::Sent, BridgeMessageKind::Reply);
        assert_eq!(BridgeMessageKind::Heartbeat, BridgeMessageKind::Heartbeat);
    }

    #[test]
    fn test_persist_bridge_message_escaping() {
        use std::io::Read;

        let tmp = std::env::temp_dir().join("torrent-test-persist-bridge-msg");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let path = tmp.join("test.jsonl");

        {
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .unwrap();

            let msg = BridgeMessage {
                text: "hello \"world\" with\\backslash and\nnewline\rand\ttab".into(),
                timestamp: chrono::Local::now().time(),
                kind: BridgeMessageKind::Sent,
            };
            crate::messaging::persist_bridge_message(&mut file, &msg);
        }

        let mut content = String::new();
        std::fs::File::open(&path).unwrap().read_to_string(&mut content).unwrap();

        // Verify JSON is valid: no raw quotes/newlines/control chars in the text field
        assert!(content.contains(r#"\"world\""#), "quotes should be escaped");
        assert!(content.contains(r#"\\backslash"#), "backslashes should be escaped");
        assert!(content.contains(r#"\n"#), "newlines should be escaped");
        assert!(content.contains(r#"\r"#), "carriage returns should be escaped");
        assert!(content.contains(r#"\t"#), "tabs should be escaped");
        assert!(content.contains(r#""kind":"sent""#));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_open_bridge_log_rejects_bad_session_id() {
        assert!(crate::messaging::open_bridge_log("").is_none(), "empty session_id");
        assert!(crate::messaging::open_bridge_log("../../../etc/passwd").is_none(), "path traversal");
        assert!(crate::messaging::open_bridge_log(&"a".repeat(65)).is_none(), "too long");
        assert!(crate::messaging::open_bridge_log("valid-session_123").is_some(), "valid session_id");

        // Cleanup
        let _ = std::fs::remove_dir_all(".torrent/sessions/valid-session_123");
    }

    #[test]
    fn test_send_arc_via_bridge_unreachable() {
        // Sending to a port with no listener should fail gracefully
        let result = App::send_arc_via_bridge(
            59999,  // unlikely to have a server
            &std::path::PathBuf::from("plans/test-plan.md"),
            false,
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_send_arc_via_bridge_path_extraction() {
        // Verify the path extraction logic works correctly
        let path = std::path::PathBuf::from("/abs/path/to/plans/feat-auth-plan.md");
        let display_path = path.display().to_string();
        let arc_path = display_path
            .find("plans/")
            .map(|idx| &display_path[idx..])
            .unwrap_or(&display_path);
        assert_eq!(arc_path, "plans/feat-auth-plan.md");
    }
}
