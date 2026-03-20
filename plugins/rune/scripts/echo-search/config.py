"""Echo Search — Configuration, constants, security validation, and utilities.

This module centralises all configuration state consumed by the echo-search
MCP server: environment variable reads, security validation (SEC-001 through
SEC-007), stopwords, SQL helpers, dirty-signal helpers, trace logging, and
talisman config loading with mtime caching.

**No internal dependencies** — this module imports only the Python standard
library (plus an optional ``yaml`` import for talisman loading).  Every other
echo-search module may safely ``from config import …`` without creating
circular imports.

Key exports
-----------
Constants:
    ECHO_DIR, DB_PATH, GLOBAL_ECHO_DIR, GLOBAL_DB_PATH,
    ECHO_ELICITATION_ENABLED, STOPWORDS

Security:
    _FORBIDDEN_PREFIXES  (module-level validation runs at import time)

SQL helpers:
    _in_clause(count)

Dirty-signal helpers:
    _signal_path, _check_and_clear_dirty, _write_dirty_signal,
    _GLOBAL_DIRTY_FILENAME, _global_dirty_path,
    _check_and_clear_global_dirty, _write_global_dirty_signal

Trace / diagnostics:
    _RUNE_TRACE, _trace(stage, start)

Talisman config:
    _talisman_cache, _talisman_search_paths, _try_load_talisman_file,
    _load_talisman, _get_echoes_config
"""

from __future__ import annotations

import logging
import os
import sys
import time
from typing import Any, Dict, List, Optional

logger = logging.getLogger("echo-search")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ECHO_DIR = os.environ.get("ECHO_DIR", "")
DB_PATH = os.environ.get("DB_PATH", "")

# SEC-001/SEC-003: Validate env vars don't point to system or sensitive directories
_FORBIDDEN_PREFIXES = (
    "/etc", "/usr", "/bin", "/sbin", "/var/run", "/proc", "/sys",
    os.path.expanduser("~/.ssh"),
    os.path.expanduser("~/.gnupg"),
    os.path.expanduser("~/.aws"),
)
for _env_name, _env_val in [("ECHO_DIR", ECHO_DIR), ("DB_PATH", DB_PATH)]:
    if _env_val:
        _resolved = os.path.realpath(_env_val)
        if any(_resolved.startswith(p) for p in _FORBIDDEN_PREFIXES):
            print(
                "Error: %s points to system directory: %s" % (_env_name, _resolved),
                file=sys.stderr,
            )
            sys.exit(1)
# SEC-003 FIX: Allowlist validation for ECHO_DIR — must be under user home,
# project dir, or system temp. Prevents reading from arbitrary locations.
if ECHO_DIR:
    _echo_resolved = os.path.realpath(ECHO_DIR)
    _home = os.path.expanduser("~")
    _cwd = os.path.realpath(os.getcwd())
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    _allowed_echo_prefixes = (_home, _cwd, _tmpdir)
    # SEC-003 FIX: Add os.sep to prevent prefix-collision bypass (e.g. /home/alice-evil
    # would pass startswith("/home/alice") without the separator check).
    if not any(_echo_resolved.startswith(p + os.sep) or _echo_resolved == p
               for p in _allowed_echo_prefixes):
        print(
            "Error: ECHO_DIR must be under home, project, or temp directory: %s"
            % _echo_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

if DB_PATH:
    _db_resolved = os.path.realpath(DB_PATH)
    if not (_db_resolved.endswith(".db") or _db_resolved.endswith(".sqlite")):
        print(
            "Error: DB_PATH must end with .db or .sqlite: %s" % _db_resolved,
            file=sys.stderr,
        )
        sys.exit(1)
    # SEC-007 FIX: Allowlist DB_PATH parent directory — must be under user home,
    # project dir, or system temp. Prevents writes to arbitrary locations.
    _db_parent = os.path.dirname(_db_resolved)
    _home = os.path.expanduser("~")
    _cwd = os.path.realpath(os.getcwd())
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    _allowed_prefixes = (_home, _cwd, _tmpdir)
    # SEC-003 FIX: Add os.sep guard against prefix-collision bypass.
    if not any(_db_parent.startswith(p + os.sep) or _db_parent == p
               for p in _allowed_prefixes):
        print(
            "Error: DB_PATH must be under home, project, or temp directory: %s"
            % _db_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

# Global echo store — cross-project knowledge + doc packs (lazy, optional)
GLOBAL_ECHO_DIR = os.environ.get("GLOBAL_ECHO_DIR", "")
GLOBAL_DB_PATH = os.environ.get("GLOBAL_DB_PATH", "")

# Validate global env vars through the same security checks as project vars
for _env_name, _env_val in [("GLOBAL_ECHO_DIR", GLOBAL_ECHO_DIR),
                             ("GLOBAL_DB_PATH", GLOBAL_DB_PATH)]:
    if _env_val:
        _resolved = os.path.realpath(_env_val)
        if any(_resolved.startswith(p) for p in _FORBIDDEN_PREFIXES):
            print(
                "Error: %s points to system directory: %s"
                % (_env_name, _resolved),
                file=sys.stderr,
            )
            sys.exit(1)

if GLOBAL_ECHO_DIR:
    _global_echo_resolved = os.path.realpath(GLOBAL_ECHO_DIR)
    _home = os.path.expanduser("~")
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    # SEC-003 FIX: Add os.sep guard against prefix-collision bypass.
    if not any(_global_echo_resolved.startswith(p + os.sep) or _global_echo_resolved == p
               for p in (_home, _tmpdir)):
        print(
            "Error: GLOBAL_ECHO_DIR must be under home or temp directory: %s"
            % _global_echo_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

if GLOBAL_DB_PATH:
    _gdb_resolved = os.path.realpath(GLOBAL_DB_PATH)
    if not (_gdb_resolved.endswith(".db") or _gdb_resolved.endswith(".sqlite")):
        print(
            "Error: GLOBAL_DB_PATH must end with .db or .sqlite: %s"
            % _gdb_resolved,
            file=sys.stderr,
        )
        sys.exit(1)
    # SEC-003 FIX: Allowlist GLOBAL_DB_PATH parent directory — must be under
    # user home or system temp (matching DB_PATH allowlist pattern).
    _gdb_parent = os.path.dirname(_gdb_resolved)
    _home = os.path.expanduser("~")
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    # SEC-003 FIX: Add os.sep guard against prefix-collision bypass.
    if not any(_gdb_parent.startswith(p + os.sep) or _gdb_parent == p
               for p in (_home, _tmpdir)):
        print(
            "Error: GLOBAL_DB_PATH must be under home or temp directory: %s"
            % _gdb_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

# Talisman gate: echoes.elicitation_enabled (default: false).
# When false, elicitation is skipped during automated workflows.
# Set via start.sh from talisman.yml echoes.elicitation_enabled.
ECHO_ELICITATION_ENABLED = os.environ.get("ECHO_ELICITATION_ENABLED", "false").lower() == "true"

# ---------------------------------------------------------------------------
# Elicitation strategy note
# ---------------------------------------------------------------------------
# OPTION B (implemented): When ECHO_ELICITATION_ENABLED=true and result
# count exceeds the refinement threshold, we include an "elicitation_suggestion"
# field in the search response with recommended query refinements. The caller
# (Claude Code) can then present these suggestions interactively via its own
# elicitation layer. This avoids protocol-level complexity entirely.
#
# (Option A — protocol-level elicitation via write_stream — is not implemented
# because the MCP low-level Server's request/response model does not support
# sending elicitation/create mid-response. Option A infrastructure has been
# removed per BACK-107.)

STOPWORDS = frozenset([
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
    "from", "had", "has", "have", "he", "her", "his", "i", "in",
    "is", "it", "its", "my", "not", "of", "on", "or", "our", "she",
    "so", "that", "the", "their", "them", "then", "there", "these",
    "they", "this", "to", "us", "was", "we", "what", "when", "which",
    "who", "will", "with", "you", "your",
])

# ---------------------------------------------------------------------------
# SQL helpers
# ---------------------------------------------------------------------------


def _in_clause(count):
    # type: (int) -> str
    """Build a parameterized IN-clause placeholder string.

    Returns a string like ``?,?,?`` for *count* parameters.
    SAFE: The output contains only literal ``?`` characters — never
    user-supplied data — so %-formatting the result into SQL is
    equivalent to parameterized queries.
    """
    return ",".join(["?"] * count)


# ---------------------------------------------------------------------------
# Dirty signal helpers (consumed from annotate-hook.sh)
# ---------------------------------------------------------------------------

# The PostToolUse hook (annotate-hook.sh) writes a sentinel file when a
# MEMORY.md is edited.  Before each search we check for this file and
# trigger a reindex so new echoes appear immediately in results.

_SIGNAL_SUFFIX = os.path.join(".rune", "echoes")


def _signal_path(echo_dir):
    # type: (str) -> str
    """Derive the dirty-signal file path from ECHO_DIR.

    ECHO_DIR is ``<project>/.rune/echoes``.  The hook writes the signal to
    ``<project>/tmp/.rune-signals/.echo-dirty``.
    """
    if not echo_dir:
        return ""
    # Strip /.rune/echoes (or .rune/echoes) suffix to get project root
    normalized = echo_dir.rstrip(os.sep)
    if normalized.endswith(_SIGNAL_SUFFIX):
        project_root = normalized[: -len(_SIGNAL_SUFFIX)].rstrip(os.sep)
    else:
        # Fallback: walk up two directories
        project_root = os.path.dirname(os.path.dirname(normalized))
    # SEC-007: Re-canonicalize derived project root to prevent path traversal
    project_root = os.path.realpath(project_root)
    return os.path.join(project_root, "tmp", ".rune-signals", ".echo-dirty")


def _check_and_clear_dirty(echo_dir):
    # type: (str) -> bool
    """Return True (and delete the file) if the dirty signal is present."""
    path = _signal_path(echo_dir)
    if not path:
        return False
    try:
        os.remove(path)
        return True
    except FileNotFoundError:
        pass  # Signal was already consumed by another process
    except OSError:
        pass  # Permission issue or other OS error — safe to ignore
    return False


def _write_dirty_signal(echo_dir: str) -> None:
    """EDGE-021: Trigger dirty signal after promotion."""
    sig_path = _signal_path(echo_dir)
    if sig_path:
        try:
            os.makedirs(os.path.dirname(sig_path), exist_ok=True)
            with open(sig_path, "w") as f:
                f.write("promoted")
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Global dirty signal (enrichment D4)
# ---------------------------------------------------------------------------
# Global echoes use a dedicated signal path at GLOBAL_ECHO_DIR/.global-echo-dirty
# instead of deriving via _signal_path(), because the global echo directory
# has no project root to derive from.

_GLOBAL_DIRTY_FILENAME = ".global-echo-dirty"


def _global_dirty_path() -> str:
    """Return the global dirty signal file path, or empty string if disabled."""
    if not GLOBAL_ECHO_DIR:
        return ""
    return os.path.join(GLOBAL_ECHO_DIR, _GLOBAL_DIRTY_FILENAME)


def _check_and_clear_global_dirty() -> bool:
    """Return True (and delete the file) if the global dirty signal is present."""
    path = _global_dirty_path()
    if not path:
        return False
    try:
        os.remove(path)
        return True
    except FileNotFoundError:
        pass  # Signal was already consumed by another process
    except OSError:
        pass  # Permission issue or other OS error — safe to ignore
    return False


def _write_global_dirty_signal() -> None:
    """Write the global dirty signal file."""
    path = _global_dirty_path()
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("dirty")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Talisman config with mtime caching (Task 7)
# ---------------------------------------------------------------------------

_talisman_cache = {"mtime": 0.0, "path": "", "config": {}}  # type: Dict[str, Any]
_RUNE_TRACE = os.environ.get("RUNE_TRACE", "") == "1"


def _trace(stage: str, start: float) -> None:
    """Log pipeline stage timing to stderr when RUNE_TRACE=1 (EDGE-029)."""
    if _RUNE_TRACE:
        elapsed_ms = (time.time() - start) * 1000
        print("[echo-search] %s: %.1fms" % (stage, elapsed_ms), file=sys.stderr)


def _talisman_search_paths() -> List[str]:
    """Build ordered list of talisman.yml candidate paths."""
    paths = []
    if ECHO_DIR:
        claude_dir = os.path.dirname(ECHO_DIR.rstrip(os.sep))
        paths.append(os.path.join(claude_dir, "talisman.yml"))
    config_dir = os.environ.get(
        "CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
    paths.append(os.path.join(config_dir, "talisman.yml"))
    return paths


def _try_load_talisman_file(
    talisman_path: str, mtime: float,
) -> Optional[Dict[str, Any]]:
    """Try reading and caching a single talisman.yml file."""
    if (mtime == _talisman_cache["mtime"]
            and talisman_path == _talisman_cache["path"]
            and _talisman_cache["config"]):
        return _talisman_cache["config"]
    try:
        import yaml
    except ImportError:
        return None
    try:
        # SEC-002: Verify realpath stays within the expected parent directory
        # to prevent symlink-based path traversal attacks.
        expected_root = os.path.realpath(os.path.dirname(talisman_path))
        real_talisman = os.path.realpath(talisman_path)
        try:
            if os.path.commonpath([expected_root, real_talisman]) != expected_root:
                logger.debug(
                    "talisman path escapes expected root (symlink?): %s",
                    talisman_path)
                return None
        except ValueError:
            return None
        with open(talisman_path, "r") as f:
            config = yaml.safe_load(f)
        if isinstance(config, dict):
            _talisman_cache["mtime"] = mtime
            _talisman_cache["path"] = talisman_path
            _talisman_cache["config"] = config
            return config
    except (OSError, ValueError) as exc:
        logger.debug("talisman load error for %s: %s", talisman_path, exc)
    return None


def _load_talisman() -> Dict[str, Any]:
    """Load talisman.yml with mtime caching. Returns {} on failure."""
    for path in _talisman_search_paths():
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        result = _try_load_talisman_file(path, mtime)
        if result is not None:
            return result
    return {}


def _get_echoes_config(talisman: Dict[str, Any], key: str) -> Dict[str, Any]:
    """Extract a nested echoes config section from talisman.

    Args:
        talisman: Full talisman config dict.
        key: Config key under 'echoes' (e.g., 'decomposition', 'reranking').

    Returns:
        Config dict for the section, or empty dict if not found.
    """
    echoes = talisman.get("echoes", {})
    if not isinstance(echoes, dict):
        return {}
    section = echoes.get(key, {})
    return section if isinstance(section, dict) else {}
