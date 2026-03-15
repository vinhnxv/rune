"""Unit tests for on-teammate-idle.sh (TeammateIdle hook).

Tests the quality gate that validates teammate output before allowing idle.
Verifies guard clauses, output file checks, SEAL enforcement, and security.

Requires: jq (skips gracefully if missing)
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from conftest import SCRIPTS_DIR, requires_jq

SCRIPT = SCRIPTS_DIR / "on-teammate-idle.sh"


def run_idle_hook(
    project: Path,
    config: Path,
    *,
    team_name: str = "rune-review-test123",
    teammate_name: str = "ward-sentinel",
    session_id: str = "",
    env_override: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run on-teammate-idle.sh with a TeammateIdle event."""
    input_json: dict = {
        "team_name": team_name,
        "teammate_name": teammate_name,
        "cwd": str(project),
    }
    if session_id:
        input_json["session_id"] = session_id
    env = os.environ.copy()
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


def setup_inscription(
    project: Path,
    team_name: str = "rune-review-test123",
    *,
    output_dir: str = "tmp/reviews/test123/",
    teammates: list[dict] | None = None,
) -> Path:
    """Create inscription.json with teammate output expectations."""
    signal_dir = project / "tmp" / ".rune-signals" / team_name
    signal_dir.mkdir(parents=True, exist_ok=True)
    if teammates is None:
        teammates = [{"name": "ward-sentinel", "output_file": "ward-sentinel.md"}]
    inscription = {"output_dir": output_dir, "teammates": teammates}
    path = signal_dir / "inscription.json"
    path.write_text(json.dumps(inscription))
    return path


def setup_team_dir(
    config: Path,
    team_name: str = "rune-review-test123",
) -> Path:
    """Create team directory in config dir (required for hook to proceed)."""
    team_dir = config / "teams" / team_name
    team_dir.mkdir(parents=True, exist_ok=True)
    return team_dir


# ---------------------------------------------------------------------------
# Guard Clauses
# ---------------------------------------------------------------------------


class TestTeammateIdleGuardClauses:
    @requires_jq
    def test_exit_0_empty_team_name(self, project_env):
        project, config = project_env
        result = run_idle_hook(project, config, team_name="")
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_non_rune_team(self, project_env):
        project, config = project_env
        result = run_idle_hook(project, config, team_name="custom-team")
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_invalid_team_name(self, project_env):
        project, config = project_env
        result = run_idle_hook(project, config, team_name="rune-$(whoami)")
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_team_name_too_long(self, project_env):
        project, config = project_env
        result = run_idle_hook(project, config, team_name="rune-" + "a" * 200)
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_missing_cwd(self, project_env):
        project, config = project_env
        _ = project  # CWD not needed — input JSON omits cwd
        input_json = {"team_name": "rune-review-test", "teammate_name": "ward"}
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config.resolve())
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            input=json.dumps(input_json),
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_no_inscription(self, project_env):
        """No inscription.json → no quality gate → allow idle."""
        project, config = project_env
        result = run_idle_hook(project, config)
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_teammate_not_in_inscription(self, project_env):
        """Teammate not listed in inscription → allow idle."""
        project, config = project_env
        setup_inscription(
            project,
            teammates=[{"name": "other-ash", "output_file": "other-ash.md"}],
        )
        setup_team_dir(config)
        result = run_idle_hook(project, config, teammate_name="ward-sentinel")
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# Output File Validation
# ---------------------------------------------------------------------------


class TestTeammateIdleOutputValidation:
    @requires_jq
    def test_blocks_when_output_missing(self, project_env):
        """Missing output file → exit 2 (block idle)."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        # Don't create the output file
        (project / "tmp" / "reviews" / "test123").mkdir(parents=True, exist_ok=True)
        result = run_idle_hook(project, config)
        assert result.returncode == 2
        assert "not found" in result.stderr.lower() or "Output file" in result.stderr

    @requires_jq
    def test_blocks_when_output_too_small(self, project_env):
        """Output file under 50 bytes → exit 2 (block idle)."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "ward-sentinel.md").write_text("tiny")
        result = run_idle_hook(project, config)
        assert result.returncode == 2
        assert "too small" in result.stderr.lower() or "empty" in result.stderr.lower()

    @requires_jq
    def test_allows_when_output_exists_and_sufficient(self, project_env):
        """Output file with enough content and findings → exit 0 (allow idle)."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        # Write content with 20+ lines and proper P2 finding markers
        lines = ["# Review Findings", ""]
        for i in range(20):
            lines.append(f"P2: Finding {i+1} — details about this issue")
        lines.append("")
        lines.append("SEAL: ward-sentinel")
        content = "\n".join(lines)
        (output_dir / "ward-sentinel.md").write_text(content)
        result = run_idle_hook(project, config)
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# SEAL Enforcement
# ---------------------------------------------------------------------------


class TestTeammateIdleSealEnforcement:
    @requires_jq
    def test_blocks_review_without_seal(self, project_env):
        """Review team output without SEAL → exit 2."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        content = "# Review Findings\n\n" + "Finding details. " * 10
        (output_dir / "ward-sentinel.md").write_text(content)
        result = run_idle_hook(project, config)
        assert result.returncode == 2
        assert "SEAL" in result.stderr

    @requires_jq
    def test_allows_review_with_seal_colon(self, project_env):
        """SEAL: marker at line start → passes."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        # Write content with 20+ lines and P2 findings (required by finding density check)
        lines = ["# Review", ""]
        for i in range(20):
            lines.append(f"P2: Detail {i+1} — issue details here")
        lines.append("")
        lines.append("SEAL: ward-sentinel")
        content = "\n".join(lines)
        (output_dir / "ward-sentinel.md").write_text(content)
        result = run_idle_hook(project, config)
        assert result.returncode == 0

    @requires_jq
    def test_allows_review_with_seal_tag(self, project_env):
        """<seal> tag → passes."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        # Write content with 20+ lines and P2 findings (required by finding density check)
        lines = ["# Review", ""]
        for i in range(20):
            lines.append(f"P2: Detail {i+1} — issue details here")
        lines.append("")
        lines.append("<seal>ward-sentinel</seal>")
        content = "\n".join(lines)
        (output_dir / "ward-sentinel.md").write_text(content)
        result = run_idle_hook(project, config)
        assert result.returncode == 0

    @requires_jq
    def test_no_seal_for_work_team(self, project_env):
        """Work teams don't require SEAL markers."""
        project, config = project_env
        setup_inscription(
            project,
            team_name="rune-work-abc",
            output_dir="tmp/work/abc/",
        )
        setup_team_dir(config, team_name="rune-work-abc")
        output_dir = project / "tmp" / "work" / "abc"
        output_dir.mkdir(parents=True, exist_ok=True)
        content = "# Implementation\n" + "Code changes. " * 10
        (output_dir / "ward-sentinel.md").write_text(content)
        result = run_idle_hook(project, config, team_name="rune-work-abc")
        assert result.returncode == 0

    @requires_jq
    def test_seal_required_for_audit_team(self, project_env):
        """Audit teams require SEAL (like review teams)."""
        project, config = project_env
        setup_inscription(
            project,
            team_name="rune-audit-abc",
            output_dir="tmp/audit/abc/",
        )
        setup_team_dir(config, team_name="rune-audit-abc")
        output_dir = project / "tmp" / "audit" / "abc"
        output_dir.mkdir(parents=True, exist_ok=True)
        content = "# Audit\n" + "Finding details. " * 10
        (output_dir / "ward-sentinel.md").write_text(content)
        result = run_idle_hook(project, config, team_name="rune-audit-abc")
        assert result.returncode == 2
        assert "SEAL" in result.stderr


# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------


class TestTeammateIdleSecurity:
    @requires_jq
    @pytest.mark.security
    def test_blocks_path_traversal_in_output_file(self, project_env):
        """Path traversal in inscription output_file → exit 2."""
        project, config = project_env
        setup_inscription(
            project,
            teammates=[
                {"name": "ward-sentinel", "output_file": "../../../etc/passwd"}
            ],
        )
        setup_team_dir(config)
        result = run_idle_hook(project, config)
        assert result.returncode == 2
        assert "path traversal" in result.stderr.lower()

    @requires_jq
    @pytest.mark.security
    def test_blocks_path_traversal_in_output_dir(self, project_env):
        """Path traversal in inscription output_dir → exit 2."""
        project, config = project_env
        signal_dir = project / "tmp" / ".rune-signals" / "rune-review-test123"
        signal_dir.mkdir(parents=True, exist_ok=True)
        inscription = {
            "output_dir": "tmp/../../../etc/",
            "teammates": [{"name": "ward-sentinel", "output_file": "ward.md"}],
        }
        (signal_dir / "inscription.json").write_text(json.dumps(inscription))
        setup_team_dir(config)
        result = run_idle_hook(project, config)
        assert result.returncode == 2

    @requires_jq
    @pytest.mark.security
    def test_blocks_output_dir_outside_tmp(self, project_env):
        """output_dir not starting with tmp/ → exit 2."""
        project, config = project_env
        signal_dir = project / "tmp" / ".rune-signals" / "rune-review-test123"
        signal_dir.mkdir(parents=True, exist_ok=True)
        inscription = {
            "output_dir": "src/evil/",
            "teammates": [{"name": "ward-sentinel", "output_file": "ward.md"}],
        }
        (signal_dir / "inscription.json").write_text(json.dumps(inscription))
        setup_team_dir(config)
        result = run_idle_hook(project, config)
        assert result.returncode == 2

    @requires_jq
    @pytest.mark.security
    def test_blocks_invalid_teammate_name_chars(self, project_env):
        """Teammate name with special chars → exit 0 (skip)."""
        project, config = project_env
        result = run_idle_hook(project, config, teammate_name="ward;rm -rf /")
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# Layer 0: Orphan Detection
# ---------------------------------------------------------------------------


class TestTeammateIdleOrphanDetection:
    @requires_jq
    def test_force_stops_when_team_dir_gone(self, project_env):
        """Team directory removed (TeamDelete ran) → {"continue": false}."""
        project, config = project_env
        # Do NOT create team dir — simulates post-TeamDelete state
        result = run_idle_hook(project, config)
        assert result.returncode == 0
        output = json.loads(result.stdout)
        assert output["continue"] is False
        assert "orphaned" in output["stopReason"].lower() or "no longer exists" in output["stopReason"].lower()

    @requires_jq
    def test_force_stops_when_workflow_completed(self, project_env):
        """Workflow state is 'completed' → {"continue": false}."""
        project, config = project_env
        setup_team_dir(config)
        # Write a completed workflow state file
        state = {
            "team_name": "rune-review-test123",
            "status": "completed",
        }
        (project / "tmp" / ".rune-review-test123.json").write_text(json.dumps(state))
        result = run_idle_hook(project, config)
        assert result.returncode == 0
        output = json.loads(result.stdout)
        assert output["continue"] is False
        assert "completed" in output["stopReason"]

    @requires_jq
    def test_force_stops_when_workflow_failed(self, project_env):
        """Workflow state is 'failed' → {"continue": false}."""
        project, config = project_env
        setup_team_dir(config)
        state = {
            "team_name": "rune-review-test123",
            "status": "failed",
        }
        (project / "tmp" / ".rune-review-test123.json").write_text(json.dumps(state))
        result = run_idle_hook(project, config)
        assert result.returncode == 0
        output = json.loads(result.stdout)
        assert output["continue"] is False

    @requires_jq
    def test_allows_when_workflow_in_progress(self, project_env):
        """Workflow state is 'in_progress' → does NOT force-stop."""
        project, config = project_env
        setup_team_dir(config)
        state = {
            "team_name": "rune-review-test123",
            "status": "in_progress",
        }
        (project / "tmp" / ".rune-review-test123.json").write_text(json.dumps(state))
        # No inscription → will exit 0 (no quality gate), but NOT via force-stop
        result = run_idle_hook(project, config)
        assert result.returncode == 0
        # Should NOT have {"continue": false} in output
        if result.stdout.strip():
            try:
                output = json.loads(result.stdout)
                assert output.get("continue") is not False
            except json.JSONDecodeError:
                pass  # No JSON output = allowed idle normally


# ---------------------------------------------------------------------------
# Layer 0.5: Session Ownership (GAP-1 fix)
# ---------------------------------------------------------------------------


class TestTeammateIdleSessionOwnership:
    @requires_jq
    @pytest.mark.session_isolation
    def test_skips_when_session_mismatch(self, project_env):
        """Different session_id → exit 0 (skip, don't apply quality gates)."""
        project, config = project_env
        team_dir = setup_team_dir(config)
        # Stamp team with session-A
        (team_dir / ".session").write_text("session-A")
        # Hook fires from session-B
        setup_inscription(project)
        # Create output dir but NO output file — if session check works,
        # the quality gate (which would block) is never reached
        (project / "tmp" / "reviews" / "test123").mkdir(parents=True, exist_ok=True)
        result = run_idle_hook(project, config, session_id="session-B")
        # Should skip (exit 0) — NOT block (exit 2) despite missing output
        assert result.returncode == 0

    @requires_jq
    @pytest.mark.session_isolation
    def test_proceeds_when_session_matches(self, project_env):
        """Same session_id → apply quality gates normally."""
        project, config = project_env
        team_dir = setup_team_dir(config)
        (team_dir / ".session").write_text("session-A")
        setup_inscription(project)
        (project / "tmp" / "reviews" / "test123").mkdir(parents=True, exist_ok=True)
        # Same session, missing output file → should block
        result = run_idle_hook(project, config, session_id="session-A")
        assert result.returncode == 2

    @requires_jq
    @pytest.mark.session_isolation
    def test_proceeds_when_no_session_file(self, project_env):
        """No .session file in team dir → apply gates (backward compat)."""
        project, config = project_env
        setup_team_dir(config)
        # No .session file written — pre-TLC-004 team
        setup_inscription(project)
        (project / "tmp" / "reviews" / "test123").mkdir(parents=True, exist_ok=True)
        result = run_idle_hook(project, config, session_id="session-A")
        # Should proceed to quality gate → block on missing output
        assert result.returncode == 2

    @requires_jq
    @pytest.mark.session_isolation
    def test_proceeds_when_no_session_in_input(self, project_env):
        """No session_id in hook input → skip check (backward compat)."""
        project, config = project_env
        team_dir = setup_team_dir(config)
        (team_dir / ".session").write_text("session-A")
        setup_inscription(project)
        (project / "tmp" / "reviews" / "test123").mkdir(parents=True, exist_ok=True)
        # No session_id in input — should proceed to quality gate
        result = run_idle_hook(project, config)  # no session_id
        assert result.returncode == 2


# ---------------------------------------------------------------------------
# Retry Gate & Time Gate
# ---------------------------------------------------------------------------


class TestTeammateIdleRetryGate:
    @requires_jq
    def test_blocks_first_two_failures_then_force_stops(self, project_env):
        """After 3 consecutive quality gate failures → {"continue": false}."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        (project / "tmp" / "reviews" / "test123").mkdir(parents=True, exist_ok=True)
        # Don't create output file → each call triggers quality gate failure

        # Failure 1: exit 2 (block + feedback)
        r1 = run_idle_hook(project, config)
        assert r1.returncode == 2

        # Failure 2: exit 2 (block + feedback)
        r2 = run_idle_hook(project, config)
        assert r2.returncode == 2

        # Failure 3: exit 0 with {"continue": false} (force-stop)
        r3 = run_idle_hook(project, config)
        assert r3.returncode == 0
        output = json.loads(r3.stdout)
        assert output["continue"] is False
        assert "quality gate" in output["stopReason"].lower() or "3" in output["stopReason"]

    @requires_jq
    def test_retry_counter_resets_on_success(self, project_env):
        """GAP-2 fix: retry counter resets when quality gate passes."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)

        # Fail twice (counter = 2)
        r1 = run_idle_hook(project, config)
        assert r1.returncode == 2
        r2 = run_idle_hook(project, config)
        assert r2.returncode == 2

        # Now write valid output so the gate passes → resets counter
        lines = ["# Review", ""]
        for i in range(25):
            lines.append(f"P2: Finding {i+1} — issue details here")
        lines.append("")
        lines.append("SEAL: ward-sentinel")
        (output_dir / "ward-sentinel.md").write_text("\n".join(lines))

        r3 = run_idle_hook(project, config)
        assert r3.returncode == 0
        # Verify stdout is NOT {"continue": false}
        if r3.stdout.strip():
            try:
                output = json.loads(r3.stdout)
                assert output.get("continue") is not False
            except json.JSONDecodeError:
                pass

        # Remove output file again → should start fresh counter
        (output_dir / "ward-sentinel.md").unlink()

        # Next 2 failures should block (exit 2), not force-stop
        r4 = run_idle_hook(project, config)
        assert r4.returncode == 2
        r5 = run_idle_hook(project, config)
        assert r5.returncode == 2

    @requires_jq
    def test_time_gate_corrupt_first_idle_resets(self, project_env):
        """Corrupt first-idle file → resets timer instead of false-positive stop."""
        project, config = project_env
        setup_team_dir(config)
        signal_dir = project / "tmp" / ".rune-signals" / "rune-review-test123"
        signal_dir.mkdir(parents=True, exist_ok=True)

        # Write corrupt first-idle file (empty)
        (signal_dir / "ward-sentinel.first-idle").write_text("")

        # No inscription → no quality gate → exit 0 (but should not crash)
        result = run_idle_hook(project, config)
        assert result.returncode == 0

    @requires_jq
    def test_time_gate_stale_first_idle_resets(self, project_env):
        """First-idle timestamp from >24h ago → resets instead of instant stop."""
        project, config = project_env
        setup_team_dir(config)
        signal_dir = project / "tmp" / ".rune-signals" / "rune-review-test123"
        signal_dir.mkdir(parents=True, exist_ok=True)

        # Write epoch from 2 days ago
        import time
        stale_epoch = str(int(time.time()) - 172800)
        (signal_dir / "ward-sentinel.first-idle").write_text(stale_epoch)

        # No inscription → exit 0 (time gate should reset, not trigger)
        result = run_idle_hook(project, config)
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# Worker Evidence Check
# ---------------------------------------------------------------------------


class TestTeammateIdleWorkerEvidence:
    @requires_jq
    def test_worker_allows_idle_when_no_assigned_tasks(self, project_env):
        """Worker with no assigned tasks → allow idle."""
        project, config = project_env
        team_name = "rune-work-abc123"
        setup_team_dir(config, team_name=team_name)
        # Create task dir but no tasks assigned to this worker
        task_dir = config / "tasks" / team_name
        task_dir.mkdir(parents=True, exist_ok=True)
        result = run_idle_hook(project, config, team_name=team_name)
        assert result.returncode == 0

    @requires_jq
    def test_worker_blocks_when_tasks_missing_done_signal(self, project_env):
        """Worker with assigned tasks but no .done signals → exit 2."""
        project, config = project_env
        team_name = "rune-work-abc123"
        setup_team_dir(config, team_name=team_name)

        # Create a task assigned to our teammate
        task_dir = config / "tasks" / team_name
        task_dir.mkdir(parents=True, exist_ok=True)
        task = {"id": "task-001", "owner": "ward-sentinel", "status": "in_progress"}
        (task_dir / "task-001.json").write_text(json.dumps(task))

        # Create signal dir but NO .done file
        signal_dir = project / "tmp" / ".rune-signals" / team_name
        signal_dir.mkdir(parents=True, exist_ok=True)

        result = run_idle_hook(project, config, team_name=team_name)
        assert result.returncode == 2
        assert "task-001" in result.stderr or "completion signal" in result.stderr.lower()

    @requires_jq
    def test_worker_allows_when_all_tasks_have_done_signals(self, project_env):
        """Worker with all assigned tasks having .done signals → allow idle."""
        project, config = project_env
        team_name = "rune-work-abc123"
        setup_team_dir(config, team_name=team_name)

        # Create assigned task
        task_dir = config / "tasks" / team_name
        task_dir.mkdir(parents=True, exist_ok=True)
        task = {"id": "task-001", "owner": "ward-sentinel", "status": "in_progress"}
        (task_dir / "task-001.json").write_text(json.dumps(task))

        # Create .done signal
        signal_dir = project / "tmp" / ".rune-signals" / team_name
        signal_dir.mkdir(parents=True, exist_ok=True)
        (signal_dir / "task-001.done").write_text('{"task_id":"task-001"}')

        result = run_idle_hook(project, config, team_name=team_name)
        assert result.returncode == 0

    @requires_jq
    def test_worker_skips_completed_tasks(self, project_env):
        """Tasks already marked completed are not checked for .done signals."""
        project, config = project_env
        team_name = "rune-work-abc123"
        setup_team_dir(config, team_name=team_name)

        task_dir = config / "tasks" / team_name
        task_dir.mkdir(parents=True, exist_ok=True)
        # Task already completed — should not require .done signal
        task = {"id": "task-001", "owner": "ward-sentinel", "status": "completed"}
        (task_dir / "task-001.json").write_text(json.dumps(task))

        signal_dir = project / "tmp" / ".rune-signals" / team_name
        signal_dir.mkdir(parents=True, exist_ok=True)

        result = run_idle_hook(project, config, team_name=team_name)
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# Content Depth Validation
# ---------------------------------------------------------------------------


class TestTeammateIdleContentDepth:
    def _setup_review_with_output(
        self, project: Path, config: Path, content: str
    ) -> subprocess.CompletedProcess[str]:
        """Helper: set up review inscription and write output content."""
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "ward-sentinel.md").write_text(content)
        return run_idle_hook(project, config)

    @requires_jq
    def test_blocks_shallow_output_for_review(self, project_env):
        """Review output with too few lines → exit 2."""
        project, config = project_env
        # Only 5 lines — well below the 50-line threshold
        content = "# Review\nSEAL: ward-sentinel\nP1: Issue\nDetails.\nEnd."
        result = self._setup_review_with_output(project, config, content)
        assert result.returncode == 2
        assert "shallow" in result.stderr.lower() or "too small" in result.stderr.lower()

    @requires_jq
    def test_blocks_no_findings_and_no_declaration(self, project_env):
        """Output with no findings AND no 'no issues found' declaration → exit 2."""
        project, config = project_env
        # 60 lines of generic text, SEAL present, but no findings or declaration
        lines = ["# Review Findings", ""]
        for i in range(55):
            lines.append(f"Line {i+1}: Some generic analysis text here.")
        lines.append("")
        lines.append("SEAL: ward-sentinel")
        content = "\n".join(lines)
        result = self._setup_review_with_output(project, config, content)
        assert result.returncode == 2
        assert "no findings" in result.stderr.lower() or "explicitly state" in result.stderr.lower()

    @requires_jq
    def test_allows_output_with_no_issues_declaration(self, project_env):
        """Output with explicit 'no issues found' declaration → exit 0."""
        project, config = project_env
        lines = ["# Review Findings", ""]
        for i in range(55):
            lines.append(f"Line {i+1}: Analysis of the code structure.")
        lines.append("")
        lines.append("No issues found in the reviewed files.")
        lines.append("")
        lines.append("SEAL: ward-sentinel")
        content = "\n".join(lines)
        result = self._setup_review_with_output(project, config, content)
        assert result.returncode == 0

    @requires_jq
    def test_allows_output_with_findings(self, project_env):
        """Output with P1/P2 findings → exit 0."""
        project, config = project_env
        lines = ["# Review Findings", ""]
        for i in range(30):
            lines.append(f"P2: Finding {i+1} — details about issue")
        lines.append("")
        lines.append("SEAL: ward-sentinel")
        content = "\n".join(lines)
        result = self._setup_review_with_output(project, config, content)
        assert result.returncode == 0


# ---------------------------------------------------------------------------
# Layer 4: All-Tasks-Done Signal
# ---------------------------------------------------------------------------


class TestTeammateIdleAllTasksDoneSignal:
    @staticmethod
    def _make_valid_review_output(project: Path, team_name: str = "rune-review-test123"):
        """Set up inscription + valid output so quality gates pass, reaching Layer 4."""
        setup_inscription(project, team_name=team_name)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        lines = ["# Review Findings", ""]
        for i in range(25):
            lines.append(f"P2: Finding {i+1} — issue details")
        lines.append("")
        lines.append("SEAL: ward-sentinel")
        (output_dir / "ward-sentinel.md").write_text("\n".join(lines))

    @requires_jq
    def test_writes_all_tasks_done_signal(self, project_env):
        """When all tasks completed → writes all-tasks-done signal file."""
        project, config = project_env
        team_name = "rune-review-test123"
        setup_team_dir(config, team_name=team_name)

        # Create task dir with one completed task
        task_dir = config / "tasks" / team_name
        task_dir.mkdir(parents=True, exist_ok=True)
        task = {"id": "task-001", "status": "completed"}
        (task_dir / "task-001.json").write_text(json.dumps(task))

        # Provide valid inscription + output so quality gates pass → Layer 4 reached
        self._make_valid_review_output(project, team_name)

        result = run_idle_hook(project, config, team_name=team_name)
        assert result.returncode == 0

        signal_file = project / "tmp" / ".rune-signals" / team_name / "all-tasks-done"
        assert signal_file.exists(), "all-tasks-done signal should be written"
        signal_data = json.loads(signal_file.read_text())
        assert "timestamp" in signal_data

    @requires_jq
    def test_no_signal_when_tasks_pending(self, project_env):
        """When tasks still in_progress → no all-tasks-done signal."""
        project, config = project_env
        team_name = "rune-review-test123"
        setup_team_dir(config, team_name=team_name)

        task_dir = config / "tasks" / team_name
        task_dir.mkdir(parents=True, exist_ok=True)
        task = {"id": "task-001", "status": "in_progress"}
        (task_dir / "task-001.json").write_text(json.dumps(task))

        # Valid output so script reaches Layer 4
        self._make_valid_review_output(project, team_name)

        result = run_idle_hook(project, config, team_name=team_name)
        assert result.returncode == 0

        signal_file = project / "tmp" / ".rune-signals" / team_name / "all-tasks-done"
        assert not signal_file.exists(), "all-tasks-done should NOT be written when tasks pending"
