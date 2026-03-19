use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::Utc;
use color_eyre::eyre::eyre;
use color_eyre::Result;

use ratatui::widgets::ListState;

use crate::monitor::{self, ActivityDetector, ActivityState};
use crate::resource::{self, ProcessHealth, ResourceSnapshot};
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
    pub selected_plans: Vec<QueueEntry>, // ordered plan+config pairs
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

    // Stateful list states for scrollable rendering (ratatui ListState)
    pub active_arcs_list_state: ListState,
    pub config_list_state: ListState,
    pub plan_list_state: ListState,
    pub queue_list_state: ListState,

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

    // Claude Code version string (detected at startup)
    pub claude_version: String,

    // Phase timeout configuration (session-scoped, loaded from env once)
    pub phase_timeout_config: PhaseTimeoutConfig,
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
    pub config_idx: usize,   // config dir this plan was launched with
    pub tmux_session: String,
    pub launched_at: Instant,
    pub arc: Option<ArcHandle>,
    pub last_status: Option<ArcStatus>,
    pub merge_detected_at: Option<Instant>,
    pub tmux_pane_pid: Option<u32>,  // Shell PID inside tmux pane
    pub claude_pid: Option<u32>,     // Claude Code process PID (= owner_pid in checkpoint)
    pub loop_state: Option<monitor::ArcLoopState>, // From arc-phase-loop.local.md
    pub session_info: Option<crate::scanner::SessionInfo>, // Enriched session info
    // Phase timeout tracking (multi-tick state machine, like merge_detected_at)
    pub current_phase_started: Option<Instant>,  // Reset on phase change
    pub current_phase_name: Option<String>,       // Last known phase for change detection
    pub timeout_triggered_at: Option<Instant>,    // When SIGTERM was sent (grace period start)
    /// Activity detector for multi-signal idle/stop detection (F3).
    pub activity_detector: ActivityDetector,
    /// Adaptive grace duration computed once when merge is detected (F4).
    pub grace_duration: Option<Duration>,
    /// Fixed skip deadline — set once when 's' is pressed during grace (F4).
    /// Stored as absolute Instant to avoid the recomputation bug (RUIN-007).
    pub grace_skip_at: Option<Instant>,
    /// Resume state for auto-retry after phase timeout (F5).
    pub resume_state: Option<ResumeState>,
    /// Cooldown deadline — earliest time a restart is allowed.
    pub restart_cooldown_until: Option<Instant>,
}

impl RunState {
    /// Best-effort arc_id from either the arc handle or last polled status.
    fn arc_id(&self) -> Option<String> {
        self.arc
            .as_ref()
            .map(|a| a.arc_id.clone())
            .or_else(|| self.last_status.as_ref().map(|s| s.arc_id.clone()))
    }

    /// Arc duration from the checkpoint's started_at (real arc time),
    /// falling back to torrent's launched_at (includes wait/init overhead).
    fn arc_duration(&self) -> Duration {
        if let Some(handle) = &self.arc {
            if let Ok(contents) = std::fs::read_to_string(&handle.checkpoint_path) {
                if let Ok(cp) = serde_json::from_str::<serde_json::Value>(&contents) {
                    if let Some(started) = cp.get("started_at").and_then(|v| v.as_str()) {
                        if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(started) {
                            let elapsed = Utc::now().signed_duration_since(dt.with_timezone(&Utc));
                            if let Ok(std_dur) = elapsed.to_std() {
                                return std_dur;
                            }
                        }
                    }
                }
            }
        }
        self.launched_at.elapsed()
    }
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
    pub completion: Option<monitor::ArcCompletion>,
    pub schema_warning: Option<String>,
    // Resource monitoring
    pub resource: Option<ResourceSnapshot>,
    pub process_health: ProcessHealth,
    /// Activity state from multi-signal detection (None if detector not initialized).
    pub activity_state: Option<ActivityState>,
}

#[derive(Clone)]
pub struct PhaseSummary {
    pub completed: u32,
    pub total: u32,
    pub skipped: u32,
    pub current_phase_name: String,
}

/// Map a phase name to a timeout category.
/// Categories group phases with similar expected durations.
fn phase_category(name: &str) -> &str {
    match name {
        "forge" => "forge",
        "work" | "task_decomposition" | "design_extraction" | "design_prototype"
        | "design_iteration" => "work",
        "test" | "test_coverage_critique" => "test",
        "ship" | "merge" | "pre_ship_validation" | "release_quality_check"
        | "deploy_verify" | "bot_review_wait" | "pr_comment_resolution" => "ship",
        _ => "review",
    }
}

/// Per-phase timeout configuration loaded from TORRENT_TIMEOUT_* env vars.
/// Falls back to `default_timeout` for phases whose category has no override.
///
/// Env vars: TORRENT_TIMEOUT_FORGE, TORRENT_TIMEOUT_WORK, TORRENT_TIMEOUT_TEST,
/// TORRENT_TIMEOUT_REVIEW, TORRENT_TIMEOUT_SHIP (values in minutes).
/// TORRENT_TIMEOUT_DEFAULT overrides the global default (60 min).
pub struct PhaseTimeoutConfig {
    timeouts: HashMap<String, Duration>,
    default_timeout: Duration,
}

impl PhaseTimeoutConfig {
    /// Parse timeout config from environment variables.
    /// Each TORRENT_TIMEOUT_<CATEGORY> is an integer in minutes.
    pub fn from_env() -> Self {
        let default_mins: u64 = std::env::var("TORRENT_TIMEOUT_DEFAULT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(60);

        let mut timeouts = HashMap::new();
        for category in &["forge", "work", "test", "review", "ship"] {
            let env_key = format!("TORRENT_TIMEOUT_{}", category.to_uppercase());
            if let Some(mins) = std::env::var(&env_key).ok().and_then(|s| s.parse::<u64>().ok()) {
                timeouts.insert(category.to_string(), Duration::from_secs(mins * 60));
            }
        }

        Self {
            timeouts,
            default_timeout: Duration::from_secs(default_mins * 60),
        }
    }

    /// Get the timeout duration for a given phase name.
    /// Looks up the phase's category, then checks for a configured override.
    pub fn timeout_for(&self, phase: &str) -> Duration {
        let cat = phase_category(phase);
        self.timeouts
            .get(cat)
            .copied()
            .unwrap_or(self.default_timeout)
    }

    /// Apply CLI overrides on top of env-based config.
    /// Each override is (phase_category, minutes).
    pub fn apply_overrides(&mut self, overrides: &[(String, u64)]) {
        for (phase, mins) in overrides {
            let clamped = (*mins).max(1);
            self.timeouts
                .insert(phase.to_lowercase(), Duration::from_secs(clamped * 60));
        }
    }

    /// Returns true if all timeouts are at their defaults (no env overrides).
    /// Used to skip timeout checking entirely when unconfigured.
    #[allow(dead_code)] // used by UI layer and tests
    pub fn is_default(&self) -> bool {
        self.timeouts.is_empty()
            && self.default_timeout == Duration::from_secs(60 * 60)
    }
}

/// Result of a completed arc run.
pub struct CompletedRun {
    pub plan: PlanFile,
    pub result: ArcCompletion,
    pub duration: Duration,
    pub arc_id: Option<String>,
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
    SkipGrace,
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
            queue: VecDeque::new(),
            current_run: None,
            completed_runs: Vec::new(),
            tmux_session_id: None,
            config_cursor: 0,
            plan_cursor: 0,
            queue_cursor: 0,
            active_arcs_list_state: ListState::default(),
            config_list_state: ListState::default(),
            plan_list_state: ListState::default(),
            queue_list_state: ListState::default(),
            last_discovery_poll: None,
            last_heartbeat_poll: None,
            last_checkpoint_poll: None,
            last_loop_state_poll: None,
            last_active_arcs_prune: None,
            launched_wall_clock: None,
            status_message: initial_status,
            claude_path: crate::tmux::Tmux::resolve_claude_path()
                .unwrap_or_else(|_| "claude".to_string()),
            sys,
            git_branch: Self::read_git_branch(),
            all_done_at: None,
            queue_editing: false,
            should_quit: false,
            claude_version: Self::detect_claude_version(),
            phase_timeout_config: PhaseTimeoutConfig::from_env(),
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
        self.queue = self.selected_plans.drain(..).collect();
    }

    /// Print a summary to stdout after terminal is restored.
    pub fn print_quit_summary(&self) {
        let completed = self.completed_runs.len();
        let total = self.queue_total_items();

        if total == 0 && completed == 0 {
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
            Action::SkipGrace => {
                if let Some(ref mut run) = self.current_run {
                    if run.merge_detected_at.is_some() && run.grace_skip_at.is_none() {
                        // Set fixed skip deadline: 5 seconds from now (RUIN-007 fix).
                        // Stored as absolute Instant — not recomputed each tick.
                        run.grace_skip_at = Instant::now().checked_add(Duration::from_secs(5));
                        self.status_message = Some(" Grace skip in 5s…".into());
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
                    let old_queue_len = self.queue.len();
                    for entry in &self.queue {
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
                    self.queue = remapped_queue;

                    // Remap current_run plan (for is_plan_in_flight matching)
                    if let Some(ref mut run) = self.current_run {
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
                        self.status_message = Some(parts.join(", "));
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
                    self.queue.push_back(entry);
                }
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
            date: None,
        };

        self.tmux_session_id = arc.tmux_session.clone();
        let session_info = arc.session_info;
        let loop_state = arc.loop_state;
        self.current_run = Some(RunState {
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
            activity_detector: ActivityDetector::new(),
            grace_duration: None,
            grace_skip_at: None,
            resume_state: None, // monitoring existing arc — no resume tracking
            restart_cooldown_until: None,
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
            let arc_id = run.arc_id();
            let duration = run.arc_duration();
            self.completed_runs.push(CompletedRun {
                plan: run.plan,
                result: ArcCompletion::Cancelled {
                    reason: Some("skipped by user".into()),
                },
                duration,
                arc_id,
            });
            self.tmux_session_id = None;
            // Clamp cursor after item count changed
            let total = self.queue_total_items();
            if total > 0 && self.queue_cursor >= total {
                self.queue_cursor = total - 1;
            }
        }
    }

    /// Kill the current tmux session and stop all execution.
    fn kill_current_session(&mut self) {
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
            });
        }
        self.tmux_session_id = None;
        self.queue.clear();
        self.queue_cursor = 0;
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

        // Check restart cooldown (auto-resume after phase timeout)
        self.check_restart_cooldown();

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

        // Step 0: Clean stale arc state from previous run.
        // arc-phase-loop.local.md belongs to CWD (not per-arc) — if the previous
        // arc's cleanup didn't remove it, poll_discovery would match the wrong arc.
        let cwd = std::env::current_dir().unwrap_or_default();
        let stale_loop = cwd.join(".rune").join("arc-phase-loop.local.md");
        if stale_loop.exists() {
            let _ = std::fs::remove_file(&stale_loop);
        }
        // Also clean up pre-migration legacy state file
        let legacy_loop = cwd.join(".claude").join("arc-phase-loop.local.md");
        if legacy_loop.exists() {
            let _ = std::fs::remove_file(&legacy_loop);
        }

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
            self.status_message = Some("git pull failed — retrying...".into());
            self.queue.push_front(QueueEntry {
                plan_idx,
                config_idx: self.selected_config,
            });
            return Ok(());
        }

        // Step 2: Record wall-clock time BEFORE launch (for discovery matching)
        self.launched_wall_clock = Some(Utc::now());

        // Step 3: Create tmux session (empty shell) in the current working directory.
        // The -c flag ensures Claude Code inherits the correct CWD for session isolation.
        let session_id = Tmux::generate_session_id();
        let cwd = std::env::current_dir().unwrap_or_default();
        if let Err(e) = Tmux::create_session(&session_id, &cwd) {
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

        let resume_state = ResumeState::load(&plan.path.display().to_string());
        self.current_run = Some(RunState {
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
                    &config.path.to_string_lossy(),
                    &self.sys,
                )
            }),
            current_phase_started: None,
            current_phase_name: None,
            timeout_triggered_at: None,
            activity_detector: ActivityDetector::new(),
            grace_duration: None,
            grace_skip_at: None,
            resume_state: Some(resume_state),
            restart_cooldown_until: None,
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
        // Use run's config_idx (not selected_config) to avoid drift from queue-edit
        let run_config_idx = self.current_run.as_ref().map(|r| r.config_idx);
        let config_dir_str = run_config_idx
            .and_then(|idx| self.config_dirs.get(idx))
            .map(|c| c.path.to_string_lossy().to_string());
        let expected_config_dir = config_dir_str.as_deref();

        let (plan_path, expected_claude_pid, has_loop_state) = {
            let run = match &self.current_run {
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
                self.status_message = Some("Arc loop state detected, discovering checkpoint...".into());
            }
            if let Some(run) = &mut self.current_run {
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
            let activity_state = if run.activity_detector.should_check() {
                let pane_hash = Tmux::capture_pane_hash(&run.tmux_session, 30);
                let last_line = Tmux::capture_last_line(&run.tmux_session);
                run.activity_detector.update_hash(pane_hash);
                let cpu = res_snapshot.as_ref().map(|s| s.cpu_percent);
                let process_found = proc_health != ProcessHealth::NotFound;
                Some(run.activity_detector.detect(
                    status.is_stale,
                    cpu,
                    process_found,
                    last_line.as_deref(),
                ))
            } else {
                // Between pane checks, reuse last known activity state
                run.last_status.as_ref().and_then(|s| s.activity_state)
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

    /// Check if the current phase has exceeded its timeout.
    /// Uses a multi-tick state machine (like merge_detected_at):
    /// 1. Phase exceeds timeout → send SIGTERM via libc::kill, set timeout_triggered_at
    /// 2. 15s grace after SIGTERM → hard kill via Tmux::kill_session
    ///
    /// IMPORTANT: Completion check (merge_detected_at) is done BEFORE this,
    /// so a phase that just completed won't be killed.
    fn check_phase_timeout(&mut self) {
        let run = match &mut self.current_run {
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

        let timeout = self.phase_timeout_config.timeout_for(&phase_name);
        if started.elapsed() < timeout {
            return; // Not timed out yet
        }

        // Timeout exceeded — send SIGTERM to Claude Code process
        let pid_to_kill = run.claude_pid;
        run.timeout_triggered_at = Some(Instant::now());

        if let Some(pid) = pid_to_kill {
            // SAFETY: libc::kill sends a signal to a process. We use SIGTERM (graceful).
            let ret = unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
            if ret != 0 {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::ESRCH) {
                    // Process already gone — skip 15s grace, go straight to tmux kill
                    self.status_message = Some(format!(
                        "Phase timeout: PID {} already exited, killing tmux (phase: {})",
                        pid, phase_name,
                    ));
                    if let Some(run) = &self.current_run {
                        let _ = Tmux::kill_session(&run.tmux_session);
                    }
                } else if err.raw_os_error() == Some(libc::EPERM) {
                    self.status_message = Some(format!(
                        "Phase timeout: SIGTERM to PID {} denied (EPERM) (phase: {}, limit: {}m)",
                        pid, phase_name, timeout.as_secs() / 60,
                    ));
                } else {
                    self.status_message = Some(format!(
                        "Phase timeout: SIGTERM to PID {} failed: {} (phase: {})",
                        pid, err, phase_name,
                    ));
                }
            } else {
                self.status_message = Some(format!(
                    "Phase timeout: SIGTERM sent to PID {} (phase: {}, limit: {}m)",
                    pid, phase_name, timeout.as_secs() / 60,
                ));
            }
        } else {
            // No PID available — fall back to tmux kill directly
            self.status_message = Some(format!(
                "Phase timeout: no PID, killing tmux (phase: {}, limit: {}m)",
                phase_name,
                timeout.as_secs() / 60,
            ));
            if let Some(ref run) = self.current_run {
                let _ = Tmux::kill_session(&run.tmux_session);
            }
        }
    }

    /// Handle auto-resume after a phase timeout kill.
    /// Called after the hard-kill path in check_phase_timeout().
    fn handle_timeout_resume(&mut self) {
        // Get config from env
        let max_resumes = env_or_u64("TORRENT_MAX_RESUMES", 3) as u32;
        let cooldown_secs = env_or_u64("TORRENT_RESTART_COOLDOWN", 30);

        let run = match &mut self.current_run {
            Some(r) => r,
            None => return,
        };

        let resume_state = match &mut run.resume_state {
            Some(s) => s,
            None => return,
        };

        // Determine phase index from current phase name
        let phase_name = run.current_phase_name.clone().unwrap_or_default();
        // Use a simple incrementing index based on total_restarts as fallback
        let phase_index = resume_state.phase_retries.len() as u32;

        // Check if we should skip this plan
        if resume_state.should_skip(phase_index, max_resumes) {
            self.status_message = Some(format!(
                "Phase {} stuck {} times — skipping plan",
                phase_name, max_resumes
            ));
            // Save state, then cleanup and move to next plan
            let _ = resume_state.save();
            self.cleanup_skipped_plan();
            return;
        }

        // Record the restart
        resume_state.record_restart(phase_index, &phase_name, "phase_timeout");

        // Rapid failure detection (AC8): if 3+ restarts within 5 minutes, warn
        if resume_state.is_rapid_failure() {
            self.status_message = Some(format!(
                "RAPID FAILURE: {} retries in <5 min on phase {} — possible systemic issue",
                resume_state.total_restarts, phase_name
            ));
        }

        let _ = resume_state.save();

        // Set cooldown
        run.restart_cooldown_until = Some(Instant::now() + Duration::from_secs(cooldown_secs));

        self.status_message = Some(format!(
            "Phase timeout on {} — restarting in {}s (attempt {}/{})",
            phase_name, cooldown_secs,
            resume_state.phase_retries.get(&phase_index).copied().unwrap_or(0),
            max_resumes
        ));
    }

    /// Check if a restart cooldown has expired and execute the restart.
    fn check_restart_cooldown(&mut self) {
        let should_restart = self.current_run.as_ref()
            .and_then(|r| r.restart_cooldown_until)
            .map_or(false, |deadline| Instant::now() >= deadline);

        if !should_restart { return; }

        let run = self.current_run.as_ref().unwrap();
        let plan_path = run.plan.path.clone();
        let config_idx = run.config_idx;
        let config = match self.config_dirs.get(config_idx) {
            Some(c) => c.clone(),
            None => return,
        };
        let old_session = run.tmux_session.clone();
        let cwd = std::env::current_dir().unwrap_or_default();

        // Recreate tmux session
        match crate::tmux::Tmux::recreate_session(
            &old_session, &cwd, &config.path, &self.claude_path
        ) {
            Ok(new_session_id) => {
                // Send /arc --resume
                if let Err(e) = crate::tmux::Tmux::send_arc_resume_command(&new_session_id, &plan_path) {
                    self.status_message = Some(format!("Failed to send /arc --resume: {}", e));
                    return;
                }
                // Update run state with new session
                if let Some(run) = &mut self.current_run {
                    run.tmux_session = new_session_id.clone();
                    run.restart_cooldown_until = None;
                    run.timeout_triggered_at = None;
                    run.current_phase_started = None;
                    run.launched_at = Instant::now();
                    run.arc = None; // Will be re-discovered
                    run.last_status = None;
                }
                self.tmux_session_id = Some(new_session_id);
                self.last_discovery_poll = None; // Force re-discovery
                self.status_message = Some("Auto-resumed with /arc --resume".into());
            }
            Err(e) => {
                self.status_message = Some(format!("Restart failed: {} — skipping plan", e));
                self.cleanup_skipped_plan();
            }
        }
    }

    /// Clean up a plan that has been skipped (exhausted retries or restart failure).
    fn cleanup_skipped_plan(&mut self) {
        if let Some(run) = self.current_run.take() {
            let _ = crate::tmux::Tmux::kill_session(&run.tmux_session);
            // Clean orphaned arc state
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
            self.completed_runs.push(CompletedRun {
                plan: run.plan,
                result: ArcCompletion::Failed {
                    reason: format!("skipped: phase {} exceeded retry budget", phase),
                },
                duration,
                arc_id,
            });
        }
        self.tmux_session_id = None;
        let total = self.queue_total_items();
        if total > 0 && self.queue_cursor >= total {
            self.queue_cursor = total - 1;
        }
    }

    /// Compute adaptive grace duration from runtime metrics (F4).
    /// Formula: base + (child_count * 2) + (cpu_percent * 0.5), clamped to [min, max].
    /// Configurable via TORRENT_GRACE_BASE, TORRENT_GRACE_MIN, TORRENT_GRACE_MAX env vars.
    /// Falls back to GRACE_PERIOD_SECS for backward compatibility if new vars are not set.
    fn compute_grace_duration(&self) -> Duration {
        // Backward compatibility: if GRACE_PERIOD_SECS is set and new vars are not,
        // use it as max_grace to ease migration.
        let legacy_secs: Option<u64> = std::env::var("GRACE_PERIOD_SECS")
            .ok()
            .and_then(|s| s.parse().ok());
        let has_new_vars = std::env::var("TORRENT_GRACE_BASE").is_ok()
            || std::env::var("TORRENT_GRACE_MIN").is_ok()
            || std::env::var("TORRENT_GRACE_MAX").is_ok();

        if legacy_secs.is_some() && !has_new_vars {
            // Legacy mode: use fixed duration from GRACE_PERIOD_SECS
            return Duration::from_secs(legacy_secs.unwrap());
        }

        let base = env_or_u64("TORRENT_GRACE_BASE", 30);
        let min = env_or_u64("TORRENT_GRACE_MIN", 10);
        let max = env_or_u64("TORRENT_GRACE_MAX", 120);

        let child_count = self.current_run
            .as_ref()
            .and_then(|r| r.last_status.as_ref())
            .and_then(|s| s.resource.as_ref())
            .map(|r| r.child_count as u64)
            .unwrap_or(0);

        let cpu = self.current_run
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
    /// On first call: computes adaptive duration and stores it.
    /// On skip request: reduces remaining time to minimum 5 seconds.
    fn check_grace_period(&mut self, now: Instant) {
        // Compute and cache grace duration on first call after merge detection
        let grace_duration = if let Some(ref run) = self.current_run {
            if run.merge_detected_at.is_some() && run.grace_duration.is_none() {
                let computed = self.compute_grace_duration();
                if let Some(ref mut run) = self.current_run {
                    run.grace_duration = Some(computed);
                }
                computed
            } else {
                run.grace_duration.unwrap_or_else(|| Duration::from_secs(30))
            }
        } else {
            return;
        };

        // Handle skip: check if fixed skip deadline has passed (RUIN-007 fix).
        // grace_skip_at is an absolute Instant set once — no recomputation drift.
        let skip_triggered = self.current_run
            .as_ref()
            .and_then(|r| r.grace_skip_at)
            .map(|deadline| now >= deadline)
            .unwrap_or(false);

        let should_complete = skip_triggered || self
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

                // Determine completion type from last polled status.
                // Map monitor::ArcCompletion → app::ArcCompletion to preserve
                // the actual result (Shipped, Failed, Cancelled) instead of
                // always defaulting to Merged.
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
                // Extract phase data and config dir before consuming `run`
                let (phases_completed, phases_total, phases_skipped) =
                    run.last_status.as_ref()
                        .map(|s| (s.phase_summary.completed, s.phase_summary.total, s.phase_summary.skipped))
                        .unwrap_or((0, 0, 0));
                let config_dir = self.config_dirs.get(run.config_idx)
                    .map(|c| c.path.display().to_string())
                    .unwrap_or_else(|| "~/.claude".to_string());

                let arc_id = run.arc_id();
                let duration = run.arc_duration();
                let completed = CompletedRun {
                    plan: run.plan,
                    result,
                    duration,
                    arc_id,
                };

                // Log the completed run to structured JSONL
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
                    restarts: vec![],
                };
                if let Err(e) = crate::log::append_run_log(&entry) {
                    eprintln!("warning: failed to write run log: {}", e);
                }

                self.completed_runs.push(completed);

                // Clamp queue cursor after item count changed
                let total = self.queue_total_items();
                if total > 0 && self.queue_cursor >= total {
                    self.queue_cursor = total - 1;
                }
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn test_phase_category_defaults_to_review() {
        // Unknown phases fall back to "review" category
        assert_eq!(phase_category("code_review"), "review");
        assert_eq!(phase_category("gap_analysis"), "review");
        assert_eq!(phase_category("unknown_phase_xyz"), "review");
        assert_eq!(phase_category(""), "review");
    }

    #[test]
    fn test_phase_timeout_config_defaults() {
        // No env vars set — all lookups should return the default 60 minutes
        let config = PhaseTimeoutConfig {
            timeouts: HashMap::new(),
            default_timeout: Duration::from_secs(60 * 60),
        };
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
        let default_config = PhaseTimeoutConfig {
            timeouts: HashMap::new(),
            default_timeout: Duration::from_secs(60 * 60),
        };
        assert!(default_config.is_default());

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
    fn test_phase_timeout_config_from_env() {
        // Use unique env var names to avoid thread-safety issues with parallel tests.
        // We test from_env() by setting one var, calling from_env, then cleaning up.
        // Note: this test reads TORRENT_TIMEOUT_* which won't conflict with other tests.
        unsafe {
            std::env::set_var("TORRENT_TIMEOUT_WORK", "120");
            std::env::set_var("TORRENT_TIMEOUT_DEFAULT", "45");
        }

        let config = PhaseTimeoutConfig::from_env();

        // Work category should be 120 minutes
        assert_eq!(config.timeout_for("work"), Duration::from_secs(120 * 60));
        // Default should be 45 minutes
        assert_eq!(config.default_timeout, Duration::from_secs(45 * 60));
        // Unconfigured category uses the custom default
        assert_eq!(config.timeout_for("forge"), Duration::from_secs(45 * 60));

        // Cleanup
        unsafe {
            std::env::remove_var("TORRENT_TIMEOUT_WORK");
            std::env::remove_var("TORRENT_TIMEOUT_DEFAULT");
        }
    }

    #[test]
    fn test_phase_timeout_config_from_env_invalid() {
        // Invalid env var values should be ignored (fallback to default)
        unsafe {
            std::env::set_var("TORRENT_TIMEOUT_TEST", "not_a_number");
            std::env::remove_var("TORRENT_TIMEOUT_DEFAULT"); // ensure clean state
        }

        let config = PhaseTimeoutConfig::from_env();

        // Invalid value ignored — test category uses default (60 min)
        assert_eq!(config.timeout_for("test"), Duration::from_secs(60 * 60));
        assert_eq!(config.default_timeout, Duration::from_secs(60 * 60));

        // Cleanup
        unsafe {
            std::env::remove_var("TORRENT_TIMEOUT_TEST");
        }
    }
}
