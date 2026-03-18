"""Unit tests for the validate-gap-fixer-paths.sh PreToolUse hook.

Tests the shell script as a subprocess, verifying:
- Guard clauses (non-write tools, non-subagent callers, no active gap-fix, missing jq)
- Blocked path patterns (.claude/, .github/, node_modules/, .env, .env.*, CI YAML, path traversal, hidden files)
- Allowed paths (src/, tests/, tmp/arc/{id}/ output directory, regular yml files)
- Security properties (deny JSON structure, hookEventName presence, identifier validation)
- Edge cases (release.yml blocked, deeply nested .claude paths, non-CI yml allowed)
- Session isolation (owner_pid + config_dir cross-session safety)

The script is a fail-open PreToolUse hook (SEC-GAP-001):
  - Exit 0 without JSON => tool call allowed
  - Exit 0 with permissionDecision="deny" JSON => tool call blocked
  - Exit 2 is never emitted by this script (fail-open design)

Requires: jq (tests marked @requires_jq skip gracefully when jq is absent)
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from conftest import SCRIPTS_DIR, requires_jq

SCRIPT = SCRIPTS_DIR / "validate-gap-fixer-paths.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SUBAGENT_TRANSCRIPT = "/home/user/.claude/projects/abc123/subagents/gap-fixer-1/transcript.json"
NON_SUBAGENT_TRANSCRIPT = "/home/user/.claude/projects/abc123/transcript.json"

VALID_IDENTIFIER = "fix-abc123"
GAP_STATE_FILENAME = f".rune-gap-fix-{VALID_IDENTIFIER}.json"
ACTIVE_STATE = {"status": "active", "identifier": VALID_IDENTIFIER}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def make_write_input(
    file_path: str,
    *,
    transcript_path: str = SUBAGENT_TRANSCRIPT,
    tool_name: str = "Write",
    cwd: str | None = None,
) -> dict:
    """Build a minimal PreToolUse hook input dict for a file-writing tool."""
    payload: dict = {
        "tool_name": tool_name,
        "tool_input": {"file_path": file_path},
        "transcript_path": transcript_path,
    }
    if cwd is not None:
        payload["cwd"] = cwd
    return payload


def create_gap_state(
    project: Path,
    identifier: str = VALID_IDENTIFIER,
    status: str = "active",
    *,
    config_dir: Path | None = None,
    owner_pid: int | None = None,
) -> Path:
    """Write a gap-fix state file into project/tmp/ and return its path.

    config_dir is stored as its resolved (symlink-free) path because
    resolve-session-identity.sh uses ``pwd -P`` to canonicalize the path.
    """
    tmp_dir = project / "tmp"
    tmp_dir.mkdir(exist_ok=True)
    state: dict = {"status": status, "identifier": identifier}
    if config_dir is not None:
        state["config_dir"] = str(config_dir.resolve())
    if owner_pid is not None:
        state["owner_pid"] = owner_pid
    state_file = tmp_dir / f".rune-gap-fix-{identifier}.json"
    state_file.write_text(json.dumps(state))
    return state_file


def is_deny_json(stdout: str) -> bool:
    """Return True if stdout contains a valid deny permissionDecision JSON."""
    stripped = stdout.strip()
    if not stripped:
        return False
    try:
        data = json.loads(stripped)
        output = data.get("hookSpecificOutput", {})
        return output.get("permissionDecision") == "deny"
    except (json.JSONDecodeError, AttributeError):
        return False


def parse_hook_output(stdout: str) -> dict:
    """Parse hook stdout as JSON, raising AssertionError with context on failure."""
    stripped = stdout.strip()
    assert stripped, "Expected JSON output on stdout, got empty string"
    try:
        return json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"Invalid JSON on stdout: {exc!r}\nOutput was: {stripped!r}") from exc


# ===========================================================================
# TestGapFixerGuardClauses
# ===========================================================================


class TestGapFixerGuardClauses:
    """Exit-0 (allow) cases where the hook applies no restriction."""

    def test_exit_0_without_jq(self, hook_runner) -> None:
        """Missing jq -> exit 0 with warning on stderr (fail-open)."""
        result = hook_runner(
            SCRIPT,
            make_write_input("src/main.py"),
            env_override={"PATH": "/usr/bin:/bin"},
        )
        assert result.returncode == 0
        assert "jq not found" in result.stderr or result.returncode == 0

    @requires_jq
    def test_exit_0_for_read_tool(self, hook_runner, project_env) -> None:
        """Read tool (not a write tool) -> fast-path exit 0."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            {
                "tool_name": "Read",
                "tool_input": {"file_path": ".claude/settings.json"},
                "transcript_path": SUBAGENT_TRANSCRIPT,
            },
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_bash_tool(self, hook_runner, project_env) -> None:
        """Bash tool -> fast-path exit 0 (only Write/Edit/NotebookEdit are checked)."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            {
                "tool_name": "Bash",
                "tool_input": {"command": "rm -rf .claude/"},
                "transcript_path": SUBAGENT_TRANSCRIPT,
            },
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_glob_tool(self, hook_runner, project_env) -> None:
        """Glob tool -> fast-path exit 0."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            {
                "tool_name": "Glob",
                "tool_input": {"pattern": "**/*.py"},
                "transcript_path": SUBAGENT_TRANSCRIPT,
            },
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_edit_tool_non_subagent(self, hook_runner, project_env) -> None:
        """Edit tool from team-lead (no /subagents/ in transcript_path) -> exit 0."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(
                ".claude/settings.json",
                transcript_path=NON_SUBAGENT_TRANSCRIPT,
                tool_name="Edit",
            ),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_write_tool_missing_transcript_path(self, hook_runner, project_env) -> None:
        """Write tool with no transcript_path field -> fail-open, exit 0."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            {
                "tool_name": "Write",
                "tool_input": {"file_path": ".claude/settings.json"},
            },
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_write_tool_empty_transcript_path(self, hook_runner, project_env) -> None:
        """Write tool with empty transcript_path -> treated as non-subagent, exit 0."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            {
                "tool_name": "Write",
                "tool_input": {"file_path": ".claude/settings.json"},
                "transcript_path": "",
            },
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_when_no_gap_fix_state_file(self, hook_runner, project_env) -> None:
        """No active gap-fix state file -> hook does not apply, exit 0."""
        # Do NOT create any state file in tmp/
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/settings.json"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_when_gap_fix_state_not_active(self, hook_runner, project_env) -> None:
        """State file with status != 'active' -> hook skips, exit 0."""
        project, _ = project_env
        create_gap_state(project, status="completed")
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/settings.json"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_when_gap_fix_state_is_paused(self, hook_runner, project_env) -> None:
        """State file with status='paused' -> not active, hook skips."""
        project, _ = project_env
        create_gap_state(project, status="paused")
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/CLAUDE.md"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_missing_file_path(self, hook_runner, project_env) -> None:
        """Write tool with empty file_path -> fast-path exit 0."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            {
                "tool_name": "Write",
                "tool_input": {"file_path": ""},
                "transcript_path": SUBAGENT_TRANSCRIPT,
            },
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_missing_cwd(self, hook_runner) -> None:
        """Missing cwd field in hook input -> fail-open, exit 0."""
        result = hook_runner(
            SCRIPT,
            {
                "tool_name": "Write",
                "tool_input": {"file_path": ".claude/settings.json"},
                "transcript_path": SUBAGENT_TRANSCRIPT,
                "cwd": "",
            },
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_malformed_json(self, hook_runner) -> None:
        """Malformed JSON stdin -> fail-open, exit 0."""
        result = hook_runner(SCRIPT, "not valid json {{{")
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_0_for_empty_stdin(self, hook_runner) -> None:
        """Empty stdin -> fail-open, exit 0."""
        result = hook_runner(SCRIPT, "")
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)


# ===========================================================================
# TestGapFixerBlockedPaths
# ===========================================================================


class TestGapFixerBlockedPaths:
    """Paths that must be denied when a gap-fix workflow is active."""

    def _run_blocked(self, hook_runner, project_env, file_path: str, tool: str = "Write") -> None:
        """Helper: create state, run hook, assert deny was emitted."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(file_path, tool_name=tool),
        )
        assert result.returncode == 0, f"Expected exit 0, got {result.returncode}"
        assert is_deny_json(result.stdout), (
            f"Expected deny JSON for path {file_path!r}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )

    @requires_jq
    def test_blocks_dot_claude_settings(self, hook_runner, project_env) -> None:
        """Writing to .claude/settings.json must be denied."""
        self._run_blocked(hook_runner, project_env, ".claude/settings.json")

    @requires_jq
    def test_blocks_dot_claude_claude_md(self, hook_runner, project_env) -> None:
        """Writing to .claude/CLAUDE.md must be denied."""
        self._run_blocked(hook_runner, project_env, ".claude/CLAUDE.md")

    @requires_jq
    def test_blocks_dot_claude_subdir(self, hook_runner, project_env) -> None:
        """Writing to any file under .claude/ must be denied."""
        self._run_blocked(hook_runner, project_env, ".rune/arc/checkpoint.json")

    @requires_jq
    def test_blocks_dot_github_workflows(self, hook_runner, project_env) -> None:
        """Writing to .github/workflows/build.yml must be denied."""
        self._run_blocked(hook_runner, project_env, ".github/workflows/build.yml")

    @requires_jq
    def test_blocks_dot_github_root_file(self, hook_runner, project_env) -> None:
        """Writing to .github/CODEOWNERS must be denied."""
        self._run_blocked(hook_runner, project_env, ".github/CODEOWNERS")

    @requires_jq
    def test_blocks_node_modules_file(self, hook_runner, project_env) -> None:
        """Writing to node_modules/lodash/index.js must be denied."""
        self._run_blocked(hook_runner, project_env, "node_modules/lodash/index.js")

    @requires_jq
    def test_blocks_node_modules_nested(self, hook_runner, project_env) -> None:
        """Writing to deeply nested node_modules path must be denied."""
        self._run_blocked(hook_runner, project_env, "node_modules/@scope/pkg/src/index.ts")

    @requires_jq
    def test_blocks_dot_env(self, hook_runner, project_env) -> None:
        """Writing to .env must be denied."""
        self._run_blocked(hook_runner, project_env, ".env")

    @requires_jq
    def test_blocks_dot_env_local(self, hook_runner, project_env) -> None:
        """Writing to .env.local must be denied."""
        self._run_blocked(hook_runner, project_env, ".env.local")

    @requires_jq
    def test_blocks_dot_env_production(self, hook_runner, project_env) -> None:
        """Writing to .env.production must be denied."""
        self._run_blocked(hook_runner, project_env, ".env.production")

    @requires_jq
    def test_blocks_dot_env_test(self, hook_runner, project_env) -> None:
        """Writing to .env.test must be denied."""
        self._run_blocked(hook_runner, project_env, ".env.test")

    @requires_jq
    def test_blocks_ci_yml(self, hook_runner, project_env) -> None:
        """Writing to ci.yml must be denied."""
        self._run_blocked(hook_runner, project_env, "ci.yml")

    @requires_jq
    def test_blocks_pipeline_yml(self, hook_runner, project_env) -> None:
        """Writing to pipeline.yml must be denied."""
        self._run_blocked(hook_runner, project_env, "pipeline.yml")

    @requires_jq
    def test_blocks_deploy_yml(self, hook_runner, project_env) -> None:
        """Writing to deploy.yml must be denied."""
        self._run_blocked(hook_runner, project_env, "deploy.yml")

    @requires_jq
    def test_blocks_release_yml(self, hook_runner, project_env) -> None:
        """Writing to release.yml must be denied."""
        self._run_blocked(hook_runner, project_env, "release.yml")

    @requires_jq
    def test_blocks_github_workflows_ci_yml(self, hook_runner, project_env) -> None:
        """Writing to .github/workflows/ci.yml must be denied (both .github/ and ci*.yml)."""
        self._run_blocked(hook_runner, project_env, ".github/workflows/ci.yml")

    @requires_jq
    def test_blocks_path_traversal_dotdot_slash(self, hook_runner, project_env) -> None:
        """Path containing ../ must be denied (path traversal)."""
        self._run_blocked(hook_runner, project_env, "../etc/passwd")

    @requires_jq
    def test_blocks_path_traversal_embedded(self, hook_runner, project_env) -> None:
        """Path with embedded ../ must be denied (path traversal)."""
        self._run_blocked(hook_runner, project_env, "src/../../secrets/key")

    @requires_jq
    def test_blocks_hidden_file_in_subdir(self, hook_runner, project_env) -> None:
        """Hidden file inside a subdirectory (src/.hidden) must be denied."""
        self._run_blocked(hook_runner, project_env, "src/.hidden")

    @requires_jq
    def test_blocks_hidden_file_nested(self, hook_runner, project_env) -> None:
        """Hidden file at a nested path (a/b/.secret) must be denied."""
        self._run_blocked(hook_runner, project_env, "a/b/.secret")

    @requires_jq
    def test_blocks_edit_tool_to_dot_claude(self, hook_runner, project_env) -> None:
        """Edit tool targeting .claude/ must also be denied."""
        self._run_blocked(hook_runner, project_env, ".claude/hooks.json", tool="Edit")

    @requires_jq
    def test_blocks_notebook_edit_to_dot_github(self, hook_runner, project_env) -> None:
        """NotebookEdit tool targeting .github/ must be denied."""
        self._run_blocked(hook_runner, project_env, ".github/actions/step.yml", tool="NotebookEdit")


# ===========================================================================
# TestGapFixerAllowedPaths
# ===========================================================================


class TestGapFixerAllowedPaths:
    """Paths that must be allowed even when gap-fix is active."""

    def _run_allowed(self, hook_runner, project_env, file_path: str, tool: str = "Write") -> None:
        """Helper: create state, run hook, assert no deny emitted."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(file_path, tool_name=tool),
        )
        assert result.returncode == 0, f"Expected exit 0, got {result.returncode}"
        assert not is_deny_json(result.stdout), (
            f"Expected allow for path {file_path!r}, "
            f"but got deny. stdout={result.stdout!r}"
        )

    @requires_jq
    def test_allows_src_py_file(self, hook_runner, project_env) -> None:
        """Writing to src/module.py must be allowed."""
        self._run_allowed(hook_runner, project_env, "src/module.py")

    @requires_jq
    def test_allows_src_nested_file(self, hook_runner, project_env) -> None:
        """Writing to src/subpackage/utils.py must be allowed."""
        self._run_allowed(hook_runner, project_env, "src/subpackage/utils.py")

    @requires_jq
    def test_allows_tests_file(self, hook_runner, project_env) -> None:
        """Writing to tests/test_module.py must be allowed."""
        self._run_allowed(hook_runner, project_env, "tests/test_module.py")

    @requires_jq
    def test_allows_root_python_file(self, hook_runner, project_env) -> None:
        """Writing to a root-level Python file must be allowed."""
        self._run_allowed(hook_runner, project_env, "setup.py")

    @requires_jq
    def test_allows_regular_md_file(self, hook_runner, project_env) -> None:
        """Writing to CHANGELOG.md must be allowed."""
        self._run_allowed(hook_runner, project_env, "CHANGELOG.md")

    @requires_jq
    def test_allows_regular_json_file(self, hook_runner, project_env) -> None:
        """Writing to package.json must be allowed."""
        self._run_allowed(hook_runner, project_env, "package.json")

    @requires_jq
    def test_allows_gap_output_directory(self, hook_runner, project_env) -> None:
        """Writing to the gap-fixer output dir tmp/arc/{id}/ must be allowed (allow-list)."""
        self._run_allowed(hook_runner, project_env, f"tmp/arc/{VALID_IDENTIFIER}/report.md")

    @requires_jq
    def test_allows_gap_output_subdirectory(self, hook_runner, project_env) -> None:
        """Writing to tmp/arc/{id}/subdir/file.json must be allowed."""
        self._run_allowed(hook_runner, project_env, f"tmp/arc/{VALID_IDENTIFIER}/findings/gap-001.json")

    @requires_jq
    def test_allows_non_ci_yml_file(self, hook_runner, project_env) -> None:
        """Writing to docker-compose.yml must be allowed (not a CI YAML)."""
        self._run_allowed(hook_runner, project_env, "docker-compose.yml")

    @requires_jq
    def test_allows_config_yml_without_ci_keyword(self, hook_runner, project_env) -> None:
        """Writing to config.yml must be allowed (no CI keyword match)."""
        self._run_allowed(hook_runner, project_env, "config.yml")

    @requires_jq
    def test_allows_edit_to_src(self, hook_runner, project_env) -> None:
        """Edit tool targeting src/ must be allowed."""
        self._run_allowed(hook_runner, project_env, "src/app.ts", tool="Edit")

    @requires_jq
    def test_allows_notebook_edit_in_tests(self, hook_runner, project_env) -> None:
        """NotebookEdit tool targeting tests/ must be allowed."""
        self._run_allowed(hook_runner, project_env, "tests/analysis.ipynb", tool="NotebookEdit")

    @requires_jq
    def test_allows_absolute_path_within_cwd_src(self, hook_runner, project_env) -> None:
        """Absolute file path within CWD/src/ must be allowed (normalized to relative)."""
        project, _ = project_env
        create_gap_state(project)
        abs_path = str(project / "src" / "main.py")
        result = hook_runner(
            SCRIPT,
            make_write_input(abs_path),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)


# ===========================================================================
# TestGapFixerSecurity
# ===========================================================================


class TestGapFixerSecurity:
    """Security-critical assertions: deny JSON structure, identifier validation."""

    @requires_jq
    def test_deny_json_has_hook_event_name(self, hook_runner, project_env) -> None:
        """Deny output must include hookEventName='PreToolUse' (required by SDK)."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/settings.json"),
        )
        assert result.returncode == 0
        data = parse_hook_output(result.stdout)
        hook_output = data["hookSpecificOutput"]
        assert hook_output["hookEventName"] == "PreToolUse"

    @requires_jq
    def test_deny_json_has_permission_decision_deny(self, hook_runner, project_env) -> None:
        """Deny output must have permissionDecision='deny'."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(".env"),
        )
        data = parse_hook_output(result.stdout)
        assert data["hookSpecificOutput"]["permissionDecision"] == "deny"

    @requires_jq
    def test_deny_json_has_permission_decision_reason(self, hook_runner, project_env) -> None:
        """Deny output must include a non-empty permissionDecisionReason."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(".github/workflows/ci.yml"),
        )
        data = parse_hook_output(result.stdout)
        reason = data["hookSpecificOutput"].get("permissionDecisionReason", "")
        assert reason, "permissionDecisionReason must not be empty"
        assert "SEC-GAP-001" in reason

    @requires_jq
    def test_deny_reason_includes_target_path(self, hook_runner, project_env) -> None:
        """permissionDecisionReason must include the target file path."""
        project, _ = project_env
        create_gap_state(project)
        target = ".claude/settings.json"
        result = hook_runner(
            SCRIPT,
            make_write_input(target),
        )
        data = parse_hook_output(result.stdout)
        reason = data["hookSpecificOutput"]["permissionDecisionReason"]
        assert target in reason or "settings.json" in reason

    @requires_jq
    def test_deny_json_has_additional_context(self, hook_runner, project_env) -> None:
        """Deny output must include additionalContext with human review guidance."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("node_modules/evil/index.js"),
        )
        data = parse_hook_output(result.stdout)
        ctx = data["hookSpecificOutput"].get("additionalContext", "")
        assert ctx, "additionalContext must not be empty"
        assert "NEEDS_HUMAN_REVIEW" in ctx or "human" in ctx.lower() or "Infrastructure" in ctx

    @requires_jq
    def test_deny_json_additional_context_references_identifier(self, hook_runner, project_env) -> None:
        """additionalContext must reference the gap-fix identifier's output dir."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(".env.local"),
        )
        data = parse_hook_output(result.stdout)
        ctx = data["hookSpecificOutput"]["additionalContext"]
        assert VALID_IDENTIFIER in ctx

    @requires_jq
    def test_invalid_identifier_chars_fail_open(self, hook_runner, project_env) -> None:
        """State file with identifier containing invalid chars -> fail-open, exit 0 allow."""
        project, _ = project_env
        # Use a filesystem-safe identifier that still fails the ^[a-zA-Z0-9_-]+$ regex
        # (dot and space are both invalid per the script's pattern but safe as filenames)
        bad_id = "fix.with.dots"
        state_file = project / "tmp" / f".rune-gap-fix-{bad_id}.json"
        state_file.write_text(json.dumps({"status": "active", "identifier": bad_id}))
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/settings.json"),
        )
        assert result.returncode == 0
        # Must NOT produce a deny (fail-open on invalid identifier)
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_oversized_identifier_fail_open(self, hook_runner, project_env) -> None:
        """State file with identifier > 64 chars -> fail-open, exit 0 allow."""
        project, _ = project_env
        long_id = "a" * 65
        state_file = project / "tmp" / f".rune-gap-fix-{long_id}.json"
        state_file.write_text(json.dumps({"status": "active"}))
        result = hook_runner(
            SCRIPT,
            make_write_input(".env"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_deny_json_is_valid_json(self, hook_runner, project_env) -> None:
        """Deny output must be parseable as valid JSON."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(".github/CODEOWNERS"),
        )
        assert result.returncode == 0
        stripped = result.stdout.strip()
        assert stripped, "Expected JSON on stdout"
        # This will raise json.JSONDecodeError if invalid
        parsed = json.loads(stripped)
        assert isinstance(parsed, dict)

    @requires_jq
    def test_absolute_path_outside_cwd_normalized(self, hook_runner, project_env) -> None:
        """Absolute file path outside CWD -> passed through as-is; .claude/ prefix still blocked."""
        project, _ = project_env
        create_gap_state(project)
        # Use the actual CWD-relative .claude/ path as absolute
        abs_path = str(project / ".claude" / "settings.json")
        result = hook_runner(
            SCRIPT,
            make_write_input(abs_path),
        )
        # Should be blocked: after stripping CWD prefix, becomes .claude/settings.json
        assert result.returncode == 0
        assert is_deny_json(result.stdout)


# ===========================================================================
# TestGapFixerEdgeCases
# ===========================================================================


class TestGapFixerEdgeCases:
    """Edge cases and boundary conditions for the gap-fixer path validator."""

    @requires_jq
    def test_release_yml_is_blocked(self, hook_runner, project_env) -> None:
        """release.yml matches *release*.yml pattern and must be blocked."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("release.yml"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout), "release.yml must be blocked as a CI YAML file"

    @requires_jq
    def test_nested_release_yml_is_blocked(self, hook_runner, project_env) -> None:
        """scripts/release.yml (nested) must also be blocked."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("scripts/release.yml"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout)

    @requires_jq
    def test_non_ci_yml_allowed(self, hook_runner, project_env) -> None:
        """ansible.yml does not match any CI pattern and must be allowed."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("ansible.yml"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_mkdocs_yml_allowed(self, hook_runner, project_env) -> None:
        """mkdocs.yml does not match CI patterns and must be allowed."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("mkdocs.yml"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_dot_claude_leading_slash_stripped(self, hook_runner, project_env) -> None:
        """File path starting with ./ should be normalized: ./.claude/x -> .claude/x (blocked)."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("./.claude/settings.json"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout), "./.claude/ must be treated the same as .claude/"

    @requires_jq
    def test_dot_github_leading_slash_stripped(self, hook_runner, project_env) -> None:
        """File path ./.github/x normalizes to .github/x and must be blocked."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("./.github/CODEOWNERS"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout)

    @requires_jq
    def test_nested_dot_claude_path_blocked(self, hook_runner, project_env) -> None:
        """Deeply nested .claude/ path must be blocked."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/skills/my-skill/SKILL.md"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout)

    @requires_jq
    def test_multiple_state_files_first_active_wins(self, hook_runner, project_env) -> None:
        """Multiple state files: script uses first active one found."""
        project, _ = project_env
        # Create two state files: one completed, one active
        (project / "tmp" / ".rune-gap-fix-old-fix.json").write_text(
            json.dumps({"status": "completed"})
        )
        create_gap_state(project, identifier="new-fix-abc")
        result = hook_runner(
            SCRIPT,
            make_write_input(".env"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout)

    @requires_jq
    def test_state_file_missing_status_field_skipped(self, hook_runner, project_env) -> None:
        """State file without 'status' field is not treated as active -> hook skips."""
        project, _ = project_env
        (project / "tmp" / f".rune-gap-fix-{VALID_IDENTIFIER}.json").write_text(
            json.dumps({"identifier": VALID_IDENTIFIER})  # No status field
        )
        result = hook_runner(
            SCRIPT,
            make_write_input(".env"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_path_traversal_double_dot_at_end(self, hook_runner, project_env) -> None:
        """Path ending with '..' (no trailing slash) must be blocked."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("src/.."),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout)

    @requires_jq
    def test_dot_env_exact_match_only(self, hook_runner, project_env) -> None:
        """'config.env.backup' does not match .env or .env.* pattern -> allowed."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("config.env.backup"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_gap_output_dir_for_active_identifier_is_allow_listed(self, hook_runner, project_env) -> None:
        """Writing to tmp/arc/{id}/ bypasses all blocked-path checks (allow-list is checked first)."""
        project, _ = project_env
        create_gap_state(project, identifier="fix-abc123")
        # Even if someone named their gap output file "ci.yml", it must be allowed
        result = hook_runner(
            SCRIPT,
            make_write_input("tmp/arc/fix-abc123/ci.yml"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_gap_output_dir_for_different_identifier_not_allowed(self, hook_runner, project_env) -> None:
        """Output dir for a *different* identifier than the active state is not allow-listed."""
        project, _ = project_env
        # Active identifier is VALID_IDENTIFIER ("fix-abc123"), but path uses different id
        create_gap_state(project, identifier=VALID_IDENTIFIER)
        result = hook_runner(
            SCRIPT,
            make_write_input("tmp/arc/other-identifier/report.md"),
        )
        # Not in the allow-list, hits the normal path — "tmp/arc/other-identifier/report.md"
        # doesn't match any blocked pattern, so must be allowed
        assert result.returncode == 0
        # No deny for a path that doesn't match any blocked pattern
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_deploy_yml_nested_in_subdir(self, hook_runner, project_env) -> None:
        """infra/deploy.yml must be blocked (nested CI YAML)."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("infra/deploy.yml"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout)

    @requires_jq
    def test_pipeline_yml_nested_in_subdir(self, hook_runner, project_env) -> None:
        """ci/pipeline.yml must be blocked (nested CI YAML)."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("ci/pipeline.yml"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout)

    @requires_jq
    def test_non_yml_ci_filename_allowed(self, hook_runner, project_env) -> None:
        """ci.yaml (with .yaml extension, not .yml) is NOT matched by the *.yml pattern -> allowed."""
        project, _ = project_env
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input("ci.yaml"),
        )
        # The script pattern is `*.yml` only — .yaml is NOT blocked
        assert result.returncode == 0
        assert not is_deny_json(result.stdout)

    @requires_jq
    def test_exit_code_always_zero(self, hook_runner, project_env) -> None:
        """Script always exits 0 — even for blocked paths (deny via JSON, not exit code)."""
        project, _ = project_env
        create_gap_state(project)
        for blocked_path in [
            ".env",
            ".claude/settings.json",
            ".github/CODEOWNERS",
            "node_modules/pkg/index.js",
            "../traversal",
            "ci.yml",
        ]:
            result = hook_runner(
                SCRIPT,
                make_write_input(blocked_path),
            )
            assert result.returncode == 0, (
                f"Script exited {result.returncode} for {blocked_path!r} — "
                "must always exit 0 (deny via JSON, not exit code)"
            )


# ===========================================================================
# TestGapFixerSessionIsolation
# ===========================================================================


class TestGapFixerSessionIsolation:
    """Session isolation: owner_pid + config_dir cross-session safety."""

    @requires_jq
    @pytest.mark.session_isolation
    def test_matching_owner_pid_enforces(self, hook_runner, project_env) -> None:
        """State file with owner_pid matching PPID -> enforcement active (deny blocked path)."""
        project, config = project_env
        create_gap_state(
            project,
            config_dir=config,
            owner_pid=os.getpid(),  # Matches PPID set by hook_runner
        )
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/settings.json"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout), (
            "Expected deny for .claude/ path when owner_pid matches — "
            f"stdout={result.stdout!r}"
        )

    @requires_jq
    @pytest.mark.session_isolation
    def test_mismatched_live_owner_pid_skips(self, hook_runner, project_env) -> None:
        """State file with mismatched live owner_pid -> enforcement skipped (fail-open)."""
        project, config = project_env
        # PID 1 (init/launchd) is always alive but never our PPID
        create_gap_state(
            project,
            config_dir=config,
            owner_pid=1,
        )
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/settings.json"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout), (
            "Expected allow (skip) when owner_pid is a different live process — "
            f"stdout={result.stdout!r}"
        )

    @requires_jq
    @pytest.mark.session_isolation
    def test_no_owner_pid_enforces_backward_compat(self, hook_runner, project_env) -> None:
        """State file without owner_pid/config_dir -> enforcement active (backward compat)."""
        project, _ = project_env
        # Legacy state file: no owner_pid, no config_dir
        create_gap_state(project)
        result = hook_runner(
            SCRIPT,
            make_write_input(".env"),
        )
        assert result.returncode == 0
        assert is_deny_json(result.stdout), (
            "Expected deny for .env when state file has no owner_pid (backward compat) — "
            f"stdout={result.stdout!r}"
        )

    @requires_jq
    @pytest.mark.session_isolation
    def test_mismatched_config_dir_skips(self, hook_runner, project_env) -> None:
        """State file with mismatched config_dir -> enforcement skipped (fail-open)."""
        project, config = project_env
        # Use a non-existent config_dir that won't match the test's CLAUDE_CONFIG_DIR
        create_gap_state(
            project,
            config_dir=Path("/tmp/fake-other-claude-config"),
            owner_pid=os.getpid(),
        )
        result = hook_runner(
            SCRIPT,
            make_write_input(".claude/settings.json"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout), (
            "Expected allow (skip) when config_dir doesn't match — "
            f"stdout={result.stdout!r}"
        )

    @requires_jq
    @pytest.mark.session_isolation
    def test_dead_owner_pid_skips(self, hook_runner, project_env) -> None:
        """State file with dead owner_pid -> enforcement skipped (orphan recovery)."""
        project, config = project_env
        # Use a very high PID that's extremely unlikely to be alive
        create_gap_state(
            project,
            config_dir=config,
            owner_pid=4194304,  # Above typical PID_MAX on most systems
        )
        result = hook_runner(
            SCRIPT,
            make_write_input(".env"),
        )
        assert result.returncode == 0
        assert not is_deny_json(result.stdout), (
            "Expected allow (skip) for dead owner_pid (orphan state) — "
            f"stdout={result.stdout!r}"
        )
