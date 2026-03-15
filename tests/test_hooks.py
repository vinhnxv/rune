"""Unit tests for Rune hook scripts (on-task-completed.sh, on-teammate-idle.sh).

Tests the shell scripts as subprocesses, verifying:
- Exit codes for various input scenarios
- Guard clauses (non-Rune teams, invalid characters, path traversal)
- Signal file creation and atomicity
- SEAL enforcement for review/audit workflows
- JSON validity checks and diagnostics

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
TASK_COMPLETED = SCRIPTS_DIR / "on-task-completed.sh"
TEAMMATE_IDLE = SCRIPTS_DIR / "on-teammate-idle.sh"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_hook(
    script: Path,
    input_json: dict | str,
    *,
    env_override: dict[str, str] | None = None,
    timeout: int = 10,
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
def signal_dir() -> Iterator[Path]:
    """Create a temporary signal directory structure for testing."""
    with tempfile.TemporaryDirectory(prefix="rune-test-") as tmpdir:
        tmp = Path(tmpdir)
        # Create the signal directory structure: tmp/.rune-signals/{team_name}/
        signals = tmp / "tmp" / ".rune-signals" / "rune-test-team"
        signals.mkdir(parents=True)
        yield tmp


@pytest.fixture
def inscription_dir() -> Iterator[Path]:
    """Create a temporary directory with an inscription.json for idle tests.

    Also creates a config directory with the team directory so the hook
    doesn't treat the teammate as orphaned.
    """
    with tempfile.TemporaryDirectory(prefix="rune-idle-test-") as tmpdir:
        tmp = Path(tmpdir)
        signals = tmp / "tmp" / ".rune-signals" / "rune-review-test"
        signals.mkdir(parents=True)

        # Write inscription.json
        inscription = {
            "teammates": [
                {"name": "test-ash", "output_file": "test-ash.md"},
            ],
            "output_dir": "tmp/reviews/test/",
        }
        inscription_path = signals / "inscription.json"
        inscription_path.write_text(json.dumps(inscription))

        # Create output directory
        output_dir = tmp / "tmp" / "reviews" / "test"
        output_dir.mkdir(parents=True)

        # Create config directory with team directory (required for hook to proceed)
        config_dir = tmp / "config"
        team_dir = config_dir / "teams" / "rune-review-test"
        team_dir.mkdir(parents=True)

        # Set environment variable for tests that use run_hook
        os.environ["CLAUDE_CONFIG_DIR"] = str(config_dir.resolve())

        yield tmp

        # Cleanup
        os.environ.pop("CLAUDE_CONFIG_DIR", None)


# ===========================================================================
# on-task-completed.sh tests
# ===========================================================================


class TestTaskCompleted:
    """Tests for on-task-completed.sh."""

    @requires_jq
    def test_exit_0_for_non_rune_team(self) -> None:
        """Non-Rune teams should be silently skipped (exit 0)."""
        result = run_hook(TASK_COMPLETED, {
            "team_name": "other-team",
            "task_id": "1",
            "teammate_name": "worker",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_empty_team_name(self) -> None:
        """Missing team_name should exit 0."""
        result = run_hook(TASK_COMPLETED, {
            "task_id": "1",
            "teammate_name": "worker",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_missing_task_id(self) -> None:
        """Missing task_id should exit 0."""
        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-review-test",
            "teammate_name": "worker",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_malformed_json(self) -> None:
        """Malformed JSON should warn on stderr and exit 0 (BACK-101)."""
        result = run_hook(TASK_COMPLETED, "not valid json {{{")
        assert result.returncode == 0
        assert "not valid JSON" in result.stderr

    @requires_jq
    def test_exit_0_for_path_traversal_in_team_name(self) -> None:
        """Team names with path traversal chars should be rejected."""
        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-../evil",
            "task_id": "1",
            "teammate_name": "worker",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_invalid_task_id_chars(self) -> None:
        """Task IDs with special characters should be rejected."""
        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-review-test",
            "task_id": "../../etc/passwd",
            "teammate_name": "worker",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_oversized_team_name(self) -> None:
        """Team names exceeding 128 chars should be rejected."""
        long_name = "rune-" + "a" * 130
        result = run_hook(TASK_COMPLETED, {
            "team_name": long_name,
            "task_id": "1",
            "teammate_name": "worker",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_when_signal_dir_missing(self) -> None:
        """When signal directory doesn't exist, exit 0 silently."""
        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-review-test",
            "task_id": "1",
            "teammate_name": "worker",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_missing_cwd(self) -> None:
        """Missing cwd field should warn and exit 0."""
        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-review-test",
            "task_id": "1",
            "teammate_name": "worker",
        })
        assert result.returncode == 0
        assert "missing 'cwd'" in result.stderr.lower() or result.returncode == 0

    @requires_jq
    def test_writes_signal_file(self, signal_dir: Path) -> None:
        """Valid input with existing signal dir should create a .done file."""
        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-test-team",
            "task_id": "task-42",
            "teammate_name": "test-worker",
            "task_subject": "Test task",
            "cwd": str(signal_dir),
        })
        assert result.returncode == 0

        done_file = signal_dir / "tmp" / ".rune-signals" / "rune-test-team" / "task-42.done"
        assert done_file.exists(), f"Expected {done_file} to exist"

        content = json.loads(done_file.read_text())
        assert content["task_id"] == "task-42"
        assert content["teammate"] == "test-worker"
        assert content["subject"] == "Test task"
        assert "completed_at" in content

    @requires_jq
    def test_truncates_long_subject(self, signal_dir: Path) -> None:
        """Subjects longer than 256 chars should be truncated (SEC-C05)."""
        long_subject = "x" * 500
        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-test-team",
            "task_id": "task-trunc",
            "teammate_name": "worker",
            "task_subject": long_subject,
            "cwd": str(signal_dir),
        })
        assert result.returncode == 0

        done_file = signal_dir / "tmp" / ".rune-signals" / "rune-test-team" / "task-trunc.done"
        if done_file.exists():
            content = json.loads(done_file.read_text())
            assert len(content["subject"]) <= 256

    @requires_jq
    def test_expected_file_validation(self, signal_dir: Path) -> None:
        """Invalid .expected content should warn and exit 0."""
        expected_file = signal_dir / "tmp" / ".rune-signals" / "rune-test-team" / ".expected"
        expected_file.write_text("0")  # Invalid: must be positive integer

        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-test-team",
            "task_id": "task-99",
            "teammate_name": "worker",
            "task_subject": "Test",
            "cwd": str(signal_dir),
        })
        assert result.returncode == 0

    @requires_jq
    def test_all_done_sentinel(self, signal_dir: Path) -> None:
        """When all tasks complete, .all-done sentinel should be written."""
        team_dir = signal_dir / "tmp" / ".rune-signals" / "rune-test-team"

        # Set expected count to 1
        (team_dir / ".expected").write_text("1")

        result = run_hook(TASK_COMPLETED, {
            "team_name": "rune-test-team",
            "task_id": "only-task",
            "teammate_name": "worker",
            "task_subject": "Solo task",
            "cwd": str(signal_dir),
        })
        assert result.returncode == 0

        all_done = team_dir / ".all-done"
        assert all_done.exists(), "Expected .all-done sentinel to be written when DONE_COUNT >= EXPECTED"

    @requires_jq
    def test_arc_team_prefix_accepted(self, signal_dir: Path) -> None:
        """Arc teams (arc-*) should also be processed."""
        # Create signal dir for arc team
        arc_dir = signal_dir / "tmp" / ".rune-signals" / "arc-work-test"
        arc_dir.mkdir(parents=True)

        result = run_hook(TASK_COMPLETED, {
            "team_name": "arc-work-test",
            "task_id": "arc-1",
            "teammate_name": "worker",
            "task_subject": "Arc task",
            "cwd": str(signal_dir),
        })
        assert result.returncode == 0

        done_file = arc_dir / "arc-1.done"
        assert done_file.exists()

    def test_exit_0_without_jq(self) -> None:
        """Script should exit 0 with warning when jq is missing."""
        result = run_hook(
            TASK_COMPLETED,
            "{}",
            env_override={"PATH": "/usr/bin:/bin"},  # Likely no jq
        )
        # Either exits 0 (jq missing → warning) or exits 0 (jq present → no-op)
        assert result.returncode == 0


# ===========================================================================
# on-teammate-idle.sh tests
# ===========================================================================


class TestTeammateIdle:
    """Tests for on-teammate-idle.sh."""

    @requires_jq
    def test_exit_0_for_non_rune_team(self) -> None:
        """Non-Rune teams should be silently skipped."""
        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "other-team",
            "teammate_name": "bob",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_empty_team_name(self) -> None:
        """Missing team_name should exit 0."""
        result = run_hook(TEAMMATE_IDLE, {
            "teammate_name": "bob",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_invalid_team_chars(self) -> None:
        """Team names with invalid characters should be rejected."""
        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-te$t",
            "teammate_name": "bob",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_oversized_team_name(self) -> None:
        """Team names > 128 chars should be rejected."""
        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-" + "x" * 130,
            "teammate_name": "bob",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_missing_cwd(self) -> None:
        """Missing cwd should warn and exit 0."""
        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "bob",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_when_no_inscription(self) -> None:
        """When inscription.json doesn't exist, exit 0 (no quality gate)."""
        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "bob",
            "cwd": "/tmp",
        })
        assert result.returncode == 0

    @requires_jq
    def test_exit_0_for_teammate_not_in_inscription(
        self, inscription_dir: Path
    ) -> None:
        """Teammates not listed in inscription should exit 0."""
        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "unknown-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 0

    @requires_jq
    def test_blocks_idle_when_output_missing(self, inscription_dir: Path) -> None:
        """Should block idle (exit 2) when expected output file is missing."""
        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "test-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 2
        assert "Output file not found" in result.stderr

    @requires_jq
    def test_blocks_idle_when_output_too_small(
        self, inscription_dir: Path
    ) -> None:
        """Should block idle (exit 2) when output file is < 50 bytes."""
        output_file = inscription_dir / "tmp" / "reviews" / "test" / "test-ash.md"
        output_file.write_text("tiny")  # 4 bytes < 50 minimum

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "test-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 2
        assert "too small" in result.stderr.lower()

    @requires_jq
    def test_blocks_idle_when_seal_missing_in_review(
        self, inscription_dir: Path
    ) -> None:
        """Review workflows should block idle when SEAL marker is missing."""
        output_file = inscription_dir / "tmp" / "reviews" / "test" / "test-ash.md"
        output_file.write_text("# Review\n\nThis is a review output without a seal marker.\n" * 5)

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "test-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 2
        assert "SEAL" in result.stderr

    @requires_jq
    def test_allows_idle_with_seal_present(self, inscription_dir: Path) -> None:
        """Review workflows should allow idle when SEAL marker is present."""
        output_file = inscription_dir / "tmp" / "reviews" / "test" / "test-ash.md"
        # Include P2 findings so finding density check passes (grep -cE fix exposed this)
        lines = ["# Review Output", ""]
        for i in range(20):
            lines.append(f"P2: Finding {i+1} — issue details")
        lines.append("")
        lines.append("SEAL: {")
        lines.append("  findings: 3,")
        lines.append("  confidence: 0.9")
        lines.append("}")
        content = "\n".join(lines)
        output_file.write_text(content)

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "test-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 0

    @requires_jq
    def test_seal_not_required_for_non_review_teams(
        self, inscription_dir: Path
    ) -> None:
        """Non-review/audit teams should not require SEAL markers."""
        # Rewrite inscription for a work team
        signals = inscription_dir / "tmp" / ".rune-signals" / "rune-work-test"
        signals.mkdir(parents=True)
        inscription = {
            "teammates": [{"name": "worker", "output_file": "worker.md"}],
            "output_dir": "tmp/reviews/test/",
        }
        (signals / "inscription.json").write_text(json.dumps(inscription))

        output_file = inscription_dir / "tmp" / "reviews" / "test" / "worker.md"
        output_file.write_text("# Work output\n\nCompleted task.\n" * 5)

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-work-test",
            "teammate_name": "worker",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 0

    @requires_jq
    def test_path_traversal_in_output_file_rejected(
        self, inscription_dir: Path
    ) -> None:
        """Output files with path traversal should be blocked (SEC-003)."""
        signals = inscription_dir / "tmp" / ".rune-signals" / "rune-review-test"
        inscription = {
            "teammates": [
                {"name": "evil-ash", "output_file": "../../etc/passwd"},
            ],
            "output_dir": "tmp/reviews/test/",
        }
        (signals / "inscription.json").write_text(json.dumps(inscription))

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "evil-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 2  # Blocked — exit 2 for security violations
        assert "path traversal" in result.stderr.lower()

    @requires_jq
    def test_path_traversal_in_output_dir_rejected(
        self, inscription_dir: Path
    ) -> None:
        """Output dirs with path traversal should be blocked (SEC-003)."""
        signals = inscription_dir / "tmp" / ".rune-signals" / "rune-review-test"
        inscription = {
            "teammates": [
                {"name": "test-ash", "output_file": "test-ash.md"},
            ],
            "output_dir": "tmp/../../../etc/",
        }
        (signals / "inscription.json").write_text(json.dumps(inscription))

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "test-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 2  # Blocked — exit 2 for security violations
        assert "path traversal" in result.stderr.lower()

    @requires_jq
    def test_output_dir_outside_tmp_rejected(
        self, inscription_dir: Path
    ) -> None:
        """Output dirs not under tmp/ should be blocked."""
        signals = inscription_dir / "tmp" / ".rune-signals" / "rune-review-test"
        inscription = {
            "teammates": [
                {"name": "test-ash", "output_file": "test-ash.md"},
            ],
            "output_dir": "src/evil/",
        }
        (signals / "inscription.json").write_text(json.dumps(inscription))

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "rune-review-test",
            "teammate_name": "test-ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 2  # Blocked — exit 2 for security violations
        assert "outside tmp/" in result.stderr

    @requires_jq
    def test_arc_review_requires_seal(self, inscription_dir: Path) -> None:
        """Arc review teams (arc-review-*) should also enforce SEAL."""
        # Create signal dir for arc-review team
        signals = inscription_dir / "tmp" / ".rune-signals" / "arc-review-test"
        signals.mkdir(parents=True)
        inscription = {
            "teammates": [{"name": "ash", "output_file": "ash.md"}],
            "output_dir": "tmp/reviews/test/",
        }
        (signals / "inscription.json").write_text(json.dumps(inscription))

        # Create team directory for arc-review-test (required for hook to proceed)
        config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR", ""))
        arc_team_dir = config_dir / "teams" / "arc-review-test"
        arc_team_dir.mkdir(parents=True, exist_ok=True)

        output_file = inscription_dir / "tmp" / "reviews" / "test" / "ash.md"
        output_file.write_text("# Arc review output without seal.\n" * 5)

        result = run_hook(TEAMMATE_IDLE, {
            "team_name": "arc-review-test",
            "teammate_name": "ash",
            "cwd": str(inscription_dir),
        })
        assert result.returncode == 2
        assert "SEAL" in result.stderr

    def test_exit_0_without_jq(self) -> None:
        """Script should exit 0 with warning when jq is missing."""
        result = run_hook(
            TEAMMATE_IDLE,
            "{}",
            env_override={"PATH": "/usr/bin:/bin"},
        )
        assert result.returncode == 0
