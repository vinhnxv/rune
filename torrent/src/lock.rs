//! CWD-based instance lock for torrent.
//!
//! Prevents multiple torrent instances from running in the same directory,
//! which would cause git working tree conflicts and arc-phase-loop.local.md
//! cross-contamination.
//!
//! Lock file: `{CWD}/.torrent.lock` containing the PID of the owning process.
//! On startup, torrent checks if the lock exists and the PID is alive.

use std::fs::{self, OpenOptions};
use std::io::Write;
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

    // Attempt atomic file creation (O_CREAT|O_EXCL) — fails if file already exists.
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
    {
        Ok(mut file) => {
            let _ = file.write_all(my_pid.to_string().as_bytes());
            LockResult::Acquired(LockGuard { path: lock_path })
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // Lock file exists — check if the owning process is still alive
            if let Ok(contents) = fs::read_to_string(&lock_path) {
                if let Ok(existing_pid) = contents.trim().parse::<u32>() {
                    if existing_pid == my_pid {
                        // We already hold this lock (re-entrant)
                        return LockResult::Acquired(LockGuard { path: lock_path });
                    }
                    if is_pid_alive(existing_pid) {
                        return LockResult::AlreadyRunning {
                            pid: existing_pid,
                            lock_path,
                        };
                    }
                }
            }
            // Stale lock — remove and retry atomically
            let _ = fs::remove_file(&lock_path);
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&lock_path)
            {
                Ok(mut file) => {
                    let _ = file.write_all(my_pid.to_string().as_bytes());
                    LockResult::StaleRecovered(LockGuard { path: lock_path })
                }
                Err(_) => {
                    // Another process won the race for the stale lock — treat as already running
                    let pid = fs::read_to_string(&lock_path)
                        .ok()
                        .and_then(|s| s.trim().parse::<u32>().ok())
                        .unwrap_or(0);
                    LockResult::AlreadyRunning { pid, lock_path }
                }
            }
        }
        Err(_) => {
            // Unexpected I/O error (permissions, disk full, etc.) — treat as acquired
            // to avoid blocking startup; the lock is best-effort protection.
            let _ = fs::write(&lock_path, my_pid.to_string());
            LockResult::Acquired(LockGuard { path: lock_path })
        }
    }
}

fn is_pid_alive(pid: u32) -> bool {
    crate::resource::is_pid_alive(pid)
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
