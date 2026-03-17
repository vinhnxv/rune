use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::Utc;
use color_eyre::eyre::eyre;
use color_eyre::Result;

use crate::monitor;
use crate::resource::{self, ProcessHealth, ResourceSnapshot};
use crate::scanner::{ConfigDir, PlanFile};
use crate::tmux::Tmux;

/// Compare two plan names by filename (ignoring path prefix).
/// Handles: "plans/foo.md" vs "foo.md" vs "/abs/plans/foo.md".
fn plans_match(a: &str, b: &str) -> bool {
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
    pub selected_plans: Vec<usize>, // ordered indices — execution order
    pub active_panel: Panel,

    // Execution view
    pub view: AppView,
    pub queue: VecDeque<QueueEntry>,
    pub current_run: Option<RunState>,
    pub completed_runs: Vec<CompletedRun>,
    pub tmux_session_id: Option<String>,

    // UI state
    pub config_cursor: usize,
    pub plan_cursor: usize,
    pub queue_cursor: usize, // cursor position in queue (Running view)

    // Polling timers (non-blocking, checked on each tick)
    pub last_discovery_poll: Option<Instant>,
    pub last_heartbeat_poll: Option<Instant>,
    pub last_checkpoint_poll: Option<Instant>,
    pub last_loop_state_poll: Option<Instant>,
    pub last_active_arcs_prune: Option<Instant>,
    pub launched_wall_clock: Option<chrono::DateTime<Utc>>,

    // Status message for display in UI
    pub status_message: Option<String>,

    // Resolved absolute path to claude binary (avoids PATH issues in tmux)
    pub claude_path: String,

    // Resource monitoring (sysinfo)
    pub sys: sysinfo::System,

    // Current git branch of CWD
    pub git_branch: String,

    // Timestamp when all plans completed (for auto-quit countdown)
    pub all_done_at: Option<Instant>,

    // Queue editing mode — Selection view appends to queue instead of starting fresh
    pub queue_editing: bool,

    // Whether we should quit
    pub should_quit: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppView {
    /// Active arcs detected at startup — resume or dismiss.
    ActiveArcs,
    /// Normal selection view — pick config + plans.
    Selection,
    /// Running view — monitoring current arc execution.
    Running,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Panel {
    ConfigList,
    PlanList,
}

/// A queued plan with its associated config dir.
#[derive(Debug, Clone)]
pub struct QueueEntry {
    pub plan_idx: usize,
    pub config_idx: usize,
}

/// State of the currently executing arc run.
#[allow(dead_code)] // tmux_pane_pid kept for diagnostics
pub struct RunState {
    pub plan: PlanFile,
    pub plan_index: usize,   // 1-indexed position in selected_plans
    pub total_plans: usize,
    pub tmux_session: String,
    pub launched_at: Instant,
    pub arc: Option<ArcHandle>,
    pub last_status: Option<ArcStatus>,
    pub merge_detected_at: Option<Instant>,
    pub tmux_pane_pid: Option<u32>,  // Shell PID inside tmux pane
    pub claude_pid: Option<u32>,     // Claude Code process PID (= owner_pid in checkpoint)
    pub loop_state: Option<monitor::ArcLoopState>, // From arc-phase-loop.local.md
    pub session_info: Option<crate::scanner::SessionInfo>, // Enriched session info
}

/// Handle to a discovered arc checkpoint + heartbeat pair.
pub struct ArcHandle {
    pub arc_id: String,
    pub checkpoint_path: PathBuf,
    pub heartbeat_path: PathBuf,
    pub plan_file: String,
    pub config_dir: String,
    pub owner_pid: String,
    pub session_id: String,  // Claude Code session UUID from checkpoint
}

/// Polled status of a running arc.
#[derive(Clone)]
#[allow(dead_code)] // schema_warning stored for UI display
pub struct ArcStatus {
    pub arc_id: String,
    pub current_phase: String,
    pub last_tool: String,
    pub last_activity: String,
    pub phase_summary: PhaseSummary,
    pub phase_nav: Option<monitor::PhaseNavigation>,
    pub pr_url: Option<String>,
    pub is_stale: bool,
    pub schema_warning: Option<String>,
    // Resource monitoring
    pub resource: Option<ResourceSnapshot>,
    pub process_health: ProcessHealth,
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
    pub result: ArcCompletion,
    pub duration: Duration,
}

#[derive(Debug, Clone)]
#[allow(dead_code)] // all variants needed for completeness
pub enum ArcCompletion {
    Merged { pr_url: Option<String> },
    Shipped { pr_url: Option<String> },
    Cancelled { reason: Option<String> },
    Failed { reason: String },
}

/// Actions dispatched from keybinding handler.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    // Active arcs view
    AttachActiveArc,
    MonitorActiveArc,
    DismissActiveArcs,
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
    PickPlans,       // Enter queue-edit mode (Running → Selection)
    RemoveFromQueue, // Delete queue item at cursor
    // Queue-edit mode (Selection while queue_editing=true)
    AppendToQueue,   // Confirm — append selected plans to queue
    CancelQueueEdit, // Cancel — return to Running without changes
    // No-op
    None,
}

impl App {
    pub fn new() -> Result<Self> {
        let config_dirs = crate::scanner::scan_config_dirs()?;
        let cwd = std::env::current_dir()?;
        let plans = crate::scanner::scan_plans(&cwd)?;

        // Initialize sysinfo BEFORE scanning arcs (needed for session enrichment)
        let sys = resource::create_process_system();

        // Startup scan: detect active arc sessions
        let active_arcs = crate::scanner::scan_active_arcs(&config_dirs, &cwd, &sys);
        let initial_view = if active_arcs.is_empty() {
            AppView::Selection
        } else {
            AppView::ActiveArcs
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
            queue: VecDeque::new(),
            current_run: None,
            completed_runs: Vec::new(),
            tmux_session_id: None,
            config_cursor: 0,
            plan_cursor: 0,
            queue_cursor: 0,
            last_discovery_poll: None,
            last_heartbeat_poll: None,
            last_checkpoint_poll: None,
            last_loop_state_poll: None,
            last_active_arcs_prune: None,
            launched_wall_clock: None,
            status_message: None,
            claude_path: crate::tmux::Tmux::resolve_claude_path()
                .unwrap_or_else(|_| "claude".to_string()),
            sys: resource::create_process_system(),
            git_branch: Self::read_git_branch(),
            all_done_at: None,
            queue_editing: false,
            should_quit: false,
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

    /// Check if a plan index is already queued or currently running.
    /// Used in queue-edit mode to prevent duplicate selection.
    pub fn is_plan_in_flight(&self, plan_idx: usize) -> bool {
        let plan = match self.plans.get(plan_idx) {
            Some(p) => p,
            None => return false,
        };
        // Currently running? (match by file name — paths may differ: relative vs absolute)
        if let Some(ref run) = self.current_run {
            if plans_match(&run.plan.name, &plan.name) {
                return true;
            }
        }
        // In queue?
        if self.queue.iter().any(|e| e.plan_idx == plan_idx) {
            return true;
        }
        // Already completed?
        if self.completed_runs.iter().any(|r| plans_match(&r.plan.name, &plan.name)) {
            return true;
        }
        false
    }

    /// Refresh session info (mcp count, teammate count, etc).
    pub fn refresh_session_info(&mut self) {
        if let Some(run) = &mut self.current_run {
            if let Some(pid) = run.claude_pid {
                let config_dir = run.arc.as_ref()
                    .map(|a| a.config_dir.as_str())
                    .unwrap_or("");
                run.session_info = crate::scanner::enrich_session_info_pub(
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
        let should_prune = self
            .last_active_arcs_prune
            .map(|t| now.duration_since(t) >= Duration::from_secs(10))
            .unwrap_or(true);
        if !should_prune {
            return;
        }
        self.last_active_arcs_prune = Some(now);

        self.active_arcs.retain(|arc| {
            // If it has a tmux session, verify it still exists
            if let Some(ref session) = arc.tmux_session {
                if !Tmux::session_exists(session) {
                    return false;
                }
            }
            // If it has a PID, verify it's still alive
            if !arc.loop_state.owner_pid.is_empty() && arc.pid_alive {
                if !Self::is_pid_alive(&arc.loop_state.owner_pid) {
                    return false;
                }
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

    /// Check if a PID is alive (wrapper around kill -0).
    fn is_pid_alive(pid_str: &str) -> bool {
        let pid: u32 = match pid_str.parse() {
            Ok(p) => p,
            Err(_) => return false,
        };
        Command::new("kill")
            .args(["-0", &pid.to_string()])
            .output()
            .is_ok_and(|o| o.status.success())
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
        }
    }

    /// Total number of items displayed in the Queue panel.
    fn queue_total_items(&self) -> usize {
        self.completed_runs.len()
            + if self.current_run.is_some() { 1 } else { 0 }
            + self.queue.len()
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
        if let Some(pos) = self.selected_plans.iter().position(|&i| i == idx) {
            // Already selected — remove it (reorders remaining)
            self.selected_plans.remove(pos);
        } else {
            // Not selected — add to end (becomes last in execution order)
            self.selected_plans.push(idx);
        }
    }

    /// Toggle all plans. If any are selected, deselect all. Otherwise select all in file order.
    /// In queue-edit mode, only select plans not already in-flight.
    pub fn toggle_all(&mut self) {
        if self.selected_plans.is_empty() {
            if self.queue_editing {
                self.selected_plans = (0..self.plans.len())
                    .filter(|&i| !self.is_plan_in_flight(i))
                    .collect();
            } else {
                self.selected_plans = (0..self.plans.len()).collect();
            }
        } else {
            self.selected_plans.clear();
        }
    }


    /// Transition to Running view — populate the execution queue.
    pub fn start_run(&mut self) {
        self.view = AppView::Running;
        self.queue = self.selected_plans.iter()
            .map(|&plan_idx| QueueEntry {
                plan_idx,
                config_idx: self.selected_config,
            })
            .collect();
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
        if let Some(ref run) = self.current_run {
            let phase = run
                .last_status
                .as_ref()
                .map(|s| s.current_phase.as_str())
                .unwrap_or("starting");
            println!("  ▶ {:<30} {} phase  (running)", run.plan.name, phase);
        }

        // Show pending plans in queue
        for entry in &self.queue {
            if let Some(plan) = self.plans.get(entry.plan_idx) {
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
                if let Some(session_id) = &self.tmux_session_id {
                    let sid = session_id.clone();
                    // Attach blocks — TUI suspends until user detaches (Ctrl-B D)
                    let _ = Tmux::attach(&sid);
                }
            }
            Action::RemoveFromQueue => self.remove_queue_item(),
            Action::SkipPlan => self.skip_current_plan(),
            Action::KillSession => self.kill_current_session(),
            Action::PickPlans => {
                // Enter queue-edit mode: show Selection to pick more plans
                self.queue_editing = true;
                self.selected_plans.clear(); // fresh selection for appending
                self.active_panel = Panel::PlanList;
                // Re-scan plans in case new ones appeared
                let cwd = std::env::current_dir().unwrap_or_default();
                if let Ok(plans) = crate::scanner::scan_plans(&cwd) {
                    self.plans = plans;
                }
                self.plan_cursor = 0;
                self.view = AppView::Selection;
            }
            Action::AppendToQueue => {
                // Append selected plans with currently selected config dir
                for &plan_idx in &self.selected_plans {
                    self.queue.push_back(QueueEntry {
                        plan_idx,
                        config_idx: self.selected_config,
                    });
                }
                let count = self.selected_plans.len();
                self.selected_plans.clear();
                self.queue_editing = false;
                self.all_done_at = None; // reset auto-quit since queue grew
                self.view = AppView::Running;
                self.status_message = Some(format!("{count} plan(s) added to queue"));
            }
            Action::CancelQueueEdit => {
                self.selected_plans.clear();
                self.queue_editing = false;
                self.view = AppView::Running;
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
        };

        self.tmux_session_id = arc.tmux_session.clone();
        let session_info = arc.session_info;
        let loop_state = arc.loop_state;
        self.current_run = Some(RunState {
            plan,
            plan_index: 1,
            total_plans: 1,
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
        });

        self.view = AppView::Running;
    }

    /// Remove a queue item at the current cursor position.
    /// Only pending items (not completed or current) can be removed.
    fn remove_queue_item(&mut self) {
        let completed_count = self.completed_runs.len();
        let current_count = if self.current_run.is_some() { 1 } else { 0 };
        let non_removable = completed_count + current_count;

        if self.queue_cursor < non_removable {
            // Cursor is on a completed run or current — not removable
            self.status_message = Some("Cannot remove completed or running items".into());
            return;
        }

        let queue_idx = self.queue_cursor - non_removable;
        if queue_idx < self.queue.len() {
            let removed = self.queue.remove(queue_idx);
            let name = removed
                .and_then(|e| self.plans.get(e.plan_idx))
                .map(|p| p.name.clone())
                .unwrap_or_else(|| "?".into());
            self.status_message = Some(format!("Removed: {name}"));

            // Adjust cursor if it's past the end
            let total = self.queue_total_items();
            if total > 0 && self.queue_cursor >= total {
                self.queue_cursor = total - 1;
            }
        }
    }

    /// Skip the current plan — kill tmux, move to next.
    fn skip_current_plan(&mut self) {
        if let Some(run) = self.current_run.take() {
            let _ = Tmux::kill_session(&run.tmux_session);
            self.completed_runs.push(CompletedRun {
                plan: run.plan,
                result: ArcCompletion::Cancelled {
                    reason: Some("skipped by user".into()),
                },
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
                result: ArcCompletion::Failed {
                    reason: "killed by user".into(),
                },
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
            if let Some(entry) = self.queue.pop_front() {
                self.all_done_at = None;
                self.selected_config = entry.config_idx;
                self.launch_next_plan(entry.plan_idx)?;
            } else if !self.completed_runs.is_empty() {
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
                            self.status_message = Some(format!(
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

            // Loop state liveness check (every 60s)
            // If arc-phase-loop.local.md is gone, the arc has completed or been stopped
            let should_check_loop = self
                .last_loop_state_poll
                .map(|t| now.duration_since(t) >= Duration::from_secs(60))
                .unwrap_or(true);

            if should_check_loop {
                self.check_loop_state_liveness();
                self.refresh_git_branch();
                self.refresh_session_info();
                self.last_loop_state_poll = Some(now);
            }

            // Check grace period completion
            self.check_grace_period(now);
        }

        Ok(())
    }

    /// Check if arc-phase-loop.local.md still exists and refresh loop state.
    /// If it's gone, the arc has completed or been stopped — trigger completion.
    fn check_loop_state_liveness(&mut self) {
        let cwd = std::env::current_dir().unwrap_or_default();
        let loop_file = cwd.join(".claude").join("arc-phase-loop.local.md");

        if !loop_file.exists() {
            self.status_message = Some(
                "arc-phase-loop.local.md removed — arc completed or stopped".into(),
            );
            if let Some(run) = &mut self.current_run {
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
                if let Some(run) = &mut self.current_run {
                    run.loop_state = Some(state);
                }
            }
            None => {
                // active: false — arc cancelled
                self.status_message = Some(
                    "arc-phase-loop.local.md active: false — arc cancelled".into(),
                );
                if let Some(run) = &mut self.current_run {
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
        let config = self.config_dirs.get(self.selected_config).ok_or_else(|| {
            eyre!("no config dir selected")
        })?;

        // Step 1: git checkout main + pull (blocking, before tmux)
        // Use .output() to CAPTURE stdout/stderr — .status() leaks into TUI display
        let checkout = Command::new("git")
            .args(["checkout", "main"])
            .output();
        if checkout.as_ref().map_or(true, |o| !o.status.success()) {
            self.status_message = Some("git checkout main failed — clean up working tree".into());
            self.queue.push_front(QueueEntry {
                plan_idx,
                config_idx: self.selected_config,
            });
            return Ok(());
        }
        let pull = Command::new("git")
            .args(["pull", "--ff-only"])
            .output();
        if pull.as_ref().map_or(true, |o| !o.status.success()) {
            self.status_message = Some("git pull failed — try manually".into());
        }

        // Step 2: Record wall-clock time BEFORE launch (for discovery matching)
        self.launched_wall_clock = Some(Utc::now());

        // Step 3: Create tmux session (empty shell)
        let session_id = Tmux::generate_session_id();
        if let Err(e) = Tmux::create_session(&session_id) {
            self.status_message = Some(format!("tmux failed: {e}"));
            return Ok(());
        }
        self.tmux_session_id = Some(session_id.clone());

        // Step 4: Start Claude Code inside the session
        if let Err(e) = Tmux::start_claude(&session_id, &config.path, &self.claude_path) {
            self.status_message = Some(format!("start claude failed: {e}"));
            return Ok(());
        }

        // Step 5: Wait for Claude Code to fully initialize (12s)
        self.status_message = Some(format!("Waiting for Claude Code in {}...", &session_id));
        std::thread::sleep(Duration::from_secs(12));

        // Step 5.5: Capture tmux pane PID (shell inside tmux)
        let tmux_pane_pid = Tmux::get_pane_pid(&session_id).ok();

        // Step 5.6: Find Claude Code process (child of pane shell)
        let claude_pid = tmux_pane_pid.and_then(|ppid| {
            for _ in 0..3 {
                if let Some(pid) = Tmux::get_claude_pid(ppid) {
                    return Some(pid);
                }
                std::thread::sleep(Duration::from_secs(2));
            }
            None
        });

        // Step 6: Send /arc command (uses Escape+delay+Enter workaround for Ink)
        if Self::send_arc_with_retry(&session_id, &plan.path, 2).is_none() {
            self.status_message = Some(format!("FAILED: send /arc failed. tmux attach -t {}", &session_id));
        } else {
            self.status_message = Some(format!("/arc sent to {}", &session_id));
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
            tmux_pane_pid,
            claude_pid,
            loop_state: None,
            session_info: claude_pid.and_then(|pid| {
                crate::scanner::enrich_session_info_pub(
                    &pid.to_string(),
                    &config.path.to_string_lossy(),
                    &self.sys,
                )
            }),
        });

        // Reset poll timers
        self.last_discovery_poll = None;
        self.last_heartbeat_poll = None;
        self.last_checkpoint_poll = None;

        Ok(())
    }

    /// Poll for arc discovery using 2-layer strategy:
    /// 1. Parse arc-phase-loop.local.md (instant, created first by Rune arc)
    /// 2. Fallback: glob scan <config_dir>/arc/arc-*/checkpoint.json
    fn poll_discovery(&mut self) {
        let launched_after = match self.launched_wall_clock {
            Some(t) => t,
            None => return,
        };

        // Extract needed values before borrowing self.current_run mutably
        let config_dir_str = self
            .config_dirs
            .get(self.selected_config)
            .map(|c| c.path.to_string_lossy().to_string());
        let expected_config_dir = config_dir_str.as_deref();

        let (plan_path, expected_claude_pid, has_loop_state) = {
            let run = match &self.current_run {
                Some(r) => r,
                None => return,
            };
            (run.plan.path.clone(), run.claude_pid, run.loop_state.is_some())
        };

        // Read loop state if not yet populated
        if !has_loop_state {
            if let Some(config_dir) = expected_config_dir {
                let loop_state = monitor::read_arc_loop_state(Path::new(config_dir));
                if loop_state.is_some() {
                    self.status_message = Some("Arc loop state detected, discovering checkpoint...".into());
                }
                if let Some(run) = &mut self.current_run {
                    run.loop_state = loop_state;
                }
            }
        }

        // Run discovery (2-layer: loop state → glob scan)
        let cwd = std::env::current_dir().unwrap_or_default();
        if let Some(handle) = monitor::discover_arc(
            &cwd,
            &plan_path,
            launched_after,
            expected_config_dir,
            expected_claude_pid,
        ) {
            if let Some(run) = &mut self.current_run {
                run.arc = Some(ArcHandle {
                    arc_id: handle.arc_id,
                    checkpoint_path: handle.checkpoint_path,
                    heartbeat_path: handle.heartbeat_path,
                    plan_file: handle.plan_file,
                    config_dir: handle.config_dir,
                    owner_pid: handle.owner_pid,
                    session_id: handle.session_id,
                });
            }
        }
    }

    /// Poll arc status (heartbeat + checkpoint + resources) and update display state.
    fn poll_status(&mut self) {
        // Refresh sysinfo for resource polling (lightweight, no sleep needed after init)
        resource::refresh_process_system(&mut self.sys);

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
            session_id: arc.session_id.clone(),
        };

        // Poll resource usage for Claude Code process
        let (res_snapshot, proc_health) = if let Some(pid) = run.claude_pid {
            let snap = resource::snapshot(&self.sys, pid);
            let health = resource::check_health(&self.sys, pid);
            (snap, health)
        } else {
            (None, ProcessHealth::NotFound)
        };

        if let Some(status) = monitor::poll_arc_status(&monitor_handle) {
            // Surface schema version warning once (first poll only)
            if run.last_status.is_none() {
                if let Some(ref warning) = status.schema_warning {
                    self.status_message = Some(format!("⚠ {}", warning));
                }
            }

            // Check for completion — start grace period
            if status.completion.is_some() && run.merge_detected_at.is_none() {
                run.merge_detected_at = Some(Instant::now());
            }

            // Combined stale detection: heartbeat staleness OR low-cpu process health
            let is_stale = status.is_stale || proc_health == ProcessHealth::LowCpu;

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
                schema_warning: status.schema_warning,
                resource: res_snapshot,
                process_health: proc_health,
            });
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

    /// Grace period after merge detection before starting next plan.
    /// Configurable via GRACE_PERIOD_SECS env var (default: 240s = 4 min).
    fn grace_period_secs() -> u64 {
        std::env::var("GRACE_PERIOD_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(240)
    }

    /// Check if grace period has elapsed after merge detection.
    fn check_grace_period(&mut self, now: Instant) {
        let grace_duration = Duration::from_secs(Self::grace_period_secs());

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

                let _ = pr_url; // consumed by ArcCompletion variant
                self.completed_runs.push(CompletedRun {
                    plan: run.plan,
                    result,
                    duration: run.launched_at.elapsed(),
                });
            }
        }
    }

    /// Send /arc command with retry logic. Returns Some(()) on success, None on failure.
    /// Uses exponential backoff between retries (5s, then 10s).
    fn send_arc_with_retry(session_id: &str, plan_path: &Path, max_attempts: u8) -> Option<()> {
        let mut delay_secs = 5;

        for attempt in 1..=max_attempts {
            match Tmux::send_arc_command(session_id, plan_path) {
                Ok(()) => return Some(()),
                Err(e) if attempt < max_attempts => {
                    eprintln!("send /arc attempt {} failed: {}, retrying in {}s", attempt, e, delay_secs);
                    std::thread::sleep(Duration::from_secs(delay_secs));
                    delay_secs *= 2; // exponential backoff: 5s -> 10s
                }
                Err(e) => {
                    eprintln!("send /arc failed after {} attempts: {}", max_attempts, e);
                    return None;
                }
            }
        }
        None
    }
}
