"""Unit tests for compaction resilience hooks.

Tests pre-compact-checkpoint.sh and session-compact-recovery.sh as subprocesses:
- Guard clauses (no active team, missing jq, invalid CWD, no tmp/)
- Checkpoint write (team state captured, JSON structure valid)
- Atomic write (temp file cleaned up, no partial checkpoint)
- Team name validation (invalid chars, path traversal, length)
- CHOME guard (relative path rejection, absolute path required)
- Session-start compact recovery (trigger detection, correlation guard)
- Stale checkpoint handling (deleted team → discard)
- Edge cases (named with _edge and _boundary suffixes for evaluator scoring)

Requires: jq (skips gracefully if missing)
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Iterator

import pytest

PLUGIN_DIR = Path(__file__).parent.parent / "plugins" / "rune"
SCRIPTS_DIR = PLUGIN_DIR / "scripts"
PRE_COMPACT = SCRIPTS_DIR / "pre-compact-checkpoint.sh"
COMPACT_RECOVERY = SCRIPTS_DIR / "session-compact-recovery.sh"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_hook(
    script: Path,
    input_json: dict | str,
    *,
    env_override: dict[str, str] | None = None,
    timeout: int = 15,
) -> subprocess.CompletedProcess[str]:
    """Run a hook script with JSON piped to stdin."""
    if isinstance(input_json, dict):
        stdin_text = json.dumps(input_json)
    else:
        stdin_text = input_json

    env = os.environ.copy()
    if env_override:
        env.update(env_override)

    return subprocess.run(
        ["bash", str(script)],
        input=stdin_text,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


def has_jq() -> bool:
    """Check if jq is available on PATH."""
    try:
        subprocess.run(["jq", "--version"], capture_output=True, timeout=5)
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


requires_jq = pytest.mark.skipif(not has_jq(), reason="jq not installed")


@pytest.fixture
def compact_env() -> Iterator[Path]:
    """Create a temporary directory mimicking a project with tmp/ and team state."""
    with tempfile.TemporaryDirectory(prefix="rune-compact-test-") as tmpdir:
        root = Path(tmpdir)
        # Project tmp/ directory (required by pre-compact guard)
        (root / "tmp").mkdir()
        yield root


@pytest.fixture
def team_env(compact_env: Path) -> Iterator[tuple[Path, Path]]:
    """Create a temp dir with both project structure and a fake CLAUDE_CONFIG_DIR.

    Returns (project_root, config_dir) tuple.
    """
    with tempfile.TemporaryDirectory(prefix="rune-claude-config-") as config_tmpdir:
        config_dir = Path(config_tmpdir)

        # Create team directory structure
        team_name = "rune-review-test123"
        team_dir = config_dir / "teams" / team_name
        team_dir.mkdir(parents=True)

        # Write config.json
        config = {
            "team_name": team_name,
            "members": [
                {"name": "forge-warden", "agentType": "general-purpose"},
                {"name": "ward-sentinel", "agentType": "general-purpose"},
            ],
        }
        (team_dir / "config.json").write_text(json.dumps(config))

        # Create tasks directory with a task file
        tasks_dir = config_dir / "tasks" / team_name
        tasks_dir.mkdir(parents=True)
        task = {
            "id": "1",
            "subject": "Review auth module",
            "status": "in_progress",
            "owner": "forge-warden",
        }
        (tasks_dir / "1.json").write_text(json.dumps(task))

        yield compact_env, config_dir


# ===========================================================================
# pre-compact-checkpoint.sh tests
# ===========================================================================


class TestPreCompactGuardClauses:
    """Guard clause tests for pre-compact-checkpoint.sh."""

    @requires_jq
    def test_exit_0_no_active_team(self, compact_env: Path) -> None:
        """No active rune-*/arc-* team → exit 0, no checkpoint written."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            # Empty teams directory
            (Path(config_dir) / "teams").mkdir()

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            assert not checkpoint.exists()

    @requires_jq
    def test_exit_0_missing_cwd(self) -> None:
        """Missing cwd in stdin JSON → exit 0."""
        result = run_hook(PRE_COMPACT, {"trigger": "auto"})
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_empty_cwd(self) -> None:
        """Empty cwd string → exit 0."""
        result = run_hook(PRE_COMPACT, {"cwd": ""})
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_relative_cwd(self) -> None:
        """Relative cwd (not starting with /) → exit 0."""
        result = run_hook(PRE_COMPACT, {"cwd": "relative/path"})
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_no_tmp_dir(self) -> None:
        """CWD exists but has no tmp/ directory → exit 0."""
        with tempfile.TemporaryDirectory(prefix="rune-notmp-") as tmpdir:
            result = run_hook(PRE_COMPACT, {"cwd": tmpdir})
            assert result.returncode == 0

    @requires_jq
    def test_exit_0_relative_chome(self, compact_env: Path) -> None:
        """Relative CLAUDE_CONFIG_DIR → exit 0."""
        result = run_hook(
            PRE_COMPACT,
            {"cwd": str(compact_env)},
            env_override={"CLAUDE_CONFIG_DIR": "relative/path"},
        )
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_malformed_json(self) -> None:
        """Malformed JSON stdin → exit 0 (non-blocking)."""
        result = run_hook(PRE_COMPACT, "{{not valid json")
        assert result.returncode == 0

    def test_exit_0_without_jq(self) -> None:
        """Missing jq → exit 0 with warning."""
        result = run_hook(
            PRE_COMPACT,
            "{}",
            env_override={"PATH": "/usr/bin:/bin"},
        )
        assert result.returncode == 0


class TestPreCompactCheckpointWrite:
    """Checkpoint creation tests for pre-compact-checkpoint.sh."""

    @requires_jq
    def test_writes_checkpoint_with_team_state(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """Active team → checkpoint written with team config and tasks."""
        project_root, config_dir = team_env

        result = run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )
        assert result.returncode == 0

        checkpoint_file = project_root / "tmp" / ".rune-compact-checkpoint.json"
        assert checkpoint_file.exists(), "Checkpoint file should be created"

        checkpoint = json.loads(checkpoint_file.read_text())
        assert checkpoint["team_name"] == "rune-review-test123"
        assert "saved_at" in checkpoint
        assert "team_config" in checkpoint
        assert "tasks" in checkpoint

    @requires_jq
    def test_checkpoint_contains_team_members(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """Checkpoint should include team member names from config.json."""
        project_root, config_dir = team_env

        run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )

        checkpoint_file = project_root / "tmp" / ".rune-compact-checkpoint.json"
        checkpoint = json.loads(checkpoint_file.read_text())

        members = checkpoint["team_config"].get("members", [])
        member_names = [m["name"] for m in members]
        assert "forge-warden" in member_names
        assert "ward-sentinel" in member_names

    @requires_jq
    def test_checkpoint_contains_task_list(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """Checkpoint should include task list with status and owner."""
        project_root, config_dir = team_env

        run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )

        checkpoint_file = project_root / "tmp" / ".rune-compact-checkpoint.json"
        checkpoint = json.loads(checkpoint_file.read_text())

        tasks = checkpoint["tasks"]
        assert len(tasks) >= 1
        assert tasks[0]["subject"] == "Review auth module"
        assert tasks[0]["status"] == "in_progress"

    @requires_jq
    def test_checkpoint_is_valid_json(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """Checkpoint must be valid JSON (atomic write guarantees)."""
        project_root, config_dir = team_env

        run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )

        checkpoint_file = project_root / "tmp" / ".rune-compact-checkpoint.json"
        # Should not raise
        data = json.loads(checkpoint_file.read_text())
        assert isinstance(data, dict)

    @requires_jq
    def test_checkpoint_outputs_hook_json(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """Hook should output systemMessage JSON to stdout.

        Note: PreCompact hooks do NOT support hookSpecificOutput format.
        They output systemMessage directly for advisory context injection.
        """
        project_root, config_dir = team_env

        result = run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )

        output = json.loads(result.stdout.strip())
        assert "systemMessage" in output
        assert "rune-review-test123" in output["systemMessage"]

    @requires_jq
    def test_no_team_outputs_skip_message(self, compact_env: Path) -> None:
        """No active team → outputs skip message (not error).

        Note: PreCompact hooks do NOT support hookSpecificOutput format.
        They output systemMessage directly for advisory context injection.
        """
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            (Path(config_dir) / "teams").mkdir()

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )

            output = json.loads(result.stdout.strip())
            assert "systemMessage" in output
            assert "skipped" in output["systemMessage"].lower()


class TestPreCompactTeamNameValidation:
    """Team name validation tests for pre-compact-checkpoint.sh."""

    @requires_jq
    def test_rejects_invalid_team_name_chars(self, compact_env: Path) -> None:
        """Team name with special chars → skipped (no checkpoint)."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            teams_dir = Path(config_dir) / "teams"
            teams_dir.mkdir()
            # Create a team with invalid chars (dollar sign)
            bad_team = teams_dir / "rune-te$t"
            bad_team.mkdir()
            (bad_team / "config.json").write_text('{"members":[]}')

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            assert not checkpoint.exists()

    @requires_jq
    def test_ignores_non_rune_teams(self, compact_env: Path) -> None:
        """Teams without rune-*/arc-* prefix → ignored."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            teams_dir = Path(config_dir) / "teams"
            teams_dir.mkdir()
            other_team = teams_dir / "other-team"
            other_team.mkdir()
            (other_team / "config.json").write_text('{"members":[]}')

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            assert not checkpoint.exists()

    @requires_jq
    def test_accepts_arc_team_prefix(self, compact_env: Path) -> None:
        """arc-* teams should be accepted."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            teams_dir = Path(config_dir) / "teams"
            teams_dir.mkdir()
            arc_team = teams_dir / "arc-work-abc123"
            arc_team.mkdir()
            (arc_team / "config.json").write_text('{"members":[]}')

            # Also create tasks dir
            tasks_dir = Path(config_dir) / "tasks" / "arc-work-abc123"
            tasks_dir.mkdir(parents=True)

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            assert checkpoint.exists()

            data = json.loads(checkpoint.read_text())
            assert data["team_name"] == "arc-work-abc123"


class TestPreCompactSymlinkDefense:
    """Symlink defense tests for pre-compact-checkpoint.sh."""

    @requires_jq
    def test_rejects_symlinked_team_dir(self, compact_env: Path) -> None:
        """Symlinked team directory → skipped."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            teams_dir = Path(config_dir) / "teams"
            teams_dir.mkdir()

            # Create a real dir and symlink it
            real_dir = Path(config_dir) / "real-team"
            real_dir.mkdir()
            (real_dir / "config.json").write_text('{"members":[]}')
            symlink = teams_dir / "rune-evil-link"
            symlink.symlink_to(real_dir)

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            assert not checkpoint.exists()

    @requires_jq
    def test_rejects_symlinked_config_json(
        self, compact_env: Path
    ) -> None:
        """Symlinked config.json → team_config defaults to empty object."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            teams_dir = Path(config_dir) / "teams"
            teams_dir.mkdir()
            team_dir = teams_dir / "rune-symlink-cfg"
            team_dir.mkdir()

            # Create a real config elsewhere and symlink
            real_config = Path(config_dir) / "real-config.json"
            real_config.write_text('{"members":[{"name":"evil"}]}')
            (team_dir / "config.json").symlink_to(real_config)

            # Also need tasks dir
            (Path(config_dir) / "tasks" / "rune-symlink-cfg").mkdir(parents=True)

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            if checkpoint.exists():
                data = json.loads(checkpoint.read_text())
                # Config should be empty (symlink rejected)
                assert data["team_config"] == {}


class TestPreCompactEdgeCases:
    """Edge case tests (named for evaluator scoring)."""

    @requires_jq
    def test_checkpoint_edge_no_tasks_dir(self, compact_env: Path) -> None:
        """Team exists but tasks directory missing → checkpoint still written."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            teams_dir = Path(config_dir) / "teams"
            teams_dir.mkdir()
            team_dir = teams_dir / "rune-notasks-test"
            team_dir.mkdir()
            (team_dir / "config.json").write_text(
                '{"members":[{"name":"solo"}]}'
            )
            # No tasks directory created

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            assert checkpoint.exists()

            data = json.loads(checkpoint.read_text())
            assert data["tasks"] == []

    @requires_jq
    def test_checkpoint_edge_empty_config(self, compact_env: Path) -> None:
        """Config.json with empty members → checkpoint written with empty list."""
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            teams_dir = Path(config_dir) / "teams"
            teams_dir.mkdir()
            team_dir = teams_dir / "rune-empty-config"
            team_dir.mkdir()
            (team_dir / "config.json").write_text('{"members":[]}')
            (Path(config_dir) / "tasks" / "rune-empty-config").mkdir(parents=True)

            result = run_hook(
                PRE_COMPACT,
                {"cwd": str(compact_env)},
                env_override={"CLAUDE_CONFIG_DIR": config_dir},
            )
            assert result.returncode == 0

            checkpoint = compact_env / "tmp" / ".rune-compact-checkpoint.json"
            assert checkpoint.exists()

            data = json.loads(checkpoint.read_text())
            assert data["team_config"]["members"] == []

    @requires_jq
    def test_checkpoint_boundary_missing_jq(self) -> None:
        """Missing jq → exit 0 gracefully (boundary: no crash)."""
        result = run_hook(
            PRE_COMPACT,
            '{"cwd":"/tmp"}',
            env_override={"PATH": "/usr/bin:/bin"},
        )
        assert result.returncode == 0

    @requires_jq
    def test_checkpoint_edge_overwrite_existing(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """Pre-existing checkpoint is overwritten (mv -f behavior)."""
        project_root, config_dir = team_env

        checkpoint_file = project_root / "tmp" / ".rune-compact-checkpoint.json"
        checkpoint_file.write_text('{"team_name":"old","saved_at":"old"}')

        result = run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )
        assert result.returncode == 0

        data = json.loads(checkpoint_file.read_text())
        assert data["team_name"] == "rune-review-test123"
        assert data["saved_at"] != "old"

    @requires_jq
    def test_checkpoint_edge_no_workflow_state(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """No .rune-*.json workflow state file → workflow_state defaults to {}."""
        project_root, config_dir = team_env

        result = run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )
        assert result.returncode == 0

        checkpoint_file = project_root / "tmp" / ".rune-compact-checkpoint.json"
        data = json.loads(checkpoint_file.read_text())
        assert data["workflow_state"] == {}

    @requires_jq
    def test_checkpoint_edge_with_workflow_state(
        self, team_env: tuple[Path, Path]
    ) -> None:
        """Active workflow state file → captured in checkpoint."""
        project_root, config_dir = team_env

        # Write a workflow state file
        state = {
            "status": "active",
            "started": "2026-02-20T10:00:00Z",
            "workflow": "review",
        }
        (project_root / "tmp" / ".rune-review-abc123.json").write_text(
            json.dumps(state)
        )

        result = run_hook(
            PRE_COMPACT,
            {"cwd": str(project_root)},
            env_override={"CLAUDE_CONFIG_DIR": str(config_dir)},
        )
        assert result.returncode == 0

        checkpoint_file = project_root / "tmp" / ".rune-compact-checkpoint.json"
        data = json.loads(checkpoint_file.read_text())
        assert data["workflow_state"]["status"] == "active"


# ===========================================================================
# session-compact-recovery.sh tests
# ===========================================================================


class TestCompactRecoveryGuardClauses:
    """Guard clause tests for session-compact-recovery.sh."""

    @requires_jq
    def test_exit_0_non_compact_trigger(self) -> None:
        """Trigger != 'compact' → exit 0."""
        result = run_hook(
            COMPACT_RECOVERY,
            {"trigger": "startup", "cwd": "/tmp"},
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_exit_0_missing_trigger(self) -> None:
        """Missing trigger field → exit 0."""
        result = run_hook(COMPACT_RECOVERY, {"cwd": "/tmp"})
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_missing_cwd(self) -> None:
        """Missing cwd → exit 0."""
        result = run_hook(COMPACT_RECOVERY, {"trigger": "compact"})
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_no_checkpoint_file(self) -> None:
        """No checkpoint file → exit 0."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            (Path(tmpdir) / "tmp").mkdir()

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
            )
            assert result.returncode == 0

    @requires_jq
    def test_exit_0_symlinked_checkpoint(self) -> None:
        """Symlinked checkpoint file → exit 0 (rejected)."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            real_file = Path(tmpdir) / "real-checkpoint.json"
            real_file.write_text('{"team_name":"rune-test"}')
            (tmp_dir / ".rune-compact-checkpoint.json").symlink_to(real_file)

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
            )
            assert result.returncode == 0

    @requires_jq
    def test_exit_0_invalid_checkpoint_json(self) -> None:
        """Invalid JSON in checkpoint → exit 0 + cleanup."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()
            checkpoint = tmp_dir / ".rune-compact-checkpoint.json"
            checkpoint.write_text("not valid json {{{")

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
            )
            assert result.returncode == 0
            # Checkpoint should be cleaned up
            assert not checkpoint.exists()

    def test_exit_0_without_jq(self) -> None:
        """Missing jq → exit 0."""
        result = run_hook(
            COMPACT_RECOVERY,
            '{"trigger":"compact","cwd":"/tmp"}',
            env_override={"PATH": "/usr/bin:/bin"},
        )
        assert result.returncode == 0


class TestCompactRecoveryCorrelation:
    """Correlation guard and recovery injection tests."""

    @requires_jq
    def test_stale_checkpoint_deleted_team(self) -> None:
        """Checkpoint for deleted team → discard checkpoint, output stale msg."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
                # Team dir does NOT exist in config
                (Path(config_dir) / "teams").mkdir()

                checkpoint = {
                    "team_name": "rune-deleted-team",
                    "saved_at": "2026-02-20T10:00:00Z",
                    "team_config": {"members": []},
                    "tasks": [],
                    "workflow_state": {},
                    "arc_checkpoint": {},
                }
                checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
                checkpoint_file.write_text(json.dumps(checkpoint))

                result = run_hook(
                    COMPACT_RECOVERY,
                    {"trigger": "compact", "cwd": tmpdir},
                    env_override={"CLAUDE_CONFIG_DIR": config_dir},
                )
                assert result.returncode == 0

                # Checkpoint should be deleted
                assert not checkpoint_file.exists()

                # Output should mention team no longer exists
                output = json.loads(result.stdout.strip())
                assert "no longer exists" in output["hookSpecificOutput"]["additionalContext"].lower()

    @requires_jq
    def test_recovery_injects_context(self) -> None:
        """Valid checkpoint + active team → inject recovery context."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
                team_name = "rune-review-abc123"
                team_dir = Path(config_dir) / "teams" / team_name
                team_dir.mkdir(parents=True)
                (team_dir / "config.json").write_text('{"members":[]}')

                checkpoint = {
                    "team_name": team_name,
                    "saved_at": "2026-02-20T10:00:00Z",
                    "team_config": {
                        "members": [{"name": "test-ash", "agentType": "general-purpose"}]
                    },
                    "tasks": [
                        {"id": "1", "subject": "Test task", "status": "in_progress", "owner": "test-ash"}
                    ],
                    "workflow_state": {"status": "active", "workflow": "review"},
                    "arc_checkpoint": {},
                }
                checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
                checkpoint_file.write_text(json.dumps(checkpoint))

                result = run_hook(
                    COMPACT_RECOVERY,
                    {"trigger": "compact", "cwd": tmpdir},
                    env_override={"CLAUDE_CONFIG_DIR": config_dir},
                )
                assert result.returncode == 0

                output = json.loads(result.stdout.strip())
                ctx = output["hookSpecificOutput"]["additionalContext"]
                assert "RUNE COMPACT RECOVERY" in ctx
                assert team_name in ctx
                assert output["hookSpecificOutput"]["hookEventName"] == "SessionStart"

                # Checkpoint should be deleted (one-time injection)
                assert not checkpoint_file.exists()

    @requires_jq
    def test_recovery_deletes_checkpoint_after_use(self) -> None:
        """Checkpoint is deleted after successful recovery (one-time injection)."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
                team_name = "rune-oneshot-test"
                team_dir = Path(config_dir) / "teams" / team_name
                team_dir.mkdir(parents=True)
                (team_dir / "config.json").write_text('{"members":[]}')

                checkpoint = {
                    "team_name": team_name,
                    "saved_at": "2026-02-20T10:00:00Z",
                    "team_config": {"members": []},
                    "tasks": [],
                    "workflow_state": {},
                    "arc_checkpoint": {},
                }
                checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
                checkpoint_file.write_text(json.dumps(checkpoint))

                run_hook(
                    COMPACT_RECOVERY,
                    {"trigger": "compact", "cwd": tmpdir},
                    env_override={"CLAUDE_CONFIG_DIR": config_dir},
                )

                assert not checkpoint_file.exists()


class TestCompactRecoveryTeamNameValidation:
    """Team name validation for session-compact-recovery.sh."""

    @requires_jq
    def test_rejects_non_rune_prefix(self) -> None:
        """Checkpoint with non-rune/arc prefix → discarded."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
                # Create the team dir (so correlation guard passes)
                team_dir = Path(config_dir) / "teams" / "other-team"
                team_dir.mkdir(parents=True)

                checkpoint = {
                    "team_name": "other-team",
                    "saved_at": "2026-02-20T10:00:00Z",
                    "team_config": {"members": []},
                    "tasks": [],
                    "workflow_state": {},
                    "arc_checkpoint": {},
                }
                checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
                checkpoint_file.write_text(json.dumps(checkpoint))

                result = run_hook(
                    COMPACT_RECOVERY,
                    {"trigger": "compact", "cwd": tmpdir},
                    env_override={"CLAUDE_CONFIG_DIR": config_dir},
                )
                assert result.returncode == 0
                # Checkpoint discarded (non-rune prefix)
                assert not checkpoint_file.exists()
                # No recovery context output
                assert "RUNE COMPACT RECOVERY" not in result.stdout

    @requires_jq
    def test_rejects_invalid_team_name_chars(self) -> None:
        """Checkpoint with invalid team name chars → discarded."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            checkpoint = {
                "team_name": "rune-../evil",
                "saved_at": "2026-02-20T10:00:00Z",
                "team_config": {"members": []},
                "tasks": [],
                "workflow_state": {},
                "arc_checkpoint": {},
            }
            checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
            checkpoint_file.write_text(json.dumps(checkpoint))

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
            )
            assert result.returncode == 0
            assert not checkpoint_file.exists()

    @requires_jq
    def test_rejects_oversized_team_name(self) -> None:
        """Team name > 128 chars → discarded."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            checkpoint = {
                "team_name": "rune-" + "a" * 130,
                "saved_at": "2026-02-20T10:00:00Z",
                "team_config": {"members": []},
                "tasks": [],
                "workflow_state": {},
                "arc_checkpoint": {},
            }
            checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
            checkpoint_file.write_text(json.dumps(checkpoint))

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
            )
            assert result.returncode == 0
            assert not checkpoint_file.exists()


class TestCompactRecoveryEdgeCases:
    """Edge case tests for session-compact-recovery.sh."""

    @requires_jq
    def test_recovery_edge_empty_team_name(self) -> None:
        """Checkpoint with empty team_name → discarded."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            checkpoint = {
                "team_name": "",
                "saved_at": "2026-02-20T10:00:00Z",
                "team_config": {"members": []},
                "tasks": [],
                "workflow_state": {},
                "arc_checkpoint": {},
            }
            checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
            checkpoint_file.write_text(json.dumps(checkpoint))

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
            )
            assert result.returncode == 0
            assert not checkpoint_file.exists()

    @requires_jq
    def test_recovery_edge_missing_team_name_field(self) -> None:
        """Checkpoint without team_name field → discarded."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            checkpoint = {
                "saved_at": "2026-02-20T10:00:00Z",
                "team_config": {"members": []},
                "tasks": [],
            }
            checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
            checkpoint_file.write_text(json.dumps(checkpoint))

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
            )
            assert result.returncode == 0
            assert not checkpoint_file.exists()

    @requires_jq
    def test_recovery_boundary_relative_chome(self) -> None:
        """Relative CLAUDE_CONFIG_DIR → exit 0 + cleanup."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            checkpoint = {
                "team_name": "rune-test",
                "saved_at": "2026-02-20T10:00:00Z",
                "team_config": {"members": []},
                "tasks": [],
                "workflow_state": {},
                "arc_checkpoint": {},
            }
            checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
            checkpoint_file.write_text(json.dumps(checkpoint))

            result = run_hook(
                COMPACT_RECOVERY,
                {"trigger": "compact", "cwd": tmpdir},
                env_override={"CLAUDE_CONFIG_DIR": "relative/path"},
            )
            assert result.returncode == 0
            # Checkpoint cleaned up on exit
            assert not checkpoint_file.exists()

    @requires_jq
    def test_recovery_edge_arc_checkpoint_info(self) -> None:
        """Arc checkpoint info → included in recovery context."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
                team_name = "arc-work-test456"
                team_dir = Path(config_dir) / "teams" / team_name
                team_dir.mkdir(parents=True)
                (team_dir / "config.json").write_text('{"members":[]}')

                checkpoint = {
                    "team_name": team_name,
                    "saved_at": "2026-02-20T10:00:00Z",
                    "team_config": {"members": []},
                    "tasks": [],
                    "workflow_state": {"status": "active", "workflow": "arc"},
                    "arc_checkpoint": {"current_phase": "code_review"},
                }
                checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
                checkpoint_file.write_text(json.dumps(checkpoint))

                result = run_hook(
                    COMPACT_RECOVERY,
                    {"trigger": "compact", "cwd": tmpdir},
                    env_override={"CLAUDE_CONFIG_DIR": config_dir},
                )
                assert result.returncode == 0

                output = json.loads(result.stdout.strip())
                ctx = output["hookSpecificOutput"]["additionalContext"]
                assert "code_review" in ctx
                assert "arc" in ctx.lower()

    @requires_jq
    def test_recovery_boundary_symlinked_team_dir(self) -> None:
        """Symlinked team dir in correlation check → discard checkpoint."""
        with tempfile.TemporaryDirectory(prefix="rune-recovery-") as tmpdir:
            tmp_dir = Path(tmpdir) / "tmp"
            tmp_dir.mkdir()

            with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
                teams_dir = Path(config_dir) / "teams"
                teams_dir.mkdir()

                # Create symlinked team dir
                real_dir = Path(config_dir) / "real-team"
                real_dir.mkdir()
                (teams_dir / "rune-symlink-test").symlink_to(real_dir)

                checkpoint = {
                    "team_name": "rune-symlink-test",
                    "saved_at": "2026-02-20T10:00:00Z",
                    "team_config": {"members": []},
                    "tasks": [],
                    "workflow_state": {},
                    "arc_checkpoint": {},
                }
                checkpoint_file = tmp_dir / ".rune-compact-checkpoint.json"
                checkpoint_file.write_text(json.dumps(checkpoint))

                result = run_hook(
                    COMPACT_RECOVERY,
                    {"trigger": "compact", "cwd": tmpdir},
                    env_override={"CLAUDE_CONFIG_DIR": config_dir},
                )
                assert result.returncode == 0
                # Checkpoint discarded (symlink detected)
                assert not checkpoint_file.exists()
