"""Unit tests for enforce-teams.sh (ATE-1: Agent Teams enforcement hook).

Tests the script as a subprocess, verifying:
- Guard clauses: non-Task tools, missing cwd, jq absence
- Workflow detection: review/audit/arc/work/inspect/mend/plan/forge state files
- team_name enforcement: deny Task without team_name, allow Task with team_name
- Session isolation: skip other session's state files (PID + config_dir mismatch)
- Edge cases: no active workflows, stale state files, empty tool_input

Requires: jq (tests decorated with @requires_jq skip gracefully when jq absent)
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Iterator

import pytest

from conftest import SCRIPTS_DIR, requires_jq

ENFORCE_TEAMS = SCRIPTS_DIR / "enforce-teams.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_task_input(
    project: Path,
    *,
    team_name: str | None = None,
    subagent_type: str = "general-purpose",
    description: str = "Do some work",
) -> dict:
    """Build a minimal Task tool_input JSON payload.

    If team_name is None the field is omitted (bare Task call).
    If team_name is provided it is included (compliant Task call).
    subagent_type defaults to "general-purpose" (blocked by ATE-1).
    """
    tool_input: dict = {
        "description": description,
        "subagent_type": subagent_type,
        "prompt": "Perform the task.",
    }
    if team_name is not None:
        tool_input["team_name"] = team_name

    return {
        "tool_name": "Task",
        "cwd": str(project),
        "tool_input": tool_input,
    }


def _make_non_task_input(project: Path, tool_name: str = "Bash") -> dict:
    """Build a minimal non-Task tool invocation JSON payload."""
    return {
        "tool_name": tool_name,
        "cwd": str(project),
        "tool_input": {"command": "echo hello"},
    }


def _write_review_state(
    project: Path,
    suffix: str = "abc123",
    *,
    status: str = "active",
    config_dir: Path | None = None,
    owner_pid: int | None = None,
    workflow_type: str = "review",
) -> Path:
    """Write a tmp/.rune-{workflow_type}-{suffix}.json state file.

    config_dir is stored as its resolved (symlink-free) path because
    resolve-session-identity.sh uses ``pwd -P`` to canonicalize the path,
    which on macOS turns /var/... into /private/var/...
    """
    state: dict = {"status": status, "workflow": workflow_type}
    if config_dir is not None:
        # Use resolve() to match what resolve-session-identity.sh produces via pwd -P
        state["config_dir"] = str(config_dir.resolve())
    if owner_pid is not None:
        state["owner_pid"] = owner_pid
    state_file = project / "tmp" / f".rune-{workflow_type}-{suffix}.json"
    state_file.write_text(json.dumps(state))
    return state_file


def _write_arc_checkpoint(
    project: Path,
    arc_id: str = "forge-abc123",
    *,
    phase: str = "in_progress",
    config_dir: Path | None = None,
    owner_pid: int | None = None,
) -> Path:
    """Write a .rune/arc/{arc_id}/checkpoint.json file.

    config_dir is stored as its resolved (symlink-free) path because
    resolve-session-identity.sh uses ``pwd -P`` to canonicalize the path.
    """
    arc_dir = project / ".claude" / "arc" / arc_id
    arc_dir.mkdir(parents=True, exist_ok=True)
    checkpoint: dict = {"phase": phase, "arc_id": arc_id}
    if config_dir is not None:
        # Use resolve() to match what resolve-session-identity.sh produces via pwd -P
        checkpoint["config_dir"] = str(config_dir.resolve())
    if owner_pid is not None:
        checkpoint["owner_pid"] = owner_pid
    checkpoint_file = arc_dir / "checkpoint.json"
    checkpoint_file.write_text(json.dumps(checkpoint))
    return checkpoint_file


def _deny_output(result: subprocess.CompletedProcess[str]) -> dict:
    """Parse the deny JSON from stdout; raises on invalid JSON."""
    return json.loads(result.stdout.strip())


def _is_deny(result: subprocess.CompletedProcess[str]) -> bool:
    """Return True when the hook output contains a deny decision."""
    if result.returncode != 0:
        return False
    try:
        payload = _deny_output(result)
        decision = (
            payload.get("hookSpecificOutput", {}).get("permissionDecision", "")
        )
        return decision == "deny"
    except (json.JSONDecodeError, KeyError):
        return False


def _is_allow(result: subprocess.CompletedProcess[str]) -> bool:
    """Return True when the hook exits 0 without a deny decision."""
    if result.returncode != 0:
        return False
    stdout = result.stdout.strip()
    if not stdout:
        return True
    try:
        payload = json.loads(stdout)
        decision = (
            payload.get("hookSpecificOutput", {}).get("permissionDecision", "allow")
        )
        return decision != "deny"
    except json.JSONDecodeError:
        return True


# ---------------------------------------------------------------------------
# Guard clause tests
# ---------------------------------------------------------------------------


class TestEnforceTeamsGuardClauses:
    """Fast-exit guard clauses — script should exit 0 without blocking."""

    def test_exit_0_without_jq(self) -> None:
        """Missing jq must not cause a crash — exits 0 with warning on stderr."""
        result = subprocess.run(
            ["bash", str(ENFORCE_TEAMS)],
            input=json.dumps({"tool_name": "Task", "cwd": "/tmp"}),
            capture_output=True,
            text=True,
            timeout=10,
            env={**os.environ, "PATH": "/usr/bin:/bin"},
        )
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_non_task_tool_bash(self, hook_runner) -> None:
        """Non-Task tools (Bash) must be passed through immediately."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "ls"}},
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_non_task_tool_write(self, hook_runner) -> None:
        """Write tool must not be blocked by this hook."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {
                "tool_name": "Write",
                "cwd": "/tmp",
                "tool_input": {"file_path": "/tmp/x.txt", "content": "hi"},
            },
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_non_task_tool_read(self, hook_runner) -> None:
        """Read tool must not be blocked by this hook."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "Read", "cwd": "/tmp", "tool_input": {"file_path": "/tmp/x"}},
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_team_create_tool(self, hook_runner) -> None:
        """TeamCreate is handled by a different hook; must pass through here."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {
                "tool_name": "TeamCreate",
                "cwd": "/tmp",
                "tool_input": {"team_name": "rune-test"},
            },
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_missing_tool_name(self, hook_runner) -> None:
        """Missing tool_name field must not block (defaults to empty, not Task)."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {"cwd": "/tmp", "tool_input": {}},
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_empty_tool_name(self, hook_runner) -> None:
        """Empty tool_name string must exit 0 immediately."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "", "cwd": "/tmp", "tool_input": {}},
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_missing_cwd(self, hook_runner) -> None:
        """Task tool with no cwd field must exit 0 (cannot resolve project)."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "Task", "tool_input": {"description": "work"}},
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_empty_cwd(self, hook_runner) -> None:
        """Empty cwd string must exit 0."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "Task", "cwd": "", "tool_input": {}},
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_nonexistent_cwd(self, hook_runner) -> None:
        """cwd pointing to a nonexistent path must exit 0."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {
                "tool_name": "Task",
                "cwd": "/nonexistent/path/abc123xyz",
                "tool_input": {},
            },
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_relative_cwd(self, hook_runner) -> None:
        """Relative cwd that resolves to a non-absolute path must exit 0."""
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "Task", "cwd": "relative/path", "tool_input": {}},
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_exit_0_for_malformed_json_input(self, hook_runner) -> None:
        """Malformed JSON stdin must exit 0 without crashing."""
        result = hook_runner(ENFORCE_TEAMS, "{{not valid json{{")
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_task_with_no_active_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Task tool with no active Rune workflow must be allowed through."""
        project, config = project_env
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project),
        )
        assert result.returncode == 0
        assert not _is_deny(result)


# ---------------------------------------------------------------------------
# Workflow detection tests
# ---------------------------------------------------------------------------


class TestEnforceTeamsWorkflowDetection:
    """Verify that each supported Rune workflow type is correctly detected."""

    @requires_jq
    def test_detects_active_review_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Active .rune-review-*.json with status='active' is detected."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_detects_active_audit_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Active .rune-audit-*.json with status='active' is detected."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="audit"
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_detects_active_work_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Active .rune-work-*.json with status='active' is detected."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="work"
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_detects_active_inspect_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Active .rune-inspect-*.json with status='active' is detected."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="inspect"
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_detects_active_mend_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Active .rune-mend-*.json with status='active' is detected."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="mend"
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_detects_active_plan_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Active .rune-plan-*.json with status='active' is detected."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="plan"
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_detects_active_forge_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Active .rune-forge-*.json with status='active' is detected."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="forge"
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_detects_active_arc_checkpoint(
        self, hook_runner, project_env
    ) -> None:
        """Arc checkpoint with 'in_progress' phase triggers enforcement."""
        project, config = project_env
        _write_arc_checkpoint(
            project, config_dir=config, owner_pid=os.getpid()
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_arc_completed_checkpoint_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """Arc checkpoint with 'completed' phase (no 'in_progress') is not active."""
        project, config = project_env
        _write_arc_checkpoint(
            project, phase="completed", config_dir=config, owner_pid=os.getpid()
        )
        # 'in_progress' is searched as a literal string in the file.
        # A checkpoint that only contains "completed" won't match.
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        # completed checkpoints have no "in_progress" string → not active
        assert not _is_deny(result)

    @requires_jq
    def test_review_inactive_status_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """State file with status != 'active' must not trigger enforcement."""
        project, config = project_env
        _write_review_state(
            project,
            status="completed",
            config_dir=config,
            owner_pid=os.getpid(),
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_review_cancelled_status_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """State file with status='cancelled' must not trigger enforcement."""
        project, config = project_env
        _write_review_state(
            project,
            status="cancelled",
            config_dir=config,
            owner_pid=os.getpid(),
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_no_tmp_dir_no_detection(self, hook_runner, project_env) -> None:
        """Project without tmp/ directory cannot have state files — allowed."""
        project, config = project_env
        # tmp/ exists from fixture; remove it to simulate a fresh project
        tmp_dir = project / "tmp"
        for child in tmp_dir.iterdir():
            child.unlink()
        tmp_dir.rmdir()
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_empty_tmp_dir_no_detection(self, hook_runner, project_env) -> None:
        """Empty tmp/ directory has no state files — Task allowed."""
        project, config = project_env
        # tmp/ exists but is empty (no .rune-*.json files)
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_no_arc_dir_skips_arc_check(self, hook_runner, project_env) -> None:
        """Missing .rune/arc/ directory means no arc workflows to check."""
        project, config = project_env
        import shutil
        arc_dir = project / ".claude" / "arc"
        if arc_dir.exists():
            shutil.rmtree(arc_dir)
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)


# ---------------------------------------------------------------------------
# team_name enforcement tests
# ---------------------------------------------------------------------------


class TestEnforceTeamsTeamNameEnforcement:
    """Verify correct allow/deny decisions based on team_name presence."""

    @requires_jq
    def test_denies_task_without_team_name_during_review(
        self, hook_runner, project_env
    ) -> None:
        """Bare Task (no team_name) during active review must be denied."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert result.returncode == 0
        assert _is_deny(result)

    @requires_jq
    def test_denies_task_without_team_name_during_audit(
        self, hook_runner, project_env
    ) -> None:
        """Bare Task during active audit must be denied."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="audit"
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)

    @requires_jq
    def test_denies_task_without_team_name_during_arc(
        self, hook_runner, project_env
    ) -> None:
        """Bare Task during active arc checkpoint must be denied."""
        project, config = project_env
        _write_arc_checkpoint(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)

    @requires_jq
    def test_allows_task_with_team_name_during_review(
        self, hook_runner, project_env
    ) -> None:
        """Task with team_name during active review must be allowed."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name="rune-review-abc123"),
        )
        assert result.returncode == 0
        assert not _is_deny(result)

    @requires_jq
    def test_allows_task_with_team_name_during_audit(
        self, hook_runner, project_env
    ) -> None:
        """Task with team_name during active audit must be allowed."""
        project, config = project_env
        _write_review_state(
            project, config_dir=config, owner_pid=os.getpid(), workflow_type="audit"
        )
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name="rune-audit-xyz789"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_allows_task_with_team_name_during_arc(
        self, hook_runner, project_env
    ) -> None:
        """Task with team_name during active arc must be allowed."""
        project, config = project_env
        _write_arc_checkpoint(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name="arc-forge-123abc"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_allows_task_with_empty_team_name_denied(
        self, hook_runner, project_env
    ) -> None:
        """Task with team_name set to empty string is treated as missing — denied."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        payload = {
            "tool_name": "Task",
            "cwd": str(project),
            "tool_input": {
                "description": "Work",
                "team_name": "",
            },
        }
        result = hook_runner(ENFORCE_TEAMS, payload)
        assert _is_deny(result)

    @requires_jq
    def test_deny_json_has_ate1_violation_message(
        self, hook_runner, project_env
    ) -> None:
        """The deny permissionDecisionReason must reference ATE-1."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)
        payload = _deny_output(result)
        reason = payload["hookSpecificOutput"].get("permissionDecisionReason", "")
        assert "ATE-1" in reason

    @requires_jq
    def test_deny_json_has_correct_hook_event_name(
        self, hook_runner, project_env
    ) -> None:
        """Deny JSON must contain hookEventName='PreToolUse' per hook contract."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)
        payload = _deny_output(result)
        event_name = payload["hookSpecificOutput"].get("hookEventName", "")
        assert event_name == "PreToolUse"

    @requires_jq
    def test_deny_json_has_additional_context(
        self, hook_runner, project_env
    ) -> None:
        """Deny JSON must include additionalContext field with remediation guidance."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)
        payload = _deny_output(result)
        ctx = payload["hookSpecificOutput"].get("additionalContext", "")
        assert len(ctx) > 0
        assert "team_name" in ctx.lower() or "TeamCreate" in ctx

    @requires_jq
    def test_deny_json_is_valid_json(self, hook_runner, project_env) -> None:
        """Deny output must be syntactically valid JSON."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert result.returncode == 0
        # Must not raise
        payload = json.loads(result.stdout.strip())
        assert isinstance(payload, dict)

    @requires_jq
    def test_allows_task_no_workflow_any_team_name(
        self, hook_runner, project_env
    ) -> None:
        """Without an active workflow, Task is always allowed regardless of team_name."""
        project, _ = project_env
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name="arbitrary-team"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_allows_task_no_workflow_no_team_name(
        self, hook_runner, project_env
    ) -> None:
        """Without an active workflow, even a bare Task must be allowed."""
        project, _ = project_env
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert not _is_deny(result)


# ---------------------------------------------------------------------------
# Read-only subagent exemption tests (ATE-1 exemption for Explore/Plan)
# ---------------------------------------------------------------------------


class TestEnforceTeamsReadOnlyExemption:
    """Verify that read-only built-in subagent types (Explore, Plan) are exempt."""

    @requires_jq
    def test_allows_explore_without_team_name_during_review(
        self, hook_runner, project_env
    ) -> None:
        """Explore subagent (read-only, Haiku) must be allowed without team_name."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="Explore"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_allows_plan_without_team_name_during_review(
        self, hook_runner, project_env
    ) -> None:
        """Plan subagent (read-only) must be allowed without team_name."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="Plan"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_allows_explore_without_team_name_during_arc(
        self, hook_runner, project_env
    ) -> None:
        """Explore must be allowed during active arc checkpoint."""
        project, config = project_env
        _write_arc_checkpoint(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="Explore"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_allows_plan_without_team_name_during_arc(
        self, hook_runner, project_env
    ) -> None:
        """Plan must be allowed during active arc checkpoint."""
        project, config = project_env
        _write_arc_checkpoint(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="Plan"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_denies_general_purpose_without_team_name(
        self, hook_runner, project_env
    ) -> None:
        """general-purpose agents must still be denied without team_name."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="general-purpose"),
        )
        assert _is_deny(result)

    @requires_jq
    def test_denies_bash_agent_without_team_name(
        self, hook_runner, project_env
    ) -> None:
        """Bash subagent type must still be denied without team_name."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="Bash"),
        )
        assert _is_deny(result)

    @requires_jq
    def test_denies_custom_rune_agent_without_team_name(
        self, hook_runner, project_env
    ) -> None:
        """Custom Rune agent types must still be denied without team_name."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(
                project, team_name=None, subagent_type="rune:review:flaw-hunter"
            ),
        )
        assert _is_deny(result)

    @requires_jq
    def test_explore_case_sensitive(
        self, hook_runner, project_env
    ) -> None:
        """Explore exemption is case-sensitive — 'explore' (lowercase) is denied."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="explore"),
        )
        assert _is_deny(result)

    @requires_jq
    def test_explore_no_workflow_still_allowed(
        self, hook_runner, project_env
    ) -> None:
        """Explore without active workflow is allowed (baseline — no enforcement)."""
        project, _ = project_env
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name=None, subagent_type="Explore"),
        )
        assert not _is_deny(result)


# ---------------------------------------------------------------------------
# Session isolation tests
# ---------------------------------------------------------------------------


class TestEnforceTeamsSessionIsolation:
    """Cross-session safety: state files from other sessions must be ignored."""

    @requires_jq
    def test_skips_review_state_from_different_config_dir(
        self, hook_runner, project_env
    ) -> None:
        """State file with a different config_dir must be skipped."""
        project, config = project_env
        with tempfile.TemporaryDirectory(prefix="rune-other-config-") as other_cfg:
            # Write state that belongs to a different config dir
            _write_review_state(
                project,
                config_dir=Path(other_cfg),
                owner_pid=os.getpid(),
            )
            result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
            # Should not block — belongs to different installation
            assert not _is_deny(result)

    @requires_jq
    def test_skips_arc_checkpoint_from_different_config_dir(
        self, hook_runner, project_env
    ) -> None:
        """Arc checkpoint with a different config_dir must be skipped."""
        project, config = project_env
        with tempfile.TemporaryDirectory(prefix="rune-other-config-") as other_cfg:
            _write_arc_checkpoint(
                project,
                config_dir=Path(other_cfg),
                owner_pid=os.getpid(),
            )
            result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
            assert not _is_deny(result)

    @requires_jq
    def test_skips_review_state_owned_by_live_other_pid(
        self, hook_runner, project_env
    ) -> None:
        """State file owned by a live PID != PPID (active sibling session) is skipped.

        The hook_runner fixture sets env PPID=os.getpid() (the test process PID).
        We use os.getppid() as the stored owner_pid: it is a different live process
        that is accessible via kill -0 (same uid), so the hook must skip this file.
        """
        project, config = project_env
        # Guard: test requires parent PID to differ from current PID
        assert os.getppid() != os.getpid(), "PID namespace prevents this test"
        # os.getppid() is alive and accessible (kill -0 succeeds) but != os.getpid()
        live_other_pid = os.getppid()
        _write_review_state(
            project,
            config_dir=config,
            owner_pid=live_other_pid,
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        # live pid != PPID and kill -0 succeeds → different session → skip → not deny
        assert not _is_deny(result)

    @requires_jq
    def test_skips_arc_checkpoint_owned_by_live_other_pid(
        self, hook_runner, project_env
    ) -> None:
        """Arc checkpoint owned by a live foreign PID must be skipped."""
        project, config = project_env
        # Guard: test requires parent PID to differ from current PID
        assert os.getppid() != os.getpid(), "PID namespace prevents this test"
        # os.getppid() is alive and accessible (kill -0 succeeds) but != os.getpid()
        live_other_pid = os.getppid()
        _write_arc_checkpoint(
            project,
            config_dir=config,
            owner_pid=live_other_pid,
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_processes_review_state_owned_by_dead_pid(
        self, hook_runner, project_env
    ) -> None:
        """State owned by a dead PID (orphan) must be considered for the current session."""
        project, config = project_env
        # Use a very large PID that is almost certainly not running
        dead_pid = 2_000_000
        _write_review_state(
            project,
            config_dir=config,
            owner_pid=dead_pid,
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        # Orphaned state is treated as belonging to current context → enforce
        assert _is_deny(result)

    @requires_jq
    def test_processes_arc_checkpoint_owned_by_dead_pid(
        self, hook_runner, project_env
    ) -> None:
        """Arc checkpoint owned by a dead PID must be picked up for enforcement."""
        project, config = project_env
        dead_pid = 2_000_000
        _write_arc_checkpoint(
            project,
            config_dir=config,
            owner_pid=dead_pid,
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_processes_state_without_ownership_fields(
        self, hook_runner, project_env
    ) -> None:
        """State file with no config_dir / owner_pid is treated as current session."""
        project, _config = project_env
        # Write a minimal state file without ownership metadata
        state_file = project / "tmp" / ".rune-review-minimal.json"
        state_file.write_text(json.dumps({"status": "active"}))
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        # No ownership info → not filtered → enforced
        assert _is_deny(result)

    @requires_jq
    def test_skips_multiple_other_session_states(
        self, hook_runner, project_env
    ) -> None:
        """Multiple state files all from other live sessions → no active workflow."""
        project, config = project_env
        live_other_pid = os.getppid()  # alive + accessible, != test process PID
        for i, wtype in enumerate(("review", "audit", "work")):
            _write_review_state(
                project,
                suffix=f"other-{i}",
                config_dir=config,
                owner_pid=live_other_pid,
                workflow_type=wtype,
            )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_own_session_state_detected_among_foreign_states(
        self, hook_runner, project_env
    ) -> None:
        """One own-session state mixed with foreign states triggers enforcement."""
        project, config = project_env
        live_other_pid = os.getppid()  # alive + accessible, != test process PID
        # Two foreign states (live accessible pid, different from test PPID → skip)
        _write_review_state(
            project, suffix="foreign-1", config_dir=config, owner_pid=live_other_pid
        )
        _write_review_state(
            project, suffix="foreign-2", config_dir=config, owner_pid=live_other_pid
        )
        # One owned by current session (dead PID → orphan → not filtered → enforced)
        _write_review_state(
            project,
            suffix="own",
            config_dir=config,
            owner_pid=2_000_000,  # dead — not filtered
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)


# ---------------------------------------------------------------------------
# Edge case and staleness tests
# ---------------------------------------------------------------------------


class TestEnforceTeamsEdgeCases:
    """Edge cases: stale state files, no workflow, malformed state, multiple files."""

    @requires_jq
    def test_stale_review_state_file_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """State files older than 120 minutes must not trigger enforcement.

        We simulate staleness by backdating the mtime using os.utime().
        Note: STALE_THRESHOLD_MIN is 120 in enforce-teams.sh, so we use 130 min.
        """
        project, config = project_env
        state_file = _write_review_state(
            project, config_dir=config, owner_pid=os.getpid()
        )
        # Backdate to 130 minutes ago (beyond 120-min threshold)
        stale_time = time.time() - (130 * 60)
        os.utime(state_file, (stale_time, stale_time))
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_stale_arc_checkpoint_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """Arc checkpoint older than 120 minutes must be ignored.

        Note: STALE_THRESHOLD_MIN is 120 in enforce-teams.sh, so we use 130 min.
        """
        project, config = project_env
        checkpoint_file = _write_arc_checkpoint(
            project, config_dir=config, owner_pid=os.getpid()
        )
        # Backdate to 130 minutes ago (beyond 120-min threshold)
        stale_time = time.time() - (130 * 60)
        os.utime(checkpoint_file, (stale_time, stale_time))
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_fresh_review_state_detected(
        self, hook_runner, project_env
    ) -> None:
        """State file written just now (fresh) must trigger enforcement."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert _is_deny(result)

    @requires_jq
    def test_multiple_active_workflow_types_enforce_once(
        self, hook_runner, project_env
    ) -> None:
        """Multiple simultaneous active workflow state files → still deny (idempotent)."""
        project, config = project_env
        _write_review_state(
            project, suffix="r1", config_dir=config, owner_pid=os.getpid()
        )
        _write_review_state(
            project,
            suffix="a1",
            config_dir=config,
            owner_pid=os.getpid(),
            workflow_type="audit",
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)

    @requires_jq
    def test_task_with_team_name_allowed_even_with_multiple_active_workflows(
        self, hook_runner, project_env
    ) -> None:
        """Multiple active workflows but Task includes team_name → allowed."""
        project, config = project_env
        _write_review_state(
            project, suffix="r1", config_dir=config, owner_pid=os.getpid()
        )
        _write_review_state(
            project,
            suffix="a1",
            config_dir=config,
            owner_pid=os.getpid(),
            workflow_type="audit",
        )
        result = hook_runner(
            ENFORCE_TEAMS,
            _make_task_input(project, team_name="rune-review-r1"),
        )
        assert not _is_deny(result)

    @requires_jq
    def test_malformed_state_file_json_does_not_crash(
        self, hook_runner, project_env
    ) -> None:
        """Malformed JSON in a state file must not crash the hook."""
        project, _config = project_env
        bad_state = project / "tmp" / ".rune-review-bad.json"
        bad_state.write_text("{invalid json {{")
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert result.returncode == 0

    @requires_jq
    def test_state_file_missing_status_field_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """State file without a 'status' field does not contain 'active' → skipped."""
        project, config = project_env
        state_file = project / "tmp" / ".rune-review-nostatus.json"
        state_file.write_text(json.dumps({"workflow": "review", "config_dir": str(config)}))
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        # No "active" string in file → not detected as active workflow
        assert not _is_deny(result)

    @requires_jq
    def test_unknown_rune_prefix_file_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """Unknown .rune-*.json file type (not in supported list) is not checked."""
        project, _config = project_env
        # e.g. .rune-unknown-abc.json — not in the glob list
        state_file = project / "tmp" / ".rune-unknown-abc.json"
        state_file.write_text(json.dumps({"status": "active"}))
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert not _is_deny(result)

    @requires_jq
    def test_arc_checkpoint_at_wrong_depth_not_detected(
        self, hook_runner, project_env
    ) -> None:
        """Arc checkpoint deeper than maxdepth 2 is not found by find."""
        project, config = project_env
        # Place checkpoint 3 levels deep: .rune/arc/a/b/checkpoint.json
        deep_dir = project / ".claude" / "arc" / "a" / "b"
        deep_dir.mkdir(parents=True, exist_ok=True)
        checkpoint = deep_dir / "checkpoint.json"
        checkpoint.write_text(
            json.dumps({"phase": "in_progress", "config_dir": str(config)})
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        # find -maxdepth 2 won't reach depth 3 → not detected
        assert not _is_deny(result)

    @requires_jq
    def test_non_task_tool_not_blocked_even_with_active_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Non-Task tools must never be blocked regardless of active workflow."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        for tool_name in ("Bash", "Write", "Read", "Edit", "Grep", "Glob"):
            result = hook_runner(
                ENFORCE_TEAMS,
                _make_non_task_input(project, tool_name=tool_name),
            )
            assert result.returncode == 0, f"{tool_name} should not be blocked"
            assert not _is_deny(result), f"{tool_name} should not produce deny output"

    @requires_jq
    def test_empty_tool_input_object_denied_during_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Task with completely empty tool_input (no team_name) is denied."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "Task", "cwd": str(project), "tool_input": {}},
        )
        assert _is_deny(result)

    @requires_jq
    def test_null_tool_input_denied_during_workflow(
        self, hook_runner, project_env
    ) -> None:
        """Task with null tool_input (no team_name) is denied during active workflow."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            {"tool_name": "Task", "cwd": str(project), "tool_input": None},
        )
        assert _is_deny(result)

    @requires_jq
    def test_task_with_team_name_none_value_denied(
        self, hook_runner, project_env
    ) -> None:
        """Task with team_name=null in tool_input is treated as missing."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(
            ENFORCE_TEAMS,
            {
                "tool_name": "Task",
                "cwd": str(project),
                "tool_input": {"team_name": None},
            },
        )
        assert _is_deny(result)

    @requires_jq
    def test_exit_0_always_regardless_of_decision(
        self, hook_runner, project_env
    ) -> None:
        """Hook must always exit 0 (never exit 2) — deny is in JSON, not exit code."""
        project, config = project_env
        _write_review_state(project, config_dir=config, owner_pid=os.getpid())
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert result.returncode == 0

    @requires_jq
    def test_symlinked_state_file_handled_gracefully(
        self, hook_runner, project_env
    ) -> None:
        """Symlinked state file pointing to active content is handled without crash."""
        project, config = project_env
        # Write real state in a temp location
        real_state = project / "tmp" / ".real-state.json"
        real_state.write_text(json.dumps({"status": "active", "config_dir": str(config)}))
        # Symlink as a review state file
        symlink = project / "tmp" / ".rune-review-symlink.json"
        symlink.symlink_to(real_state)
        # The hook should handle the symlink (either detect or skip) without crash
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project))
        assert result.returncode == 0

    @requires_jq
    def test_multiple_arc_checkpoints_one_active(
        self, hook_runner, project_env
    ) -> None:
        """Multiple arc checkpoints — only one is in_progress — must enforce."""
        project, config = project_env
        _write_arc_checkpoint(
            project, arc_id="arc-completed-1", phase="completed",
            config_dir=config, owner_pid=os.getpid()
        )
        _write_arc_checkpoint(
            project, arc_id="arc-active-2", phase="in_progress",
            config_dir=config, owner_pid=os.getpid()
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)

    @requires_jq
    def test_stale_plus_fresh_state_enforces_on_fresh(
        self, hook_runner, project_env
    ) -> None:
        """One stale and one fresh state file → fresh triggers enforcement.

        Note: STALE_THRESHOLD_MIN is 120 in enforce-teams.sh, so we use 130 min for stale.
        """
        project, config = project_env
        # Write stale state (130 min ago = beyond 120-min threshold)
        stale_file = _write_review_state(
            project,
            suffix="stale-one",
            config_dir=config,
            owner_pid=os.getpid(),
        )
        stale_time = time.time() - 130 * 60
        os.utime(stale_file, (stale_time, stale_time))
        # Write fresh state
        _write_review_state(
            project,
            suffix="fresh-one",
            config_dir=config,
            owner_pid=os.getpid(),
            workflow_type="audit",
        )
        result = hook_runner(ENFORCE_TEAMS, _make_task_input(project, team_name=None))
        assert _is_deny(result)
