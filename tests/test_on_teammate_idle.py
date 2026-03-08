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
    env_override: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run on-teammate-idle.sh with a TeammateIdle event."""
    input_json = {
        "team_name": team_name,
        "teammate_name": teammate_name,
        "cwd": str(project),
    }
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
        """Output file with enough content → exit 0 (allow idle)."""
        project, config = project_env
        setup_inscription(project)
        setup_team_dir(config)
        output_dir = project / "tmp" / "reviews" / "test123"
        output_dir.mkdir(parents=True, exist_ok=True)
        # Write content with 20+ lines (hook requires minimum depth)
        lines = ["# Review Findings", ""]
        for i in range(20):
            lines.append(f"- Finding {i+1}: Details about this finding")
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
        # Write content with 20+ lines (hook requires minimum depth)
        lines = ["# Review", ""]
        for i in range(20):
            lines.append(f"- Detail {i+1}: More details here")
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
        # Write content with 20+ lines (hook requires minimum depth)
        lines = ["# Review", ""]
        for i in range(20):
            lines.append(f"- Detail {i+1}: More details here")
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
