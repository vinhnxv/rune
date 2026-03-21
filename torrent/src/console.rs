//! Console logging with timestamps and log levels.
//!
//! Replaces raw `eprintln!` with structured output:
//!   `2026-03-22 14:30:05 [INFO] message here`
//!
//! Also writes to `.torrent/logs/console.log` for post-mortem debugging.
//! The TUI captures stderr, so console logs only appear after TUI exits
//! or in the log file.

use chrono::Local;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::sync::OnceLock;

/// Log file path (initialized once on first use).
static LOG_FILE: OnceLock<Option<std::path::PathBuf>> = OnceLock::new();

/// Initialize the console log file path.
fn log_file_path() -> &'static Option<std::path::PathBuf> {
    LOG_FILE.get_or_init(|| {
        let dir = crate::log::log_dir();
        if fs::create_dir_all(&dir).is_ok() {
            Some(dir.join("console.log"))
        } else {
            None
        }
    })
}

/// Write a formatted log line to both stderr and the log file.
pub fn log_line(level: &str, msg: &str) {
    let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S");
    let line = format!("{timestamp} [{level}] {msg}");

    // Write to stderr (visible after TUI exits or in non-TUI mode)
    eprintln!("{line}");

    // Append to log file (always available for debugging)
    if let Some(path) = log_file_path() {
        if let Ok(mut file) = OpenOptions::new().append(true).create(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
}

/// Structured log macros with timestamp and level.
///
/// Usage:
///   tlog!(INFO, "server started on port {}", port);
///   tlog!(WARN, "bridge unhealthy, falling back to tmux");
///   tlog!(ERROR, "callback server failed: {}", err);
#[macro_export]
macro_rules! tlog {
    (INFO, $($arg:tt)*) => {
        $crate::console::log_line("INFO", &format!($($arg)*))
    };
    (WARN, $($arg:tt)*) => {
        $crate::console::log_line("WARN", &format!($($arg)*))
    };
    (ERROR, $($arg:tt)*) => {
        $crate::console::log_line("ERROR", &format!($($arg)*))
    };
    (DEBUG, $($arg:tt)*) => {
        if std::env::var("TORRENT_DEBUG").is_ok() {
            $crate::console::log_line("DEBUG", &format!($($arg)*))
        }
    };
}
