---
name: codex-cli
description: |
  Use when invoking `codex exec`, checking Codex availability, configuring cross-model
  verification, or troubleshooting Codex integration errors. Covers detection, execution,
  error handling, sandbox modes, talisman config, and .codexignore prerequisites.
  Keywords: codex, cross-model, GPT, oracle, codex exec, codexignore.

  <example>
  Context: A Rune command needs to run Codex for cross-model review.
  user: "Run code review with Codex"
  assistant: "I'll detect Codex availability, verify .codexignore, then run codex exec with read-only sandbox."
  <commentary>Load codex-cli skill for detection + execution patterns.</commentary>
  </example>

  <example>
  Context: Arc Phase 6 needs to check if Codex Oracle should be summoned.
  user: "/rune:arc plans/my-plan.md"
  assistant: "Detecting Codex Oracle per codex-detection.md before summoning Ashes..."
  <commentary>Codex detection is a prerequisite step before Ash selection in review/audit/forge phases.</commentary>
  </example>
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# Codex CLI Integration

Canonical patterns for Rune commands to communicate with the OpenAI Codex CLI.
All Rune workflows that invoke Codex MUST follow these patterns.

## Detection

Run the canonical detection algorithm before any Codex invocation.
See [codex-detection.md](../roundtable-circle/references/codex-detection.md) for the full 9-step algorithm.

```
1. Read talisman.yml (project or global)
2. Check talisman.codex.disabled → skip if true
3. Check CLI installed: command -v codex
4. Check CLI executable: codex --version
5. Check authentication: codex login status
6. Check jq availability (for JSONL parsing)
7. Check talisman.codex.workflows includes current workflow
8. Check .codexignore exists (required for --full-auto)
9. If all pass → add Codex Oracle to agent selection
```

Note: Model validation (CODEX_MODEL_ALLOWLIST) happens at Codex invocation time in each
workflow command, not during detection. See [security-patterns.md](../roundtable-circle/references/security-patterns.md) for the allowlist regex.

Detection is fast — CLI presence checks (steps 3-4) are <100ms with no network calls.
Full detection including auth check (step 5) may take longer.

## Talisman Configuration

Codex settings are read from `talisman.yml` under the `codex:` key.
All values have sensible defaults — Codex works zero-config if the CLI is installed.

```yaml
codex:
  disabled: false                      # Kill switch — skip Codex entirely
  model: "gpt-5.3-codex"        # Model for codex exec
  reasoning: "xhigh"                  # Reasoning effort (xhigh | high | medium | low)
  sandbox: "read-only"                 # Always read-only (reserved for future use)
  context_budget: 20                   # Max files per session
  confidence_threshold: 80             # Min confidence % to report findings
  workflows: [review, audit, plan, forge, work, mend, goldmask, inspect]  # Which pipelines use Codex (v1.39.0: added "mend", v1.51.0: added "goldmask", "inspect")
  skip_git_check: false                # Pass --skip-git-repo-check if true
  work_advisory:
    enabled: true                      # Codex advisory in /rune:strive
    max_diff_size: 15000               # Truncate diff for advisory
  review_diff:
    enabled: true                      # Diff-focused review for /rune:appraise
    max_diff_size: 15000               # Max diff chars per batch
    context_lines: 5                   # Context lines around changes
    include_new_files_full: true       # Full content for new files
  verification:
    enabled: true                      # Hallucination guard cross-verification
    fuzzy_match_threshold: 0.7         # Code snippet similarity threshold
    cross_model_bonus: 0.15            # Confidence boost for Claude+Codex agreement
```

**Config resolution (precedence):**

```
1. Project talisman: .claude/talisman.yml
2. Global talisman: ~/.claude/talisman.yml
3. Built-in defaults (shown above)
```

## Supported Models

| Model | Best For | Notes |
|-------|----------|-------|
| `gpt-5.3-codex` | Code review, complex reasoning | **Default, recommended** |
| `gpt-5.3-codex-spark` | Spark variant | Alternative |
| `gpt-5.2-codex` | Stable fallback | Legacy |
| `gpt-5-codex` | Simpler analysis, faster | Lower cost |

**Only `gpt-5.x-codex` and `gpt-5.x-codex-spark` models are supported.** Other model families (o1-o4, gpt-4o, non-codex) fail with ChatGPT accounts. The `CODEX_MODEL_ALLOWLIST` regex in [security-patterns.md](../roundtable-circle/references/security-patterns.md) enforces this at validation time.

## Security Prerequisites

### .codexignore (required for --full-auto)

Before invoking `codex exec --full-auto`, verify `.codexignore` exists at repo root.
`--full-auto` grants the external model unrestricted read access to ALL repository files.

**Pre-flight check:**
1. Verify `.codexignore` exists
2. If missing, warn user and suggest creating from template
3. Do NOT proceed with `--full-auto` without `.codexignore`

**Default template:**

```
# .codexignore — Prevent Codex from reading sensitive files
.env*
*.pem
*.key
*.p12
*.db
*.sqlite
.npmrc
docker-compose*.yml
*credentials*
*secrets*
*token*
.git/
.claude/
```

**Note:** Review `.codexignore` for project-specific sensitive files before first use.
Teams should add any proprietary configs, internal tooling paths, or domain-specific secrets.

### Sandbox Modes

| Mode | Use Case | Flags |
|------|----------|-------|
| `read-only` | Code review, analysis | `--sandbox read-only --full-auto` **(default)** |
| `workspace-write` | Refactoring, editing | `--sandbox workspace-write --full-auto` |
| `danger-full-access` | Full system access | Requires explicit `--dangerously-auto-approve` |

Rune uses `read-only` for review/audit/forge workflows. Only `/rune:strive` advisory
may use `workspace-write` in the future (currently read-only).

## Execution Pattern

See [codex-execution.md](references/codex-execution.md) for all invocation patterns, error handling, and hallucination guard.

**Invocation modes**: Standard (with jq), Fallback (no jq), Diff-focused (review workflows)
**Error handling**: All errors non-fatal — pipeline continues without Codex. 12 classified error codes.
**Hallucination guard**: 3-step verification (file existence → line reference → semantic check) on all output.

**When to use which pattern:**

| Workflow | Pattern |
|----------|---------|
| review, work (advisory) | Diff-focused |
| audit, plan, forge | File-focused |

## Output Conventions

Each workflow writes Codex output to a designated path:

| Workflow | Output Path | Prefix |
|----------|------------|--------|
| review | `tmp/reviews/{id}/codex-oracle.md` | CDX |
| audit | `tmp/audit/{id}/codex-oracle.md` | CDX |
| forge | `tmp/arc/{id}/research/codex-oracle.md` or `tmp/forge/{id}/{section}-codex-oracle.md` | CDX |
| plan (research) | `tmp/plans/{id}/research/codex-analysis.md` | CDX |
| plan (review) | `tmp/plans/{id}/codex-plan-review.md` | CDX |
| work (advisory) | `tmp/work/{id}/codex-advisory.md` | CDX |
| elicitation | `tmp/{workflow}/{id}/elicitation/codex-prompt-{method}.txt` | CDX |
| mend (verification) | `tmp/mend/{id}/codex-mend-verification.md` | CDX-MEND |
| arena (judge) | `tmp/plans/{id}/arena/codex-arena-judge.md` | CDX-ARENA |
| arc (semantic) | `tmp/arc/{id}/codex-semantic-verification.md` | CDX |
| arc (gap) | `tmp/arc/{id}/codex-gap-analysis.md` | CDX-GAP |
| work (trial-forger) | `tmp/work/{id}/codex-edge-cases.md` | CDX |
| work (rune-smith) | `tmp/work/{id}/codex-smith-prompt.txt` (temp) | CDX |
| appraise (diff verify) | `tmp/reviews/{id}/codex-diff-verification.md` | CDX-VERIFY |
| arc (test critique) | `tmp/arc/{id}/test-critique.md` | CDX-TEST |
| arc (release quality) | `tmp/arc/{id}/release-quality.md` | CDX-RELEASE |
| forge (section validate) | `tmp/forge/{id}/codex-section-validation.md` | CDX-SECTION |
| devise (tiebreaker) | `tmp/plans/{id}/codex-tiebreaker.md` | CDX-TIEBREAKER |
| arc (task decompose) | `tmp/arc/{id}/task-validation.md` | CDX-TASK |
| goldmask (risk amplify) | `tmp/goldmask/{id}/risk-amplification.md` | CDX-RISK |
| inspect (drift detect) | `tmp/inspect/{id}/drift-report.md` | CDX-INSPECT-DRIFT |
| audit (arch review) | `tmp/audit/{id}/architecture-review.md` | CDX-ARCH |
| strive (post-monitor) | `tmp/work/{id}/architectural-critique.md` | CDX-ARCH-STRIVE |

**Every codex outcome** (success, failure, skip, error) MUST produce an MD file at the
designated path. Even skip/error messages are written so downstream phases know Codex was attempted.

## Architecture Rules

1. **Separate teammate**: Codex MUST run on a separate teammate (`Task` with `run_in_background: true`).
   Do not inline in the orchestrator. This isolates untrusted codex output from the main context window.

   **Lightweight Inline Exception** (v1.39.0+): Integration points that meet ALL of the following
   criteria may run `codex exec` inline (without a separate teammate):
   - `reasoning: "low"` or `"medium"` (never `"high"`)
   - `timeout <= 120s`
   - Input < 5KB (truncated before exec)
   - Output parsed for a single value (JSON score, verdict, or pass/fail flag — not full reviews)
   - SEC-003 applied (prompt written to temp file, not inline interpolation)
   - Nonce boundary around untrusted content

   Current inline exceptions: Semantic Verification (Point 4), Trial Forger (Point 6),
   Rune Smith Advisory (Point 7, default OFF), Shatter Scoring (Point 8), Echo Validation (Point 9),
   Diff Verification (Point 10), Test Coverage Critique (Point 11), Release Quality Check (Point 12),
   Section Validation (Point 13), Research Tiebreaker (Point 14), Task Decomposition (Point 15),
   Risk Amplification (Point 16, default OFF), Drift Detection (Point 17, default OFF),
   Architecture Review (Point 18, default OFF), Post-monitor Critique (Point 19, default OFF).

2. **Always write to MD file**: Every outcome produces an MD file at the designated output path.

3. **Non-fatal**: All codex errors are non-fatal. The pipeline always continues.

4. **CDX prefix**: All Codex findings use the `CDX` prefix for structured RUNE:FINDING markers.

5. **Truthbinding**: Codex prompts MUST include the ANCHOR anti-injection preamble
   (see `codex-oracle.md` for the canonical prompt).

6. **Codex counts toward max_ashes**: When summoned as a full review teammate (Codex Oracle in
   review/audit), Codex counts against the `talisman.settings.max_ashes` cap (default 9).

   **Additive exception** (v1.39.0+): Cross-model methods that use the lightweight inline pattern
   (e.g., elicitation sage cross-model, semantic verification, trial forger edge cases) do NOT
   count toward max_ashes because they run within existing agents, not as separate teammates.
   Only dedicated Codex teammates (codex-oracle, codex-mend-verifier, codex-arena-judge,
   codex-gap-analyzer) count toward the cap.

## Codex Timeout Budget (v1.39.0+, expanded v1.51.0+)

With all 19 deep integration points enabled across 7 workflows, Codex adds significant
overhead. Plan your workflow timeouts accordingly. Each integration has strong skip conditions
that reduce actual invocations to 3-5 per run.

| # | Point | Timeout | Reasoning | Phase | Default | Skip Condition | Est. Skip Rate |
|---|-------|---------|-----------|-------|---------|----------------|----------------|
| 1 | Elicitation Sage | 300s | varies | Plan brainstorm | ON | — | ~10% |
| 2 | Mend Verification | 660s | xhigh | Post-mend | ON | — | ~10% |
| 3 | Arena Judge | 300s | xhigh | Plan arena | ON | — | ~20% |
| 4 | Semantic Verification | 300s | xhigh | Arc Phase 2.8 | ON | — | ~10% |
| 5 | Gap Analysis | 600s | xhigh | Arc Phase 5.6 | ON | — | ~20% |
| 6 | Trial Forger | 300s | xhigh | Work (per test task) | ON | — | ~20% |
| 7 | Rune Smith | 300s | xhigh | Work (per worker, opt-in) | **OFF** | — | N/A |
| 8 | Shatter | 300s | xhigh | Plan Phase 2.5 | ON | — | ~20% |
| 9 | Echo Validation | 300s | xhigh | Post-workflow | ON | — | ~10% |
| 10 | Diff Verification | 300s | high | Appraise Phase 6.2 | ON | `p1_p2_findings_count == 0` | ~30% |
| 11 | Test Coverage Critique | 600s | xhigh | Arc Phase 7.8 | ON | `coverage_pct >= 80 && pass_rate == 100` | ~50% |
| 12 | Release Quality Check | 300s | high | Arc Phase 8.55 | ON | `!breaking_changes && !changelog_stale` | ~60% |
| 13 | Section Validation | 300s | medium | Forge Phase 1.7 | ON | `plan_sections <= 5` | ~40% |
| 14 | Research Tiebreaker | 300s | high | Devise Phase 2.3.5 | ON | `conflictsDetected == 0` | ~80% |
| 15 | Task Decomposition | 300s | high | Arc Phase 4.5 | ON | `task_count <= 5` | ~40% |
| 16 | Risk Amplification | 600s | xhigh | Goldmask Phase 3.5 | **OFF** | `critical_files == 0 in risk-map` | ~40% |
| 17 | Drift Detection | 600s | xhigh | Inspect Phase 1.5 | **OFF** | `scope_files <= 10` | ~50% |
| 18 | Architecture Review | 600s | xhigh | Audit Phase 6.3 | **OFF** | Only runs in `audit` mode | ~70% |
| 19 | Post-monitor Critique | 300s | high | Strive Phase 3.7 | **OFF** | `total_worker_commits <= 3` | ~30% |

### Budget Summary

| Scenario | Codex Calls | Est. Time | Est. Cost/Run |
|----------|------------|-----------|---------------|
| Original 9 deep (v1.39.0) | 5-7 | ~15 min | ~$1.00-$2.10 |
| After expansion (worst-case) | 8-10 | ~40-50 min | ~$1.50-$3.00 |
| After expansion (with skip conditions) | 3-5 | ~15-25 min | ~$0.60-$1.50 |
| All 19 integrations (theoretical, all workflows) | 19 | ~95 min | ~$2.85-$5.70 |

> **Note**: The ~95 min figure spans 7 different workflows. No single command invokes all 7.
> A realistic `/rune:arc` run expects 6-8 Codex calls totaling ~30-40 min.

### Per-Workflow Codex Budget Caps

| Workflow | Max Codex Time | Max Codex Calls | Rationale |
|----------|---------------|-----------------|-----------|
| `/rune:arc` | 1800s (30 min) | 10 | Arc's hard cap is 285 min; 30 min = ~10.5% |
| `/rune:appraise` | 600s (10 min) | 3 | Review should stay fast |
| `/rune:audit` | 900s (15 min) | 4 | Audit is thorough, higher budget |
| `/rune:devise` | 900s (15 min) | 4 | Planning can be deliberate |
| `/rune:forge` | 600s (10 min) | 2 | Enrichment should not dominate |
| `/rune:inspect` | 600s (10 min) | 2 | Inspection is focused |
| `/rune:strive` | 900s (15 min) | 5 | Work with per-task calls |
| Goldmask | 600s (10 min) | 2 | Analysis layer, not core workflow |

Per-feature `reasoning` keys (e.g., `codex.semantic_verification.reasoning: "xhigh"`) override
the global `codex.reasoning` for that specific feature only.

## Cross-References

| File | What It Provides |
|------|-----------------|
| [codex-detection.md](../roundtable-circle/references/codex-detection.md) | Canonical 9-step detection algorithm |
| [codex-oracle-prompt.md](references/codex-oracle-prompt.md) | Full Ash prompt template with hallucination guard |
| [circle-registry.md](../roundtable-circle/references/circle-registry.md) | Codex Oracle's place in Ash registry |
| [talisman.example.yml](../../talisman.example.yml) (codex section) | All configurable options with comments |

## Script Wrapper (v1.81.0+)

**`scripts/codex-exec.sh`** is the canonical invocation method for all Rune Codex calls.
It encapsulates SEC-009 stdin pipe, model allowlist, timeout clamping, and error classification
in a single script — replacing raw `Bash()` commands that the LLM might improvise incorrectly.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" [OPTIONS] PROMPT_FILE

Options:
  -m MODEL          Model (default: gpt-5.3-codex, validated against allowlist)
  -r REASONING      xhigh|high|medium|low (default: xhigh)
  -t TIMEOUT        Seconds, clamped to [300, 900] (default: 600)
  -s STREAM_IDLE    Stream idle timeout ms (default: 540000)
  -j                Enable --json + jq JSONL parsing
  -g                Pass --skip-git-repo-check
  -k KILL_AFTER     Kill-after grace period seconds (default: 30, 0=disable)
```

**Exit codes**: 0=success, 1=missing codex CLI, 2=pre-flight failure (.codexignore, invalid file), 124=timeout, 137=killed

**Key behaviors**:
- Reads prompt via stdin pipe (SEC-009) — never `$(cat)`
- Validates model against `CODEX_MODEL_ALLOWLIST` regex
- Validates reasoning against `[high, medium, low]`
- Clamps timeout to `[300, 900]`
- Rejects symlink prompt files and paths with `..`
- Caps prompt file at 1MB (SEC-2 DoS prevention)
- Classifies errors to structured `CODEX_ERROR[CODE]` format on stderr
- Falls back gracefully (no jq → raw mode, no timeout → unwrapped)

**Example** (arc Phase 2.8 semantic verification):
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" \
  -m "${codexModel}" -r "${codexReasoning}" -t ${semanticTimeout} -g \
  "tmp/arc/${id}/codex-semantic-${aspect.name}-prompt.txt"
```

## Quick Reference

| Task | Pattern |
|------|---------|
| Check if Codex available | `command -v codex >/dev/null 2>&1` |
| Check version | `codex --version` |
| Check auth | `codex login status` |
| Run via wrapper (preferred) | `"${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m gpt-5.3-codex -r xhigh -t 600 -g PROMPT.txt` |
| Run with JSON parsing | `"${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" -j -g PROMPT.txt` |
| Review files (legacy) | `codex exec -m gpt-5.3-codex --sandbox read-only --full-auto --json "Review: ..."` |
| Resume session | `echo "continue" \| codex exec resume --last` |
| Check jq available | `command -v jq >/dev/null 2>&1` |
| Disable entirely | `codex.disabled: true` in talisman.yml |
