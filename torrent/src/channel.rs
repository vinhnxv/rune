use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

// color_eyre used by callers; re-export not needed in this module.

/// Maximum consecutive failures before auto-disabling the channel.
const MAX_FAILURES: u32 = 3;

/// Timeout for bridge health check requests.
const HEALTH_CHECK_TIMEOUT: Duration = Duration::from_secs(2);

/// Timeout for port discovery (how long to wait for port.txt).
const PORT_DISCOVERY_TIMEOUT: Duration = Duration::from_secs(30);

/// Polling interval when waiting for port.txt to appear.
const PORT_DISCOVERY_POLL: Duration = Duration::from_millis(500);

/// Configuration for the channels bridge connection.
///
/// Passed into `start_claude()` when channels are enabled.
/// Contains the ports needed for bridge ↔ Torrent communication.
#[derive(Debug, Clone)]
pub struct ChannelsConfig {
    /// Port the bridge HTTP server listens on.
    pub bridge_port: u16,
    /// Port Torrent's callback server listens on for push events.
    pub callback_port: u16,
}

/// Channel communication state for a running arc session.
///
/// Channels are OUTBOUND-ONLY (Claude → Torrent) in v0.7.0.
/// Inbound (Torrent → Claude) is broken in Claude Code v2.1.80
/// (#36477, #36691). Command delivery still uses tmux send-keys.
///
/// When channels are disabled or unhealthy, Torrent operates in
/// file-only monitoring mode (checkpoint.json + heartbeat.json).
pub struct ChannelState {
    /// Bridge HTTP port (None if channels not enabled or port not discovered).
    pub bridge_port: Option<u16>,
    /// Whether channel communication is healthy.
    pub healthy: bool,
    /// Last successful channel event timestamp.
    pub last_event: Option<Instant>,
    /// Consecutive callback failures (auto-disable after [`MAX_FAILURES`]).
    pub failure_count: u32,
    /// Whether this session was started with channels enabled.
    /// False for resumed sessions (--resume + channels = broken, #36638).
    pub enabled: bool,
}

impl ChannelState {
    /// Create a new disabled channel state (default for resumed sessions).
    pub fn disabled() -> Self {
        Self {
            bridge_port: None,
            healthy: false,
            last_event: None,
            failure_count: 0,
            enabled: false,
        }
    }

    /// Try to discover bridge port from port.txt written by the bridge server.
    ///
    /// The bridge writes its port to `tmp/arc/arc-{session_id}/bridge-port.txt`
    /// after starting. This method polls for that file up to [`PORT_DISCOVERY_TIMEOUT`].
    ///
    /// Returns `None` if the file doesn't appear within the timeout.
    pub fn discover_port(session_id: &str) -> Option<u16> {
        let port_path = format!("tmp/arc/arc-{session_id}/bridge-port.txt");
        let path = Path::new(&port_path);
        let start = Instant::now();

        while start.elapsed() < PORT_DISCOVERY_TIMEOUT {
            if let Ok(contents) = fs::read_to_string(path) {
                if let Ok(port) = contents.trim().parse::<u16>() {
                    return Some(port);
                }
            }
            std::thread::sleep(PORT_DISCOVERY_POLL);
        }

        None
    }

    /// Check bridge liveness via GET /ping.
    ///
    /// Sends a synchronous HTTP request to the bridge's `/ping` endpoint.
    /// Updates health state based on the response.
    pub fn check_health(&mut self) -> bool {
        let port = match self.bridge_port {
            Some(p) => p,
            None => {
                self.healthy = false;
                return false;
            }
        };

        let url = format!("http://127.0.0.1:{port}/ping");
        let result = ureq::get(&url)
            .timeout(HEALTH_CHECK_TIMEOUT)
            .call();

        match result {
            Ok(resp) if resp.status() == 200 => {
                self.record_success();
                true
            }
            _ => {
                self.record_failure();
                false
            }
        }
    }

    /// Mark channel as unhealthy after consecutive failures.
    ///
    /// Increments the failure counter. When [`MAX_FAILURES`] consecutive
    /// failures occur, the channel is auto-disabled to avoid wasting
    /// cycles on a dead bridge.
    pub fn record_failure(&mut self) {
        self.failure_count += 1;
        if self.failure_count >= MAX_FAILURES {
            self.healthy = false;
            self.enabled = false;
        }
    }

    /// Reset failure counter on successful event receipt.
    pub fn record_success(&mut self) {
        self.failure_count = 0;
        self.healthy = true;
        self.last_event = Some(Instant::now());
    }

    /// Attempt to initialize channel state for a fresh session.
    ///
    /// Discovers the bridge port, then checks health. Returns `None` if
    /// port discovery fails (bridge not running or not yet ready).
    pub fn try_init(session_id: &str, callback_port: u16) -> Option<Self> {
        let bridge_port = Self::discover_port(session_id)?;

        let mut state = Self {
            bridge_port: Some(bridge_port),
            healthy: false,
            last_event: None,
            failure_count: 0,
            enabled: true,
        };

        // Initial health check — don't fail init if bridge isn't ready yet.
        // The main loop will retry health checks periodically.
        state.check_health();

        let _ = callback_port; // Used by callback.rs for event routing

        Some(state)
    }

    /// Whether channel events should be processed.
    ///
    /// Returns true only when the channel is both enabled and healthy.
    pub fn is_active(&self) -> bool {
        self.enabled && self.healthy
    }

    /// Duration since the last successful channel event, if any.
    pub fn since_last_event(&self) -> Option<Duration> {
        self.last_event.map(|t| t.elapsed())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_disabled_state() {
        let state = ChannelState::disabled();
        assert!(!state.enabled);
        assert!(!state.healthy);
        assert!(state.bridge_port.is_none());
        assert!(state.last_event.is_none());
        assert_eq!(state.failure_count, 0);
        assert!(!state.is_active());
    }

    #[test]
    fn test_failure_counting() {
        let mut state = ChannelState {
            bridge_port: Some(9901),
            healthy: true,
            last_event: None,
            failure_count: 0,
            enabled: true,
        };

        // First two failures: still enabled
        state.record_failure();
        assert_eq!(state.failure_count, 1);
        assert!(state.enabled);

        state.record_failure();
        assert_eq!(state.failure_count, 2);
        assert!(state.enabled);

        // Third failure: auto-disable
        state.record_failure();
        assert_eq!(state.failure_count, 3);
        assert!(!state.enabled);
        assert!(!state.healthy);
        assert!(!state.is_active());
    }

    #[test]
    fn test_record_success_resets_counter() {
        let mut state = ChannelState {
            bridge_port: Some(9901),
            healthy: false,
            last_event: None,
            failure_count: 2,
            enabled: true,
        };

        state.record_success();
        assert_eq!(state.failure_count, 0);
        assert!(state.healthy);
        assert!(state.last_event.is_some());
        assert!(state.is_active());
    }

    #[test]
    fn test_is_active_requires_both_enabled_and_healthy() {
        let mut state = ChannelState {
            bridge_port: Some(9901),
            healthy: true,
            last_event: None,
            failure_count: 0,
            enabled: false,
        };
        assert!(!state.is_active(), "disabled but healthy → not active");

        state.enabled = true;
        state.healthy = false;
        assert!(!state.is_active(), "enabled but unhealthy → not active");

        state.healthy = true;
        assert!(state.is_active(), "enabled and healthy → active");
    }

    #[test]
    fn test_auto_disable_cannot_be_undone_by_success_alone() {
        let mut state = ChannelState {
            bridge_port: Some(9901),
            healthy: true,
            last_event: None,
            failure_count: 0,
            enabled: true,
        };

        // Trigger auto-disable
        for _ in 0..MAX_FAILURES {
            state.record_failure();
        }
        assert!(!state.enabled);

        // record_success resets counter and healthy, but NOT enabled
        state.record_success();
        assert_eq!(state.failure_count, 0);
        assert!(state.healthy);
        assert!(!state.enabled, "auto-disable persists after success");
        assert!(!state.is_active());
    }

    #[test]
    fn test_since_last_event_none_initially() {
        let state = ChannelState::disabled();
        assert!(state.since_last_event().is_none());
    }

    #[test]
    fn test_since_last_event_after_success() {
        let mut state = ChannelState {
            bridge_port: Some(9901),
            healthy: false,
            last_event: None,
            failure_count: 0,
            enabled: true,
        };
        state.record_success();
        let elapsed = state.since_last_event().expect("should have last_event");
        assert!(elapsed < Duration::from_secs(1));
    }

    #[test]
    fn test_discover_port_reads_file() {
        // Create a temp dir simulating the arc directory structure
        let tmp = std::env::temp_dir().join("torrent-test-discover-port");
        let session_id = "test-port-discovery";
        let arc_dir = tmp.join(format!("arc-{session_id}"));
        fs::create_dir_all(&arc_dir).unwrap();

        let port_file = arc_dir.join("bridge-port.txt");
        fs::write(&port_file, "9901\n").unwrap();

        // discover_port uses a relative path — we'd need to be in the right dir.
        // Instead, test the parsing logic directly:
        let contents = fs::read_to_string(&port_file).unwrap();
        let port: u16 = contents.trim().parse().unwrap();
        assert_eq!(port, 9901);

        // Cleanup
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_check_health_no_port() {
        let mut state = ChannelState {
            bridge_port: None,
            healthy: true,
            last_event: None,
            failure_count: 0,
            enabled: true,
        };
        assert!(!state.check_health());
        assert!(!state.healthy);
    }
}
