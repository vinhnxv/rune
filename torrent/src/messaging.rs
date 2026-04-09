//! Message transport and bridge communication state.
//!
//! `MessageState` owns the data for message input, bridge display, and
//! channel communication. Orchestrating send methods that need access to
//! `set_status()` remain on `App` and delegate to `MessageState` via split borrows.
//!
//! The 3-tier fallback chain (Bridge HTTP → Inbox → Tmux) is **live code** — do NOT
//! remove any transport method (ROT-002 was a false positive).

use std::collections::VecDeque;
use std::time::Instant;

use crate::callback::CallbackServer;
use crate::types::{BridgeMessage, BridgeMessageKind, MsgTransport};

/// Maximum messages displayed in Bridge View TUI.
pub(crate) const BRIDGE_MSG_DISPLAY_CAP: usize = 26;

/// Truncate a string to `max` bytes on a valid char boundary.
pub(crate) fn truncate_str(s: &str, max: usize) -> &str {
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

/// Message transport and bridge view state for the TUI.
pub struct MessageState {
    /// Whether channels mode is enabled (--channels flag or config).
    pub channels_enabled: bool,
    /// Callback port for receiving channel events from bridge.
    pub callback_port: u16,
    /// Callback HTTP server instance (started when channels_enabled).
    pub callback_server: Option<CallbackServer>,

    /// Whether the message input bar is active.
    pub message_input_active: bool,
    /// Current message text being typed.
    pub message_input_buf: String,
    /// Last message delivery transport (for UI display).
    pub last_msg_transport: Option<MsgTransport>,
    /// Last message received from Claude Code via channel events (trimmed to 200 chars).
    pub last_claude_msg: Option<String>,

    /// Ring buffer of bridge messages for Bridge View (capacity BRIDGE_MSG_DISPLAY_CAP).
    pub bridge_messages: VecDeque<BridgeMessage>,
    /// File handle for append-only message persistence (opened once per session).
    pub bridge_log_file: Option<std::fs::File>,
    /// Scroll offset for Bridge View message list (0 = auto-scroll to bottom).
    pub bridge_scroll_offset: usize,

    /// Last time an auto-accept was sent for a permission/yes-no prompt.
    /// Used for debouncing — at most 1 auto-accept per 60 seconds.
    pub last_auto_accept: Option<Instant>,
}

impl MessageState {
    /// Create a new message state with defaults.
    pub fn new() -> Self {
        Self {
            channels_enabled: false,
            callback_port: 9900,
            callback_server: None,
            message_input_active: false,
            message_input_buf: String::new(),
            last_msg_transport: None,
            last_claude_msg: None,
            bridge_messages: VecDeque::with_capacity(BRIDGE_MSG_DISPLAY_CAP),
            bridge_log_file: None,
            bridge_scroll_offset: 0,
            last_auto_accept: None,
        }
    }

    /// Push a message to the display ring buffer and persist to file.
    pub fn push_bridge_message(&mut self, msg: BridgeMessage, tmux_session_id: Option<&str>) {
        // Lazy-open the log file on first message
        if self.bridge_log_file.is_none() {
            if let Some(session_id) = tmux_session_id {
                self.bridge_log_file = open_bridge_log(session_id);
            }
        }
        // Persist to file (all messages, including filtered heartbeats)
        if let Some(ref mut file) = self.bridge_log_file {
            persist_bridge_message(file, &msg);
        }
        // Display filter: skip consecutive heartbeats (replace last one)
        if msg.kind == BridgeMessageKind::Heartbeat
            && self.bridge_messages.back().map(|m| m.kind) == Some(BridgeMessageKind::Heartbeat)
        {
            self.bridge_messages.pop_back();
        }
        // Push to display ring buffer
        if self.bridge_messages.len() >= BRIDGE_MSG_DISPLAY_CAP {
            self.bridge_messages.pop_front();
        }
        self.bridge_messages.push_back(msg);
        // Auto-scroll to bottom on new message (unless user scrolled up)
        // bridge_scroll_offset == 0 means already at bottom — no action needed.
    }
}

/// Open (or create) the JSONL log file for this session.
/// Called once when the first bridge message arrives.
pub(crate) fn open_bridge_log(session_id: &str) -> Option<std::fs::File> {
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
pub(crate) fn persist_bridge_message(file: &mut std::fs::File, msg: &BridgeMessage) {
    use std::io::Write;
    let kind_str = match msg.kind {
        BridgeMessageKind::Sent => "sent",
        BridgeMessageKind::SendFailed => "send_failed",
        BridgeMessageKind::Phase => "phase",
        BridgeMessageKind::Complete => "complete",
        BridgeMessageKind::Heartbeat => "heartbeat",
        BridgeMessageKind::Reply => "reply",
    };
    // Use serde_json for RFC 8259-compliant escaping (handles Unicode control chars).
    let escaped = serde_json::to_string(&msg.text).unwrap_or_else(|_| "\"\"".to_string());
    let line = format!(
        r#"{{"ts":"{}","kind":"{}","text":{}}}"#,
        chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%.3f"),
        kind_str,
        escaped,
    );
    let _ = writeln!(file, "{}", line);
}
