use serde::Deserialize;
use std::collections::HashMap;

/// Arc checkpoint — identity and phase progress.
/// Read from: $CLAUDE_CONFIG_DIR/arc/arc-{id}/checkpoint.json
#[derive(Debug, Clone, Deserialize)]
pub struct Checkpoint {
    pub id: String,
    pub plan_file: String,
    #[serde(default)]
    pub config_dir: String,
    #[serde(default)]
    pub owner_pid: String,
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub phases: HashMap<String, PhaseStatus>,
    #[serde(default)]
    pub pr_url: Option<String>,
    #[serde(default)]
    pub commits: Vec<String>,
    #[serde(default)]
    pub started_at: String,
}

/// Status of a single arc phase (forge, work, ship, merge, etc.).
#[derive(Debug, Clone, Deserialize)]
pub struct PhaseStatus {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub started_at: Option<String>,
    #[serde(default)]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub team_name: Option<String>,
}

/// Arc heartbeat — liveness signal updated every ~30s.
/// Read from: tmp/arc/arc-{id}/heartbeat.json
#[derive(Debug, Clone, Deserialize)]
pub struct Heartbeat {
    #[serde(default)]
    pub arc_id: String,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub last_tool: String,
    #[serde(default)]
    pub last_activity: String,
}
