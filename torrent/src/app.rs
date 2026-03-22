use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::Utc;
use color_eyre::eyre::eyre;
use color_eyre::Result;

/// Maximum messages displayed in Bridge View TUI.
const BRIDGE_MSG_DISPLAY_CAP: usize = 26;

/// A message displayed in the Bridge View.
#[derive(Debug, Clone)]
pub struct BridgeMessage {
    /// Display text (truncated to 500 chars).
    pub text: String,
    /// When the message was received/sent (wall clock for display).
    pub timestamp: chrono::NaiveTime,
    /// Message direction and type.
    pub kind: BridgeMessageKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeMessageKind {
    /// Outbound: user sent a message to Claude
    Sent,
    /// Outbound: message delivery failed (all transports exhausted)
    SendFailed,
    /// Inbound: phase transition event
    Phase,
    /// Inbound: arc completion event
    Complete,
    /// Inbound: heartbeat from Claude
    Heartbeat,
    /// Inbound: text reply from Claude
    Reply,
}

use ratatui::widgets::ListState;

use crate::callback::{CallbackServer, ChannelEvent};
use crate::channel::{ChannelState, ChannelsConfig};
use crate::diagnostic::{DiagnosticAction, DiagnosticEngine, DiagnosticResult, DiagnosticState};
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
fn truncate_str(s: &str, max: usize) -> &str {
    if s.len() <= max {
        s
    } else {
        let mut end = max;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }
}

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

    // Inter-plan cooldown — delay before launching next plan after merge/ship
    // Configurable via TORRENT_INTER_PLAN_COOLDOWN env var (default: 300s = 5 min)
    pub inter_plan_cooldown_until: Option<Instant>,

    // Queue editing mode — Selection view appends to queue instead of starting fresh
    pub queue_editing: bool,

    // Whether we should quit
    pub should_quit: bool,

    // Claude Code version string (detected at startup)
    pub claude_version: String,

    // Phase timeout configuration (session-scoped, loaded from env once)
    pub phase_timeout_config: PhaseTimeoutConfig,

    // Diagnostic engine for session health monitoring
    pub diagnostic_engine: DiagnosticEngine,
    pub last_diagnostic_poll: Option<Instant>,
    /// Current diagnostic result for UI banner display.
    pub last_diagnostic: Option<DiagnosticResult>,

    // Channel communication (optional, experimental)
    /// Whether channels mode is enabled (--channels flag or config).
    pub channels_enabled: bool,
    /// Callback port for receiving channel events from bridge.
    pub callback_port: u16,
    /// Callback HTTP server instance (started when channels_enabled).
    pub callback_server: Option<CallbackServer>,
    /// Last time we polled the channel for events.
    pub last_channel_poll: Option<Instant>,

    // Message input mode (send messages to Claude via bridge inbox)
    /// Whether the message input bar is active.
    pub message_input_active: bool,
    /// Current message text being typed.
    pub message_input_buf: String,
    /// Last message delivery transport (for UI display).
    pub last_msg_transport: Option<MsgTransport>,
    /// Last message received from Claude Code via channel events (trimmed to 200 chars).
    pub last_claude_msg: Option<String>,

    // Bridge View state
    /// Ring buffer of bridge messages for Bridge View (capacity BRIDGE_MSG_DISPLAY_CAP).
    pub bridge_messages: VecDeque<BridgeMessage>,
    /// File handle for append-only message persistence (opened once per session).
    pub bridge_log_file: Option<std::fs::File>,
    /// Scroll offset for Bridge View message list (0 = auto-scroll to bottom).
    /// Incremented by Up, decremented by Down, reset to 0 on new message or SubmitMessage.
    pub bridge_scroll_offset: usize,
}

/// Message delivery transport used for the last sent message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // Bridge/Inbox reserved for when Claude Code supports inbound MCP messages
pub enum MsgTransport {
    /// HTTP POST to bridge → MCP notification → Claude
    Bridge,
    /// File queue → check_inbox tool → Claude
    Inbox,
    /// tmux send-keys → keyboard injection → Claude
    Tmux,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppView {
    /// Active arcs detected at startup — resume or dismiss.
    ActiveArcs,
    /// Normal selection view — pick config + plans.
    Selection,
    /// Running view — monitoring current arc execution.
    Running,
    /// Bridge view — full-screen chat with the bridge (channels mode).
    Bridge,
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
    /// Channel state for optional outbound communication (Claude → Torrent).
    /// None when channels are disabled or failed to initialize.
    pub channel_state: Option<ChannelState>,
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
    /// Recovery mode determined by handle_timeout_resume() BEFORE session recreation.
    /// Consumed by check_restart_cooldown() Phase 2 AFTER run.arc is reset to None.
    pub recovery_mode: Option<crate::resume::RecoveryMode>,
    /// Set to true after Phase 1 (session recreation) completes in check_restart_cooldown().
    /// Used as discriminant for Phase 1 vs Phase 2 — replaces the flawed `run.arc.is_some()`
    /// check which doesn't work for Retry mode (where arc is always None).
    pub session_recreated: bool,
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
        // Forge: plan enrichment
        "forge" => "forge",

        // Work: implementation + design
        "work" | "task_decomposition" | "design_extraction" | "design_prototype"
        | "design_iteration" => "work",

        // QA gates: lightweight verification
        "forge_qa" | "work_qa" | "gap_analysis_qa" | "code_review_qa"
        | "mend_qa" | "test_qa" => "qa",

        // Analysis: medium-weight analysis
        "gap_analysis" | "codex_gap_analysis" | "goldmask_verification"
        | "goldmask_correlation" | "semantic_verification" | "gap_remediation"
        | "plan_refine" | "verification" | "drift_review" => "analysis",

        // Test
        "test" | "test_coverage_critique" => "test",

        // Ship: merge + deploy
        "ship" | "merge" | "pre_ship_validation" | "release_quality_check"
        | "deploy_verify" | "bot_review_wait" | "pr_comment_resolution" => "ship",

        // Review: code review + inspection + design verification
        "plan_review" | "code_review" | "inspect" | "inspect_fix"
        | "verify_inspect" | "mend" | "verify_mend"
        | "storybook_verification" | "design_verification" | "ux_verification" => "review",

        // Fallback
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
    /// Categories always get explicit defaults instead of falling through
    /// to TORRENT_TIMEOUT_DEFAULT.
    pub fn from_env() -> Self {
        let default_mins: u64 = std::env::var("TORRENT_TIMEOUT_DEFAULT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(60);

        let mut timeouts = HashMap::new();
        let categories: &[(&str, &str, u64)] = &[
            ("forge",    "TORRENT_TIMEOUT_FORGE",    30),  // 30 min
            ("work",     "TORRENT_TIMEOUT_WORK",     45),  // 45 min
            ("qa",       "TORRENT_TIMEOUT_QA",       15),  // 15 min
            ("analysis", "TORRENT_TIMEOUT_ANALYSIS", 20),  // 20 min
            ("test",     "TORRENT_TIMEOUT_TEST",     30),  // 30 min
            ("review",   "TORRENT_TIMEOUT_REVIEW",   30),  // 30 min
            ("ship",     "TORRENT_TIMEOUT_SHIP",     20),  // 20 min
        ];

        for &(cat, env_key, default) in categories {
            let mins: u64 = std::env::var(env_key)
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(default);
            timeouts.insert(cat.to_string(), Duration::from_secs(mins * 60));
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
        if self.default_timeout != Duration::from_secs(60 * 60) {
            return false;
        }
        let category_defaults: &[(&str, u64)] = &[
            ("forge", 30), ("work", 45), ("qa", 15),
            ("analysis", 20), ("test", 30), ("review", 30), ("ship", 20),
        ];
        self.timeouts.len() == category_defaults.len()
            && category_defaults.iter().all(|&(cat, mins)| {
                self.timeouts.get(cat) == Some(&Duration::from_secs(mins * 60))
            })
    }
}

/// Result of a completed arc run.
pub struct CompletedRun {
    pub plan: PlanFile,
    pub result: ArcCompletion,
    pub duration: Duration,
    pub arc_id: Option<String>,
    /// Restart events collected during this run (for F2 structured logging).
    pub resume_restarts: Option<Vec<crate::log::RestartEvent>>,
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
    // Message input mode
    OpenMessageInput,   // Open message input bar
    SubmitMessage,      // Send message to Claude via bridge inbox
    CancelMessageInput, // Cancel message input
    MessageChar(char),  // Append character to message buffer
    MessageBackspace,   // Delete last character from buffer
    // Channels mode
    HealthCheck,        // Check bridge health (channels only)
    OpenBridge,         // Open Bridge View (channels only)
    CloseBridge,        // Return to Running View from Bridge View
    BridgeScrollUp,     // Scroll up in Bridge View message list
    BridgeScrollDown,   // Scroll down in Bridge View message list
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
            status_message_set_at: None,
            claude_path: crate::tmux::Tmux::resolve_claude_path()
                .unwrap_or_else(|_| "claude".to_string()),
            sys,
            git_branch: Self::read_git_branch(),
            all_done_at: None,
            inter_plan_cooldown_until: None,
            queue_editing: false,
            should_quit: false,
            claude_version: Self::detect_claude_version(),
            phase_timeout_config: PhaseTimeoutConfig::from_env(),
            diagnostic_engine: DiagnosticEngine::new(),
            last_diagnostic_poll: None,
            last_diagnostic: None,
            channels_enabled: false,
            callback_port: 9900,
            callback_server: None,
            last_channel_poll: None,
            message_input_active: false,
            message_input_buf: String::new(),
            last_msg_transport: None,
            last_claude_msg: None,
            bridge_messages: VecDeque::with_capacity(BRIDGE_MSG_DISPLAY_CAP),
            bridge_log_file: None,
            bridge_scroll_offset: 0,
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
                // Skip inter-plan cooldown if active
                if self.inter_plan_cooldown_until.is_some() {
                    self.inter_plan_cooldown_until = None;
                    self.set_status(" Cooldown skipped — launching next plan");
                } else if let Some(ref mut run) = self.current_run {
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
                    self.queue.push_back(entry);
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
                if self.tmux_session_id.is_some() {
                    self.message_input_active = true;
                    self.message_input_buf.clear();
                } else {
                    self.set_status("No active session to send to");
                }
            }
            Action::SubmitMessage => {
                if !self.message_input_buf.trim().is_empty() {
                    let msg = self.message_input_buf.clone();
                    self.message_input_active = false;
                    self.bridge_scroll_offset = 0; // snap to bottom on send
                    self.message_input_buf.clear();
                    self.send_message_to_claude(&msg);
                }
            }
            Action::CancelMessageInput => {
                self.message_input_active = false;
                self.message_input_buf.clear();
            }
            Action::MessageChar(c) => {
                // Cap input at 2000 characters to prevent oversized HTTP bodies.
                // Uses char count (not byte length) for consistent behavior with
                // multi-byte Unicode input (e.g. Vietnamese, CJK).
                if self.message_input_buf.chars().count() < 2000 {
                    self.message_input_buf.push(c);
                }
            }
            Action::MessageBackspace => {
                self.message_input_buf.pop();
            }
            Action::HealthCheck => {
                if !self.channels_enabled {
                    self.set_status("Health check requires --channels mode");
                } else if self.current_run.is_some() {
                    // Try init if channel_state is None
                    if let Some(run) = &mut self.current_run {
                        if run.channel_state.is_none() {
                            run.channel_state = ChannelState::try_init(&run.tmux_session);
                        }
                    }
                    // Perform health check and build status message
                    let status_msg = if let Some(run) = &mut self.current_run {
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
                if self.channels_enabled && self.tmux_session_id.is_some() {
                    self.view = AppView::Bridge;
                    self.message_input_buf.clear();
                } else if self.channels_enabled {
                    self.set_status("No active session — start an arc first");
                }
            }
            Action::CloseBridge => {
                self.view = AppView::Running;
                self.message_input_active = false;
                self.bridge_scroll_offset = 0;
            }
            Action::BridgeScrollUp => {
                let max_offset = self.bridge_messages.len().saturating_sub(1);
                if self.bridge_scroll_offset < max_offset {
                    self.bridge_scroll_offset += 1;
                }
            }
            Action::BridgeScrollDown => {
                if self.bridge_scroll_offset > 0 {
                    self.bridge_scroll_offset -= 1;
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
        let completed_count = self.completed_runs.len();
        let current_count = if self.current_run.is_some() { 1 } else { 0 };
        let non_removable = completed_count + current_count;

        if self.queue_cursor < non_removable {
            // Cursor is on a completed run or current — not removable
            self.set_status("Cannot remove completed or running items");
            return;
        }

        let queue_idx = self.queue_cursor - non_removable;
        if queue_idx < self.queue.len() {
            let removed = self.queue.remove(queue_idx);
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
                resume_restarts: None,
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
            // Inter-plan cooldown gate — wait before launching next plan
            if let Some(deadline) = self.inter_plan_cooldown_until {
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
                self.inter_plan_cooldown_until = None;
            }

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
        let has_arc = match self.current_run.as_ref() {
            Some(run) => run.arc.is_some(),
            None => return Ok(()),
        };

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

            // Bootstrap diagnostic check (every 30s during discovery)
            let should_diag = self
                .last_diagnostic_poll
                .map(|t| now.duration_since(t) >= Duration::from_secs(30))
                .unwrap_or(true);
            if should_diag {
                self.poll_diagnostic_bootstrap();
                self.last_diagnostic_poll = Some(now);
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

            // Channel event processing (non-blocking, every 2s when enabled)
            if self.channels_enabled {
                let should_poll_channel = self
                    .last_channel_poll
                    .map(|t| now.duration_since(t) >= Duration::from_secs(2))
                    .unwrap_or(true);

                if should_poll_channel {
                    self.drain_channel_events();
                    self.last_channel_poll = Some(now);
                }
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

            // Runtime diagnostic check (every 30s during execution)
            let should_diag = self
                .last_diagnostic_poll
                .map(|t| now.duration_since(t) >= Duration::from_secs(30))
                .unwrap_or(true);
            if should_diag {
                self.poll_diagnostic_runtime();
                self.last_diagnostic_poll = Some(now);
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
                self.set_status(
                    "arc-phase-loop.local.md active: false — arc cancelled",
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

        // Step 0.5: Pre-arc diagnostic check — verify session health before launch.
        // If there's an existing tmux session we can probe, check for blocking errors
        // (billing, auth) before spending time creating a new session.
        if let Some(ref sid) = self.tmux_session_id {
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
        // Use .output() to CAPTURE stdout/stderr — .status() leaks into TUI display
        let checkout = Command::new("git")
            .args(["checkout", "main"])
            .output();
        if checkout.as_ref().map_or(true, |o| !o.status.success()) {
            self.set_status("git checkout main failed — clean up working tree");
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
            self.set_status("git pull failed — retrying...");
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
            self.set_status(format!("tmux failed: {e}"));
            return Ok(());
        }
        self.tmux_session_id = Some(session_id.clone());

        // Step 4: Build channels config (if enabled) and start Claude Code
        let channels_cfg = if self.channels_enabled {
            Some(ChannelsConfig {
                bridge_port: self.callback_port.checked_add(1).unwrap_or(self.callback_port.saturating_sub(1)), // SEC-012: prevent u16 overflow
                callback_port: self.callback_port,
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

        // Step 6: Send /arc command — check for existing checkpoint first
        let resume_state = ResumeState::load(&plan.path.display().to_string());
        let has_checkpoint = self.check_existing_checkpoint(&plan);

        // Resolve bridge port for channels-first dispatch
        let bridge_port = if self.channels_enabled {
            self.current_run.as_ref()
                .and_then(|r| r.channel_state.as_ref())
                .and_then(|cs| cs.bridge_port)
        } else {
            None
        };

        if has_checkpoint && resume_state.total_restarts == 0 {
            // First launch but checkpoint exists from a previous torrent session — resume
            if Self::send_arc_prefer_bridge(&session_id, &plan.path, 3, bridge_port, true).is_none() {
                self.set_status(format!("FAILED: send /arc --resume failed. tmux attach -t {}", &session_id));
            } else {
                let transport = if bridge_port.is_some() { "bridge" } else { "tmux" };
                self.set_status(format!("Resuming existing checkpoint [{}]", transport));
            }
        } else if Self::send_arc_prefer_bridge(&session_id, &plan.path, 2, bridge_port, false).is_none() {
            self.set_status(format!("FAILED: send /arc failed. tmux attach -t {}", &session_id));
        } else {
            let transport = if bridge_port.is_some() { "bridge" } else { "tmux" };
            self.set_status(format!("/arc sent to {} [{}]", &session_id, transport));
        }
        // Reset bridge log file for new session (so it opens a fresh file for this session_id)
        self.bridge_log_file = None;

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
            text: format!("── new session: {} ──", self.tmux_session_id.as_deref().unwrap_or("unknown")),
            timestamp: chrono::Local::now().time(),
            kind: BridgeMessageKind::Phase,
        });

        // Start callback server if channels are enabled
        if self.channels_enabled && self.callback_server.is_none() {
            match CallbackServer::start(self.callback_port) {
                Ok(server) => {
                    self.callback_server = Some(server);
                    // Initialize channel state now that callback server is running
                    if let Some(run) = &mut self.current_run {
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
        self.last_discovery_poll = None;
        self.last_heartbeat_poll = None;
        self.last_checkpoint_poll = None;
        self.last_channel_poll = None;

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
                self.set_status("Arc loop state detected, discovering checkpoint...");
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
    /// Send a message to the Claude Code session.
    ///
    /// When channels are active and bridge is reachable, uses HTTP POST to
    /// bridge /msg endpoint (Channels API). Falls back to tmux send-keys
    /// when bridge is unreachable or channels are disabled.
    fn send_message_to_claude(&mut self, msg: &str) {
        if self.channels_enabled {
            self.send_via_bridge_http(msg);
        } else {
            self.send_via_tmux(msg);
        }

        // Push to bridge messages for Bridge View display.
        // Show as Sent regardless of transport outcome — the status bar
        // already shows transport-level errors (e.g. "send failed: ...").
        // Use a distinct kind if delivery definitively failed.
        let delivery_failed = self.last_msg_transport.is_none()
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
        let bridge_port = self.current_run.as_ref()
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
                    self.last_msg_transport = Some(MsgTransport::Inbox);
                    self.set_status(format!("✉ [inbox] {}", truncate_str(msg, 50)));
                } else {
                    self.last_msg_transport = Some(MsgTransport::Bridge);
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
        let session_id = self.tmux_session_id.as_deref().unwrap_or("default");
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
                self.last_msg_transport = Some(MsgTransport::Inbox);
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
        let session_id = match &self.tmux_session_id {
            Some(id) => id.clone(),
            None => {
                self.set_status("no active session");
                return;
            }
        };
        let prefixed = format!("[torrent:tmux] {msg}");
        match Tmux::send_keys(&session_id, &prefixed) {
            Ok(_) => {
                self.last_msg_transport = Some(MsgTransport::Tmux);
                self.set_status(format!("✉ [tmux] {}", truncate_str(msg, 50)));
            }
            Err(e) => {
                self.set_status(format!("send failed: {e}"));
            }
        }
    }

    /// Open (or create) the JSONL log file for this session.
    /// Called once when the first bridge message arrives.
    fn open_bridge_log(session_id: &str) -> Option<std::fs::File> {
        // SEC-006: Validate session_id format before path construction
        if session_id.is_empty()
            || session_id.len() > 64
            || !session_id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return None;
        }
        let dir = std::path::PathBuf::from(".torrent/sessions").join(session_id);
        std::fs::create_dir_all(&dir).ok()?;
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("messages.jsonl"))
            .ok()
    }

    /// Append a message to the JSONL log file (fire-and-forget).
    fn persist_bridge_message(file: &mut std::fs::File, msg: &BridgeMessage) {
        use std::io::Write;
        let kind_str = match msg.kind {
            BridgeMessageKind::Sent => "sent",
            BridgeMessageKind::SendFailed => "send_failed",
            BridgeMessageKind::Phase => "phase",
            BridgeMessageKind::Complete => "complete",
            BridgeMessageKind::Heartbeat => "heartbeat",
            BridgeMessageKind::Reply => "reply",
        };
        // Escape text for JSON safety (backslashes, quotes, and control characters).
        let escaped = msg.text.replace('\\', "\\\\").replace('"', "\\\"")
            .replace('\n', "\\n").replace('\r', "\\r").replace('\t', "\\t");
        let line = format!(
            r#"{{"ts":"{}","kind":"{}","text":"{}"}}"#,
            chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%.3f"),
            kind_str,
            escaped,
        );
        let _ = writeln!(file, "{}", line);
    }

    /// Push a message to the display ring buffer and persist to file.
    fn push_bridge_message(&mut self, msg: BridgeMessage) {
        // Lazy-open the log file on first message
        if self.bridge_log_file.is_none() {
            if let Some(session_id) = &self.tmux_session_id {
                self.bridge_log_file = Self::open_bridge_log(session_id);
            }
        }
        // Persist to file (all messages, including filtered heartbeats)
        if let Some(ref mut file) = self.bridge_log_file {
            Self::persist_bridge_message(file, &msg);
        }
        // Display filter: skip consecutive heartbeats (replace last one)
        if msg.kind == BridgeMessageKind::Heartbeat {
            if self.bridge_messages.back().map(|m| m.kind) == Some(BridgeMessageKind::Heartbeat) {
                self.bridge_messages.pop_back();
            }
        }
        // Push to display ring buffer
        if self.bridge_messages.len() >= BRIDGE_MSG_DISPLAY_CAP {
            self.bridge_messages.pop_front();
        }
        self.bridge_messages.push_back(msg);
        // Auto-scroll to bottom on new message (unless user scrolled up)
        if self.bridge_scroll_offset == 0 {
            // Already at bottom — no action needed
        }
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
        let server = match self.callback_server.as_ref() {
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
            .current_run
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
            if let Some(run) = &mut self.current_run {
                if run.channel_state.is_none() {
                    run.channel_state = ChannelState::try_init(&run.tmux_session);
                }
            }

            // Update channel health on successful event
            if let Some(run) = &mut self.current_run {
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
                    self.last_claude_msg = Some(truncate_str(&msg, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&msg, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Phase,
                    });
                    if let Some(run) = &mut self.current_run {
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
                    self.last_claude_msg = Some(truncate_str(&msg, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&msg, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Complete,
                    });
                    if let Some(run) = &mut self.current_run {
                        run.activity_detector.hash_unchanged_count = 0;
                    }
                }
                ChannelEvent::Heartbeat { activity, current_tool, .. } => {
                    let msg = if current_tool.is_empty() {
                        format!("Claude: {}", activity)
                    } else {
                        format!("Claude: {} (using {})", activity, current_tool)
                    };
                    self.last_claude_msg = Some(truncate_str(&msg, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&msg, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Heartbeat,
                    });
                    if let Some(run) = &mut self.current_run {
                        if activity == "active" {
                            run.activity_detector.hash_unchanged_count = 0;
                        }
                    }
                }
                ChannelEvent::Reply { text, .. } => {
                    self.set_status(format!("[reply] {}", truncate_str(&text, 80)));
                    self.last_claude_msg = Some(truncate_str(&text, 200).to_string());
                    self.push_bridge_message(BridgeMessage {
                        text: truncate_str(&text, 500).to_string(),
                        timestamp: chrono::Local::now().time(),
                        kind: BridgeMessageKind::Reply,
                    });
                    if let Some(run) = &mut self.current_run {
                        run.activity_detector.hash_unchanged_count = 0;
                    }
                }
            }
        }
    }

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

    /// Run bootstrap diagnostic check during discovery phase.
    /// Detects early failures (plan not found, plugin missing, auth errors)
    /// before the arc checkpoint is even created.
    fn poll_diagnostic_bootstrap(&mut self) {
        let (session_id, pane_pid) = match self.extract_session_pane() {
            Some(v) => v,
            None => return,
        };
        // Compute elapsed time since launch for checkpoint timeout detection (D6)
        let elapsed = self.current_run.as_ref()
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
            let plan_idx = self.current_run.as_ref()
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
            let plan_idx = self.current_run.as_ref()
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
        let run = self.current_run.as_ref()?;
        let session_id = self.tmux_session_id.as_ref()?;
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
                self.queue.clear();
                if let Some(run) = self.current_run.take() {
                    let _ = Tmux::kill_session(&run.tmux_session);
                    let arc_id = run.arc_id();
                    let duration = run.arc_duration();
                    self.completed_runs.push(CompletedRun {
                        plan: run.plan,
                        result: ArcCompletion::Failed {
                            reason: format!("diagnostic: {}", diag.state.label()),
                        },
                        duration,
                        arc_id,
                        resume_restarts: None,
                    });
                }
                self.tmux_session_id = None;
                true
            }

            DiagnosticAction::SkipPlan => {
                self.set_status(format!(
                    "DIAGNOSTIC: {} — skipping plan", diag.state.label()
                ));
                if let Some(run) = self.current_run.take() {
                    let _ = Tmux::kill_session(&run.tmux_session);
                    let arc_id = run.arc_id();
                    let duration = run.arc_duration();
                    self.completed_runs.push(CompletedRun {
                        plan: run.plan,
                        result: ArcCompletion::Cancelled {
                            reason: Some(format!("diagnostic: {}", diag.state.label())),
                        },
                        duration,
                        arc_id,
                        resume_restarts: None,
                    });
                }
                self.tmux_session_id = None;
                true
            }

            DiagnosticAction::KillAndCooldown | DiagnosticAction::KillAndRetryAuth => {
                if let Some(strategy) = diag.action.retry_strategy() {
                    let plan_name = self.current_run.as_ref()
                        .map(|r| r.plan.path.display().to_string())
                        .unwrap_or_default();
                    let mut resume = self.current_run.as_ref()
                        .and_then(|r| r.resume_state.clone())
                        .unwrap_or_else(|| ResumeState::load(&plan_name));

                    let max = strategy.max_retries();
                    if resume.total_restarts >= max {
                        self.set_status(format!(
                            "DIAGNOSTIC: {} — max retries exceeded, skipping",
                            diag.state.label()
                        ));
                        if let Some(run) = self.current_run.take() {
                            let _ = Tmux::kill_session(&run.tmux_session);
                            let arc_id = run.arc_id();
                            let duration = run.arc_duration();
                            self.completed_runs.push(CompletedRun {
                                plan: run.plan,
                                result: ArcCompletion::Failed {
                                    reason: format!("diagnostic: {} retries exhausted", diag.state.label()),
                                },
                                duration,
                                arc_id,
                                resume_restarts: None,
                            });
                        }
                        self.tmux_session_id = None;
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

                    if let Some(ref sid) = self.tmux_session_id {
                        let _ = Tmux::kill_session(sid);
                    }

                    if let Some(run) = &mut self.current_run {
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
                if let Some(run) = self.current_run.take() {
                    let _ = Tmux::kill_session(&run.tmux_session);
                    // Re-queue the plan for retry
                    self.queue.push_front(QueueEntry {
                        plan_idx,
                        config_idx: run.config_idx,
                    });
                }
                self.tmux_session_id = None;
                true
            }

            DiagnosticAction::Retry3xThenSkip => {
                let plan_name = self.current_run.as_ref()
                    .map(|r| r.plan.path.display().to_string())
                    .unwrap_or_default();
                let mut resume = self.current_run.as_ref()
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
                    if let Some(run) = self.current_run.take() {
                        let _ = Tmux::kill_session(&run.tmux_session);
                        let arc_id = run.arc_id();
                        let duration = run.arc_duration();
                        self.completed_runs.push(CompletedRun {
                            plan: run.plan,
                            result: ArcCompletion::Failed {
                                reason: format!("diagnostic: {} retries exhausted", diag.state.label()),
                            },
                            duration,
                            arc_id,
                            resume_restarts: None,
                        });
                    }
                    self.tmux_session_id = None;
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

                if let Some(ref sid) = self.tmux_session_id {
                    let _ = Tmux::kill_session(sid);
                }

                if let Some(run) = &mut self.current_run {
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
                    self.set_status(format!(
                        "Phase timeout: PID {} already exited, killing tmux (phase: {})",
                        pid, phase_name,
                    ));
                    if let Some(run) = &self.current_run {
                        let _ = Tmux::kill_session(&run.tmux_session);
                    }
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
            // No PID available — fall back to tmux kill directly
            self.set_status(format!(
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
    ///
    /// Determines recovery mode (Retry vs Resume vs Evaluate) BEFORE session
    /// recreation resets `run.arc` and `run.last_status` to None.
    fn handle_timeout_resume(&mut self) {
        use crate::resume::RecoveryMode;

        let max_resumes = env_or_u64("TORRENT_MAX_RESUMES", 3) as u32;

        // Determine recovery mode BEFORE taking mutable borrow on resume_state.
        // This reads run.arc and run.last_status immutably.
        let mode = match &self.current_run {
            Some(run) => Self::determine_recovery_mode(run),
            None => return,
        };

        let run = match &mut self.current_run {
            Some(r) => r,
            None => return,
        };

        // Store mode on RunState so check_restart_cooldown Phase 2 can use it
        // after run.arc and run.last_status have been reset to None.
        run.recovery_mode = Some(mode);
        run.session_recreated = false; // Reset for new restart cycle

        let resume_state = match &mut run.resume_state {
            Some(s) => s,
            None => return,
        };

        match mode {
            RecoveryMode::Evaluate => {
                // Arc is done — don't count as a restart
                self.status_message = Some("Arc completed during timeout — evaluating".into());
                self.status_message_set_at = Some(Instant::now());
                if let Some(run) = &mut self.current_run {
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
                // P1-001 FIX: Use a deterministic hash of the phase name so the same phase
                // always maps to the same index.
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
            env_or_u64("TORRENT_RESTART_COOLDOWN", 60) // default increased from 30 to 60
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
    fn determine_recovery_mode(run: &RunState) -> crate::resume::RecoveryMode {
        use crate::resume::RecoveryMode;

        if let Some(ref status) = run.last_status {
            if status.completion.is_some() {
                return RecoveryMode::Evaluate; // Arc finished, just record result
            }
            return RecoveryMode::Resume; // Arc was tracked, has phase progress
        }
        if run.arc.is_some() {
            return RecoveryMode::Resume; // Arc discovered, checkpoint exists
        }
        RecoveryMode::Retry // Arc never started or wasn't discovered
    }

    /// Check if a restart cooldown has expired and execute the restart.
    ///
    /// Two-phase non-blocking state machine (PERF-001 FIX):
    /// Phase 1: Cooldown expires → create new tmux session, set init_wait deadline (12s)
    /// Phase 2: Init wait expires → send /arc --resume command
    /// This avoids blocking the tick loop with thread::sleep.
    fn check_restart_cooldown(&mut self) {
        // FLAW-005 FIX: Use guard clause instead of fragile unwrap
        let run = match &self.current_run {
            Some(r) => r,
            None => return,
        };

        let cooldown_deadline = match run.restart_cooldown_until {
            Some(d) => d,
            None => return,
        };

        let now = Instant::now();
        if now < cooldown_deadline {
            // Show countdown in status (single `now` capture avoids TOCTOU panic
            // where Instant::duration_since underflows between two Instant::now() calls)
            let remaining = cooldown_deadline.duration_since(now).as_secs();
            if remaining > 0 {
                self.set_status(format!(
                    "Restarting in {}s...", remaining
                ));
            }
            return;
        }

        // Cooldown expired — check if session already recreated (phase 2: send command)
        // FLAW-001 FIX: Use `session_recreated` flag instead of `run.arc.is_some()`.
        // The old check failed for Retry mode (arc is always None → infinite Phase 1 loop).
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
                &old_session, &cwd, &config.path, &self.claude_path, None // resume safety: #36638
            ) {
                Ok(new_session_id) => {
                    // Set init wait: 12s for Claude Code startup
                    if let Some(run) = &mut self.current_run {
                        run.tmux_session = new_session_id.clone();
                        run.restart_cooldown_until = Some(Instant::now() + Duration::from_secs(12));
                        run.timeout_triggered_at = None;
                        run.current_phase_started = None;
                        run.launched_at = Instant::now();
                        run.arc = None;
                        run.last_status = None;
                        run.session_recreated = true; // FLAW-001 FIX: mark Phase 1 done
                    }
                    self.tmux_session_id = Some(new_session_id);
                    self.last_discovery_poll = None;
                    self.set_status("Session recreated — waiting for Claude Code init...");
                }
                Err(e) => {
                    self.set_status(format!("Restart failed: {} — skipping plan", e));
                    self.cleanup_skipped_plan();
                }
            }
        } else {
            // Phase 2: Init wait expired — send appropriate command based on recovery mode
            let mode = run.recovery_mode.unwrap_or(crate::resume::RecoveryMode::Retry);
            let session = run.tmux_session.clone();

            // Resolve bridge port for channels-first dispatch
            let bp = if self.channels_enabled {
                self.current_run.as_ref()
                    .and_then(|r| r.channel_state.as_ref())
                    .and_then(|cs| cs.bridge_port)
            } else {
                None
            };

            match mode {
                crate::resume::RecoveryMode::Retry => {
                    // Fresh start — no checkpoint, arc never ran
                    if Self::send_arc_prefer_bridge(&session, &plan_path, 3, bp, false).is_none() {
                        self.set_status("Failed to send /arc (retry)");
                    } else {
                        self.set_status("Retrying with fresh /arc");
                    }
                }
                crate::resume::RecoveryMode::Resume => {
                    // Mid-arc crash — checkpoint exists, resume from last phase
                    if Self::send_arc_prefer_bridge(&session, &plan_path, 3, bp, true).is_none() {
                        self.set_status("Failed to send /arc --resume");
                    } else {
                        self.set_status("Resuming with /arc --resume");
                    }
                }
                crate::resume::RecoveryMode::Evaluate => {
                    // Arc completed but session died before torrent detected it
                    self.set_status("Arc completed — evaluating result");
                    if let Some(run) = &mut self.current_run {
                        run.merge_detected_at = Some(Instant::now());
                    }
                }
            }
            // Clear cooldown — command sent (or evaluate triggered)
            if let Some(run) = &mut self.current_run {
                run.restart_cooldown_until = None;
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
                resume_restarts: None,
            });
        }
        self.tmux_session_id = None;
        let total = self.queue_total_items();
        if total > 0 && self.queue_cursor >= total {
            self.queue_cursor = total - 1;
        }
    }

    /// Check if a resumable checkpoint exists for this plan.
    /// Looks for arc-phase-loop.local.md and verifies the plan matches.
    fn check_existing_checkpoint(&self, plan: &PlanFile) -> bool {
        let cwd = std::env::current_dir().unwrap_or_default();
        match monitor::read_arc_loop_state(&cwd) {
            Some(state) => {
                // FLAW-003 FIX: Use filename-based matching (plans_match) instead of
                // bidirectional contains() which false-positives on substrings and empty strings.
                let plan_str = plan.path.display().to_string();
                plans_match(&plan_str, &state.plan_file)
            }
            None => false,
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

        if let Some(secs) = legacy_secs {
            if !has_new_vars {
                // Legacy mode: use fixed duration from GRACE_PERIOD_SECS
                return Duration::from_secs(secs);
            }
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
                // P1-003 FIX: Collect restart events from ResumeState for F2 logging.
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
                    // P1-003 FIX: Populate restarts from ResumeState instead of always empty.
                    // AC6 requires all restart events in the structured JSONL log.
                    restarts: completed.resume_restarts.clone().unwrap_or_default(),
                };
                if let Err(e) = crate::log::append_run_log(&entry) {
                    tlog!(WARN, "failed to write run log: {}", e);
                }

                // Set inter-plan cooldown if merge/ship succeeded and more plans queued
                let was_success = matches!(
                    &completed.result,
                    ArcCompletion::Merged { .. } | ArcCompletion::Shipped { .. }
                );
                self.completed_runs.push(completed);

                if was_success && !self.queue.is_empty() {
                    let cooldown_secs = env_or_u64("TORRENT_INTER_PLAN_COOLDOWN", 300);
                    if cooldown_secs > 0 {
                        self.inter_plan_cooldown_until =
                            Some(Instant::now() + Duration::from_secs(cooldown_secs));
                    }
                }

                // Clamp queue cursor after item count changed
                let total = self.queue_total_items();
                if total > 0 && self.queue_cursor >= total {
                    self.queue_cursor = total - 1;
                }
            }
        }
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
    fn send_arc_prefer_bridge(session_id: &str, plan_path: &Path, max_attempts: u8, bridge_port: Option<u16>, resume: bool) -> Option<()> {
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
    // self.current_run which is hard to construct. Instead, test the math.

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
            App::persist_bridge_message(&mut file, &msg);
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
        assert!(App::open_bridge_log("").is_none(), "empty session_id");
        assert!(App::open_bridge_log("../../../etc/passwd").is_none(), "path traversal");
        assert!(App::open_bridge_log(&"a".repeat(65)).is_none(), "too long");
        assert!(App::open_bridge_log("valid-session_123").is_some(), "valid session_id");

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
