//! Diagnostic detection engine for torrent.
//!
//! Analyzes tmux pane output and process state to classify Claude Code session
//! health into actionable diagnostic states. Uses simple string matching (no regex)
//! to detect error patterns, with priority-ordered evaluation ensuring the most
//! critical issues are surfaced first.
//!
//! Pattern matching uses `to_lowercase().contains()` against `&[&str]` slices,
//! matching the existing codebase convention (see `monitor.rs` PROMPT_INDICATORS).

use std::time::{Duration, Instant};

use crate::resume::RetryStrategy;
use crate::tmux::Tmux;

// ── Severity ────────────────────────────────────────────────

/// Severity level for diagnostic findings.
///
/// Determines UI treatment (color, icon) and whether the batch should halt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    /// Batch must stop immediately (e.g., billing failure).
    Critical,
    /// Plan should be skipped or retried with backoff (e.g., auth error).
    High,
    /// Degraded but recoverable (e.g., rate limit, overload).
    Medium,
    /// Informational — no action needed (e.g., waiting for input).
    Low,
}

impl Severity {
    /// Short label for logging.
    #[allow(dead_code)]
    pub fn label(&self) -> &'static str {
        match self {
            Severity::Critical => "critical",
            Severity::High => "high",
            Severity::Medium => "medium",
            Severity::Low => "low",
        }
    }
}

// ── DiagnosticState ─────────────────────────────────────────

/// Classified state of a Claude Code session, derived from pane output
/// and process inspection.
///
/// Variants are ordered by detection priority: billing errors are checked
/// before auth errors, which are checked before rate limits, etc. This
/// ensures the most actionable diagnosis is returned when multiple error
/// patterns co-occur in the pane output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiagnosticState {
    // ── Process-level (D1-D10) ──
    /// Session is running normally — no error patterns detected.
    Healthy,
    /// Claude Code process not found in tmux pane (exited or not started).
    NoClaude,
    /// Authentication required — login prompt or expired token.
    #[allow(dead_code)]
    AuthRequired,
    /// Plan file not found — path error or missing file.
    PlanNotFound,
    /// Required plugin not installed or not enabled.
    PluginMissing,
    /// Permission blocked — Claude waiting for user approval.
    PermissionBlocked,
    /// Checkpoint timeout — arc phase exceeded its time budget.
    CheckpointTimeout,
    /// Claude Code process crashed (process disappeared after grace period).
    /// D7: Detection is PROCESS-BASED ONLY — pane text patterns are logging-only.
    ClaudeCrashed,
    /// Waiting for user input (shell prompt, y/n confirmation).
    #[allow(dead_code)]
    InputWaiting,
    /// Unclassified error — pane contains error indicators but no specific match.
    #[allow(dead_code)]
    Unknown,

    // ── API error states (D17-D24) ──
    /// D17: Billing/payment failure — terminal, stops entire batch.
    BillingFailure,
    /// D18: API server error (500-class) — retry with escalating backoff.
    ApiServerError,
    /// D19: API overloaded (529) — retry with long backoff.
    ApiOverloaded,
    /// D20: Authentication/token error from API — retry then skip.
    ApiAuthError,
    /// D21: Rate limited (429) — respect retry-after header.
    RateLimited,
    /// D22: Request too large (413) — skip plan, won't fit.
    RequestTooLarge,
    /// D23: Bad gateway / service unavailable (502/503) — transient, retry.
    ServiceUnavailable,
    /// D24: Network/connection error — retry with backoff.
    NetworkError,
}

impl DiagnosticState {
    /// Short label for logging and JSONL output.
    pub fn label(&self) -> &'static str {
        match self {
            Self::Healthy => "healthy",
            Self::NoClaude => "no_claude",
            Self::AuthRequired => "auth_required",
            Self::PlanNotFound => "plan_not_found",
            Self::PluginMissing => "plugin_missing",
            Self::PermissionBlocked => "permission_blocked",
            Self::CheckpointTimeout => "checkpoint_timeout",
            Self::ClaudeCrashed => "claude_crashed",
            Self::InputWaiting => "input_waiting",
            Self::Unknown => "unknown",
            Self::BillingFailure => "billing_failure",
            Self::ApiServerError => "api_server_error",
            Self::ApiOverloaded => "api_overloaded",
            Self::ApiAuthError => "api_auth_error",
            Self::RateLimited => "rate_limited",
            Self::RequestTooLarge => "request_too_large",
            Self::ServiceUnavailable => "service_unavailable",
            Self::NetworkError => "network_error",
        }
    }

    /// Human-readable banner message for the TUI.
    ///
    /// Returns `None` for `Healthy` (no banner shown when everything is fine).
    pub fn display_message(&self) -> Option<&'static str> {
        match self {
            Self::Healthy => None,
            Self::NoClaude => Some("CLAUDE NOT FOUND — waiting for process"),
            Self::AuthRequired => Some("AUTH REQUIRED — batch stopped. Please login to Claude Code"),
            Self::PlanNotFound => Some("PLAN NOT FOUND — skipping plan"),
            Self::PluginMissing => Some("PLUGIN MISSING — batch stopped. Install rune plugin"),
            Self::PermissionBlocked => Some("PERMISSION BLOCKED — Claude waiting for approval"),
            Self::CheckpointTimeout => Some("CHECKPOINT TIMEOUT — phase exceeded time budget"),
            Self::ClaudeCrashed => Some("CLAUDE CRASHED — retrying session"),
            Self::InputWaiting => Some("INPUT WAITING — Claude waiting for user input"),
            Self::Unknown => Some("UNKNOWN ERROR — unclassified issue detected"),
            Self::BillingFailure => Some("BILLING FAILURE — batch stopped. Check payment"),
            Self::ApiServerError => Some("API SERVER ERROR (500) — retrying with backoff"),
            Self::ApiOverloaded => Some("API OVERLOADED (529) — cooling down"),
            Self::ApiAuthError => Some("API AUTH ERROR — retrying authentication"),
            Self::RateLimited => Some("RATE LIMITED (429) — waiting for retry window"),
            Self::RequestTooLarge => Some("REQUEST TOO LARGE (413) — skipping plan"),
            Self::ServiceUnavailable => Some("SERVICE UNAVAILABLE (502/503) — retrying"),
            Self::NetworkError => Some("NETWORK ERROR — retrying with backoff"),
        }
    }

    /// Severity of this diagnostic state.
    pub fn severity(&self) -> Severity {
        match self {
            Self::Healthy | Self::InputWaiting => Severity::Low,
            Self::NoClaude | Self::Unknown => Severity::Medium,
            Self::RateLimited | Self::ApiOverloaded | Self::ServiceUnavailable
            | Self::NetworkError | Self::ApiServerError => Severity::Medium,
            Self::AuthRequired | Self::ApiAuthError | Self::PermissionBlocked
            | Self::CheckpointTimeout | Self::ClaudeCrashed
            | Self::PlanNotFound | Self::PluginMissing | Self::RequestTooLarge => Severity::High,
            Self::BillingFailure => Severity::Critical,
        }
    }
}

// ── DiagnosticAction ────────────────────────────────────────

/// Prescribed action for the watchdog to take in response to a diagnostic.
///
/// Each variant maps to an existing `RetryStrategy` in `resume.rs` where
/// applicable, ensuring retry tracking is unified.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiagnosticAction {
    /// No intervention needed — session is healthy.
    Continue,
    /// Stop the entire batch (billing failure). Maps to `RetryStrategy::BillingError`.
    StopBatch,
    /// Skip this plan immediately. Maps to `RetryStrategy::SkipImmediate`.
    SkipPlan,
    /// Kill session + retry with API overload backoff. Maps to `RetryStrategy::ApiOverload`.
    KillAndCooldown,
    /// Kill session + retry with auth backoff. Maps to `RetryStrategy::TokenAuth`.
    KillAndRetryAuth,
    /// Kill session + retry (generic). Maps to `RetryStrategy::PhaseTimeout`.
    RetrySession,
    /// Retry up to 3 times, then skip plan. Maps to `RetryStrategy::RateLimit`.
    Retry3xThenSkip,
    /// Wait for a timeout before re-checking.
    #[allow(dead_code)]
    WaitTimeout,
    /// Allow grace period for process restart (e.g., self-update). 60s grace.
    GracePeriod,
}

impl DiagnosticAction {
    /// Map this action to the corresponding `RetryStrategy` for backoff tracking.
    ///
    /// Returns `None` for actions that don't involve retry (Continue, WaitTimeout,
    /// GracePeriod) — those are handled by the watchdog loop directly.
    pub fn retry_strategy(&self) -> Option<RetryStrategy> {
        match self {
            Self::StopBatch => Some(RetryStrategy::BillingError),
            Self::SkipPlan => Some(RetryStrategy::SkipImmediate),
            Self::KillAndCooldown => Some(RetryStrategy::ApiOverload),
            Self::KillAndRetryAuth => Some(RetryStrategy::TokenAuth),
            Self::RetrySession => Some(RetryStrategy::PhaseTimeout),
            Self::Retry3xThenSkip => Some(RetryStrategy::RateLimit),
            Self::Continue | Self::WaitTimeout | Self::GracePeriod => None,
        }
    }
}

// ── DiagnosticResult ────────────────────────────────────────

/// Result of a diagnostic check — the state, prescribed action, and evidence.
#[derive(Debug, Clone)]
pub struct DiagnosticResult {
    /// Classified session state.
    pub state: DiagnosticState,
    /// Prescribed watchdog action.
    pub action: DiagnosticAction,
    /// Snapshot of the pane text that was analyzed (last N lines).
    #[allow(dead_code)]
    pub pane_snapshot: String,
    /// The pattern string that matched (if any). For logging/debugging.
    #[allow(dead_code)]
    pub matched_pattern: Option<String>,
}

// ── DiagnosticPattern ───────────────────────────────────────

/// A named set of string patterns that map to a diagnostic state + action.
///
/// Patterns are checked via `pane_text.to_lowercase().contains(pattern)`.
/// No regex is used — matching the codebase convention from `monitor.rs`.
struct DiagnosticPattern {
    /// Human-readable name for logging (e.g., "billing_failure").
    name: &'static str,
    /// Patterns to match (lowercase). ANY match triggers this diagnostic.
    patterns: &'static [&'static str],
    /// Resulting diagnostic state when matched.
    state: DiagnosticState,
    /// Prescribed action when matched.
    action: DiagnosticAction,
    /// If true, this pattern is only checked during bootstrap (pre-arc) phase.
    /// Skipped during runtime checks to avoid false positives from normal tool output.
    bootstrap_only: bool,
}

/// A pattern requiring co-occurrence: a numeric code AND an anchor string
/// must both appear in the pane text for a match.
///
/// This prevents false positives like "Checking 500 files" triggering
/// an API server error diagnostic. (Concern P1.2)
struct AnchoredPattern {
    /// Human-readable name for logging.
    name: &'static str,
    /// Numeric HTTP status code to look for (as lowercase string).
    code: &'static str,
    /// At least one anchor string must also be present for the code to match.
    anchors: &'static [&'static str],
    /// Resulting diagnostic state.
    state: DiagnosticState,
    /// Prescribed action.
    action: DiagnosticAction,
}

// ── Pattern Registry (static) ───────────────────────────────

/// Simple string-match patterns, checked in priority order.
///
/// Priority: billing > auth > permission > plan > plugin > overload > rate-limit > network > request-error
const SIMPLE_PATTERNS: &[DiagnosticPattern] = &[
    // D17: Billing failure — terminal, stops batch
    DiagnosticPattern {
        name: "billing_failure",
        patterns: &[
            "billing",
            "payment required",
            "payment_required",
            "insufficient funds",
            "credit card",
            "subscription expired",
        ],
        state: DiagnosticState::BillingFailure,
        action: DiagnosticAction::StopBatch,
        bootstrap_only: false,
    },
    // D3 + D20: Auth errors
    DiagnosticPattern {
        name: "auth_error",
        patterns: &[
            "authentication_error",
            "invalid_api_key",
            "invalid api key",
            "api key expired",
            "unauthorized",
            "token expired",
            "please log in",
            "login required",
            "not authenticated",
        ],
        state: DiagnosticState::ApiAuthError,
        action: DiagnosticAction::KillAndRetryAuth, // D20: maps to RetryStrategy::TokenAuth
        bootstrap_only: false,
    },
    // D6: Permission blocked
    DiagnosticPattern {
        name: "permission_blocked",
        patterns: &[
            "permission denied",
            "permission_error",
            "not permitted",
            "access denied",
        ],
        state: DiagnosticState::PermissionBlocked,
        action: DiagnosticAction::RetrySession,
        bootstrap_only: false,
    },
    // D4: Plan not found — BOOTSTRAP ONLY
    // These patterns should never trigger during runtime because by then the plan
    // has already been loaded. Normal tool output (Read errors, file probes) can
    // contain "plan not found"-like text that would cause false SkipPlan actions.
    DiagnosticPattern {
        name: "plan_not_found",
        patterns: &[
            "plan not found",
            "plan file not found",
            "plan does not exist",
        ],
        state: DiagnosticState::PlanNotFound,
        action: DiagnosticAction::SkipPlan,
        bootstrap_only: true,
    },
    // D5: Plugin missing — BOOTSTRAP ONLY
    // Same reasoning: if plugin was loaded at bootstrap, it won't disappear mid-arc.
    DiagnosticPattern {
        name: "plugin_missing",
        patterns: &[
            "plugin not found",
            "plugin not installed",
            "skill not found",
        ],
        state: DiagnosticState::PluginMissing,
        action: DiagnosticAction::StopBatch,
        bootstrap_only: true,
    },
    // D19: API overloaded (529)
    DiagnosticPattern {
        name: "api_overloaded",
        patterns: &[
            "overloaded_error",
            "overloaded",
            "api is overloaded",
        ],
        state: DiagnosticState::ApiOverloaded,
        action: DiagnosticAction::KillAndCooldown,
        bootstrap_only: false,
    },
    // D21: Rate limited
    DiagnosticPattern {
        name: "rate_limited",
        patterns: &[
            "rate_limit_error",
            "rate limit",
            "rate-limit",
            "too many requests",
        ],
        state: DiagnosticState::RateLimited,
        action: DiagnosticAction::Retry3xThenSkip,
        bootstrap_only: false,
    },
    // D24: Network errors
    DiagnosticPattern {
        name: "network_error",
        patterns: &[
            "connection_error",
            "network error",
            "connection refused",
            "connection reset",
            "connection timed out",
            "dns resolution failed",
            "econnrefused",
            "econnreset",
            "etimedout",
        ],
        state: DiagnosticState::NetworkError,
        action: DiagnosticAction::KillAndCooldown,
        bootstrap_only: false,
    },
    // D22: Request too large
    DiagnosticPattern {
        name: "request_too_large",
        patterns: &[
            "request too large",
            "request_too_large",
            "payload too large",
            "content too long",
        ],
        state: DiagnosticState::RequestTooLarge,
        action: DiagnosticAction::SkipPlan,
        bootstrap_only: false,
    },
    // D23: Service unavailable
    DiagnosticPattern {
        name: "service_unavailable",
        patterns: &[
            "bad gateway",
            "bad_gateway",
            "service unavailable",
            "service_unavailable",
        ],
        state: DiagnosticState::ServiceUnavailable,
        action: DiagnosticAction::KillAndCooldown,
        bootstrap_only: false,
    },
];

/// Anchored patterns: numeric HTTP codes that require co-occurrence with
/// an error type string to avoid false positives. (Concern P1.2)
const ANCHORED_PATTERNS: &[AnchoredPattern] = &[
    // D18: 500 Internal Server Error — only when accompanied by error context
    AnchoredPattern {
        name: "api_server_error_500",
        code: "500",
        anchors: &[
            "api_error",
            "internal server error",
            "internal_server_error",
            "server error",
            "status code",
            "http error",
        ],
        state: DiagnosticState::ApiServerError,
        action: DiagnosticAction::KillAndCooldown, // D18: maps to RetryStrategy::ApiOverload
    },
    // D21: 429 Too Many Requests — anchored variant
    AnchoredPattern {
        name: "rate_limited_429",
        code: "429",
        anchors: &[
            "rate_limit",
            "rate limit",
            "too many requests",
            "status code",
            "http error",
        ],
        state: DiagnosticState::RateLimited,
        action: DiagnosticAction::Retry3xThenSkip,
    },
    // D19: 529 Overloaded — anchored variant
    AnchoredPattern {
        name: "api_overloaded_529",
        code: "529",
        anchors: &[
            "overloaded",
            "overloaded_error",
            "status code",
            "http error",
        ],
        state: DiagnosticState::ApiOverloaded,
        action: DiagnosticAction::KillAndCooldown,
    },
    // D23: 502 Bad Gateway
    AnchoredPattern {
        name: "bad_gateway_502",
        code: "502",
        anchors: &[
            "bad gateway",
            "bad_gateway",
            "status code",
            "http error",
        ],
        state: DiagnosticState::ServiceUnavailable,
        action: DiagnosticAction::KillAndCooldown,
    },
    // D23: 503 Service Unavailable
    AnchoredPattern {
        name: "service_unavailable_503",
        code: "503",
        anchors: &[
            "service unavailable",
            "service_unavailable",
            "status code",
            "http error",
        ],
        state: DiagnosticState::ServiceUnavailable,
        action: DiagnosticAction::KillAndCooldown,
    },
];

// ── DiagnosticEngine ────────────────────────────────────────

/// Grace period for D7 (ClaudeCrashed) detection.
///
/// Claude Code self-updates can take 45-90s on slow connections. Using 60s
/// grace period to avoid false positive crash detection during updates.
/// (Concern P2.8)
const CRASH_GRACE_SECS: u64 = 60;

/// Diagnostic engine that analyzes tmux pane output and process state
/// to classify Claude Code session health.
///
/// The engine is stateful: it tracks when the Claude process was last seen
/// alive to implement the D7 crash grace period.
pub struct DiagnosticEngine {
    /// Timestamp when Claude process was last confirmed alive.
    last_process_seen: Option<Instant>,
}

impl DiagnosticEngine {
    /// Create a new diagnostic engine.
    pub fn new() -> Self {
        Self {
            last_process_seen: None,
        }
    }

    /// Phase A: Pre-arc diagnostic check.
    ///
    /// Run before launching an arc to verify prerequisites:
    /// - Claude Code process is running
    /// - No auth errors visible in pane
    /// - No billing issues
    ///
    /// Returns `Healthy` if the session is ready to start an arc.
    pub fn check_pre_arc(
        &mut self,
        session_id: &str,
        pane_pid: u32,
    ) -> DiagnosticResult {
        let pane_text = Tmux::capture_pane(session_id, 50).unwrap_or_default();
        let claude_pid = Tmux::get_claude_pid(pane_pid);

        // D2: No Claude process → NoClaude
        if claude_pid.is_none() {
            return DiagnosticResult {
                state: DiagnosticState::NoClaude,
                action: DiagnosticAction::RetrySession,
                pane_snapshot: pane_text,
                matched_pattern: None,
            };
        }

        self.last_process_seen = Some(Instant::now());

        // Check pane text for error patterns (bootstrap — include all patterns)
        let mut result = self.match_patterns(&pane_text, false);

        // D2: Pre-arc auth errors escalate to StopBatch (not KillAndRetryAuth).
        // Mid-arc auth (D20) uses KillAndRetryAuth because the token may refresh,
        // but pre-arc auth failure means the session can't start at all.
        if matches!(result.state, DiagnosticState::ApiAuthError) {
            result.action = DiagnosticAction::StopBatch;
        }
        result
    }

    /// Phase B: Bootstrap diagnostic check.
    ///
    /// Run shortly after sending `/arc` command to detect early failures:
    /// - Plan not found
    /// - Plugin missing
    /// - Permission blocked
    pub fn check_bootstrap(
        &mut self,
        session_id: &str,
        pane_pid: u32,
        elapsed: Duration,
        checkpoint_timeout: Duration,
    ) -> DiagnosticResult {
        let pane_text = Tmux::capture_pane(session_id, 100).unwrap_or_default();
        let claude_pid = Tmux::get_claude_pid(pane_pid);

        if claude_pid.is_some() {
            self.last_process_seen = Some(Instant::now());
        }

        // D6: Checkpoint timeout — no checkpoint after configured timeout
        if elapsed >= checkpoint_timeout {
            return DiagnosticResult {
                state: DiagnosticState::CheckpointTimeout,
                action: DiagnosticAction::Retry3xThenSkip,
                pane_snapshot: pane_text,
                matched_pattern: Some(format!(
                    "checkpoint_timeout_{}s",
                    checkpoint_timeout.as_secs()
                )),
            };
        }

        // Check for bootstrap-specific errors (plan/plugin/permission)
        // then fall through to general pattern matching (bootstrap — include all patterns)
        self.match_patterns(&pane_text, false)
    }

    /// Phase C: Runtime diagnostic check.
    ///
    /// Run periodically during arc execution to detect:
    /// - API errors (billing, overload, rate limit, auth)
    /// - Process crash (D7) — process-based detection with 60s grace
    /// - Checkpoint timeout (D6)
    ///
    /// D7 crash detection is PROCESS-BASED ONLY: `Tmux::get_claude_pid()`
    /// returning `None` after the grace period is the sole trigger.
    /// Pane text patterns ("error", "panic", "exit") are logged but
    /// NEVER used for crash decisions — they cause false positives
    /// during active arc output. (Concern P1.1)
    pub fn check_runtime(
        &mut self,
        session_id: &str,
        pane_pid: u32,
    ) -> DiagnosticResult {
        let pane_text = Tmux::capture_pane(session_id, 100).unwrap_or_default();
        let claude_pid = Tmux::get_claude_pid(pane_pid);

        if let Some(_pid) = claude_pid {
            // Process alive — update last-seen timestamp
            self.last_process_seen = Some(Instant::now());
        } else {
            // Process not found — check grace period for D7
            let grace_expired = self
                .last_process_seen
                .map(|t| t.elapsed().as_secs() >= CRASH_GRACE_SECS)
                .unwrap_or(true); // No previous sighting → grace expired

            if grace_expired {
                return DiagnosticResult {
                    state: DiagnosticState::ClaudeCrashed,
                    action: DiagnosticAction::RetrySession,
                    pane_snapshot: pane_text,
                    matched_pattern: Some("process_gone_after_grace".to_string()),
                };
            } else {
                // Within grace period — could be self-update restart
                return DiagnosticResult {
                    state: DiagnosticState::Healthy,
                    action: DiagnosticAction::GracePeriod,
                    pane_snapshot: pane_text,
                    matched_pattern: Some("process_gone_within_grace".to_string()),
                };
            }
        }

        // Process is alive — check pane text for runtime-safe error patterns only
        self.match_patterns(&pane_text, true)
    }

    /// Match pane text against the pattern registry in priority order.
    ///
    /// When `runtime` is true, patterns marked `bootstrap_only` are skipped.
    /// This prevents false positives from normal tool output during arc execution
    /// (e.g., D4 "plan not found" from a Read error mid-arc).
    ///
    /// Evaluation order:
    /// 1. Simple patterns (billing > auth > permission > [plan > plugin if !runtime] > overload > rate-limit > network > request > service)
    /// 2. Anchored patterns (numeric HTTP codes requiring co-occurrence with error strings)
    /// 3. If no match → Healthy
    fn match_patterns(&self, pane_text: &str, runtime: bool) -> DiagnosticResult {
        let lower = pane_text.to_lowercase();

        // 1. Simple pattern matching — priority order from SIMPLE_PATTERNS
        for pattern in SIMPLE_PATTERNS {
            // Skip bootstrap-only patterns during runtime checks
            if runtime && pattern.bootstrap_only {
                continue;
            }
            for &needle in pattern.patterns {
                if lower.contains(needle) {
                    return DiagnosticResult {
                        state: pattern.state.clone(),
                        action: pattern.action.clone(),
                        pane_snapshot: pane_text.to_string(),
                        matched_pattern: Some(format!("{}:{}", pattern.name, needle)),
                    };
                }
            }
        }

        // 2. Anchored patterns — numeric codes requiring co-occurrence (Concern P1.2)
        for anchored in ANCHORED_PATTERNS {
            if lower.contains(anchored.code) {
                // Code found — check if any anchor string is also present
                for &anchor in anchored.anchors {
                    if lower.contains(anchor) {
                        return DiagnosticResult {
                            state: anchored.state.clone(),
                            action: anchored.action.clone(),
                            pane_snapshot: pane_text.to_string(),
                            matched_pattern: Some(format!(
                                "{}:{}+{}",
                                anchored.name, anchored.code, anchor
                            )),
                        };
                    }
                }
            }
        }

        // 3. No match — session is healthy
        DiagnosticResult {
            state: DiagnosticState::Healthy,
            action: DiagnosticAction::Continue,
            pane_snapshot: pane_text.to_string(),
            matched_pattern: None,
        }
    }

    /// Update the last-seen timestamp for the Claude process.
    ///
    /// Called by the watchdog when it independently confirms the process is alive
    /// (e.g., via heartbeat checks in the main poll loop).
    #[allow(dead_code)]
    pub fn mark_process_alive(&mut self) {
        self.last_process_seen = Some(Instant::now());
    }
}

// ── Tests ───────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // Helper: run match_patterns in bootstrap mode (all patterns active)
    fn match_text(text: &str) -> DiagnosticResult {
        let engine = DiagnosticEngine::new();
        engine.match_patterns(text, false)
    }

    // Helper: run match_patterns in runtime mode (bootstrap_only patterns skipped)
    fn match_text_runtime(text: &str) -> DiagnosticResult {
        let engine = DiagnosticEngine::new();
        engine.match_patterns(text, true)
    }

    // ── Billing (D17) ──

    #[test]
    fn test_billing_failure_detected() {
        let result = match_text("Error: payment required for this API call");
        assert_eq!(result.state, DiagnosticState::BillingFailure);
        assert_eq!(result.action, DiagnosticAction::StopBatch);
    }

    #[test]
    fn test_billing_case_insensitive() {
        let result = match_text("BILLING error occurred");
        assert_eq!(result.state, DiagnosticState::BillingFailure);
    }

    // ── Auth (D3/D20) ──

    #[test]
    fn test_auth_error_detected() {
        let result = match_text("authentication_error: invalid api key");
        assert_eq!(result.state, DiagnosticState::ApiAuthError);
        assert_eq!(result.action, DiagnosticAction::KillAndRetryAuth);
    }

    #[test]
    fn test_auth_maps_to_token_auth_strategy() {
        let action = DiagnosticAction::KillAndRetryAuth;
        assert_eq!(action.retry_strategy(), Some(RetryStrategy::TokenAuth));
    }

    // ── Permission (D6) ──

    #[test]
    fn test_permission_blocked_detected() {
        let result = match_text("Error: permission denied for tool Bash");
        assert_eq!(result.state, DiagnosticState::PermissionBlocked);
        assert_eq!(result.action, DiagnosticAction::RetrySession);
    }

    // ── Plan not found (D4) ──

    #[test]
    fn test_plan_not_found_detected() {
        let result = match_text("Error: plan not found at plans/missing.md");
        assert_eq!(result.state, DiagnosticState::PlanNotFound);
        assert_eq!(result.action, DiagnosticAction::SkipPlan);
    }

    #[test]
    fn test_plan_does_not_exist_detected() {
        let result = match_text("plan does not exist: plans/missing.md");
        assert_eq!(result.state, DiagnosticState::PlanNotFound);
    }

    #[test]
    fn test_generic_no_such_file_is_not_plan_not_found() {
        // Generic "no such file" from tool errors (e.g. Read) must NOT trigger PlanNotFound
        let result = match_text("Read tool error: /src/foo.ts: no such file or directory");
        assert_ne!(result.state, DiagnosticState::PlanNotFound);
    }

    #[test]
    fn test_generic_file_not_found_is_not_plan_not_found() {
        let result = match_text("Error: file not found /src/missing.rs");
        assert_ne!(result.state, DiagnosticState::PlanNotFound);
    }

    #[test]
    fn test_plan_not_found_skipped_during_runtime() {
        // D4 is bootstrap_only — must NOT trigger during runtime checks (mid-arc)
        let result = match_text_runtime("Error: plan not found at plans/missing.md");
        assert_ne!(result.state, DiagnosticState::PlanNotFound);
        assert_eq!(result.state, DiagnosticState::Healthy);
    }

    #[test]
    fn test_plugin_missing_skipped_during_runtime() {
        // D5 is bootstrap_only — must NOT trigger during runtime checks (mid-arc)
        let result = match_text_runtime("skill not found: rune:arc");
        assert_ne!(result.state, DiagnosticState::PluginMissing);
        assert_eq!(result.state, DiagnosticState::Healthy);
    }

    #[test]
    fn test_api_errors_still_detected_during_runtime() {
        // API errors (D17-D24) must still be caught during runtime
        let result = match_text_runtime("overloaded_error: API is overloaded");
        assert_eq!(result.state, DiagnosticState::ApiOverloaded);
    }

    // ── API overload (D19) ──

    #[test]
    fn test_api_overloaded_detected() {
        let result = match_text("overloaded_error: API is overloaded, please retry");
        assert_eq!(result.state, DiagnosticState::ApiOverloaded);
        assert_eq!(result.action, DiagnosticAction::KillAndCooldown);
    }

    #[test]
    fn test_overload_maps_to_api_overload_strategy() {
        let action = DiagnosticAction::KillAndCooldown;
        assert_eq!(action.retry_strategy(), Some(RetryStrategy::ApiOverload));
    }

    // ── Rate limit (D21) ──

    #[test]
    fn test_rate_limit_detected() {
        let result = match_text("rate_limit_error: too many requests");
        assert_eq!(result.state, DiagnosticState::RateLimited);
        assert_eq!(result.action, DiagnosticAction::Retry3xThenSkip);
    }

    #[test]
    fn test_rate_limit_maps_to_rate_limit_strategy() {
        let action = DiagnosticAction::Retry3xThenSkip;
        assert_eq!(action.retry_strategy(), Some(RetryStrategy::RateLimit));
    }

    // ── Anchored patterns (P1.2) ──

    #[test]
    fn test_500_without_anchor_is_healthy() {
        // "500" alone should NOT trigger — could be "Checking 500 files"
        let result = match_text("Processing 500 items in batch");
        assert_eq!(result.state, DiagnosticState::Healthy);
    }

    #[test]
    fn test_500_with_anchor_triggers_server_error() {
        let result = match_text("HTTP 500 api_error: internal server error");
        assert_eq!(result.state, DiagnosticState::ApiServerError);
        assert_eq!(result.action, DiagnosticAction::KillAndCooldown);
    }

    #[test]
    fn test_429_with_anchor_triggers_rate_limit() {
        let result = match_text("status code 429: rate limit exceeded");
        assert_eq!(result.state, DiagnosticState::RateLimited);
    }

    #[test]
    fn test_429_without_anchor_is_healthy() {
        let result = match_text("ticket #429 assigned to user");
        assert_eq!(result.state, DiagnosticState::Healthy);
    }

    #[test]
    fn test_502_with_anchor_triggers_service_unavailable() {
        let result = match_text("http error 502 bad gateway");
        assert_eq!(result.state, DiagnosticState::ServiceUnavailable);
    }

    // ── Network (D24) ──

    #[test]
    fn test_network_error_detected() {
        let result = match_text("connection_error: ECONNREFUSED");
        assert_eq!(result.state, DiagnosticState::NetworkError);
        assert_eq!(result.action, DiagnosticAction::KillAndCooldown);
    }

    // ── Request too large (D22) ──

    #[test]
    fn test_request_too_large_detected() {
        let result = match_text("Error: request too large, reduce context");
        assert_eq!(result.state, DiagnosticState::RequestTooLarge);
        assert_eq!(result.action, DiagnosticAction::SkipPlan);
    }

    // ── Healthy (no match) ──

    #[test]
    fn test_healthy_when_no_patterns_match() {
        let result = match_text("Working on phase: forge... Edit tool called");
        assert_eq!(result.state, DiagnosticState::Healthy);
        assert_eq!(result.action, DiagnosticAction::Continue);
        assert!(result.matched_pattern.is_none());
    }

    #[test]
    fn test_healthy_on_empty_pane() {
        let result = match_text("");
        assert_eq!(result.state, DiagnosticState::Healthy);
    }

    // ── Priority ordering ──

    #[test]
    fn test_billing_takes_priority_over_auth() {
        // If both billing and auth patterns appear, billing wins (higher priority)
        let result = match_text("billing error and also unauthorized access");
        assert_eq!(result.state, DiagnosticState::BillingFailure);
    }

    #[test]
    fn test_auth_takes_priority_over_rate_limit() {
        let result = match_text("unauthorized and rate_limit_error together");
        assert_eq!(result.state, DiagnosticState::ApiAuthError);
    }

    // ── Severity ──

    #[test]
    fn test_severity_levels() {
        assert_eq!(DiagnosticState::BillingFailure.severity(), Severity::Critical);
        assert_eq!(DiagnosticState::ClaudeCrashed.severity(), Severity::High);
        assert_eq!(DiagnosticState::ApiOverloaded.severity(), Severity::Medium);
        assert_eq!(DiagnosticState::Healthy.severity(), Severity::Low);
    }

    // ── RetryStrategy mapping ──

    #[test]
    fn test_action_strategy_mappings() {
        assert_eq!(DiagnosticAction::StopBatch.retry_strategy(), Some(RetryStrategy::BillingError));
        assert_eq!(DiagnosticAction::SkipPlan.retry_strategy(), Some(RetryStrategy::SkipImmediate));
        assert_eq!(DiagnosticAction::KillAndCooldown.retry_strategy(), Some(RetryStrategy::ApiOverload));
        assert_eq!(DiagnosticAction::KillAndRetryAuth.retry_strategy(), Some(RetryStrategy::TokenAuth));
        assert_eq!(DiagnosticAction::RetrySession.retry_strategy(), Some(RetryStrategy::PhaseTimeout));
        assert_eq!(DiagnosticAction::Retry3xThenSkip.retry_strategy(), Some(RetryStrategy::RateLimit));
        assert_eq!(DiagnosticAction::Continue.retry_strategy(), None);
        assert_eq!(DiagnosticAction::WaitTimeout.retry_strategy(), None);
        assert_eq!(DiagnosticAction::GracePeriod.retry_strategy(), None);
    }

    // ── DiagnosticState labels ──

    #[test]
    fn test_state_labels_are_snake_case() {
        let states = [
            DiagnosticState::Healthy,
            DiagnosticState::NoClaude,
            DiagnosticState::BillingFailure,
            DiagnosticState::ApiServerError,
            DiagnosticState::RateLimited,
            DiagnosticState::ClaudeCrashed,
        ];
        for state in &states {
            let label = state.label();
            assert!(
                label.chars().all(|c| c.is_ascii_lowercase() || c == '_'),
                "label '{}' should be snake_case",
                label
            );
        }
    }
}
