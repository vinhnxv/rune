"""Unit tests for on-session-stop.sh (STOP-001).

Tests the Stop hook that auto-cleans stale Rune workflows on session stop.
Verifies guard clauses, team dir cleanup (Phase 1), state file cleanup (Phase 2),
arc checkpoint cleanup (Phase 3), session isolation, and edge cases.

Requires: jq (skips gracefully if missing)
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

from conftest import SCRIPTS_DIR, requires_jq

SCRIPT = SCRIPTS_DIR / "on-session-stop.sh"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_stop_hook(
    project: Path,
    config: Path,
    *,
    stop_hook_active: bool = False,
    env_override: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run on-session-stop.sh with configurable input."""
    input_json: dict = {"cwd": str(project)}
    if stop_hook_active:
        input_json["stop_hook_active"] = True
    env = os.environ.copy()
    # Resolve symlinks for config_dir to match what state files store
    # (on macOS, /var is a symlink to /private/var)
    resolved_config = str(config.resolve())
    env["CLAUDE_CONFIG_DIR"] = resolved_config
    env["RUNE_CURRENT_CFG"] = resolved_config  # For ownership matching
    if env_override:
        env.update(env_override)
    return subprocess.run(
        ["bash", str(SCRIPT)],
        input=json.dumps(input_json),
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
        cwd=str(project),
    )


def create_state_file(
    project: Path,
    config: Path,
    *,
    name: str = ".rune-review-abc123.json",
    status: str = "active",
    team_name: str = "rune-review-abc123",
    owner_pid: str | None = None,
) -> Path:
    """Create a Rune workflow state file in project/tmp/."""
    state_dir = project / "tmp"
    state_dir.mkdir(exist_ok=True)
    pid = owner_pid or str(os.getpid())
    state = {
        "status": status,
        "team_name": team_name,
        "config_dir": str(config.resolve()),
        "owner_pid": pid,
        "session_id": "test-session",
    }
    path = state_dir / name
    path.write_text(json.dumps(state))
    return path


def create_arc_checkpoint(
    project: Path,
    config: Path,
    *,
    arc_id: str = "arc-run-001",
    phases: dict | None = None,
    age_minutes: int = 10,
    owner_pid: str | None = None,
) -> Path:
    """Create an arc checkpoint with in_progress phases."""
    arc_dir = project / ".claude" / "arc" / arc_id
    arc_dir.mkdir(parents=True, exist_ok=True)
    pid = owner_pid or str(os.getpid())
    checkpoint = {
        "config_dir": str(config.resolve()),
        "owner_pid": pid,
        "phases": phases or {
            "forge": {"status": "completed"},
            "work": {"status": "in_progress"},
            "review": {"status": "pending"},
        },
    }
    path = arc_dir / "checkpoint.json"
    path.write_text(json.dumps(checkpoint))
    # Backdate the file modification time
    if age_minutes > 0:
        old_time = time.time() - (age_minutes * 60)
        os.utime(str(path), (old_time, old_time))
    return path


def backdate_dir(path: Path, minutes: int) -> None:
    """Set a directory's mtime to N minutes ago."""
    old_time = time.time() - (minutes * 60)
    os.utime(str(path), (old_time, old_time))


# ---------------------------------------------------------------------------
# Guard Clauses
# ---------------------------------------------------------------------------


class TestSessionStopGuardClauses:
    @requires_jq
    def test_exit_0_no_cwd(self, project_env):
        """Missing CWD in input -> exit 0 silently."""
        _project, config = project_env
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config.resolve())
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            input=json.dumps({}),
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_exit_0_empty_cwd(self, project_env):
        """Empty CWD string -> exit 0 silently."""
        _project, config = project_env
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config.resolve())
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            input=json.dumps({"cwd": ""}),
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_exit_0_stop_hook_active(self, project_env):
        """stop_hook_active=true -> exit 0 (loop prevention)."""
        project, config = project_env
        # Create something that would normally be cleaned
        create_state_file(project, config)
        result = run_stop_hook(project, config, stop_hook_active=True)
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_exit_0_batch_loop_active_owned(self, project_env):
        """arc-batch loop active AND owned by this session -> exit 0 (deference)."""
        project, config = project_env
        batch_file = project / ".claude" / "arc-batch-loop.local.md"
        batch_file.parent.mkdir(parents=True, exist_ok=True)
        resolved_config = str(config.resolve())
        batch_file.write_text(
            f"---\nconfig_dir: {resolved_config}\nowner_pid: {os.getpid()}\n---\n"
        )
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_proceeds_when_batch_loop_different_config(self, project_env):
        """arc-batch loop owned by different config -> proceeds with cleanup."""
        project, config = project_env
        batch_file = project / ".claude" / "arc-batch-loop.local.md"
        batch_file.parent.mkdir(parents=True, exist_ok=True)
        batch_file.write_text(
            f"---\nconfig_dir: /different/config\nowner_pid: {os.getpid()}\n---\n"
        )
        # Create a state file to trigger cleanup
        create_state_file(project, config)
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        # Cleanup should have run (state file set to stopped)

    @requires_jq
    def test_exit_0_nonexistent_cwd(self, project_env):
        """CWD pointing to nonexistent directory -> exit 0."""
        _project, config = project_env
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config.resolve())
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            input=json.dumps({"cwd": "/nonexistent/path/that/does/not/exist"}),
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_exit_0_empty_input(self, project_env):
        """Empty JSON input -> exit 0."""
        _project, config = project_env
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config.resolve())
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            input="{}",
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""


# ---------------------------------------------------------------------------
# Phase 1: Team Dir Cleanup
# ---------------------------------------------------------------------------


class TestSessionStopTeamCleanup:
    @requires_jq
    def test_cleans_team_with_matching_state_file(self, project_env):
        """Team dirs with matching active state files are cleaned."""
        project, config = project_env
        team_name = "rune-review-test1"
        # Create team dir
        team_dir = config / "teams" / team_name
        team_dir.mkdir(parents=True, exist_ok=True)
        (team_dir / "config.json").write_text("{}")
        # Create task dir
        task_dir = config / "tasks" / team_name
        task_dir.mkdir(parents=True, exist_ok=True)
        # Create matching state file
        create_state_file(
            project, config,
            name=f".rune-review-test1.json",
            team_name=team_name,
        )
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert not team_dir.exists(), "Team dir should be removed"
        assert not task_dir.exists(), "Task dir should be removed"

    @requires_jq
    def test_does_not_clean_young_orphan_team(self, project_env):
        """Team dirs < 30 min old without state files are NOT cleaned."""
        project, config = project_env
        team_dir = config / "teams" / "rune-review-young"
        team_dir.mkdir(parents=True, exist_ok=True)
        (team_dir / "config.json").write_text("{}")
        # Dir is fresh (just created) — no backdate
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert team_dir.exists(), "Young orphan should be preserved"

    @requires_jq
    def test_cleans_old_orphan_team_without_state(self, project_env):
        """Team dirs > 30 min old without state files are cleaned as orphans."""
        project, config = project_env
        team_dir = config / "teams" / "rune-review-old"
        team_dir.mkdir(parents=True, exist_ok=True)
        (team_dir / "config.json").write_text("{}")
        # Backdate to > 30 min old
        backdate_dir(team_dir, 45)
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert not team_dir.exists(), "Old orphan should be cleaned"

    @requires_jq
    def test_cleans_arc_prefixed_team(self, project_env):
        """arc-* team dirs with matching state files are cleaned."""
        project, config = project_env
        team_name = "arc-plan-review-xyz"
        team_dir = config / "teams" / team_name
        team_dir.mkdir(parents=True, exist_ok=True)
        create_state_file(
            project, config,
            name=".rune-plan-review-xyz.json",
            team_name=team_name,
        )
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert not team_dir.exists()

    @requires_jq
    def test_ignores_non_rune_team(self, project_env):
        """Non-rune/arc team dirs are never touched."""
        project, config = project_env
        team_dir = config / "teams" / "my-custom-team"
        team_dir.mkdir(parents=True, exist_ok=True)
        (team_dir / "config.json").write_text("{}")
        backdate_dir(team_dir, 120)  # Old but non-rune
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert team_dir.exists(), "Non-rune team dir should not be touched"

    @requires_jq
    def test_skips_symlinked_team_dir(self, project_env):
        """Symlinked team dirs are skipped (TOCTOU mitigation)."""
        project, config = project_env
        target = project / "tmp" / "fake-team"
        target.mkdir(parents=True, exist_ok=True)
        link = config / "teams" / "rune-review-link"
        link.symlink_to(target)
        backdate_dir(target, 45)
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert link.exists(), "Symlinked dir should not be removed"

    @requires_jq
    def test_reports_cleaned_teams_on_stdout(self, project_env):
        """Cleaned team names appear in stdout summary."""
        project, config = project_env
        team_name = "rune-review-reported"
        team_dir = config / "teams" / team_name
        team_dir.mkdir(parents=True, exist_ok=True)
        create_state_file(
            project, config,
            name=".rune-review-reported.json",
            team_name=team_name,
        )
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert "STOP-001" in result.stdout
        assert team_name in result.stdout


# ---------------------------------------------------------------------------
# Phase 2: State File Cleanup
# ---------------------------------------------------------------------------


class TestSessionStopStateFileCleanup:
    @requires_jq
    def test_sets_active_state_to_stopped(self, project_env):
        """Active state files are set to 'stopped'."""
        project, config = project_env
        sf = create_state_file(project, config, status="active")
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        updated = json.loads(sf.read_text())
        assert updated["status"] == "stopped"
        assert "stopped_at" in updated
        assert updated["stopped_by"] == "STOP-001"

    @requires_jq
    def test_skips_completed_state_files(self, project_env):
        """State files with status 'completed' are not modified."""
        project, config = project_env
        sf = create_state_file(project, config, status="completed")
        original = sf.read_text()
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert sf.read_text() == original

    @requires_jq
    def test_skips_already_stopped_state_files(self, project_env):
        """State files with status 'stopped' are not modified again."""
        project, config = project_env
        sf = create_state_file(project, config, status="stopped")
        original = sf.read_text()
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert sf.read_text() == original

    @requires_jq
    def test_cleans_review_state_file(self, project_env):
        project, config = project_env
        sf = create_state_file(
            project, config, name=".rune-review-test.json", status="active"
        )
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    def test_cleans_audit_state_file(self, project_env):
        project, config = project_env
        sf = create_state_file(
            project, config, name=".rune-audit-test.json", status="active"
        )
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    def test_cleans_work_state_file(self, project_env):
        project, config = project_env
        sf = create_state_file(
            project, config, name=".rune-work-test.json", status="active"
        )
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    def test_cleans_mend_state_file(self, project_env):
        project, config = project_env
        sf = create_state_file(
            project, config, name=".rune-mend-test.json", status="active"
        )
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    def test_cleans_forge_state_file(self, project_env):
        project, config = project_env
        sf = create_state_file(
            project, config, name=".rune-forge-test.json", status="active"
        )
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    def test_cleans_inspect_state_file(self, project_env):
        project, config = project_env
        sf = create_state_file(
            project, config, name=".rune-inspect-test.json", status="active"
        )
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    def test_cleans_plan_state_file(self, project_env):
        project, config = project_env
        sf = create_state_file(
            project, config, name=".rune-plan-test.json", status="active"
        )
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    def test_skips_symlinked_state_file(self, project_env):
        """Symlinked state files are skipped."""
        project, config = project_env
        target = project / "tmp" / "real-state.json"
        target.write_text(json.dumps({
            "status": "active",
            "config_dir": str(config.resolve()),
            "owner_pid": str(os.getpid()),
        }))
        link = project / "tmp" / ".rune-review-link.json"
        link.symlink_to(target)
        run_stop_hook(project, config)
        # Original should not be modified (the symlink is skipped)
        assert json.loads(target.read_text())["status"] == "active"

    @requires_jq
    def test_reports_cleaned_states_on_stdout(self, project_env):
        """Cleaned state file names appear in stdout summary."""
        project, config = project_env
        create_state_file(project, config, name=".rune-review-reported.json")
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert "STOP-001" in result.stdout
        assert "States:" in result.stdout


# ---------------------------------------------------------------------------
# Phase 3: Arc Checkpoint Cleanup
# ---------------------------------------------------------------------------


class TestSessionStopArcCheckpointCleanup:
    @requires_jq
    def test_cancels_old_in_progress_checkpoint(self, project_env):
        """Arc checkpoints older than 5 min with in_progress phases are cancelled."""
        project, config = project_env
        cp = create_arc_checkpoint(project, config, age_minutes=10)
        run_stop_hook(project, config)
        updated = json.loads(cp.read_text())
        assert updated["phases"]["work"]["status"] == "cancelled"
        assert updated["phases"]["forge"]["status"] == "completed"
        assert updated["phases"]["review"]["status"] == "pending"

    @requires_jq
    def test_skips_young_checkpoint(self, project_env):
        """Arc checkpoints younger than 5 min are NOT cancelled."""
        project, config = project_env
        cp = create_arc_checkpoint(project, config, age_minutes=2)
        run_stop_hook(project, config)
        updated = json.loads(cp.read_text())
        assert updated["phases"]["work"]["status"] == "in_progress"

    @requires_jq
    def test_skips_checkpoint_without_in_progress(self, project_env):
        """Arc checkpoints with no in_progress phases are not modified."""
        project, config = project_env
        phases = {
            "forge": {"status": "completed"},
            "work": {"status": "completed"},
        }
        cp = create_arc_checkpoint(project, config, phases=phases, age_minutes=10)
        original = cp.read_text()
        run_stop_hook(project, config)
        assert cp.read_text() == original

    @requires_jq
    def test_reports_cleaned_arcs_on_stdout(self, project_env):
        """Cancelled arc IDs appear in stdout summary."""
        project, config = project_env
        create_arc_checkpoint(project, config, arc_id="arc-run-report-test", age_minutes=10)
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert "STOP-001" in result.stdout
        assert "Arcs:" in result.stdout

    @requires_jq
    def test_skips_symlinked_checkpoint(self, project_env):
        """Symlinked checkpoint files are skipped."""
        project, config = project_env
        # Create a real checkpoint as the target
        target_dir = project / "tmp" / "fake-arc"
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / "checkpoint.json"
        target.write_text(json.dumps({
            "config_dir": str(config.resolve()),
            "owner_pid": str(os.getpid()),
            "phases": {"work": {"status": "in_progress"}},
        }))
        old_time = time.time() - 600
        os.utime(str(target), (old_time, old_time))
        # Create the arc dir with a symlinked checkpoint
        arc_dir = project / ".claude" / "arc" / "arc-symlink-test"
        arc_dir.mkdir(parents=True, exist_ok=True)
        link = arc_dir / "checkpoint.json"
        link.symlink_to(target)
        run_stop_hook(project, config)
        # Target should not be modified
        assert json.loads(target.read_text())["phases"]["work"]["status"] == "in_progress"


# ---------------------------------------------------------------------------
# Session Isolation
# ---------------------------------------------------------------------------


class TestSessionStopSessionIsolation:
    @requires_jq
    @pytest.mark.session_isolation
    def test_skips_state_file_different_config_dir(self, project_env):
        """State files with different config_dir are not cleaned."""
        project, config = project_env
        sf_path = project / "tmp" / ".rune-review-other.json"
        sf_path.parent.mkdir(exist_ok=True)
        sf_path.write_text(json.dumps({
            "status": "active",
            "team_name": "rune-review-other",
            "config_dir": "/different/config/dir",
            "owner_pid": str(os.getpid()),
        }))
        run_stop_hook(project, config)
        assert json.loads(sf_path.read_text())["status"] == "active"

    @requires_jq
    @pytest.mark.session_isolation
    def test_skips_arc_checkpoint_different_config_dir(self, project_env):
        """Arc checkpoints with different config_dir are not cancelled."""
        project, config = project_env
        arc_dir = project / ".claude" / "arc" / "arc-other-cfg"
        arc_dir.mkdir(parents=True, exist_ok=True)
        cp = arc_dir / "checkpoint.json"
        cp.write_text(json.dumps({
            "config_dir": "/different/config/dir",
            "owner_pid": str(os.getpid()),
            "phases": {"work": {"status": "in_progress"}},
        }))
        old_time = time.time() - 600
        os.utime(str(cp), (old_time, old_time))
        run_stop_hook(project, config)
        assert json.loads(cp.read_text())["phases"]["work"]["status"] == "in_progress"

    @requires_jq
    @pytest.mark.session_isolation
    def test_cleans_own_session_state_file(self, project_env):
        """State files matching current config_dir + PID are cleaned."""
        project, config = project_env
        sf = create_state_file(project, config, owner_pid=str(os.getpid()))
        run_stop_hook(project, config)
        assert json.loads(sf.read_text())["status"] == "stopped"

    @requires_jq
    @pytest.mark.session_isolation
    def test_team_not_cleaned_when_state_owned_by_other_config(self, project_env):
        """Team dirs referenced by state files with different config_dir are not cleaned."""
        project, config = project_env
        team_name = "rune-review-foreign"
        team_dir = config / "teams" / team_name
        team_dir.mkdir(parents=True, exist_ok=True)
        # Create state file owned by different config
        sf_path = project / "tmp" / ".rune-review-foreign.json"
        sf_path.parent.mkdir(exist_ok=True)
        sf_path.write_text(json.dumps({
            "status": "active",
            "team_name": team_name,
            "config_dir": "/different/config",
            "owner_pid": str(os.getpid()),
        }))
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        # Team dir still exists (the state file's config_dir doesn't match,
        # so it's not collected in state_team_names, but the dir may still be
        # cleaned if old enough as an orphan). The dir is fresh, so it survives.
        assert team_dir.exists()


# ---------------------------------------------------------------------------
# Edge Cases
# ---------------------------------------------------------------------------


class TestSessionStopEdgeCases:
    @requires_jq
    def test_no_cleanup_needed_silent_exit(self, project_env):
        """No stale resources -> exit 0 with no stdout."""
        project, config = project_env
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_combined_cleanup_all_phases(self, project_env):
        """All three phases run when resources exist in each category."""
        project, config = project_env
        # Phase 1: team dir
        team_name = "rune-review-combo"
        team_dir = config / "teams" / team_name
        team_dir.mkdir(parents=True, exist_ok=True)
        create_state_file(
            project, config,
            name=".rune-review-combo.json",
            team_name=team_name,
        )
        # Phase 2: additional active state file
        create_state_file(
            project, config,
            name=".rune-audit-combo.json",
            team_name="rune-audit-combo",
        )
        # Phase 3: arc checkpoint
        create_arc_checkpoint(project, config, arc_id="arc-combo", age_minutes=10)
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert "STOP-001" in result.stdout
        # Team cleaned
        assert not team_dir.exists()

    @requires_jq
    def test_writes_trace_log(self, project_env):
        """Cleanup log is written to tmp/.rune-stop-cleanup.log."""
        project, config = project_env
        create_state_file(project, config)
        run_stop_hook(project, config)
        log_path = project / "tmp" / ".rune-stop-cleanup.log"
        assert log_path.exists()
        log_content = log_path.read_text()
        assert "STOP-001" in log_content

    @requires_jq
    def test_handles_corrupted_state_file(self, project_env):
        """Corrupted (non-JSON) state files don't crash the hook."""
        project, config = project_env
        sf_path = project / "tmp" / ".rune-review-corrupt.json"
        sf_path.parent.mkdir(exist_ok=True)
        sf_path.write_text("not valid json {{{")
        result = run_stop_hook(project, config)
        assert result.returncode == 0

    @requires_jq
    def test_handles_missing_tmp_dir(self, project_env):
        """No tmp/ directory -> phases 2 and 3 skip gracefully."""
        project, config = project_env
        # Remove the tmp dir created by project_env
        import shutil
        shutil.rmtree(project / "tmp")
        result = run_stop_hook(project, config)
        assert result.returncode == 0
        assert result.stdout.strip() == ""
