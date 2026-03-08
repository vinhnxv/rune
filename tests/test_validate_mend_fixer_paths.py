"""Unit tests for validate-mend-fixer-paths.sh hook script (SEC-MEND-001).

Tests the PreToolUse hook that enforces file scope restrictions for mend fixer
Ashes. Validates that subagents cannot write to files outside their assigned
file group (from inscription.json), while team-leads and non-mend-workflow
contexts are left unrestricted.

Behaviour under test:
- Fast-path: non-write tools (e.g. Read, Bash) → exit 0
- Fast-path: empty file_path → exit 0
- Fast-path: non-subagent caller (no /subagents/ in transcript_path) → exit 0
- Fast-path: missing cwd → exit 0
- No active mend state file → exit 0
- Identifier validation (safe chars, length cap) → fail-open on bad identifiers
- Missing inscription.json → fail-open (exit 0)
- Empty file_group in inscription → fail-open with warning
- Assigned files → exit 0 (allowed)
- Unassigned files → exit 0 + deny JSON (permissionDecision=deny)
- Mend output dir prefix → exit 0 (always allowed)
- Missing jq → exit 0 with warning (non-blocking)

The script uses a fail-open design: every parsing/validation error results in
exit 0 (allow). Only a confirmed, valid mend workflow with a populated
inscription.json triggers denial.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from conftest import requires_jq

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PLUGIN_DIR = Path(__file__).parent.parent / "plugins" / "rune"
SCRIPTS_DIR = PLUGIN_DIR / "scripts"
SCRIPT = SCRIPTS_DIR / "validate-mend-fixer-paths.sh"

# A transcript_path that signals a subagent context (contains /subagents/)
SUBAGENT_TRANSCRIPT = "/home/user/.claude/projects/my-project/subagents/fixer-1/transcript.jsonl"
# A transcript_path for a team-lead (no /subagents/ component)
LEAD_TRANSCRIPT = "/home/user/.claude/projects/my-project/transcript.jsonl"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_state(project: Path, config: Path, identifier: str = "test123") -> None:
    """Create a minimal active mend state file under project/tmp/.

    config_dir is stored as its resolved (symlink-free) path because
    resolve-session-identity.sh uses ``pwd -P`` to canonicalize the path,
    which on macOS turns /var/... into /private/var/...
    """
    state = {
        "team_name": f"arc-mend-{identifier}",
        "status": "active",
        "config_dir": str(config.resolve()),
        "owner_pid": os.getpid(),
    }
    (project / "tmp" / f".rune-mend-{identifier}.json").write_text(
        json.dumps(state)
    )


def _make_inscription(
    project: Path,
    identifier: str = "test123",
    file_group: list[str] | None = None,
) -> None:
    """Create inscription.json under project/tmp/mend/{identifier}/."""
    if file_group is None:
        file_group = ["src/app.py", "src/utils.py"]
    mend_dir = project / "tmp" / "mend" / identifier
    mend_dir.mkdir(parents=True, exist_ok=True)
    inscription = {
        "fixers": [
            {"name": "fixer-1", "file_group": file_group},
        ]
    }
    (mend_dir / "inscription.json").write_text(json.dumps(inscription))


def _build_input(
    tool_name: str = "Write",
    file_path: str = "src/app.py",
    transcript_path: str = SUBAGENT_TRANSCRIPT,
    cwd: str | None = None,
) -> dict:
    """Build a hook input dict with sensible defaults."""
    payload: dict = {
        "tool_name": tool_name,
        "tool_input": {"file_path": file_path},
        "transcript_path": transcript_path,
    }
    if cwd is not None:
        payload["cwd"] = cwd
    return payload


def _is_deny(result_stdout: str) -> bool:
    """Return True if stdout contains a permissionDecision=deny JSON block."""
    if not result_stdout.strip():
        return False
    try:
        data = json.loads(result_stdout.strip())
        return (
            data.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
        )
    except json.JSONDecodeError:
        return False


def _deny_data(result_stdout: str) -> dict:
    """Parse and return the deny JSON from stdout."""
    return json.loads(result_stdout.strip())


# ===========================================================================
# TestMendFixerGuardClauses
# ===========================================================================


class TestMendFixerGuardClauses:
    """Guard-clause tests: every fast-path exit should return 0 with no denial."""

    @requires_jq
    def test_exit_0_for_read_tool(self, hook_runner, project_env) -> None:
        """Read tool is not a file-writing tool — must exit 0 immediately."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(tool_name="Read", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_bash_tool(self, hook_runner, project_env) -> None:
        """Bash tool is not a file-writing tool — must exit 0 immediately."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(tool_name="Bash", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_glob_tool(self, hook_runner, project_env) -> None:
        """Glob tool — must exit 0 immediately (not a write tool)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(tool_name="Glob", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_grep_tool(self, hook_runner, project_env) -> None:
        """Grep tool — must exit 0 immediately (not a write tool)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(tool_name="Grep", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_empty_file_path(self, hook_runner, project_env) -> None:
        """Write tool with empty file_path — must exit 0 (fast-path 2)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        payload = {
            "tool_name": "Write",
            "tool_input": {"file_path": ""},
            "transcript_path": SUBAGENT_TRANSCRIPT,
            "cwd": str(project),
        }
        result = hook_runner(SCRIPT, payload)
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_missing_file_path_field(self, hook_runner, project_env) -> None:
        """Write tool with no file_path field — must exit 0 (fast-path 2)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        payload = {
            "tool_name": "Write",
            "tool_input": {},
            "transcript_path": SUBAGENT_TRANSCRIPT,
            "cwd": str(project),
        }
        result = hook_runner(SCRIPT, payload)
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_non_subagent_transcript(self, hook_runner, project_env) -> None:
        """Team-lead transcript (no /subagents/) — must exit 0 (fast-path 3)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(
                transcript_path=LEAD_TRANSCRIPT,
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_missing_transcript_path(self, hook_runner, project_env) -> None:
        """Missing transcript_path — treated as non-subagent, must exit 0."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        payload = {
            "tool_name": "Write",
            "tool_input": {"file_path": "src/evil.py"},
            "cwd": str(project),
        }
        result = hook_runner(SCRIPT, payload)
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_empty_transcript_path(self, hook_runner, project_env) -> None:
        """Empty transcript_path — treated as non-subagent, must exit 0."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        payload = {
            "tool_name": "Write",
            "tool_input": {"file_path": "src/evil.py"},
            "transcript_path": "",
            "cwd": str(project),
        }
        result = hook_runner(SCRIPT, payload)
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_missing_cwd(self, hook_runner, project_env) -> None:
        """Missing cwd field — must exit 0 (fast-path 4)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        payload = {
            "tool_name": "Write",
            "tool_input": {"file_path": "src/app.py"},
            "transcript_path": SUBAGENT_TRANSCRIPT,
            # Deliberately no cwd key
        }
        result = hook_runner(SCRIPT, payload)
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_nonexistent_cwd(self, hook_runner, project_env) -> None:
        """CWD that doesn't exist on disk — must exit 0 (cd fails, fail-open)."""
        _project, _config = project_env

        payload = {
            "tool_name": "Write",
            "tool_input": {"file_path": "src/app.py"},
            "transcript_path": SUBAGENT_TRANSCRIPT,
            "cwd": "/nonexistent/path/that/does/not/exist",
        }
        result = hook_runner(SCRIPT, payload)
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_no_active_mend_state(self, hook_runner, project_env) -> None:
        """No .rune-mend-*.json in tmp/ — no active workflow, must exit 0."""
        project, _config = project_env
        # Deliberately skip _make_state and _make_inscription

        result = hook_runner(
            SCRIPT,
            _build_input(cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_mend_state_not_active(self, hook_runner, project_env) -> None:
        """State file present but status != active — must exit 0."""
        project, config = project_env
        # Write a non-active state
        state = {
            "team_name": "arc-mend-test123",
            "status": "completed",
            "config_dir": str(config.resolve()),
            "owner_pid": os.getpid(),
        }
        (project / "tmp" / ".rune-mend-test123.json").write_text(
            json.dumps(state)
        )
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/evil.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    def test_exit_0_without_jq(self, hook_runner, project_env) -> None:
        """Missing jq binary — must exit 0 with a warning on stderr (non-blocking)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(cwd=str(project)),
            env_override={"PATH": "/usr/bin:/bin"},
        )
        assert result.returncode == 0
        # May or may not emit warning depending on whether jq is truly absent
        # Key requirement: never block (exit 0 always)


# ===========================================================================
# TestMendFixerFileGroupEnforcement
# ===========================================================================


class TestMendFixerFileGroupEnforcement:
    """Tests for the core file-group enforcement logic."""

    @requires_jq
    def test_allows_write_to_assigned_file(self, hook_runner, project_env) -> None:
        """Subagent writing to a file in its assigned group — must be allowed."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py", "src/utils.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_allows_write_to_second_assigned_file(
        self, hook_runner, project_env
    ) -> None:
        """Subagent writing to the second file in its group — must be allowed."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py", "src/utils.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/utils.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_denies_write_to_unassigned_file(self, hook_runner, project_env) -> None:
        """Subagent writing outside its group — must be denied with JSON."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py", "src/utils.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/secret.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout), (
            f"Expected deny JSON on stdout, got: {result.stdout!r}"
        )

    @requires_jq
    def test_deny_json_structure_is_valid(self, hook_runner, project_env) -> None:
        """Deny JSON must include all required fields for the PreToolUse hook."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/unauthorized.py", cwd=str(project)),
        )
        assert _is_deny(result.stdout)
        data = _deny_data(result.stdout)
        hso = data["hookSpecificOutput"]
        assert hso["hookEventName"] == "PreToolUse"
        assert hso["permissionDecision"] == "deny"
        assert "permissionDecisionReason" in hso
        assert "additionalContext" in hso

    @requires_jq
    def test_deny_reason_mentions_target_file(self, hook_runner, project_env) -> None:
        """Deny reason must mention the target file path."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="lib/other_module.py", cwd=str(project)),
        )
        assert _is_deny(result.stdout)
        data = _deny_data(result.stdout)
        reason = data["hookSpecificOutput"]["permissionDecisionReason"]
        assert "lib/other_module.py" in reason

    @requires_jq
    def test_deny_reason_includes_sec_mend_code(
        self, hook_runner, project_env
    ) -> None:
        """Deny reason must include the SEC-MEND-001 code for traceability."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="tests/evil_test.py", cwd=str(project)),
        )
        assert _is_deny(result.stdout)
        data = _deny_data(result.stdout)
        reason = data["hookSpecificOutput"]["permissionDecisionReason"]
        assert "SEC-MEND-001" in reason

    @requires_jq
    def test_allows_write_to_mend_output_dir(
        self, hook_runner, project_env
    ) -> None:
        """Writes under tmp/mend/{id}/ are always allowed (fixer writes reports there)."""
        project, config = project_env
        _make_state(project, config, identifier="test123")
        _make_inscription(project, identifier="test123", file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(
                file_path="tmp/mend/test123/fixer-1-report.md",
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_allows_nested_file_in_mend_output_dir(
        self, hook_runner, project_env
    ) -> None:
        """Nested path under tmp/mend/{id}/ — always allowed."""
        project, config = project_env
        _make_state(project, config, identifier="abc456")
        _make_inscription(project, identifier="abc456", file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(
                file_path="tmp/mend/abc456/phase2/report.json",
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_denies_write_to_different_mend_output_dir(
        self, hook_runner, project_env
    ) -> None:
        """tmp/mend/ with a DIFFERENT identifier — must be denied."""
        project, config = project_env
        _make_state(project, config, identifier="test123")
        _make_inscription(project, identifier="test123", file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(
                file_path="tmp/mend/other999/evil.md",
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)

    @requires_jq
    def test_allows_multiple_fixers_file_groups(
        self, hook_runner, project_env
    ) -> None:
        """inscription.json with multiple fixers — any fixer's file is allowed."""
        project, config = project_env
        _make_state(project, config)
        mend_dir = project / "tmp" / "mend" / "test123"
        mend_dir.mkdir(parents=True, exist_ok=True)
        inscription = {
            "fixers": [
                {"name": "fixer-1", "file_group": ["src/app.py", "src/routes.py"]},
                {"name": "fixer-2", "file_group": ["lib/utils.py", "lib/helpers.py"]},
            ]
        }
        (mend_dir / "inscription.json").write_text(json.dumps(inscription))

        # File from fixer-2's group
        result = hook_runner(
            SCRIPT,
            _build_input(file_path="lib/helpers.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_denies_file_not_in_any_fixer_group(
        self, hook_runner, project_env
    ) -> None:
        """File not in any fixer's group — must be denied."""
        project, config = project_env
        _make_state(project, config)
        mend_dir = project / "tmp" / "mend" / "test123"
        mend_dir.mkdir(parents=True, exist_ok=True)
        inscription = {
            "fixers": [
                {"name": "fixer-1", "file_group": ["src/app.py"]},
                {"name": "fixer-2", "file_group": ["lib/utils.py"]},
            ]
        }
        (mend_dir / "inscription.json").write_text(json.dumps(inscription))

        result = hook_runner(
            SCRIPT,
            _build_input(file_path=".env", cwd=str(project)),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)


# ===========================================================================
# TestMendFixerSecurity
# ===========================================================================


class TestMendFixerSecurity:
    """Security-focused tests: path traversal, injection, boundary conditions."""

    @requires_jq
    def test_path_traversal_in_identifier_rejected(
        self, hook_runner, project_env
    ) -> None:
        """State file with special char in identifier — fail-open (invalid → allow).

        Filenames like '.rune-mend-test%evil.json' produce an identifier
        'test%evil' which fails the ^[a-zA-Z0-9_-]+$ safety pattern.
        The script must fail-open and allow the write.
        """
        project, _config = project_env

        # Create a state file whose identifier contains a special char (%)
        # that is legal on the filesystem but fails the identifier regex.
        bad_state_file = project / "tmp" / ".rune-mend-test%evil.json"
        bad_state_file.write_text('{"status":"active"}')

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        # Fail-open: invalid identifier → allow
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_identifier_too_long_rejected(self, hook_runner, project_env) -> None:
        """State file with identifier > 64 chars — fail-open (allow)."""
        project, _config = project_env

        long_id = "a" * 65
        state = {"status": "active"}
        (project / "tmp" / f".rune-mend-{long_id}.json").write_text(
            json.dumps(state)
        )

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        # Fail-open: identifier too long → allow
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_identifier_at_max_length_accepted(
        self, hook_runner, project_env
    ) -> None:
        """State file with identifier exactly 64 chars — must be processed."""
        project, config = project_env

        max_id = "a" * 64
        state = {
            "team_name": f"arc-mend-{max_id}",
            "status": "active",
            "config_dir": str(config.resolve()),
            "owner_pid": os.getpid(),
        }
        (project / "tmp" / f".rune-mend-{max_id}.json").write_text(
            json.dumps(state)
        )
        mend_dir = project / "tmp" / "mend" / max_id
        mend_dir.mkdir(parents=True, exist_ok=True)
        inscription = {"fixers": [{"name": "f", "file_group": ["src/app.py"]}]}
        (mend_dir / "inscription.json").write_text(json.dumps(inscription))

        # Writing to assigned file should be allowed
        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_identifier_with_special_chars_rejected(
        self, hook_runner, project_env
    ) -> None:
        """Identifier containing '$' — fail-open (invalid char → allow)."""
        project, _config = project_env

        bad_id = "test$evil"
        state = {"status": "active"}
        state_file = project / "tmp" / f".rune-mend-{bad_id}.json"
        try:
            state_file.write_text(json.dumps(state))
        except OSError:
            pytest.skip("Filesystem does not allow $ in filenames")

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_missing_inscription_json_fail_open(
        self, hook_runner, project_env
    ) -> None:
        """Active mend state but inscription.json missing — must fail-open (allow)."""
        project, config = project_env
        _make_state(project, config)
        # Deliberately skip _make_inscription

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/any_file.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_empty_file_group_fail_open_with_warning(
        self, hook_runner, project_env
    ) -> None:
        """inscription.json exists but file_group arrays are empty — fail-open + warn."""
        project, config = project_env
        _make_state(project, config)
        mend_dir = project / "tmp" / "mend" / "test123"
        mend_dir.mkdir(parents=True, exist_ok=True)
        inscription = {"fixers": [{"name": "fixer-1", "file_group": []}]}
        (mend_dir / "inscription.json").write_text(json.dumps(inscription))

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)
        # Warning on stderr about empty allowed files
        assert "WARNING" in result.stderr or result.returncode == 0

    @requires_jq
    def test_inscription_with_no_fixers_key_fail_open(
        self, hook_runner, project_env
    ) -> None:
        """inscription.json missing 'fixers' key — fail-open (empty allowed set → allow)."""
        project, config = project_env
        _make_state(project, config)
        mend_dir = project / "tmp" / "mend" / "test123"
        mend_dir.mkdir(parents=True, exist_ok=True)
        (mend_dir / "inscription.json").write_text(json.dumps({}))

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_malformed_inscription_json_fail_open(
        self, hook_runner, project_env
    ) -> None:
        """Malformed inscription.json — fail-open (jq error → allow)."""
        project, config = project_env
        _make_state(project, config)
        mend_dir = project / "tmp" / "mend" / "test123"
        mend_dir.mkdir(parents=True, exist_ok=True)
        (mend_dir / "inscription.json").write_text("not valid json {{{")

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_malformed_stdin_json_fail_open(self, hook_runner, project_env) -> None:
        """Malformed stdin JSON — fail-open (jq parse error → allow)."""
        _project, _config = project_env

        result = hook_runner(SCRIPT, "not valid json {{{")
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_absolute_path_outside_cwd_denied(
        self, hook_runner, project_env
    ) -> None:
        """Absolute file_path that falls outside CWD — must be denied."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="/etc/passwd", cwd=str(project)),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)

    @requires_jq
    def test_absolute_path_inside_cwd_allowed(
        self, hook_runner, project_env
    ) -> None:
        """Absolute file_path that resolves to an assigned file — must be allowed.

        The script canonicalises CWD with 'pwd -P', so the absolute path must
        use the same canonical prefix (important on macOS where /var is a
        symlink to /private/var).  We use Path.resolve() to get the canonical
        project root so both CWD and FILE_PATH share the same prefix.
        """
        project, config = project_env
        # Use the canonical (symlink-resolved) project path so 'pwd -P' and
        # the file_path agree on the prefix.
        canonical_project = project.resolve()
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        abs_path = str(canonical_project / "src" / "app.py")
        result = hook_runner(
            SCRIPT,
            _build_input(file_path=abs_path, cwd=str(canonical_project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)


# ===========================================================================
# TestMendFixerEdgeCases
# ===========================================================================


class TestMendFixerEdgeCases:
    """Edge cases: tool variants, path normalisation, boundary states."""

    @requires_jq
    def test_edit_tool_enforced(self, hook_runner, project_env) -> None:
        """Edit tool is a write tool — must be enforced like Write."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(
                tool_name="Edit",
                file_path="src/unauthorized.py",
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)

    @requires_jq
    def test_edit_tool_allowed_for_assigned_file(
        self, hook_runner, project_env
    ) -> None:
        """Edit tool writing to an assigned file — must be allowed."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(
                tool_name="Edit",
                file_path="src/app.py",
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_notebook_edit_tool_enforced(self, hook_runner, project_env) -> None:
        """NotebookEdit tool is a write tool — must be enforced like Write."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["notebooks/analysis.ipynb"])

        result = hook_runner(
            SCRIPT,
            _build_input(
                tool_name="NotebookEdit",
                file_path="notebooks/secret.ipynb",
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)

    @requires_jq
    def test_notebook_edit_allowed_for_assigned_notebook(
        self, hook_runner, project_env
    ) -> None:
        """NotebookEdit for an assigned notebook — must be allowed."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(
            project, file_group=["notebooks/analysis.ipynb", "src/app.py"]
        )

        result = hook_runner(
            SCRIPT,
            _build_input(
                tool_name="NotebookEdit",
                file_path="notebooks/analysis.ipynb",
                cwd=str(project),
            ),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_dot_slash_normalization_in_file_path(
        self, hook_runner, project_env
    ) -> None:
        """file_path starting with './' must match after stripping the prefix."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="./src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_dot_slash_normalization_in_inscription(
        self, hook_runner, project_env
    ) -> None:
        """inscription.json file_group entries starting with './' — must match."""
        project, config = project_env
        _make_state(project, config)
        mend_dir = project / "tmp" / "mend" / "test123"
        mend_dir.mkdir(parents=True, exist_ok=True)
        inscription = {
            "fixers": [{"name": "f", "file_group": ["./src/app.py", "./src/utils.py"]}]
        }
        (mend_dir / "inscription.json").write_text(json.dumps(inscription))

        # Writing without leading ./ should still match
        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_deny_additional_context_mentions_inscription_path(
        self, hook_runner, project_env
    ) -> None:
        """Deny additionalContext must reference the inscription.json path."""
        project, config = project_env
        identifier = "test123"
        _make_state(project, config, identifier=identifier)
        _make_inscription(project, identifier=identifier, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/evil.py", cwd=str(project)),
        )
        assert _is_deny(result.stdout)
        data = _deny_data(result.stdout)
        context = data["hookSpecificOutput"]["additionalContext"]
        assert identifier in context

    @requires_jq
    def test_only_first_active_state_file_used(
        self, hook_runner, project_env
    ) -> None:
        """Multiple mend state files — only the first active one drives enforcement."""
        project, config = project_env

        # Write two state files; first is active
        for ident in ("aaafirst", "zzzlast"):
            state = {
                "team_name": f"arc-mend-{ident}",
                "status": "active",
                "config_dir": str(config.resolve()),
                "owner_pid": os.getpid(),
            }
            (project / "tmp" / f".rune-mend-{ident}.json").write_text(
                json.dumps(state)
            )
            mend_dir = project / "tmp" / "mend" / ident
            mend_dir.mkdir(parents=True, exist_ok=True)
            inscription = {
                "fixers": [{"name": "f", "file_group": [f"src/{ident}.py"]}]
            }
            (mend_dir / "inscription.json").write_text(json.dumps(inscription))

        # Writing to a path that is NOT in either fixer's group → denied
        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/completely_different.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)

    @requires_jq
    def test_exit_0_for_lowercase_write_variant(
        self, hook_runner, project_env
    ) -> None:
        """'write' (lowercase) is not a matched tool name — must exit 0."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project)

        result = hook_runner(
            SCRIPT,
            _build_input(tool_name="write", file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_deny_json_is_valid_parseable_json(
        self, hook_runner, project_env
    ) -> None:
        """Deny output must be parseable JSON (never garbled)."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/bad.py", cwd=str(project)),
        )
        assert result.returncode == 0
        # Must be valid JSON
        try:
            data = json.loads(result.stdout.strip())
        except json.JSONDecodeError as exc:
            pytest.fail(f"Deny output is not valid JSON: {exc}\nstdout: {result.stdout!r}")
        assert "hookSpecificOutput" in data

    @requires_jq
    def test_no_stderr_on_clean_allow_path(self, hook_runner, project_env) -> None:
        """Clean allow path (assigned file) should not produce stderr noise."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path="src/app.py", cwd=str(project)),
        )
        assert result.returncode == 0
        assert not _is_deny(result.stdout)
        assert result.stderr == ""

    @requires_jq
    def test_empty_stdin_fail_open(self, hook_runner, project_env) -> None:
        """Completely empty stdin — fail-open (exit 0, no denial)."""
        _project, _config = project_env

        result = hook_runner(SCRIPT, "")
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_relative_cwd_rejected(self, hook_runner, project_env) -> None:
        """Relative cwd (not starting with /) — must exit 0 (fast-path reject)."""
        _project, _config = project_env

        payload = {
            "tool_name": "Write",
            "tool_input": {"file_path": "src/app.py"},
            "transcript_path": SUBAGENT_TRANSCRIPT,
            "cwd": "relative/path/only",
        }
        result = hook_runner(SCRIPT, payload)
        assert result.returncode == 0
        assert not _is_deny(result.stdout)

    @requires_jq
    def test_deny_for_env_file_outside_group(
        self, hook_runner, project_env
    ) -> None:
        """Attempt to write .env file — must be denied when not in group."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path=".env", cwd=str(project)),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)

    @requires_jq
    def test_deny_for_github_workflow_outside_group(
        self, hook_runner, project_env
    ) -> None:
        """Attempt to write to .github/workflows/ci.yml — must be denied."""
        project, config = project_env
        _make_state(project, config)
        _make_inscription(project, file_group=["src/app.py"])

        result = hook_runner(
            SCRIPT,
            _build_input(file_path=".github/workflows/ci.yml", cwd=str(project)),
        )
        assert result.returncode == 0
        assert _is_deny(result.stdout)
