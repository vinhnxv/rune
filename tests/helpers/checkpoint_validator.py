"""Checkpoint schema validation and artifact integrity checking.

Validates checkpoint.json against the v4 schema, checks artifact
file existence, and verifies SHA-256 hashes.
"""

from __future__ import annotations

import copy
import hashlib
import hmac
import json
from dataclasses import dataclass, field
from pathlib import Path

# Canonical phase ordering from arc.md
PHASE_ORDER = [
    "forge", "plan_review", "plan_refine", "verification", "work",
    "gap_analysis", "code_review", "mend", "verify_mend", "audit",
]

VALID_STATUSES = {"pending", "in_progress", "completed", "failed", "skipped", "timeout", "cancelled"}

PHASE_FIELDS = {"status", "artifact", "artifact_hash", "team_name"}

# Orchestrator-only phases (no team)
ORCHESTRATOR_ONLY = {"plan_refine", "verification", "gap_analysis", "verify_mend"}


@dataclass
class ValidationIssue:
    severity: str  # "error" | "warning"
    phase: str | None
    message: str


@dataclass
class CheckpointReport:
    """Result of validating a checkpoint."""

    valid: bool = True
    schema_version: int = 0
    phase_statuses: dict[str, str] = field(default_factory=dict)
    issues: list[ValidationIssue] = field(default_factory=list)
    artifact_checks: dict[str, bool] = field(default_factory=dict)
    hash_checks: dict[str, bool] = field(default_factory=dict)
    completed_phases: int = 0
    total_phases: int = len(PHASE_ORDER)

    def add_error(self, phase: str | None, message: str) -> None:
        self.issues.append(ValidationIssue("error", phase, message))
        self.valid = False

    def add_warning(self, phase: str | None, message: str) -> None:
        self.issues.append(ValidationIssue("warning", phase, message))


def sha256_file(path: Path) -> str:
    """Compute SHA-256 hex digest of a file.

    Reads in binary mode ("rb") so hashes are computed from raw bytes,
    ensuring consistent results across platforms regardless of line endings.
    """
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def _validate_metadata(checkpoint: dict, report: CheckpointReport) -> None:
    """Validate schema version, ID, and session nonce."""
    sv = checkpoint.get("schema_version")
    report.schema_version = sv or 0
    if sv != 4:
        report.add_error(None, f"Expected schema_version 4, got {sv}")

    arc_id = checkpoint.get("id", "")
    if not arc_id or not isinstance(arc_id, str):
        report.add_error(None, "Missing or invalid 'id' field")

    nonce = checkpoint.get("session_nonce", "")
    if not isinstance(nonce, str) or len(nonce) < 8:
        report.add_error(None, f"session_nonce should be at least 8 chars, got '{nonce}'")


def _validate_phase_entry(
    phase_name: str, phase: dict, report: CheckpointReport, workspace: Path | None,
) -> None:
    """Validate a single phase entry: fields, status, artifacts."""
    report.phase_statuses[phase_name] = phase.get("status", "MISSING")

    missing = PHASE_FIELDS - set(phase.keys())
    if missing:
        report.add_error(phase_name, f"Missing fields: {missing}")

    status = phase.get("status")
    if status not in VALID_STATUSES:
        report.add_error(phase_name, f"Invalid status: '{status}'")

    if status == "completed":
        report.completed_phases += 1

    if phase_name in ORCHESTRATOR_ONLY and phase.get("team_name") is not None:
        report.add_warning(phase_name, "Orchestrator-only phase has team_name set")

    if workspace and status == "completed":
        _validate_artifact(phase_name, phase, report, workspace)


def _validate_artifact(
    phase_name: str, phase: dict, report: CheckpointReport, workspace: Path,
) -> None:
    """Check artifact existence and hash integrity for a completed phase."""
    artifact_path = phase.get("artifact")
    expected_hash = phase.get("artifact_hash")

    if artifact_path:
        full_path = (workspace / artifact_path).resolve()
        if not full_path.is_relative_to(workspace.resolve()):
            report.add_error(phase_name, f"Artifact path escapes workspace: {artifact_path}")
            return
        exists = full_path.exists()
        report.artifact_checks[phase_name] = exists

        if not exists:
            report.add_error(phase_name, f"Artifact missing: {artifact_path}")
        elif expected_hash:
            actual_hash = sha256_file(full_path)
            expected_bare = expected_hash.removeprefix("sha256:")
            matches = hmac.compare_digest(actual_hash, expected_bare)
            report.hash_checks[phase_name] = matches
            if not matches:
                report.add_error(
                    phase_name,
                    f"Hash mismatch: expected {expected_bare[:16]}..., got {actual_hash[:16]}...",
                )
    elif phase_name not in ORCHESTRATOR_ONLY:
        report.add_warning(phase_name, "Completed phase has no artifact path")


def _validate_phases(checkpoint: dict, report: CheckpointReport, workspace: Path | None) -> bool:
    """Validate all phases. Returns False if phases dict is invalid (caller should abort)."""
    phases = checkpoint.get("phases", {})
    if not isinstance(phases, dict):
        report.add_error(None, "'phases' must be a dict")
        return False

    for phase_name in PHASE_ORDER:
        if phase_name not in phases:
            report.add_error(phase_name, f"Missing phase '{phase_name}' in checkpoint")
            continue

        phase = phases[phase_name]
        if not isinstance(phase, dict):
            report.add_error(phase_name, f"Phase value must be a dict, got {type(phase).__name__}")
            continue

        _validate_phase_entry(phase_name, phase, report, workspace)

    extra = set(phases.keys()) - set(PHASE_ORDER)
    if extra:
        report.add_warning(None, f"Unexpected phases in checkpoint: {extra}")

    return True


def _validate_convergence(checkpoint: dict, report: CheckpointReport) -> None:
    """Validate the convergence object."""
    conv = checkpoint.get("convergence")
    if not isinstance(conv, dict):
        report.add_error(None, "Missing or invalid 'convergence' object")
        return
    if "round" not in conv or "max_rounds" not in conv or "history" not in conv:
        report.add_error(None, "Convergence missing required fields (round, max_rounds, history)")
    if conv.get("max_rounds", 0) > 2:
        report.add_warning(None, f"max_rounds ({conv['max_rounds']}) exceeds CONVERGENCE_MAX_ROUNDS (2)")


def detect_duplicate_keys(filepath: Path) -> list[str]:
    """Detect duplicate top-level JSON keys in a checkpoint file.

    Uses object_pairs_hook to see all key-value pairs before deduplication.
    Returns a list of key names that appear more than once.
    """
    class _DupDetector:
        def __init__(self) -> None:
            self.duplicates: list[str] = []

        def check(self, pairs: list[tuple[str, object]]) -> dict:
            keys: dict[str, object] = {}
            for key, value in pairs:
                if key in keys:
                    self.duplicates.append(key)
                keys[key] = value
            return keys

    detector = _DupDetector()
    raw = filepath.read_text()
    json.loads(raw, object_pairs_hook=detector.check)
    # Deduplicate the list
    seen: set[str] = set()
    unique: list[str] = []
    for k in detector.duplicates:
        if k not in seen:
            seen.add(k)
            unique.append(k)
    return unique


def validate_checkpoint(
    checkpoint: dict,
    workspace: Path | None = None,
    filepath: Path | None = None,
) -> CheckpointReport:
    """Validate a checkpoint dict against the v4 schema.

    Args:
        checkpoint: Parsed checkpoint.json contents.
        workspace: If provided, also checks artifact files exist and hashes match.
        filepath: If provided, also checks for duplicate JSON keys in the raw file.
    """
    report = CheckpointReport()
    _validate_metadata(checkpoint, report)

    # Check for duplicate keys in raw JSON (LLM serialization bug)
    if filepath and filepath.exists():
        dup_keys = detect_duplicate_keys(filepath)
        if dup_keys:
            report.add_warning(None, f"Duplicate top-level JSON keys: {', '.join(dup_keys)}")

    if not _validate_phases(checkpoint, report, workspace):
        return report
    _validate_convergence(checkpoint, report)
    return report


def migrate_checkpoint(checkpoint: dict) -> dict:
    """Migrate a checkpoint from any schema version to v4.

    Returns a new dict (does not mutate input).
    """
    cp = copy.deepcopy(checkpoint)
    sv = cp.get("schema_version", 1)

    skipped_phase = {"status": "skipped", "artifact": None, "artifact_hash": None, "team_name": None}

    cp.setdefault("phases", {})

    if sv < 2:
        cp["phases"].setdefault("plan_refine", {**skipped_phase})
        cp["phases"].setdefault("verification", {**skipped_phase})
        cp["schema_version"] = 2
        sv = 2

    if sv < 3:
        cp["phases"].setdefault("verify_mend", {**skipped_phase})
        cp.setdefault("convergence", {"round": 0, "max_rounds": 2, "history": []})
        cp["schema_version"] = 3
        sv = 3

    if sv < 4:
        cp["phases"].setdefault("gap_analysis", {**skipped_phase})
        cp["schema_version"] = 4

    return cp


def load_checkpoint(workspace: Path, extra_search_dirs: list[Path] | None = None) -> dict | None:
    """Find and load the most recent checkpoint from a workspace.

    Searches multiple locations for checkpoint.json:
    1. {workspace}/.rune/arc/*/checkpoint.json (project-local)
    2. {workspace}/tmp/arc/*/checkpoint.json (tmp artifacts)
    3. Any extra_search_dirs (e.g., isolated config dir)

    Returns the most recently modified checkpoint found.
    """
    search_roots = [
        workspace / ".claude" / "arc",
        workspace / "tmp" / "arc",
    ]
    if extra_search_dirs:
        for d in extra_search_dirs:
            search_roots.append(d / "arc")
            # Also check project-specific paths inside config dir
            if d.exists():
                try:
                    for sub in d.iterdir():
                        if sub.is_dir():
                            arc_sub = sub / "arc"
                            if arc_sub.exists():
                                search_roots.append(arc_sub)
                except (PermissionError, OSError):
                    pass

    all_checkpoints: list[Path] = []
    resolved_workspace = workspace.resolve()
    for root in search_roots:
        if root.exists():
            for cp_path in root.glob("*/checkpoint.json"):
                # Validate discovered paths stay within workspace or declared search dirs
                resolved_cp = cp_path.resolve()
                if resolved_cp.is_relative_to(resolved_workspace):
                    all_checkpoints.append(cp_path)
                elif extra_search_dirs and any(
                    resolved_cp.is_relative_to(d.resolve()) for d in extra_search_dirs
                ):
                    all_checkpoints.append(cp_path)
                # Silently skip paths that escape all trusted roots

    if not all_checkpoints:
        return None

    newest = max(all_checkpoints, key=lambda p: p.stat().st_mtime)
    try:
        return json.loads(newest.read_text())
    except json.JSONDecodeError:
        return None
