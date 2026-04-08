//! Shared type definitions for the Torrent TUI.
//!
//! This module centralizes types used across multiple modules (app, ui, keybindings, monitor).
//!
//! ## Canonical vs Intentionally Separate Types
//!
//! **Canonical** (single source of truth — previously duplicated in `app.rs` and `monitor.rs`):
//! - [`ArcHandle`] — links checkpoint + heartbeat paths for a discovered arc instance
//! - [`PhaseSummary`] — phase progress derived from checkpoint.json
//!
//! **Intentionally separate** (app vs monitor versions serve different purposes):
//! - [`ArcStatus`] (here) vs `monitor::ArcStatus` — this version is a presentation-layer
//!   enrichment with resource snapshots, process health, and pre-formatted activity strings.
//!   Monitor's version has raw `Option<DateTime<Utc>>` for `last_activity`.
//! - [`ArcCompletion`] (here) vs `monitor::ArcCompletion` — this version has rich data
//!   variants with `pr_url` and `reason` fields. Monitor's has unit variants used as
//!   parse sentinels.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::channel::ChannelState;
use crate::monitor::{self, ActivityDetector, ActivityState, PhaseNavigation};
use crate::resource::{ProcessHealth, ResourceSnapshot};
use crate::resume::ResumeState;
use crate::scanner::PlanFile;

// ── Bridge View Types ─────────────────────────────────────────

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

// ── Message Transport ─────────────────────────────────────────

/// Message delivery transport used for the last sent message.
///
/// All 3 variants form a live 3-tier fallback chain:
/// Bridge HTTP → Inbox file → Tmux send-keys.
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

// ── View & Navigation Types ───────────────────────────────────

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

// ── Arc Execution Types ───────────────────────────────────────

/// Handle to a discovered arc checkpoint + heartbeat pair.
///
/// This is the **canonical** definition — previously duplicated in `app.rs` and `monitor.rs`.
/// Both modules now import from here.
#[derive(Debug, Clone)]
pub struct ArcHandle {
    pub arc_id: String,
    pub checkpoint_path: PathBuf,
    pub heartbeat_path: PathBuf,
    pub plan_file: String,
    pub config_dir: String,
    pub owner_pid: String,
    pub session_id: String,  // Claude Code session UUID from checkpoint
}

/// Summary of phase progress derived from checkpoint.json.
///
/// This is the **canonical** definition — previously duplicated in `app.rs` and `monitor.rs`.
#[derive(Debug, Clone)]
pub struct PhaseSummary {
    pub completed: u32,
    pub total: u32,
    pub skipped: u32,
    pub current_phase_name: String,
}

/// Polled status of a running arc (presentation-layer enrichment).
///
/// **Intentionally different** from `monitor::ArcStatus`:
/// - `last_activity` is a pre-formatted `String` (monitor uses `Option<DateTime<Utc>>`)
/// - Includes `resource` and `process_health` fields from sysinfo polling
#[derive(Clone)]
#[allow(dead_code)] // schema_warning stored for UI display
pub struct ArcStatus {
    pub arc_id: String,
    pub current_phase: String,
    pub last_tool: String,
    pub last_activity: String,
    pub phase_summary: PhaseSummary,
    pub phase_nav: Option<PhaseNavigation>,
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
    pub fn arc_id(&self) -> Option<String> {
        self.arc
            .as_ref()
            .map(|a| a.arc_id.clone())
            .or_else(|| self.last_status.as_ref().map(|s| s.arc_id.clone()))
    }

    /// Arc duration from the checkpoint's started_at (real arc time),
    /// falling back to torrent's launched_at (includes wait/init overhead).
    pub fn arc_duration(&self) -> Duration {
        if let Some(handle) = &self.arc {
            if let Ok(contents) = std::fs::read_to_string(&handle.checkpoint_path) {
                if let Ok(cp) = serde_json::from_str::<serde_json::Value>(&contents) {
                    if let Some(started) = cp.get("started_at").and_then(|v| v.as_str()) {
                        if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(started) {
                            let elapsed = chrono::Utc::now().signed_duration_since(dt.with_timezone(&chrono::Utc));
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

// ── Completion Types ──────────────────────────────────────────

/// Result of a completed arc run.
pub struct CompletedRun {
    pub plan: PlanFile,
    pub result: ArcCompletion,
    pub duration: Duration,
    pub arc_id: Option<String>,
    /// Restart events collected during this run (for F2 structured logging).
    pub resume_restarts: Option<Vec<crate::log::RestartEvent>>,
}

/// Completion status with rich data (pr_url, reason).
///
/// **Intentionally different** from `monitor::ArcCompletion` which has unit variants
/// used as parse sentinels. This version carries the data extracted during grace period.
#[derive(Debug, Clone)]
#[allow(dead_code)] // all variants needed for completeness
pub enum ArcCompletion {
    Merged { pr_url: Option<String> },
    Shipped { pr_url: Option<String> },
    Cancelled { reason: Option<String> },
    Failed { reason: String },
}

// ── Phase Timeout Configuration ───────────────────────────────

/// Map a phase name to a timeout category.
/// Categories group phases with similar expected durations.
pub(crate) fn phase_category(name: &str) -> &str {
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
    pub(crate) timeouts: HashMap<String, Duration>,
    pub(crate) default_timeout: Duration,
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

// ── Actions ───────────────────────────────────────────────────

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
