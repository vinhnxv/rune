//! Process resource monitoring via sysinfo.
//!
//! Tracks CPU and memory usage for the Claude Code process and its children.
//! Follows Melina's approach: sysinfo crate with 3-refresh trick for macOS.

use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

/// CPU/memory snapshot for a Claude Code session (root + children aggregated).
#[derive(Debug, Clone)]
pub struct ResourceSnapshot {
    /// Total CPU usage percent (root + children).
    pub cpu_percent: f32,
    /// Total memory in bytes (root + children).
    pub memory_bytes: u64,
    /// Number of child processes.
    pub child_count: u32,
    /// Process start time as epoch seconds (root only).
    pub start_time: u64,
}

impl ResourceSnapshot {
    /// Format memory as human-readable string (MB).
    pub fn memory_mb(&self) -> f32 {
        self.memory_bytes as f32 / (1024.0 * 1024.0)
    }
}

/// Staleness detection result combining heartbeat + resource signals.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessHealth {
    /// Process is active (CPU > threshold or recent heartbeat).
    Active,
    /// Process appears stale: low CPU + long uptime, but heartbeat may still be alive.
    LowCpu,
    /// Process is not found (exited or PID reused).
    NotFound,
}

impl ProcessHealth {
    pub fn label(&self) -> &'static str {
        match self {
            ProcessHealth::Active => "active",
            ProcessHealth::LowCpu => "low-cpu",
            ProcessHealth::NotFound => "not-found",
        }
    }
}

/// CPU threshold for stale detection (matches Melina's teammate threshold).
const CPU_STALE_THRESHOLD: f32 = 0.5;

/// Minimum uptime (seconds) before low-CPU triggers stale warning.
/// Short-lived processes may legitimately have low CPU during startup.
const UPTIME_STALE_THRESHOLD: u64 = 300; // 5 minutes

/// Create a `System` with accurate CPU values.
///
/// macOS requires 3 refreshes for `cpu_usage()` to return non-zero values:
/// 1. `new_all()` — initializes global CPU state + first process snapshot
/// 2. `refresh_all()` — sets the CPU time baseline
/// 3. sleep + `refresh_processes()` — calculates CPU delta
///
/// After initial creation, only `refresh_process_system()` is needed for updates.
pub fn create_process_system() -> System {
    let mut sys = System::new_all();
    sys.refresh_all();
    std::thread::sleep(std::time::Duration::from_millis(200));
    sys.refresh_processes(ProcessesToUpdate::All, true);
    sys
}

/// Lightweight refresh for an existing System — minimal overhead.
///
/// Uses `refresh_processes_specifics` with `cmd` and `exe` set to `OnlyIfNotSet`
/// so that newly discovered processes get their command line populated.
pub fn refresh_process_system(sys: &mut System) {
    sys.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing()
            .with_memory()
            .with_cpu()
            .with_cmd(UpdateKind::OnlyIfNotSet)
            .with_exe(UpdateKind::OnlyIfNotSet),
    );
}

/// Check if a process with the given PID is alive (exists and is signalable).
///
/// Uses `kill -0` which checks existence without sending a signal.
/// Shared utility — used by lock.rs, app.rs, and scanner.rs.
pub fn is_pid_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .output()
        .is_ok_and(|o| o.status.success())
}

/// Take a resource snapshot for a Claude Code process and all its children.
///
/// Aggregates CPU and memory across the entire process tree rooted at `pid`.
/// Returns `None` if the root process is not found.
pub fn snapshot(sys: &System, pid: u32) -> Option<ResourceSnapshot> {
    let root = sys.process(Pid::from_u32(pid))?;

    let mut total_cpu = root.cpu_usage();
    let mut total_mem = root.memory();
    let mut child_count = 0u32;

    // Walk all processes to find children (any depth)
    let descendants = collect_descendants(sys, pid);
    for desc_pid in &descendants {
        if let Some(proc_) = sys.process(Pid::from_u32(*desc_pid)) {
            total_cpu += proc_.cpu_usage();
            total_mem += proc_.memory();
            child_count += 1;
        }
    }

    Some(ResourceSnapshot {
        cpu_percent: total_cpu,
        memory_bytes: total_mem,
        child_count,
        start_time: root.start_time(),
    })
}

/// Check process health based on CPU usage and uptime.
///
/// Combines resource-level signals with time-based thresholds:
/// - CPU < 0.5% + uptime > 5 minutes → LowCpu (potential stale)
/// - Process not found → NotFound
/// - Otherwise → Active
pub fn check_health(sys: &System, pid: u32) -> ProcessHealth {
    let snap = match snapshot(sys, pid) {
        Some(s) => s,
        None => return ProcessHealth::NotFound,
    };

    let now = now_epoch();
    let uptime_secs = now.saturating_sub(snap.start_time);

    if snap.cpu_percent < CPU_STALE_THRESHOLD && uptime_secs > UPTIME_STALE_THRESHOLD {
        return ProcessHealth::LowCpu;
    }

    ProcessHealth::Active
}

/// Collect all descendant PIDs of a given root PID (breadth-first).
///
/// Builds a parent→children index in O(n) first, then BFS over the index.
/// Previously was O(n*d) where n=all processes and d=tree depth.
pub fn collect_descendants(sys: &System, root_pid: u32) -> Vec<u32> {
    use std::collections::HashMap;

    // Build parent→children index in a single pass over all processes
    let mut children_map: HashMap<u32, Vec<u32>> = HashMap::new();
    for (pid, proc_) in sys.processes() {
        if let Some(parent) = proc_.parent() {
            children_map
                .entry(parent.as_u32())
                .or_default()
                .push(pid.as_u32());
        }
    }

    // BFS using the index — O(d) lookups instead of O(n*d) scans
    let mut result = Vec::new();
    let mut queue = vec![root_pid];

    while let Some(parent) = queue.pop() {
        if let Some(kids) = children_map.get(&parent) {
            for &child_pid in kids {
                if child_pid != root_pid && !result.contains(&child_pid) {
                    result.push(child_pid);
                    queue.push(child_pid);
                }
            }
        }
    }

    result
}

/// Current time as epoch seconds.
fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resource_snapshot_memory_mb() {
        let snap = ResourceSnapshot {
            cpu_percent: 5.0,
            memory_bytes: 256 * 1024 * 1024, // 256 MB
            child_count: 3,
            start_time: 0,
        };
        let mb = snap.memory_mb();
        assert!((mb - 256.0).abs() < 0.01);
    }

    #[test]
    fn test_process_health_labels() {
        assert_eq!(ProcessHealth::Active.label(), "active");
        assert_eq!(ProcessHealth::LowCpu.label(), "low-cpu");
        assert_eq!(ProcessHealth::NotFound.label(), "not-found");
    }

    #[test]
    fn test_snapshot_nonexistent_pid() {
        let sys = System::new();
        // PID 0 should not exist as a user process
        assert!(snapshot(&sys, 0).is_none());
    }

    #[test]
    fn test_check_health_nonexistent_pid() {
        let sys = System::new();
        assert_eq!(check_health(&sys, 0), ProcessHealth::NotFound);
    }

    #[test]
    fn test_collect_descendants_empty_system() {
        let sys = System::new();
        let desc = collect_descendants(&sys, 12345);
        assert!(desc.is_empty());
    }

    #[test]
    fn test_create_and_refresh_system() {
        // Smoke test: just ensure these don't panic
        let mut sys = create_process_system();
        refresh_process_system(&mut sys);
        // Should have at least our own process
        assert!(!sys.processes().is_empty());
    }

    #[test]
    fn test_snapshot_own_process() {
        // Take a snapshot of our own test process — should succeed
        let sys = create_process_system();
        let own_pid = std::process::id();
        let snap = snapshot(&sys, own_pid);
        assert!(snap.is_some(), "should find own process");
        let snap = snap.unwrap();
        assert!(snap.memory_bytes > 0, "should report non-zero memory");
        assert!(snap.start_time > 0, "should have start time");
    }
}
