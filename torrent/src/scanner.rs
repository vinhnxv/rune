use color_eyre::{eyre::eyre, Result};
use glob::glob;
use std::fs;
use std::path::{Path, PathBuf};

/// A discovered Claude config directory (e.g. ~/.claude or ~/.claude-work).
#[derive(Debug, Clone)]
pub struct ConfigDir {
    pub path: PathBuf,
    pub label: String,
}

/// A plan file discovered in plans/*.md.
#[derive(Debug, Clone)]
pub struct PlanFile {
    pub path: PathBuf,
    pub name: String,
    pub title: String,
}

/// Scan $HOME for Claude config directories.
///
/// Matches:
/// - ~/.claude/ (default)
/// - ~/.claude-*/ (custom accounts)
///
/// Filters: must be a directory containing settings.json or projects/ subdirectory.
pub fn scan_config_dirs() -> Result<Vec<ConfigDir>> {
    let home = dirs::home_dir().ok_or_else(|| eyre!("cannot resolve home directory"))?;
    let mut configs = Vec::new();

    // Check ~/.claude/
    let default_dir = home.join(".claude");
    if is_valid_config_dir(&default_dir) {
        configs.push(ConfigDir {
            path: default_dir,
            label: ".claude (default)".into(),
        });
    }

    // Check ~/.claude-*/
    // SAFETY: home.display() may panic on non-UTF8 paths. We validate UTF-8 first.
    let home_str = home.to_string_lossy();
    let pattern = format!("{}/.claude-*/", home_str);
    for entry in glob(&pattern).map_err(|e| eyre!("invalid glob pattern: {e}"))? {
        match entry {
            Ok(path) if is_valid_config_dir(&path) => {
                let label = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.display().to_string());
                configs.push(ConfigDir { path, label });
            }
            _ => {}
        }
    }

    Ok(configs)
}

/// A valid config dir must contain settings.json or a projects/ subdirectory.
fn is_valid_config_dir(path: &Path) -> bool {
    path.is_dir() && (path.join("settings.json").exists() || path.join("projects").is_dir())
}

/// Scan plans/*.md in the given directory (non-recursive).
pub fn scan_plans(cwd: &Path) -> Result<Vec<PlanFile>> {
    let pattern = cwd.join("plans").join("*.md");
    let pattern_str = pattern.to_string_lossy();
    let mut plans = Vec::new();

    for entry in glob(&pattern_str).map_err(|e| eyre!("invalid glob pattern: {e}"))? {
        match entry {
            Ok(path) if path.is_file() => {
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let title = read_first_heading(&path).unwrap_or_else(|| name.clone());
                plans.push(PlanFile { path, name, title });
            }
            _ => {}
        }
    }

    plans.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(plans)
}

/// Extract the first markdown heading (# ...) from a file.
fn read_first_heading(path: &Path) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(heading) = trimmed.strip_prefix("# ") {
            return Some(heading.trim().to_string());
        }
    }
    None
}
