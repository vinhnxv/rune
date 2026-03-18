"""Tests for annotate-hook.sh — PostToolUse hook for echo dirty signaling."""

import json
import os
import stat
import subprocess

import pytest

HOOK_PATH = os.path.join(os.path.dirname(__file__), "annotate-hook.sh")


def run_hook(stdin_data, env_override=None, timeout=5):
    """Run annotate-hook.sh with given stdin and environment.

    Returns CompletedProcess with returncode, stdout, stderr.
    """
    env = os.environ.copy()
    if env_override:
        env.update(env_override)
    return subprocess.run(
        ["bash", HOOK_PATH],
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


@pytest.fixture
def project_dir(tmp_path):
    """Temporary project directory with CLAUDE_PROJECT_DIR set."""
    return str(tmp_path)


def signal_path(project_dir):
    return os.path.join(project_dir, "tmp", ".rune-signals", ".echo-dirty")


# ---------------------------------------------------------------------------
# Basic behavior
# ---------------------------------------------------------------------------

class TestBasicBehavior:
    def test_always_exits_zero(self, project_dir):
        """Hook is non-blocking — always exits 0 regardless of input."""
        result = run_hook("", env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert result.returncode == 0

    def test_exits_zero_on_invalid_json(self, project_dir):
        """Malformed JSON triggers ERR trap, but fail-forward exits 0.

        Note: The script has a fail-forward ERR trap that exits 0 even on
        errors. This is intentional — OPERATIONAL hooks should not block
        workflows due to hook failures. Invalid JSON causes jq to fail,
        but the ERR trap catches it and exits 0.
        """
        result = run_hook("not json at all", env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert result.returncode == 0  # fail-forward exits 0

    def test_exits_zero_on_empty_stdin(self, project_dir):
        """Empty stdin is handled gracefully."""
        result = run_hook("", env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert result.returncode == 0

    def test_hook_file_is_executable(self):
        """annotate-hook.sh must have execute permission."""
        assert os.access(HOOK_PATH, os.X_OK)


# ---------------------------------------------------------------------------
# Signal file creation
# ---------------------------------------------------------------------------

class TestSignalCreation:
    def test_creates_signal_on_memory_md_write(self, project_dir):
        """Writing to .rune/echoes/<role>/MEMORY.md creates a dirty signal."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/home/user/project/.rune/echoes/reviewer/MEMORY.md"
            }
        })
        result = run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert result.returncode == 0
        assert os.path.isfile(signal_path(project_dir))

        # Verify signal content is "1"
        with open(signal_path(project_dir)) as f:
            assert f.read() == "1"

    def test_creates_signal_dir_if_missing(self, project_dir):
        """tmp/.rune-signals/ is created automatically."""
        signals_dir = os.path.join(project_dir, "tmp", ".rune-signals")
        assert not os.path.exists(signals_dir)

        stdin = json.dumps({
            "tool_input": {
                "file_path": "/path/.rune/echoes/orchestrator/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert os.path.isdir(signals_dir)

    def test_signal_for_nested_role_path(self, project_dir):
        """Any role subdirectory under .rune/echoes/ triggers the signal."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/deep/nested/.rune/echoes/my-custom-role/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert os.path.isfile(signal_path(project_dir))


# ---------------------------------------------------------------------------
# No signal (non-matching paths)
# ---------------------------------------------------------------------------

class TestNoSignal:
    def test_no_signal_for_non_echo_file(self, project_dir):
        """Writing to a non-echo file does not create a signal."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/project/src/main.py"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert not os.path.exists(signal_path(project_dir))

    def test_no_signal_for_echoes_but_not_memory_md(self, project_dir):
        """Writing to .rune/echoes/ but not MEMORY.md doesn't trigger."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/project/.rune/echoes/reviewer/notes.txt"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert not os.path.exists(signal_path(project_dir))

    def test_no_signal_for_memory_md_outside_echoes(self, project_dir):
        """MEMORY.md not under .rune/echoes/ doesn't trigger."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/project/docs/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert not os.path.exists(signal_path(project_dir))

    def test_no_signal_when_file_path_missing(self, project_dir):
        """JSON without file_path key doesn't trigger."""
        stdin = json.dumps({
            "tool_input": {
                "command": "echo hello"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert not os.path.exists(signal_path(project_dir))

    def test_no_signal_for_partial_path_match(self, project_dir):
        """Path containing 'echoes' but not the full pattern doesn't trigger."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/project/.rune/echoes_backup/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert not os.path.exists(signal_path(project_dir))

    def test_signal_for_memory_md_at_echoes_root(self, project_dir):
        """MEMORY.md directly in .rune/echoes/ (no role subdir) DOES match
        the glob *".rune/echoes/"*"MEMORY.md" because * matches zero or more
        chars between echoes/ and MEMORY.md."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/project/.rune/echoes/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        # The glob pattern *".rune/echoes/"*"MEMORY.md" uses * between
        # echoes/ and MEMORY.md — which matches zero or more chars.
        # So .rune/echoes/MEMORY.md DOES match (zero chars between / and M).
        assert os.path.isfile(signal_path(project_dir))

    def test_signal_for_legacy_claude_echoes_path(self, project_dir):
        """Legacy .claude/echoes/ path still triggers dirty signal (backwards compat)."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/home/user/project/.claude/echoes/reviewer/MEMORY.md"
            }
        })
        result = run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        assert result.returncode == 0
        assert os.path.isfile(signal_path(project_dir))


# ---------------------------------------------------------------------------
# SEC-006: stdin cap
# ---------------------------------------------------------------------------

class TestStdinCap:
    def test_large_stdin_truncated_causes_jq_failure(self, project_dir):
        """SEC-006: stdin > 64KB is truncated, producing invalid JSON.

        head -c 65536 chops the closing braces off large JSON, so jq
        cannot parse any field — even file_path appearing early.
        The fail-forward ERR trap catches the jq failure and exits 0.
        No signal is created because file_path extraction failed.
        """
        inner = json.dumps({
            "tool_input": {
                "file_path": "/project/.rune/echoes/reviewer/MEMORY.md",
                "content": "x" * 100_000,  # ~100KB → truncated to 64KB
            }
        })
        result = run_hook(inner, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        # jq fails on truncated (invalid) JSON → ERR trap → fail-forward exits 0
        assert result.returncode == 0
        # No signal: jq failed before file_path could be extracted
        assert not os.path.exists(signal_path(project_dir))

    def test_file_path_beyond_cap_not_matched(self, project_dir):
        """If file_path is positioned after 64KB, truncation hides it from jq.

        The 70KB padding causes head -c 65536 to chop mid-string, making
        the JSON invalid. jq fails, ERR trap catches it, fail-forward exits 0.
        No signal is created because file_path was beyond the 64KB cap.
        """
        padding = '"padding": "' + ("A" * 70_000) + '"'
        crafted = '{"tool_input": {' + padding + ', "file_path": "/project/.rune/echoes/r/MEMORY.md"}}'
        result = run_hook(crafted, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        # Truncated JSON → jq parse error → ERR trap → fail-forward exits 0
        assert result.returncode == 0
        # No signal regardless — file_path was beyond the 64KB cap
        assert not os.path.exists(signal_path(project_dir))


# ---------------------------------------------------------------------------
# Environment variable handling
# ---------------------------------------------------------------------------

class TestEnvironment:
    def test_uses_claude_project_dir(self, project_dir):
        """Signal file goes under CLAUDE_PROJECT_DIR when set."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/p/.rune/echoes/r/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        expected = os.path.join(project_dir, "tmp", ".rune-signals", ".echo-dirty")
        assert os.path.isfile(expected)

    def test_falls_back_to_pwd_when_no_project_dir(self, tmp_path):
        """Without CLAUDE_PROJECT_DIR, falls back to $(pwd)."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/p/.rune/echoes/r/MEMORY.md"
            }
        })
        # Unset CLAUDE_PROJECT_DIR and run from tmp_path
        env = os.environ.copy()
        env.pop("CLAUDE_PROJECT_DIR", None)
        result = subprocess.run(
            ["bash", HOOK_PATH],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=5,
            env=env,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0
        expected = os.path.join(str(tmp_path), "tmp", ".rune-signals", ".echo-dirty")
        assert os.path.isfile(expected)


# ---------------------------------------------------------------------------
# Idempotency and overwrite
# ---------------------------------------------------------------------------

class TestIdempotency:
    def test_signal_overwritten_on_repeat(self, project_dir):
        """Running the hook twice overwrites the signal file (not appending)."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/p/.rune/echoes/r/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})

        with open(signal_path(project_dir)) as f:
            content = f.read()
        assert content == "1"  # not "11"

    def test_signal_file_permissions_restrictive(self, project_dir):
        """umask 077 means signal file is only readable by owner."""
        stdin = json.dumps({
            "tool_input": {
                "file_path": "/p/.rune/echoes/r/MEMORY.md"
            }
        })
        run_hook(stdin, env_override={"CLAUDE_PROJECT_DIR": project_dir})

        sig = signal_path(project_dir)
        mode = os.stat(sig).st_mode
        # umask 077 → file created with 0600 (rw-------)
        # Check that group and other have no permissions
        assert not (mode & stat.S_IRGRP)  # no group read
        assert not (mode & stat.S_IWGRP)  # no group write
        assert not (mode & stat.S_IROTH)  # no other read
        assert not (mode & stat.S_IWOTH)  # no other write
