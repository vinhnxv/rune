"""Shared fixtures for the Rune Arc test harness."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterator

# Ensure tests/ is in sys.path so `from helpers.x import Y` works regardless of cwd
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest

TESTS_DIR = Path(__file__).parent

FIXTURES_DIR = TESTS_DIR / "fixtures"
CHALLENGE_DIR = TESTS_DIR / "challenge"
PLUGIN_DIR = TESTS_DIR.parent / "plugins" / "rune"
SCRIPTS_DIR = PLUGIN_DIR / "scripts"


# ---------------------------------------------------------------------------
# Custom markers + CLI option
# ---------------------------------------------------------------------------


def pytest_addoption(parser: pytest.Parser) -> None:
    """Register custom pytest CLI options."""
    parser.addoption(
        "--run-stress",
        action="store_true",
        default=False,
        help="Run stress tests (excluded by default due to high API cost).",
    )


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line("markers", "requires_jq: test requires jq binary")
    config.addinivalue_line("markers", "security: security-critical test")
    config.addinivalue_line("markers", "session_isolation: cross-session safety test")
    config.addinivalue_line(
        "markers",
        "pressure: multi-turn arc run under cognitive-load scenarios (cap $0.50/test)",
    )
    config.addinivalue_line(
        "markers",
        "stress: multi-agent coordination test; requires --run-stress to execute (cap $2.00/test)",
    )
    config.addinivalue_line(
        "markers",
        "soak: long-running pipeline endurance test (cap $5.00/test)",
    )


def pytest_collection_modifyitems(
    config: pytest.Config,
    items: list[pytest.Item],
) -> None:
    """Skip stress-marked tests unless --run-stress was passed."""
    if config.getoption("--run-stress", default=False):
        return
    skip_stress = pytest.mark.skip(reason="pass --run-stress to run stress tests")
    for item in items:
        if item.get_closest_marker("stress"):
            item.add_marker(skip_stress)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def has_jq() -> bool:
    """Check if jq is available on PATH."""
    try:
        subprocess.run(["jq", "--version"], capture_output=True, timeout=5)
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


requires_jq = pytest.mark.skipif(not has_jq(), reason="jq not installed")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES_DIR


@pytest.fixture
def challenge_dir() -> Path:
    return CHALLENGE_DIR


@pytest.fixture
def plugin_dir() -> Path:
    return PLUGIN_DIR


@pytest.fixture
def scripts_dir() -> Path:
    return SCRIPTS_DIR


@pytest.fixture
def sample_checkpoint_v4(fixtures_dir: Path) -> dict:
    return json.loads((fixtures_dir / "checkpoint_v4.json").read_text())


@pytest.fixture
def sample_tome(fixtures_dir: Path) -> str:
    return (fixtures_dir / "tome_sample.md").read_text()


@pytest.fixture
def isolated_claude_config() -> Iterator[Path]:
    """Validate ~/.claude-rune-test/ exists for isolated E2E testing.

    This fixture expects the isolated config directory to be set up manually
    before running E2E tests. It never reads from or touches ~/.claude/.

    Manual setup:
        mkdir -p ~/.claude-rune-test
        # Copy any needed settings into it manually

    The harness uses CLAUDE_CONFIG_DIR=~/.claude-rune-test to redirect
    all Claude Code state (teams, tasks, memory) to this directory.
    """
    from helpers.claude_runner import ClaudeRunner

    config_dir = ClaudeRunner.default_config_dir()
    if not config_dir.exists():
        pytest.skip(
            f"Isolated config dir not found: {config_dir}\n"
            f"Create it manually: mkdir -p {config_dir}"
        )

    # Ensure state subdirs exist (non-destructive)
    for state_dir in ("teams", "tasks", "projects", "agent-memory"):
        (config_dir / state_dir).mkdir(exist_ok=True)

    yield config_dir


@pytest.fixture
def project_env() -> Iterator[tuple[Path, Path]]:
    """Create an isolated project root + CLAUDE_CONFIG_DIR pair for hook tests.

    Yields (project_dir, config_dir) with the standard Rune directory layout.
    Both directories are cleaned up after the test.
    """
    import os
    import tempfile

    with tempfile.TemporaryDirectory(prefix="rune-project-") as project_dir:
        with tempfile.TemporaryDirectory(prefix="rune-config-") as config_dir:
            project = Path(project_dir)
            config = Path(config_dir)
            (project / "tmp").mkdir()
            (project / ".git").mkdir()  # SEC-001: signal writer requires .git dir
            (project / ".claude").mkdir()
            (project / ".claude" / "arc").mkdir()
            (config / "teams").mkdir()
            (config / "tasks").mkdir()
            yield project, config


@pytest.fixture
def pressure_config_dir() -> Iterator[Path]:
    """Temporary CLAUDE_CONFIG_DIR for a single pressure test.

    Provides an isolated config directory with standard Rune state
    sub-directories pre-created.  Cleaned up automatically after the test.

    This root-level fixture is available to any test in the suite, not just
    tests inside ``tests/pressure/``.

    Yields:
        Path to the isolated config directory.
    """
    with tempfile.TemporaryDirectory(prefix="rune-pressure-") as tmpdir:
        config = Path(tmpdir)
        for subdir in ("teams", "tasks", "projects", "agent-memory"):
            (config / subdir).mkdir()
        yield config


@pytest.fixture
def hook_runner(project_env: tuple[Path, Path]):
    """Factory fixture for running hook scripts with proper environment isolation."""
    import os

    project, config = project_env
    # Resolve symlinks for config_dir to match what state files store
    # (on macOS, /var is a symlink to /private/var)
    resolved_config = config.resolve()

    def _run(
        script: Path,
        input_json: dict | str,
        *,
        env_override: dict[str, str] | None = None,
        timeout: int = 15,
    ) -> subprocess.CompletedProcess[str]:
        if isinstance(input_json, dict):
            # Inject cwd if not already provided
            if "cwd" not in input_json:
                input_json["cwd"] = str(project)
            stdin_text = json.dumps(input_json)
        else:
            stdin_text = input_json

        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(config)
        env["RUNE_CURRENT_CFG"] = str(resolved_config)  # Resolved for ownership matching
        env["PPID"] = str(os.getpid())  # Use test process PID
        if env_override:
            env.update(env_override)

        return subprocess.run(
            ["bash", str(script)],
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            cwd=str(project),
        )

    return _run


@pytest.fixture(autouse=True)
def cleanup_idle_retry_counters():
    """Clean up *.idle-retries files between tests to prevent cross-test contamination."""
    import glob

    yield

    # Clean up any idle retry counter files in /tmp
    for pattern in [
        "/tmp/*.idle-retries",
        "/tmp/**/**/*.idle-retries",
    ]:
        for f in glob.glob(pattern):
            try:
                Path(f).unlink(missing_ok=True)
            except OSError:
                pass
