//! CWD-based instance lock for torrent.
//!
//! Prevents multiple torrent instances from running in the same directory,
//! which would cause git working tree conflicts and arc-phase-loop.local.md
//! cross-contamination.
//!
//! Lock file: `{CWD}/.torrent.lock` containing the PID of the owning process.
//! On startup, torrent checks if the lock exists and the PID is alive.

use std::fs;
use std::path::{Path, PathBuf};
use std::process;

const LOCK_FILENAME: &str = ".torrent.lock";

/// Outcome of attempting to acquire the instance lock.
pub enum LockResult {
    /// Lock acquired successfully. Caller must call `release()` on exit.
    Acquired(LockGuard),
    /// Another torrent instance is running with the given PID.
    AlreadyRunning { pid: u32, lock_path: PathBuf },
    /// Stale lock from a dead process — cleaned up and re-acquired.
    StaleRecovered(LockGuard),
}

/// RAII guard that releases the lock file on drop.
pub struct LockGuard {
    path: PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        // Only remove if still ours (check PID matches)
        if let Ok(contents) = fs::read_to_string(&self.path) {
            if let Ok(pid) = contents.trim().parse::<u32>() {
                if pid == process::id() {
                    let _ = fs::remove_file(&self.path);
                }
            }
        }
    }
}

/// Try to acquire the instance lock for the given directory.
pub fn acquire(dir: &Path) -> LockResult {
    let lock_path = dir.join(LOCK_FILENAME);
    let my_pid = process::id();

    // Check existing lock
    if let Ok(contents) = fs::read_to_string(&lock_path) {
        if let Ok(existing_pid) = contents.trim().parse::<u32>() {
            if existing_pid != my_pid && is_pid_alive(existing_pid) {
                return LockResult::AlreadyRunning {
                    pid: existing_pid,
                    lock_path,
                };
            }
            // Stale lock — process is dead, reclaim it
            write_lock(&lock_path, my_pid);
            return LockResult::StaleRecovered(LockGuard { path: lock_path });
        }
    }

    // No lock or invalid contents — acquire
    write_lock(&lock_path, my_pid);
    LockResult::Acquired(LockGuard { path: lock_path })
}

fn write_lock(path: &Path, pid: u32) {
    let _ = fs::write(path, pid.to_string());
}

fn is_pid_alive(pid: u32) -> bool {
    // kill -0 checks if process exists without sending a signal
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .output()
        .is_ok_and(|o| o.status.success())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_acquire_and_release() {
        let dir = std::env::temp_dir().join("torrent-lock-test");
        let _ = fs::create_dir_all(&dir);
        let lock_path = dir.join(LOCK_FILENAME);

        // Clean state
        let _ = fs::remove_file(&lock_path);

        // Acquire
        let result = acquire(&dir);
        assert!(matches!(result, LockResult::Acquired(_)));
        assert!(lock_path.exists());

        let contents = fs::read_to_string(&lock_path).unwrap();
        assert_eq!(contents.trim().parse::<u32>().unwrap(), process::id());

        // Drop releases
        match result {
            LockResult::Acquired(guard) => drop(guard),
            _ => unreachable!(),
        }
        assert!(!lock_path.exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_stale_lock_recovery() {
        let dir = std::env::temp_dir().join("torrent-lock-stale-test");
        let _ = fs::create_dir_all(&dir);
        let lock_path = dir.join(LOCK_FILENAME);

        // Write a lock with a dead PID (PID 1 is init, but 99999999 is very likely dead)
        fs::write(&lock_path, "99999999").unwrap();

        let result = acquire(&dir);
        assert!(matches!(result, LockResult::StaleRecovered(_)));

        // Verify our PID is now in the lock
        let contents = fs::read_to_string(&lock_path).unwrap();
        assert_eq!(contents.trim().parse::<u32>().unwrap(), process::id());

        match result {
            LockResult::StaleRecovered(guard) => drop(guard),
            _ => unreachable!(),
        }

        let _ = fs::remove_dir_all(&dir);
    }
}
