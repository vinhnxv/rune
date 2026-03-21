//! HTTP callback server for receiving push events from torrent-bridge instances.
//!
//! Runs `tiny_http::Server` on a background thread. Bridge instances POST JSON
//! events to `/event`, routed by `session_id` in the payload. Events are forwarded
//! to the main TUI thread via `std::sync::mpsc`.
//!
//! This is the Torrent side of the Claude → Torrent outbound channel.
//! Since v0.8.0, channels are bidirectional via Channels API (notifications/claude/channel).

use std::io::Read as _;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;

use color_eyre::eyre::{eyre, Result};
use serde::Deserialize;

/// Default callback port when TORRENT_CALLBACK_PORT is not set.
pub const DEFAULT_CALLBACK_PORT: u16 = 9900;

/// Maximum request body size (64 KB — events are small JSON payloads).
const MAX_BODY_SIZE: usize = 64 * 1024;

/// Events pushed from torrent-bridge (Claude Code) to Torrent.
///
/// Each variant maps to a reply tool in the bridge's MCP server:
/// - `report_phase` → `PhaseUpdate`
/// - `report_complete` → `ArcComplete`
/// - `heartbeat` → `Heartbeat`
/// - `reply` → `Reply`
#[derive(Debug, Clone)]
#[allow(dead_code)] // Fields read in tests and reserved for future UI display
pub enum ChannelEvent {
    /// Phase started or completed.
    PhaseUpdate {
        session_id: String,
        phase: String,
        status: String,
        details: String,
    },
    /// Arc run finished (success or failure).
    ArcComplete {
        session_id: String,
        result: String,
        pr_url: Option<String>,
        error: Option<String>,
    },
    /// Liveness signal from Claude Code session.
    Heartbeat {
        session_id: String,
        activity: String,
        current_tool: String,
    },
    /// Text response from Claude Code to a channel message.
    Reply {
        session_id: String,
        text: String,
        reply_to: Option<String>,
    },
}

/// Raw JSON structure for incoming event payloads.
#[derive(Deserialize)]
struct RawEvent {
    #[serde(rename = "type")]
    event_type: String,
    session_id: String,
    #[serde(default)]
    phase: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    details: String,
    #[serde(default)]
    result: String,
    #[serde(default)]
    pr_url: Option<String>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    activity: String,
    #[serde(default)]
    current_tool: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    reply_to: Option<String>,
}

/// HTTP callback server that receives push events from torrent-bridge instances.
///
/// Lifecycle:
/// 1. `CallbackServer::start(port)` → spawns background thread with `tiny_http`
/// 2. Main thread calls `recv_event()` each tick (non-blocking)
/// 3. `drop()` sets shutdown flag → background thread exits on next accept timeout
pub struct CallbackServer {
    /// Actual port the server bound to.
    #[allow(dead_code)] // Read via port() method in tests
    port: u16,
    /// Receive end for events from the HTTP thread.
    rx: mpsc::Receiver<ChannelEvent>,
    /// Shutdown signal for the background thread.
    shutdown: Arc<AtomicBool>,
    /// Shared server handle for unblocking on shutdown.
    server: Arc<tiny_http::Server>,
    /// Join handle for cleanup.
    _handle: Option<thread::JoinHandle<()>>,
}

impl CallbackServer {
    /// Start the callback server on the given port.
    ///
    /// Spawns a background thread running `tiny_http::Server` on `127.0.0.1:port`.
    /// If `port` is 0, the OS assigns an available port.
    ///
    /// # Errors
    /// Returns an error if the port is already in use or binding fails.
    pub fn start(port: u16) -> Result<Self> {
        let addr = format!("127.0.0.1:{}", port);
        let server = tiny_http::Server::http(&addr)
            .map_err(|e| eyre!("failed to bind callback server on {}: {}", addr, e))?;

        let actual_port = server
            .server_addr()
            .to_ip()
            .map(|a| a.port())
            .ok_or_else(|| eyre!("callback server bound to non-IP address"))?;

        let server = Arc::new(server);
        let server_clone = Arc::clone(&server);
        let (tx, rx) = mpsc::channel();
        let shutdown = Arc::new(AtomicBool::new(false));
        let shutdown_clone = Arc::clone(&shutdown);

        let handle = thread::Builder::new()
            .name("torrent-callback".into())
            .spawn(move || {
                run_server(server_clone, tx, shutdown_clone);
            })?;

        Ok(Self {
            port: actual_port,
            rx,
            shutdown,
            server,
            _handle: Some(handle),
        })
    }

    /// Start the callback server using TORRENT_CALLBACK_PORT env var or default.
    ///
    /// Not currently used — port resolution happens in `main.rs` CLI parsing.
    /// Kept for potential future use as a standalone entry point.
    #[allow(dead_code)]
    pub fn start_from_env() -> Result<Self> {
        let port = std::env::var("TORRENT_CALLBACK_PORT")
            .ok()
            .and_then(|s| s.parse::<u16>().ok())
            .filter(|&p| p > 0 && p <= 65534)
            .unwrap_or(DEFAULT_CALLBACK_PORT);
        Self::start(port)
    }

    /// The port the server is listening on.
    #[allow(dead_code)] // Used in tests
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Try to receive the next event (non-blocking).
    ///
    /// Returns `None` if no events are pending. Call this each tick
    /// in the main event loop.
    pub fn recv_event(&self) -> Option<ChannelEvent> {
        self.rx.try_recv().ok()
    }

    /// Signal the background thread to stop.
    pub fn stop(&self) {
        self.shutdown.store(true, Ordering::Release);
    }
}

impl Drop for CallbackServer {
    fn drop(&mut self) {
        self.stop();
        self.server.unblock();
        // After unblock(), the background thread's recv() returns Err and exits.
    }
}

/// Background thread: accept HTTP requests and forward parsed events.
fn run_server(
    server: Arc<tiny_http::Server>,
    tx: mpsc::Sender<ChannelEvent>,
    shutdown: Arc<AtomicBool>,
) {
    // tiny_http blocks on accept. We check shutdown between requests.
    // In practice, bridge sends events frequently enough that the thread
    // won't block for long. On shutdown, the main thread drops the server
    // which unblocks accept.
    loop {
        if shutdown.load(Ordering::Acquire) {
            break;
        }

        // recv() blocks until a request arrives or the server is dropped.
        let request = match server.recv() {
            Ok(req) => req,
            Err(_) => break, // Server dropped or error — exit
        };

        if shutdown.load(Ordering::Acquire) {
            let _ = request.respond(tiny_http::Response::from_string("shutting down")
                .with_status_code(503));
            break;
        }

        handle_request(request, &tx);
    }
}

/// Handle a single HTTP request.
fn handle_request(mut request: tiny_http::Request, tx: &mpsc::Sender<ChannelEvent>) {
    let path = request.url().to_string();

    match path.as_str() {
        "/ping" => {
            let _ = request.respond(tiny_http::Response::from_string("ok"));
        }
        "/event" => {
            if request.method() != &tiny_http::Method::Post {
                let _ = request.respond(
                    tiny_http::Response::from_string("method not allowed")
                        .with_status_code(405),
                );
                return;
            }

            // Require JSON content type
            let has_json_content_type = request.headers().iter().any(|h| {
                h.field.equiv("Content-Type")
                    && h.value.as_str().contains("application/json")
            });
            if !has_json_content_type {
                let _ = request.respond(
                    tiny_http::Response::from_string("unsupported media type")
                        .with_status_code(415),
                );
                return;
            }

            // Read body with size limit
            let content_length = request
                .body_length()
                .unwrap_or(0);
            if content_length > MAX_BODY_SIZE {
                let _ = request.respond(
                    tiny_http::Response::from_string("payload too large")
                        .with_status_code(413),
                );
                return;
            }

            let mut body = Vec::with_capacity(content_length.min(MAX_BODY_SIZE));
            if request.as_reader().take(MAX_BODY_SIZE as u64).read_to_end(&mut body).is_err() {
                let _ = request.respond(
                    tiny_http::Response::from_string("read error")
                        .with_status_code(400),
                );
                return;
            }

            if body.len() >= MAX_BODY_SIZE {
                let _ = request.respond(
                    tiny_http::Response::from_string("payload too large")
                        .with_status_code(413),
                );
                return;
            }

            match parse_event(&body) {
                Ok(event) => {
                    if tx.send(event).is_err() {
                        tlog!(WARN, "callback: event dropped (receiver disconnected)");
                        let _ = request.respond(
                            tiny_http::Response::from_string("server shutting down")
                                .with_status_code(503),
                        );
                        return;
                    }
                    let _ = request.respond(tiny_http::Response::from_string("ok"));
                }
                Err(msg) => {
                    let _ = request.respond(
                        tiny_http::Response::from_string(msg).with_status_code(400),
                    );
                }
            }
        }
        _ => {
            let _ = request.respond(
                tiny_http::Response::from_string("not found").with_status_code(404),
            );
        }
    }
}

/// Parse raw JSON bytes into a typed ChannelEvent.
fn parse_event(body: &[u8]) -> std::result::Result<ChannelEvent, String> {
    let raw: RawEvent =
        serde_json::from_slice(body).map_err(|e| format!("invalid JSON: {}", e))?;

    if raw.session_id.is_empty() {
        return Err("missing session_id".into());
    }

    // Field length limits to prevent abuse (SEC-013 + BACK-015)
    if raw.session_id.len() > 64 {
        return Err("session_id exceeds 64 chars".into());
    }
    if raw.event_type.len() > 32 {
        return Err("event_type exceeds 32 chars".into());
    }
    if raw.phase.len() > 128 {
        return Err("phase exceeds 128 chars".into());
    }
    if raw.status.len() > 64 {
        return Err("status exceeds 64 chars".into());
    }
    if raw.details.len() > 1024 {
        return Err("details exceeds 1024 chars".into());
    }
    if raw.result.len() > 32 {
        return Err("result exceeds 32 chars".into());
    }
    if let Some(ref err) = raw.error {
        if err.len() > 1024 {
            return Err("error exceeds 1024 chars".into());
        }
    }
    if raw.activity.len() > 32 {
        return Err("activity exceeds 32 chars".into());
    }
    if raw.current_tool.len() > 128 {
        return Err("current_tool exceeds 128 chars".into());
    }
    if let Some(ref url) = raw.pr_url {
        if !url.starts_with("https://") {
            return Err("pr_url must start with https://".into());
        }
        if url.len() > 512 {
            return Err("pr_url exceeds 512 chars".into());
        }
    }

    match raw.event_type.as_str() {
        "phase" => Ok(ChannelEvent::PhaseUpdate {
            session_id: raw.session_id,
            phase: raw.phase,
            status: raw.status,
            details: raw.details,
        }),
        "complete" => Ok(ChannelEvent::ArcComplete {
            session_id: raw.session_id,
            result: raw.result,
            pr_url: raw.pr_url,
            error: raw.error,
        }),
        "heartbeat" => Ok(ChannelEvent::Heartbeat {
            session_id: raw.session_id,
            activity: raw.activity,
            current_tool: raw.current_tool,
        }),
        "reply" => {
            if raw.text.is_empty() {
                return Err("reply missing text".into());
            }
            if raw.text.len() > 8192 {
                return Err("reply text exceeds 8192 chars".into());
            }
            Ok(ChannelEvent::Reply {
                session_id: raw.session_id,
                text: raw.text,
                reply_to: raw.reply_to,
            })
        }
        other => Err(format!("unknown event type: {}", other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_phase_event() {
        let json = br#"{"type":"phase","session_id":"abc-123","phase":"forge","status":"started","details":"enriching plan"}"#;
        let event = parse_event(json).unwrap();
        match event {
            ChannelEvent::PhaseUpdate {
                session_id,
                phase,
                status,
                details,
            } => {
                assert_eq!(session_id, "abc-123");
                assert_eq!(phase, "forge");
                assert_eq!(status, "started");
                assert_eq!(details, "enriching plan");
            }
            _ => panic!("expected PhaseUpdate"),
        }
    }

    #[test]
    fn parse_complete_event() {
        let json = br#"{"type":"complete","session_id":"abc-123","result":"success","pr_url":"https://github.com/org/repo/pull/42"}"#;
        let event = parse_event(json).unwrap();
        match event {
            ChannelEvent::ArcComplete {
                session_id,
                result,
                pr_url,
                error,
            } => {
                assert_eq!(session_id, "abc-123");
                assert_eq!(result, "success");
                assert_eq!(pr_url.as_deref(), Some("https://github.com/org/repo/pull/42"));
                assert!(error.is_none());
            }
            _ => panic!("expected ArcComplete"),
        }
    }

    #[test]
    fn parse_heartbeat_event() {
        let json = br#"{"type":"heartbeat","session_id":"abc-123","activity":"active","current_tool":"Bash"}"#;
        let event = parse_event(json).unwrap();
        match event {
            ChannelEvent::Heartbeat {
                session_id,
                activity,
                current_tool,
            } => {
                assert_eq!(session_id, "abc-123");
                assert_eq!(activity, "active");
                assert_eq!(current_tool, "Bash");
            }
            _ => panic!("expected Heartbeat"),
        }
    }

    #[test]
    fn parse_missing_session_id() {
        let json = br#"{"type":"phase","session_id":"","phase":"work"}"#;
        let err = parse_event(json).unwrap_err();
        assert!(err.contains("missing session_id"));
    }

    #[test]
    fn parse_unknown_type() {
        let json = br#"{"type":"unknown","session_id":"abc"}"#;
        let err = parse_event(json).unwrap_err();
        assert!(err.contains("unknown event type"));
    }

    #[test]
    fn parse_invalid_json() {
        let err = parse_event(b"not json").unwrap_err();
        assert!(err.contains("invalid JSON"));
    }

    #[test]
    fn server_start_and_recv() {
        // Start on port 0 (OS-assigned) to avoid conflicts
        let server = CallbackServer::start(0).expect("failed to start callback server");
        let port = server.port();
        assert!(port > 0);

        // No events yet
        assert!(server.recv_event().is_none());

        // POST a phase event via ureq
        let url = format!("http://127.0.0.1:{}/event", port);
        let body = r#"{"type":"phase","session_id":"test-1","phase":"review","status":"completed","details":"all clear"}"#;
        let resp = ureq::post(&url)
            .set("Content-Type", "application/json")
            .send_string(body);
        assert!(resp.is_ok());

        // Give the background thread a moment to process
        std::thread::sleep(std::time::Duration::from_millis(50));

        let event = server.recv_event().expect("expected an event");
        match event {
            ChannelEvent::PhaseUpdate {
                session_id, phase, ..
            } => {
                assert_eq!(session_id, "test-1");
                assert_eq!(phase, "review");
            }
            _ => panic!("expected PhaseUpdate"),
        }

        // Ping endpoint
        let ping_url = format!("http://127.0.0.1:{}/ping", port);
        let resp = ureq::get(&ping_url).call();
        assert!(resp.is_ok());

        server.stop();
    }

    // ── Field length validation tests (SEC-013 + BACK-015) ──

    #[test]
    fn reject_session_id_too_long() {
        let long_id = "a".repeat(65);
        let json = format!(
            r#"{{"type":"phase","session_id":"{}","phase":"f","status":"s","details":"d"}}"#,
            long_id
        );
        let err = parse_event(json.as_bytes()).unwrap_err();
        assert!(err.contains("session_id exceeds 64 chars"), "got: {err}");
    }

    #[test]
    fn accept_session_id_at_limit() {
        let id = "a".repeat(64);
        let json = format!(
            r#"{{"type":"phase","session_id":"{}","phase":"f","status":"s","details":"d"}}"#,
            id
        );
        assert!(parse_event(json.as_bytes()).is_ok());
    }

    #[test]
    fn reject_event_type_too_long() {
        let long_type = "x".repeat(33);
        let json = format!(
            r#"{{"type":"{}","session_id":"abc","phase":"f","status":"s","details":"d"}}"#,
            long_type
        );
        let err = parse_event(json.as_bytes()).unwrap_err();
        assert!(err.contains("event_type exceeds 32 chars"), "got: {err}");
    }

    #[test]
    fn reject_result_too_long() {
        let long_result = "r".repeat(33);
        let json = format!(
            r#"{{"type":"complete","session_id":"abc","result":"{}"}}"#,
            long_result
        );
        let err = parse_event(json.as_bytes()).unwrap_err();
        assert!(err.contains("result exceeds 32 chars"), "got: {err}");
    }

    #[test]
    fn reject_error_too_long() {
        let long_error = "e".repeat(1025);
        let json = format!(
            r#"{{"type":"complete","session_id":"abc","result":"ok","error":"{}"}}"#,
            long_error
        );
        let err = parse_event(json.as_bytes()).unwrap_err();
        assert!(err.contains("error exceeds 1024 chars"), "got: {err}");
    }

    #[test]
    fn reject_activity_too_long() {
        let long_act = "a".repeat(33);
        let json = format!(
            r#"{{"type":"heartbeat","session_id":"abc","activity":"{}","current_tool":"t"}}"#,
            long_act
        );
        let err = parse_event(json.as_bytes()).unwrap_err();
        assert!(err.contains("activity exceeds 32 chars"), "got: {err}");
    }

    #[test]
    fn reject_current_tool_too_long() {
        let long_tool = "t".repeat(129);
        let json = format!(
            r#"{{"type":"heartbeat","session_id":"abc","activity":"a","current_tool":"{}"}}"#,
            long_tool
        );
        let err = parse_event(json.as_bytes()).unwrap_err();
        assert!(err.contains("current_tool exceeds 128 chars"), "got: {err}");
    }

    #[test]
    fn reject_pr_url_bad_protocol() {
        let json = br#"{"type":"complete","session_id":"abc","result":"ok","pr_url":"http://github.com/pull/1"}"#;
        let err = parse_event(json).unwrap_err();
        assert!(err.contains("pr_url must start with https://"), "got: {err}");
    }

    #[test]
    fn reject_pr_url_too_long() {
        let long_url = format!("https://github.com/{}", "a".repeat(500));
        let json = format!(
            r#"{{"type":"complete","session_id":"abc","result":"ok","pr_url":"{}"}}"#,
            long_url
        );
        let err = parse_event(json.as_bytes()).unwrap_err();
        assert!(err.contains("pr_url exceeds 512 chars"), "got: {err}");
    }

    #[test]
    fn accept_valid_pr_url() {
        let json = br#"{"type":"complete","session_id":"abc","result":"ok","pr_url":"https://github.com/org/repo/pull/42"}"#;
        assert!(parse_event(json).is_ok());
    }

    #[test]
    fn accept_error_none() {
        let json = br#"{"type":"complete","session_id":"abc","result":"ok"}"#;
        let event = parse_event(json).unwrap();
        match event {
            ChannelEvent::ArcComplete { error, .. } => assert!(error.is_none()),
            _ => panic!("expected ArcComplete"),
        }
    }

    #[test]
    fn accept_error_within_limit() {
        let err_msg = "e".repeat(1024);
        let json = format!(
            r#"{{"type":"complete","session_id":"abc","result":"ok","error":"{}"}}"#,
            err_msg
        );
        assert!(parse_event(json.as_bytes()).is_ok());
    }

    // ── HTTP integration test: field validation via live server ──

    #[test]
    fn server_rejects_oversized_session_id() {
        let server = CallbackServer::start(0).expect("failed to start");
        let port = server.port();
        let url = format!("http://127.0.0.1:{}/event", port);

        let long_id = "x".repeat(65);
        let body = format!(
            r#"{{"type":"phase","session_id":"{}","phase":"f","status":"s","details":"d"}}"#,
            long_id
        );
        let resp = ureq::post(&url)
            .set("Content-Type", "application/json")
            .send_string(&body);
        // Server returns 400 for validation errors
        assert!(resp.is_err(), "expected 400 for oversized session_id");

        server.stop();
    }

    #[test]
    fn server_accepts_all_three_event_types() {
        let server = CallbackServer::start(0).expect("failed to start");
        let port = server.port();
        let url = format!("http://127.0.0.1:{}/event", port);

        let events = [
            r#"{"type":"phase","session_id":"t1","phase":"work","status":"ok","details":""}"#,
            r#"{"type":"heartbeat","session_id":"t1","activity":"coding","current_tool":"Edit"}"#,
            r#"{"type":"complete","session_id":"t1","result":"success"}"#,
        ];
        for body in events {
            let resp = ureq::post(&url)
                .set("Content-Type", "application/json")
                .send_string(body);
            assert!(resp.is_ok(), "failed for: {body}");
        }

        std::thread::sleep(std::time::Duration::from_millis(100));

        // Verify all 3 events received
        let mut count = 0;
        while server.recv_event().is_some() {
            count += 1;
        }
        assert_eq!(count, 3, "expected 3 events, got {count}");

        server.stop();
    }
}
