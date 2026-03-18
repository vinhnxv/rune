"""Unit tests for arc-batch-stop-hook.sh (ARC-BATCH-LOOP).

Tests the Stop hook that drives batch arc execution via the ralph-wiggum
self-invoking loop pattern. Verifies guard clauses, session isolation,
progress tracking, plan injection, and security checks.

Requires: jq (skips gracefully if missing)
"""

from __future__ import annotations

import json
import os
import subprocess
import textwrap
from pathlib import Path

import pytest

from conftest import SCRIPTS_DIR, requires_jq

SCRIPT = SCRIPTS_DIR / "arc-batch-stop-hook.sh"


def write_state_file(
    project: Path,
    config: Path,
    *,
    active: bool = True,
    iteration: int = 1,
    max_iterations: int = 0,
    total_plans: int = 3,
    no_merge: bool = False,
    owner_pid: str | None = None,
    compact_pending: bool = False,
) -> Path:
    """Create a .rune/arc-batch-loop.local.md state file."""
    state_file = project / ".claude" / "arc-batch-loop.local.md"
    state_file.parent.mkdir(parents=True, exist_ok=True)
    # Default to os.getpid() because bash's $PPID = Python test process PID.
    # resolve() needed: macOS /var/folders → /private/var/folders symlink.
    pid = owner_pid or str(os.getpid())
    resolved_config = str(config.resolve())
    content = textwrap.dedent(f"""\
    ---
    active: {"true" if active else "false"}
    iteration: {iteration}
    max_iterations: {max_iterations}
    total_plans: {total_plans}
    no_merge: {"true" if no_merge else "false"}
    plugin_dir: /tmp/test-plugin
    config_dir: {resolved_config}
    owner_pid: {pid}
    session_id: test-session
    plans_file: tmp/arc-batch/batch-progress.json
    progress_file: tmp/arc-batch/batch-progress.json
    started_at: "2026-02-22T00:00:00.000Z"
    compact_pending: {"true" if compact_pending else "false"}
    ---

    Arc batch loop state. Do not edit manually.
    """)
    state_file.write_text(content)
    return state_file


def write_progress_file(
    project: Path,
    plans: list[dict],
) -> Path:
    """Create a batch-progress.json file."""
    progress_dir = project / "tmp" / "arc-batch"
    progress_dir.mkdir(parents=True, exist_ok=True)
    progress = {
        "schema_version": 1,
        "status": "running",
        "started_at": "2026-02-22T00:00:00.000Z",
        "updated_at": "2026-02-22T00:00:00.000Z",
        "total_plans": len(plans),
        "plans": plans,
    }
    path = progress_dir / "batch-progress.json"
    path.write_text(json.dumps(progress, indent=2))
    return path


def write_checkpoint_file(
    project: Path,
    *,
    owner_pid: str | None = None,
    ship_status: str = "completed",
    pr_url: str | None = "https://github.com/test/repo/pull/99",
) -> Path:
    """Create a mock arc checkpoint under .rune/arc/ for _find_arc_checkpoint().

    The stop hook uses _find_arc_checkpoint() to locate the newest checkpoint
    matching the current session's PPID. Without a checkpoint, ARC_STATUS
    defaults to "failed" and plans get marked as failed instead of completed.
    """
    pid = owner_pid or str(os.getpid())
    arc_id = f"arc-test-{pid}"
    ckpt_dir = project / ".claude" / "arc" / arc_id
    ckpt_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = {
        "id": arc_id,
        "schema_version": 17,
        "owner_pid": pid,
        "pr_url": pr_url,
        "phases": {
            "ship": {"status": ship_status, "pr_url": pr_url},
            "merge": {"status": ship_status if ship_status == "completed" else "pending"},
        },
    }
    path = ckpt_dir / "checkpoint.json"
    path.write_text(json.dumps(checkpoint, indent=2))
    return path


def write_arc_result_signal(
    project: Path,
    config: Path,
    *,
    owner_pid: str | None = None,
    arc_status: str = "completed",
    pr_url: str | None = "https://github.com/test/repo/pull/99",
    plan_path: str = "plans/a.md",
) -> Path:
    """Create tmp/arc-result-current.json (v1.109.2 explicit completion signal).

    Stop hooks read this signal FIRST as the primary arc completion detection.
    Falls back to _find_arc_checkpoint() if signal is missing.
    """
    pid = owner_pid or str(os.getpid())
    signal_dir = project / "tmp"
    signal_dir.mkdir(parents=True, exist_ok=True)
    signal = {
        "schema_version": 1,
        "arc_id": f"arc-test-{pid}",
        "plan_path": plan_path,
        "status": arc_status,
        "pr_url": pr_url,
        "completed_at": "2026-02-26T12:00:00Z",
        "phases_completed": 17,
        "phases_total": 23,
        "owner_pid": pid,
        "config_dir": str(config.resolve()),
    }
    path = signal_dir / "arc-result-current.json"
    path.write_text(json.dumps(signal, indent=2))
    return path


def run_batch_hook(
    project: Path,
    config: Path,
    *,
    env_override: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run arc-batch-stop-hook.sh."""
    input_json = {"cwd": str(project)}
    env = os.environ.copy()
    # resolve() needed: macOS /var/folders → /private/var/folders symlink
    env["CLAUDE_CONFIG_DIR"] = str(config.resolve())
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


# ---------------------------------------------------------------------------
# Guard Clauses
# ---------------------------------------------------------------------------


class TestArcBatchGuardClauses:
    @requires_jq
    def test_exit_0_no_state_file(self, project_env):
        """No .rune/arc-batch-loop.local.md → exit 0."""
        project, config = project_env
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_exit_0_missing_cwd(self, project_env):
        project, config = project_env
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config)
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            input="{}",
            capture_output=True, text=True, timeout=10, env=env,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    @requires_jq
    def test_exit_0_inactive_batch(self, project_env):
        """active: false → removes state file, exit 0."""
        project, config = project_env
        write_state_file(project, config, active=False)
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert result.stdout.strip() == ""
        assert not (project / ".claude" / "arc-batch-loop.local.md").exists()

    @requires_jq
    def test_exit_0_invalid_numeric_fields(self, project_env):
        """Non-numeric iteration → state file removed."""
        project, config = project_env
        state_file = project / ".claude" / "arc-batch-loop.local.md"
        state_file.parent.mkdir(parents=True, exist_ok=True)
        resolved_config = str(config.resolve())
        state_file.write_text(textwrap.dedent(f"""\
        ---
        active: true
        iteration: abc
        max_iterations: 0
        total_plans: 3
        no_merge: false
        plugin_dir: /tmp
        config_dir: {resolved_config}
        owner_pid: {os.getpid()}
        session_id: test
        plans_file: tmp/progress.json
        progress_file: tmp/progress.json
        ---
        """))
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not state_file.exists()

    @requires_jq
    def test_exit_0_max_iterations_reached(self, project_env):
        """iteration >= max_iterations → state file removed."""
        project, config = project_env
        write_state_file(project, config, iteration=3, max_iterations=3)
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not (project / ".claude" / "arc-batch-loop.local.md").exists()

    @requires_jq
    def test_exit_0_empty_frontmatter(self, project_env):
        """Corrupted state file with empty frontmatter → cleaned up."""
        project, config = project_env
        state_file = project / ".claude" / "arc-batch-loop.local.md"
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text("no frontmatter here\n")
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not state_file.exists()

    @requires_jq
    def test_exit_0_symlinked_state_file(self, project_env):
        """Symlinked state file → removed, exit 0."""
        project, config = project_env
        target = project / "tmp" / "fake-state.md"
        target.write_text("---\nactive: true\n---\n")
        link = project / ".claude" / "arc-batch-loop.local.md"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not link.exists()


# ---------------------------------------------------------------------------
# Session Isolation
# ---------------------------------------------------------------------------


class TestArcBatchSessionIsolation:
    @requires_jq
    @pytest.mark.session_isolation
    def test_exit_0_different_config_dir(self, project_env):
        """Different CLAUDE_CONFIG_DIR → skip (another installation's batch)."""
        project, config = project_env
        write_state_file(project, Path("/different/config/dir"))
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert result.stdout.strip() == ""
        # State file should NOT be removed (belongs to another session)
        assert (project / ".claude" / "arc-batch-loop.local.md").exists()

    @requires_jq
    @pytest.mark.session_isolation
    def test_processes_own_batch(self, project_env):
        """Same PPID and config_dir → processes normally.

        Uses compact_pending=True to skip Phase A (compact interlude checkpoint)
        and go directly to Phase B which injects the arc prompt for the next plan.
        """
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()), compact_pending=True)
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        # Should output block decision for next plan
        assert result.stdout.strip(), f"Expected JSON output, got empty stdout. stderr: {result.stderr}"
        output = json.loads(result.stdout)
        assert output["decision"] == "block"
        assert "plans/b.md" in output["reason"]


# ---------------------------------------------------------------------------
# Progress Tracking
# ---------------------------------------------------------------------------


class TestArcBatchProgressTracking:
    @requires_jq
    def test_marks_current_plan_completed(self, project_env):
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        # Checkpoint required: _find_arc_checkpoint() needs evidence of success,
        # otherwise ARC_STATUS defaults to "failed" (v1.107.0 safe default).
        write_checkpoint_file(project, owner_pid=pid, ship_status="completed")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        assert plan_a["status"] == "completed"
        assert plan_a["completed_at"] is not None
        assert isinstance(plan_a["completed_at"], str)

    @requires_jq
    def test_all_done_removes_state_file(self, project_env):
        """When no pending plans remain, state file is removed."""
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()), total_plans=1)
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not (project / ".claude" / "arc-batch-loop.local.md").exists()
        # Should output summary prompt
        output = json.loads(result.stdout)
        assert output["decision"] == "block"
        assert "Complete" in output["reason"] or "summary" in output["reason"].lower()

    @requires_jq
    def test_increments_iteration(self, project_env):
        """Iteration increments in Phase B (compact_pending=true).

        Phase A marks plan status and sets compact_pending=true.
        Phase B (this test) resets compact_pending, increments iteration,
        and injects the next arc prompt.
        """
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, iteration=2, owner_pid=pid, compact_pending=True)
        write_checkpoint_file(project, owner_pid=pid, ship_status="completed")
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "completed", "error": None, "completed_at": "2026-02-22T00:00:00Z"},
            {"path": "plans/b.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/c.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        state = (project / ".claude" / "arc-batch-loop.local.md").read_text()
        assert "iteration: 3" in state


# ---------------------------------------------------------------------------
# Next Plan Injection
# ---------------------------------------------------------------------------


class TestArcBatchNextPlanInjection:
    @requires_jq
    def test_outputs_block_decision_json(self, project_env):
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()))
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        output = json.loads(result.stdout)
        assert output["decision"] == "block"
        assert "systemMessage" in output

    @requires_jq
    def test_arc_prompt_contains_plan_path(self, project_env):
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()), compact_pending=True)
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/next-plan.md", "status": "pending", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        output = json.loads(result.stdout)
        assert "plans/next-plan.md" in output["reason"]

    @requires_jq
    def test_arc_prompt_includes_truthbinding(self, project_env):
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()), compact_pending=True)
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        output = json.loads(result.stdout)
        assert "ANCHOR" in output["reason"]
        assert "RE-ANCHOR" in output["reason"]

    @requires_jq
    def test_no_merge_flag_included(self, project_env):
        project, config = project_env
        write_state_file(project, config, no_merge=True, owner_pid=str(os.getpid()), compact_pending=True)
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        output = json.loads(result.stdout)
        assert "--no-merge" in output["reason"]


# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------


class TestArcBatchSecurity:
    @requires_jq
    @pytest.mark.security
    def test_rejects_path_traversal_in_progress_file(self, project_env):
        """Path traversal in progress_file → cleanup and exit."""
        project, config = project_env
        state_file = project / ".claude" / "arc-batch-loop.local.md"
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(textwrap.dedent(f"""\
        ---
        active: true
        iteration: 1
        max_iterations: 0
        total_plans: 2
        no_merge: false
        plugin_dir: /tmp
        config_dir: {config.resolve()}
        owner_pid: {os.getppid()}
        session_id: test
        plans_file: ../../etc/passwd
        progress_file: ../../etc/passwd
        ---
        """))
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not state_file.exists()
        # Security rejection should not produce any block decision (stdout empty)
        assert result.stdout.strip() == "", f"Expected no output on security rejection, got: {result.stdout!r}"

    @requires_jq
    @pytest.mark.security
    def test_rejects_shell_metachar_in_progress_file(self, project_env):
        """Shell metacharacters in progress_file → cleanup and exit."""
        project, config = project_env
        state_file = project / ".claude" / "arc-batch-loop.local.md"
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(textwrap.dedent(f"""\
        ---
        active: true
        iteration: 1
        max_iterations: 0
        total_plans: 2
        no_merge: false
        plugin_dir: /tmp
        config_dir: {config.resolve()}
        owner_pid: {os.getppid()}
        session_id: test
        plans_file: tmp/$(whoami).json
        progress_file: tmp/$(whoami).json
        ---
        """))
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not state_file.exists()
        # Security rejection should not produce any block decision (stdout empty)
        assert result.stdout.strip() == "", f"Expected no output on security rejection, got: {result.stdout!r}"

    @requires_jq
    @pytest.mark.security
    def test_rejects_path_traversal_in_next_plan(self, project_env):
        """Path traversal in plan path → cleanup and exit."""
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()))
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "../../etc/passwd", "status": "pending", "error": None, "completed_at": None},
        ])
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not (project / ".claude" / "arc-batch-loop.local.md").exists()


# ---------------------------------------------------------------------------
# Edge Cases
# ---------------------------------------------------------------------------


class TestArcBatchEdgeCases:
    @requires_jq
    def test_edge_missing_progress_file(self, project_env):
        """Progress file doesn't exist → cleanup state file."""
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()))
        # Don't create progress file
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not (project / ".claude" / "arc-batch-loop.local.md").exists()

    @requires_jq
    def test_edge_empty_progress_file(self, project_env):
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()))
        progress_dir = project / "tmp" / "arc-batch"
        progress_dir.mkdir(parents=True, exist_ok=True)
        (progress_dir / "batch-progress.json").write_text("")
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not (project / ".claude" / "arc-batch-loop.local.md").exists()

    @requires_jq
    def test_edge_corrupted_progress_json(self, project_env):
        project, config = project_env
        write_state_file(project, config, owner_pid=str(os.getpid()))
        progress_dir = project / "tmp" / "arc-batch"
        progress_dir.mkdir(parents=True, exist_ok=True)
        (progress_dir / "batch-progress.json").write_text("{invalid json}")
        result = run_batch_hook(project, config)
        assert result.returncode == 0
        assert not (project / ".claude" / "arc-batch-loop.local.md").exists()


# ---------------------------------------------------------------------------
# Arc Result Signal Detection (v1.109.2)
# ---------------------------------------------------------------------------


class TestArcResultSignalDetection:
    """Tests for 2-layer arc completion detection:
    Layer 1 (PRIMARY): _read_arc_result_signal() — explicit signal at deterministic path
    Layer 2 (FALLBACK): _find_arc_checkpoint() — checkpoint scan
    """

    @requires_jq
    def test_signal_primary_marks_plan_completed(self, project_env):
        """Signal file (Layer 1) → plan marked as completed without needing checkpoint."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        # Only write signal — NO checkpoint file. Signal should be sufficient.
        write_arc_result_signal(project, config, owner_pid=pid, arc_status="completed",
                                pr_url="https://github.com/test/repo/pull/42")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        assert plan_a["status"] == "completed"
        assert plan_a["completed_at"] is not None

    @requires_jq
    def test_signal_pr_url_used(self, project_env):
        """PR URL from signal is recorded in progress file."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        write_arc_result_signal(project, config, owner_pid=pid,
                                pr_url="https://github.com/test/repo/pull/42")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        assert plan_a.get("pr_url") == "https://github.com/test/repo/pull/42"

    @requires_jq
    def test_signal_wrong_pid_ignored(self, project_env):
        """Signal with different owner_pid → ignored, falls back to checkpoint scan."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        # Write signal with WRONG PID
        write_arc_result_signal(project, config, owner_pid="99999", arc_status="completed")
        # Write checkpoint with correct PID (fallback should find this)
        write_checkpoint_file(project, owner_pid=pid, ship_status="completed")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        # Should still be completed via checkpoint fallback (Layer 2)
        assert plan_a["status"] == "completed"

    @requires_jq
    def test_signal_wrong_config_dir_ignored(self, project_env):
        """Signal with different config_dir → ignored."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        # Create signal with wrong config_dir by writing manually
        signal_dir = project / "tmp"
        signal_dir.mkdir(parents=True, exist_ok=True)
        signal = {
            "schema_version": 1,
            "arc_id": "arc-wrong",
            "plan_path": "plans/a.md",
            "status": "completed",
            "pr_url": "https://github.com/test/repo/pull/42",
            "completed_at": "2026-02-26T12:00:00Z",
            "phases_completed": 17,
            "phases_total": 23,
            "owner_pid": pid,
            "config_dir": "/different/config/dir",
        }
        (signal_dir / "arc-result-current.json").write_text(json.dumps(signal))
        # Also write checkpoint as fallback
        write_checkpoint_file(project, owner_pid=pid, ship_status="completed")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        # Completed via checkpoint fallback
        assert plan_a["status"] == "completed"

    @requires_jq
    def test_no_signal_no_checkpoint_defaults_failed(self, project_env):
        """No signal AND no checkpoint → ARC_STATUS defaults to 'failed'."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        # Don't write signal or checkpoint
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        assert plan_a["status"] == "failed"

    @requires_jq
    def test_signal_partial_status(self, project_env):
        """Signal with 'partial' status → plan marked as partial."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        write_arc_result_signal(project, config, owner_pid=pid, arc_status="partial")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        # Partial arcs should be marked as "partial" (not "completed")
        assert plan_a["status"] == "partial"

    @requires_jq
    def test_checkpoint_fallback_when_no_signal(self, project_env):
        """No signal file → falls back to checkpoint scan (Layer 2)."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        # Only write checkpoint — no signal file
        write_checkpoint_file(project, owner_pid=pid, ship_status="completed",
                              pr_url="https://github.com/test/repo/pull/55")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        assert plan_a["status"] == "completed"

    @requires_jq
    def test_signal_symlink_rejected(self, project_env):
        """DOC-007: Symlink signal file → rejected, falls back to checkpoint."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        # Create real signal in a different location, then symlink to expected path
        real_signal = project / "tmp" / "arc-result-real.json"
        real_signal.parent.mkdir(parents=True, exist_ok=True)
        signal = {
            "schema_version": 1,
            "arc_id": f"arc-test-{pid}",
            "plan_path": "plans/a.md",
            "status": "completed",
            "pr_url": "https://github.com/test/repo/pull/42",
            "completed_at": "2026-02-26T12:00:00Z",
            "phases_completed": 17,
            "phases_total": 23,
            "owner_pid": pid,
            "config_dir": str(config.resolve()),
        }
        real_signal.write_text(json.dumps(signal, indent=2))
        symlink_path = project / "tmp" / "arc-result-current.json"
        symlink_path.symlink_to(real_signal)
        # Write checkpoint as fallback (should be used since symlink is rejected)
        write_checkpoint_file(project, owner_pid=pid, ship_status="completed")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        # Should be completed via checkpoint fallback (Layer 2) — symlink signal rejected
        assert plan_a["status"] == "completed"

    @requires_jq
    def test_signal_cleaned_after_consumption(self, project_env):
        """QUAL-004-TEST / v1.109.3: Signal file deleted after consumption to prevent stale reuse."""
        project, config = project_env
        pid = str(os.getpid())
        write_state_file(project, config, owner_pid=pid)
        signal_path = write_arc_result_signal(project, config, owner_pid=pid)
        write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        # Signal exists before hook runs
        assert signal_path.exists(), "Signal should exist before hook runs"
        run_batch_hook(project, config)
        # Signal should be deleted after consumption (prevents iteration N+1 stale read)
        assert not signal_path.exists(), "Stale signal should be cleaned after consumption"

    @requires_jq
    def test_stale_signal_does_not_affect_next_iteration(self, project_env):
        """QUAL-004-TEST: Stale signal from iteration N does NOT cause iteration N+1 to be marked completed."""
        project, config = project_env
        pid = str(os.getpid())
        # Iteration N: signal present, plan marked completed + signal cleaned up
        write_state_file(project, config, owner_pid=pid)
        write_arc_result_signal(project, config, owner_pid=pid, arc_status="completed")
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "in_progress", "error": None, "completed_at": None},
            {"path": "plans/b.md", "status": "pending", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        # Verify iteration N completed correctly
        updated = json.loads(progress_path.read_text())
        plan_a = next(p for p in updated["plans"] if p["path"] == "plans/a.md")
        assert plan_a["status"] == "completed"
        # Iteration N+1: no new signal, no checkpoint → should default to "failed"
        # Simulate iteration N+1 by re-writing state and progress with plan_b as in_progress
        write_state_file(project, config, owner_pid=pid, iteration=2)
        progress_path = write_progress_file(project, [
            {"path": "plans/a.md", "status": "completed", "error": None, "completed_at": "2026-02-26T12:00:00Z"},
            {"path": "plans/b.md", "status": "in_progress", "error": None, "completed_at": None},
        ])
        run_batch_hook(project, config)
        updated = json.loads(progress_path.read_text())
        plan_b = next(p for p in updated["plans"] if p["path"] == "plans/b.md")
        # Without stale cleanup, this would be "completed" (the bug). With cleanup, it's "failed".
        assert plan_b["status"] == "failed", "Stale signal from iteration N should not affect iteration N+1"
