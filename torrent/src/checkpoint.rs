use serde::Deserialize;
use std::collections::HashMap;

/// Schema version range that Torrent has been tested against.
/// - MIN: oldest checkpoint format we can reliably parse
/// - MAX: newest checkpoint format we've verified
///
/// Versions outside this range trigger warnings but don't hard-fail,
/// since serde ignores unknown fields gracefully.
pub const SCHEMA_VERSION_MIN: u32 = 20;
pub const SCHEMA_VERSION_MAX: u32 = 30;

/// Result of schema version validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SchemaCompat {
    /// Version within tested range — safe to use.
    Compatible,
    /// Version newer than tested — may have structural changes.
    Newer { version: u32 },
    /// Version older than tested — may lack expected fields.
    Older { version: u32 },
    /// No schema_version field present — legacy checkpoint.
    Unknown,
}

impl SchemaCompat {
    /// Human-readable warning message, or None if compatible.
    pub fn warning(&self) -> Option<String> {
        match self {
            SchemaCompat::Compatible => None,
            SchemaCompat::Newer { version } => Some(format!(
                "checkpoint schema v{} is newer than tested range (v{}-v{}). \
                 Torrent may miss new fields — consider updating.",
                version, SCHEMA_VERSION_MIN, SCHEMA_VERSION_MAX
            )),
            SchemaCompat::Older { version } => Some(format!(
                "checkpoint schema v{} is older than tested range (v{}-v{}). \
                 Phase structure may differ.",
                version, SCHEMA_VERSION_MIN, SCHEMA_VERSION_MAX
            )),
            SchemaCompat::Unknown => Some(
                "checkpoint has no schema_version — legacy format, parsing best-effort.".into(),
            ),
        }
    }
}

/// Arc checkpoint — identity and phase progress.
/// Read from: .claude/arc/arc-{id}/checkpoint.json
#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)] // serde fields read from JSON, not all accessed in Rust
pub struct Checkpoint {
    pub id: String,
    #[serde(default)]
    pub schema_version: Option<u32>,
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

impl Checkpoint {
    /// Check if this checkpoint's schema version is within Torrent's tested range.
    pub fn schema_compat(&self) -> SchemaCompat {
        match self.schema_version {
            Some(v) if v < SCHEMA_VERSION_MIN => SchemaCompat::Older { version: v },
            Some(v) if v > SCHEMA_VERSION_MAX => SchemaCompat::Newer { version: v },
            Some(_) => SchemaCompat::Compatible,
            None => SchemaCompat::Unknown,
        }
    }
}

/// Status of a single arc phase (forge, work, ship, merge, etc.).
#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)] // serde fields
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
#[allow(dead_code)] // serde fields
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

#[cfg(test)]
mod tests {
    use super::*;

    fn make_checkpoint(schema_version: Option<u32>) -> Checkpoint {
        Checkpoint {
            id: "arc-test".into(),
            schema_version,
            plan_file: "plans/test.md".into(),
            config_dir: String::new(),
            owner_pid: String::new(),
            session_id: String::new(),
            phases: std::collections::HashMap::new(),
            pr_url: None,
            commits: vec![],
            started_at: "2026-03-17T00:00:00Z".into(),
        }
    }

    #[test]
    fn test_schema_compat_in_range() {
        let cp = make_checkpoint(Some(24));
        assert_eq!(cp.schema_compat(), SchemaCompat::Compatible);
        assert!(cp.schema_compat().warning().is_none());
    }

    #[test]
    fn test_schema_compat_at_boundaries() {
        let min = make_checkpoint(Some(SCHEMA_VERSION_MIN));
        assert_eq!(min.schema_compat(), SchemaCompat::Compatible);

        let max = make_checkpoint(Some(SCHEMA_VERSION_MAX));
        assert_eq!(max.schema_compat(), SchemaCompat::Compatible);
    }

    #[test]
    fn test_schema_compat_newer() {
        let cp = make_checkpoint(Some(31));
        assert_eq!(cp.schema_compat(), SchemaCompat::Newer { version: 31 });
        assert!(cp.schema_compat().warning().unwrap().contains("newer"));
    }

    #[test]
    fn test_schema_compat_older() {
        let cp = make_checkpoint(Some(10));
        assert_eq!(cp.schema_compat(), SchemaCompat::Older { version: 10 });
        assert!(cp.schema_compat().warning().unwrap().contains("older"));
    }

    #[test]
    fn test_schema_compat_unknown() {
        let cp = make_checkpoint(None);
        assert_eq!(cp.schema_compat(), SchemaCompat::Unknown);
        assert!(cp.schema_compat().warning().unwrap().contains("legacy"));
    }

    #[test]
    fn test_deserialize_with_schema_version() {
        let json = r#"{
            "id": "arc-v24",
            "schema_version": 24,
            "plan_file": "plans/test.md",
            "phases": {},
            "started_at": "2026-03-17T00:00:00Z"
        }"#;
        let cp: Checkpoint = serde_json::from_str(json).unwrap();
        assert_eq!(cp.schema_version, Some(24));
        assert_eq!(cp.schema_compat(), SchemaCompat::Compatible);
    }

    #[test]
    fn test_deserialize_without_schema_version() {
        let json = r#"{
            "id": "arc-legacy",
            "plan_file": "plans/test.md",
            "phases": {},
            "started_at": "2026-03-17T00:00:00Z"
        }"#;
        let cp: Checkpoint = serde_json::from_str(json).unwrap();
        assert_eq!(cp.schema_version, None);
        assert_eq!(cp.schema_compat(), SchemaCompat::Unknown);
    }

    #[test]
    fn test_deserialize_ignores_unknown_fields() {
        // Simulates a v24 checkpoint with fields Torrent doesn't know about
        let json = r#"{
            "id": "arc-future",
            "schema_version": 24,
            "plan_file": "plans/test.md",
            "flags": {"approve": false},
            "arc_config": {"no_forge": false},
            "skip_map": {},
            "convergence": {"round": 0},
            "worktree": {"is_worktree": false},
            "resume_tracking": {},
            "phases": {
                "merge": {"status": "completed", "artifact": "report.md"}
            },
            "started_at": "2026-03-17T00:00:00Z"
        }"#;
        let cp: Checkpoint = serde_json::from_str(json).unwrap();
        assert_eq!(cp.schema_version, Some(24));
        // PhaseStatus also ignores unknown fields like "artifact"
        assert_eq!(cp.phases["merge"].status, "completed");
    }
}
