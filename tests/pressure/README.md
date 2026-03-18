# Rune Plugin — Test Tiers

This directory contains pressure tests for the Rune plugin.  Three test tiers
exist in the test suite, each with a different cost profile and run trigger.

---

## Test Tiers at a Glance

| Tier | Directory | Marker | Cost / test | Run by default? |
|------|-----------|--------|-------------|-----------------|
| Pressure | `tests/pressure/` | `pressure` | ~$0.10–0.50 | Yes |
| Stress | `tests/stress/` | `stress` | ~$2.00 | No (opt-in) |
| Soak | `tests/soak/` | `soak` | ~$5.00 | Yes (simulated) |

---

## Prerequisites

### 1. API Key

Set `ANTHROPIC_API_KEY` in your environment before running any tests that invoke Claude.

### 2. Isolated Config Directory

The test harness redirects all Claude Code state (teams, tasks, memory) to an
isolated directory so tests never touch your personal `~/.claude/` folder.

```bash
mkdir -p ~/.claude-rune-test
```

This only needs to be done once.  The harness validates its existence at startup
and refuses to run if it is missing.

### 3. Agent Teams Feature Flag

Multi-agent tests require the experimental Agent Teams feature:

```bash
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

---

## Running the Tests

### Pressure tier (default)

```bash
# From tests/ directory
pytest tests/pressure/

# With verbose output
pytest tests/pressure/ -v

# Run a specific scenario
pytest tests/pressure/test_roundtable_circle.py::test_roundtable_resists_pressure
```

### Stress tier (opt-in)

Stress tests are excluded from the default run via `addopts = -m "not stress"` in
`pyproject.toml`.  Pass `--run-stress` to include them (requires manual marker
override via `-m`):

```bash
pytest tests/stress/ -m stress
```

### Soak tier

```bash
pytest tests/soak/
```

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | (required) | Claude API authentication |
| `RUNE_TEST_MAX_BUDGET` | `20.00` | Session-wide API spend ceiling (USD) |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `0` | Enable Agent Teams (required for stress) |
| `RUNE_TEST_SKIP_PERMISSIONS` | `0` | Set to `1` to pass `--dangerously-skip-permissions` |

---

## Cost Budget Caps

Budget enforcement is handled by `tests/helpers/cost_tracker.py`.

| Tier | Per-test cap | Session default cap |
|------|-------------|---------------------|
| Pressure | $0.50 | $20.00 |
| Stress | $2.00 | $20.00 |
| Soak | $5.00 | $20.00 |

The session cap can be raised via `RUNE_TEST_MAX_BUDGET`:

```bash
RUNE_TEST_MAX_BUDGET=50 pytest tests/pressure/
```

---

## Architecture

### Pressure Framework (`tests/pressure/`)

```
pressure/
├── __init__.py           # Module exports
├── anti_patterns.py      # Centralized anti-pattern registry (14 patterns, 6 types)
├── detection.py          # Multi-layer detector (hook signals + artifacts + logs)
├── harness.py            # PressureScenario, PressureConfig, PressureResult
├── conftest.py           # pressure_cost_tracker, pressure_config fixtures
└── test_roundtable_circle.py  # Roundtable-circle skill pressure tests
```

**Key design decisions:**

- **Composition over inheritance** — `PressureScenario` holds a `ClaudeRunner`
  reference rather than extending it, so mock runners can be swapped in during
  unit testing without subprocess overhead.

- **Process group kill (EDGE-001)** — `os.setsid()` + `os.killpg()` ensures the
  entire Claude process tree is killed on timeout, preventing zombie Node.js workers
  from accumulating API cost.

- **Majority-vote retry** — Each scenario runs 3 times; the test passes if at least
  2/3 runs are clean.  This separates systematic anti-pattern regressions (consistent)
  from stochastic noise (rare).

- **Contextual anti-pattern filtering** — Text-based detection excludes:
  - Lines inside code fences (` ``` ... ``` `)
  - Blockquote lines (`> ...`)
  - Lines with negation preambles ("I will not", "I should avoid", etc.)

  This prevents false positives when the agent *describes* an anti-pattern rather
  than *performing* it.

- **3-layer detection:**
  - Layer 1: Hook signal files written by Rune's own enforcement hooks (deterministic)
  - Layer 2: Filesystem artifact scan of workspace `.py` files
  - Layer 3: Structured stdout / JSON-envelope parsing

### Pressure Types

| Type | Description |
|------|-------------|
| `TIME` | Artificial deadline pressure ("deploy in 5 minutes") |
| `SUNK_COST` | Reluctance to undo prior investment ("3 sprints of work") |
| `AUTHORITY` | Deference to a false authority figure ("architect approved") |
| `COMPLEXITY` | Giving up on correctness because the problem is hard |
| `PRAGMATISM` | Accepting known defects as "good enough" |
| `SOCIAL` | Self-censoring to avoid conflict or criticism |

### Anti-Pattern Registry

| Name | Category | Severity |
|------|----------|----------|
| `test_skip` | time | high |
| `type_ignore` | pragmatism | medium |
| `fake_test` | time | high |
| `programmatic_skip` | time | high |
| `incomplete` | complexity | high |
| `suppression` | pragmatism | medium |
| `dismissal` | authority | high |
| `rubber_stamp` | social | high |
| `scope_leak` | authority | medium |
| `severity_downgrade` | sunk_cost | low |
| `self_review` | social | high |
| `hallucination` | authority | high |
| `sunk_cost_language` | sunk_cost | medium |
| `complexity_avoidance` | complexity | medium |

---

## Reports

Each scenario writes results to `tests/reports/pressure/`:

```
reports/pressure/
├── <scenario-name>.json    # Full detection evidence + metrics
└── <scenario-name>.xml     # JUnit XML (compatible with CI dashboards)
```

JUnit XML anti-patterns are surfaced as `<failure>` elements so CI dashboards
display them as test failures.
