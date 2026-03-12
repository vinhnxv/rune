"""Tests for doc-pack-staleness.sh SessionStart hook."""

import json
import os
import subprocess
import tempfile
import time

import pytest


SCRIPT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "doc-pack-staleness.sh"
)


def _run_hook(manifests_dir, env_overrides=None):
    """Run the staleness hook script with a custom manifests directory.

    Returns (exit_code, stdout, stderr).
    """
    env = os.environ.copy()
    # Point CLAUDE_CONFIG_DIR to the root containing echoes/global/manifests/
    # manifests_dir = .../echoes/global/manifests → go up 3 levels
    config_dir = os.path.dirname(os.path.dirname(os.path.dirname(manifests_dir)))
    env["CLAUDE_CONFIG_DIR"] = config_dir
    # Disable trace logging to avoid file creation
    env.pop("RUNE_TRACE", None)
    if env_overrides:
        env.update(env_overrides)
    result = subprocess.run(
        ["bash", SCRIPT_PATH],
        capture_output=True, text=True, env=env, timeout=10,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


@pytest.fixture
def manifest_dir():
    """Create a temporary manifests directory structure."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Structure: tmpdir/echoes/global/manifests/
        manifests = os.path.join(tmpdir, "echoes", "global", "manifests")
        os.makedirs(manifests)
        yield manifests


def _write_manifest(manifests_dir, name, last_updated, version="1.0.0"):
    """Write a manifest JSON file."""
    manifest = {
        "name": name,
        "version": version,
        "last_updated": last_updated,
        "source": f"doc-pack:{name}@{version}",
    }
    path = os.path.join(manifests_dir, f"{name}.json")
    with open(path, "w") as f:
        json.dump(manifest, f)
    return path


class TestStalenessHookNoManifests:
    """Test hook behavior when no manifests exist."""

    def test_no_manifests_dir_exits_clean(self):
        """No manifests directory → exit 0, no output."""
        with tempfile.TemporaryDirectory() as tmpdir:
            env = {"CLAUDE_CONFIG_DIR": tmpdir}
            result = subprocess.run(
                ["bash", SCRIPT_PATH],
                capture_output=True, text=True,
                env={**os.environ, **env}, timeout=10,
            )
            assert result.returncode == 0
            assert result.stdout.strip() == ""

    def test_empty_manifests_dir(self, manifest_dir):
        """Empty manifests directory → exit 0, no output."""
        code, stdout, _ = _run_hook(manifest_dir)
        assert code == 0
        assert stdout == ""


class TestStalenessHookFreshPacks:
    """Test hook behavior with fresh (non-stale) packs."""

    def test_fresh_pack_no_warning(self, manifest_dir):
        """Pack updated today → no warning."""
        today = time.strftime("%Y-%m-%d")
        _write_manifest(manifest_dir, "shadcn-ui", today)
        code, stdout, _ = _run_hook(manifest_dir)
        assert code == 0
        assert stdout == ""

    def test_pack_at_threshold_no_warning(self, manifest_dir):
        """Pack exactly at 90 days → no warning (uses > not >=)."""
        import datetime
        threshold_date = (
            datetime.datetime.now() - datetime.timedelta(days=90)
        ).strftime("%Y-%m-%d")
        _write_manifest(manifest_dir, "tailwind-v4", threshold_date)
        code, stdout, _ = _run_hook(manifest_dir)
        assert code == 0
        assert stdout == ""


class TestStalenessHookStalePacks:
    """Test hook behavior with stale packs."""

    def test_stale_pack_warns(self, manifest_dir):
        """Pack older than 90 days → warning in JSON output."""
        _write_manifest(manifest_dir, "fastapi", "2025-01-01")
        code, stdout, _ = _run_hook(manifest_dir)
        assert code == 0
        assert stdout != ""
        data = json.loads(stdout)
        assert data["hookSpecificOutput"]["hookEventName"] == "SessionStart"
        ctx = data["hookSpecificOutput"]["additionalContext"]
        assert "fastapi" in ctx
        assert "Doc Pack Staleness" in ctx

    def test_mixed_fresh_and_stale(self, manifest_dir):
        """Mixed packs → only stale ones warned."""
        today = time.strftime("%Y-%m-%d")
        _write_manifest(manifest_dir, "shadcn-ui", today)
        _write_manifest(manifest_dir, "old-pack", "2024-06-01")
        code, stdout, _ = _run_hook(manifest_dir)
        assert code == 0
        assert "old-pack" in stdout
        assert "shadcn-ui" not in stdout


class TestStalenessHookEdgeCases:
    """Test edge cases and error handling."""

    def test_missing_last_updated_field(self, manifest_dir):
        """Manifest without last_updated → skip, no crash."""
        path = os.path.join(manifest_dir, "broken.json")
        with open(path, "w") as f:
            json.dump({"name": "broken", "version": "1.0.0"}, f)
        code, stdout, _ = _run_hook(manifest_dir)
        assert code == 0
        # No warning for the pack with missing date
        assert "broken" not in stdout

    def test_malformed_json_manifest(self, manifest_dir):
        """T-P5-15: Corrupted manifest JSON → exit 0, no crash."""
        path = os.path.join(manifest_dir, "corrupt.json")
        with open(path, "w") as f:
            f.write("{invalid json content")
        code, _, _ = _run_hook(manifest_dir)
        assert code == 0

    def test_hookEventName_present(self, manifest_dir):
        """Verify hookEventName is always SessionStart when output exists."""
        _write_manifest(manifest_dir, "stale-test", "2024-01-01")
        code, stdout, _ = _run_hook(manifest_dir)
        assert code == 0
        if stdout:
            data = json.loads(stdout)
            assert data["hookSpecificOutput"]["hookEventName"] == "SessionStart"
