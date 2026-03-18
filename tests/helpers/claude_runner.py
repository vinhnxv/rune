"""Claude CLI subprocess wrapper for automated /rune:arc invocation.

Invokes `claude -p` in non-interactive mode with the Rune plugin loaded,
captures structured JSON output, and tracks token usage and timing.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class RunResult:
    """Result from a Claude CLI invocation."""

    exit_code: int
    stdout: str
    stderr: str
    duration_seconds: float
    output_json: dict | None = None
    session_id: str | None = None
    token_usage: dict | None = None

    @property
    def success(self) -> bool:
        return self.exit_code == 0

    @property
    def result_text(self) -> str:
        if self.output_json and "result" in self.output_json:
            return self.output_json["result"]
        return self.stdout


@dataclass
class ClaudeRunner:
    """Wrapper for invoking Claude Code CLI as a subprocess.

    Configures isolated execution with:
    - Rune plugin loaded via --plugin-dir
    - No memory persistence (CLAUDE_CODE_DISABLE_AUTO_MEMORY=1)
    - Structured JSON output for machine parsing
    - Cost and turn limits for safety
    """

    plugin_dir: Path
    working_dir: Path
    max_turns: int = 200
    max_budget_usd: float = 15.0
    timeout_seconds: int = 3600  # 60 min default
    model: str | None = None
    extra_env: dict[str, str] = field(default_factory=dict)
    verbose: bool = False
    isolated_config_dir: Path | None = None

    # Fixed isolated config location in user home (never touches ~/.claude/)
    CONFIG_DIR_NAME = ".claude-rune-test"
    # State dirs to create fresh in isolated config
    _STATE_DIRS = ("teams", "tasks", "projects", "agent-memory")

    @classmethod
    def default_config_dir(cls) -> Path:
        """Return the fixed isolated config path: ~/.claude-rune-test/"""
        return Path.home() / cls.CONFIG_DIR_NAME

    def setup_isolated_config(self) -> Path:
        """Validate that the isolated config dir ~/.claude-rune-test/ exists.

        The directory must be set up manually before running E2E tests.
        This method only validates its existence and ensures required state
        subdirectories are present — it never deletes or recreates the directory.

        Raises:
            FileNotFoundError: If ~/.claude-rune-test/ does not exist.
        """
        config_dir = self.default_config_dir()
        if not config_dir.exists():
            raise FileNotFoundError(
                f"Isolated config directory not found: {config_dir}\n"
                f"Please create it manually before running E2E tests:\n"
                f"  mkdir -p {config_dir}"
            )

        # Ensure state subdirs exist (non-destructive)
        for subdir in self._STATE_DIRS:
            (config_dir / subdir).mkdir(exist_ok=True)

        self.isolated_config_dir = config_dir
        return config_dir

    def cleanup_config(self) -> None:
        """Clear memory/state from the isolated config dir.

        Removes contents of state subdirectories (agent-memory, cache, debug,
        tasks, teams, todos, plans, projects, shell-snapshots) and backup files.
        Never deletes the directory itself.
        """
        if not self.isolated_config_dir or not self.isolated_config_dir.exists():
            return

        # Clear state subdirectories (non-destructive to the dirs themselves)
        state_items = list(self._STATE_DIRS) + ["cache", "debug", "shell-snapshots", "todos", "plans"]
        for subdir in state_items:
            d = self.isolated_config_dir / subdir
            if d.exists():
                shutil.rmtree(d, ignore_errors=True)
                d.mkdir(exist_ok=True)

        # Remove history and backups, keep .claude.json
        history = self.isolated_config_dir / "history.jsonl"
        if history.exists():
            history.unlink()
        for backup in self.isolated_config_dir.glob(".claude.json.backup.*"):
            backup.unlink(missing_ok=True)

    # Env var name patterns that must never leak into subprocesses
    _SENSITIVE_ENV_PATTERNS = ("SECRET", "TOKEN", "CREDENTIAL", "PASSWORD", "PRIVATE_KEY")

    def _build_env(self) -> dict[str, str]:
        """Build isolated environment for Claude CLI.

        Starts from a full copy of os.environ because the Claude CLI
        requires many platform-specific variables (NODE_PATH, npm paths,
        locale, terminal info, etc.) to function.  After copying, we
        strip any variable whose name contains a known-sensitive pattern
        so that credentials are never forwarded to the subprocess.
        """
        env = os.environ.copy()

        # Strip known-sensitive variables to avoid leaking secrets
        for key in list(env):
            if any(pat in key.upper() for pat in self._SENSITIVE_ENV_PATTERNS):
                del env[key]

        # Marker for identifying test-spawned processes (inherited by teammates)
        env["RUNE_TEST_HARNESS"] = "1"
        # Disable memory and telemetry for hermetic testing
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_ERROR_REPORTING"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = "1"
        # Enable Agent Teams (required for Rune)
        env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"

        # Redirect config directory for full state isolation
        if self.isolated_config_dir:
            env["CLAUDE_CONFIG_DIR"] = str(self.isolated_config_dir)

        # Remove CLAUDECODE marker so nested invocation works
        env.pop("CLAUDECODE", None)

        env.update(self.extra_env)
        return env

    def _build_args(self, prompt: str) -> list[str]:
        """Build claude CLI argument list."""
        args = [
            "claude",
            "-p", prompt,
            "--plugin-dir", str(self.plugin_dir.resolve()),
            "--output-format", "json",
            "--no-session-persistence",
            "--max-turns", str(self.max_turns),
            "--max-budget-usd", str(self.max_budget_usd),
        ]
        if os.environ.get("RUNE_TEST_SKIP_PERMISSIONS", "") == "1":
            if os.environ.get("RUNE_TEST_HARNESS", "") != "1":
                logger.warning(
                    "RUNE_TEST_SKIP_PERMISSIONS is set but RUNE_TEST_HARNESS is not; "
                    "refusing to add --dangerously-skip-permissions"
                )
            else:
                args.append("--dangerously-skip-permissions")
        if self.model:
            args.extend(["--model", self.model])
        if self.verbose:
            args.append("--verbose")
        return args

    def run(self, prompt: str) -> RunResult:
        """Execute a single prompt and return structured result."""
        args = self._build_args(prompt)
        env = self._build_env()

        start = time.monotonic()
        try:
            proc = subprocess.run(
                args,
                cwd=self.working_dir,
                env=env,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
            )
        except subprocess.TimeoutExpired as e:
            duration = time.monotonic() - start
            if isinstance(e.stdout, bytes):
                stdout = e.stdout.decode("utf-8", errors="replace")
            else:
                stdout = e.stdout or ""
            return RunResult(
                exit_code=-1,
                stdout=stdout,
                stderr=f"TIMEOUT after {duration:.0f}s",
                duration_seconds=duration,
            )

        duration = time.monotonic() - start

        # Parse JSON output
        output_json = None
        session_id = None
        token_usage = None
        try:
            output_json = json.loads(proc.stdout)
            session_id = output_json.get("session_id")
            token_usage = output_json.get("usage")
        except (json.JSONDecodeError, TypeError):
            logger.debug("Failed to parse Claude CLI stdout as JSON (non-fatal)")

        return RunResult(
            exit_code=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            duration_seconds=duration,
            output_json=output_json,
            session_id=session_id,
            token_usage=token_usage,
        )

    def run_arc(
        self,
        plan_file: str,
        flags: list[str] | None = None,
    ) -> RunResult:
        """Run /rune:arc with a plan file.

        Args:
            plan_file: Relative path to plan file from working_dir.
            flags: Additional flags like --no-forge, --approve.
        """
        flag_str = " ".join(flags) if flags else ""
        prompt = f"/rune:arc {plan_file} {flag_str}".strip()
        return self.run(prompt)

    def run_review(self) -> RunResult:
        """Run /rune:appraise on current changes."""
        return self.run("/rune:appraise")

    def run_command(self, command: str) -> RunResult:
        """Run any /rune: command."""
        return self.run(command)
