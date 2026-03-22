# Rune Advanced Guide: Troubleshooting & Optimization

Diagnose common failures, reduce token costs, and optimize Rune's multi-agent workflows for your project.

Related guides:
- [Getting started](rune-getting-started.en.md)
- [Talisman deep dive guide](rune-talisman-deep-dive-guide.en.md)
- [Custom agents and extensions guide](rune-custom-agents-and-extensions-guide.en.md)
- [Arc and batch guide](rune-arc-and-batch-guide.en.md)

---

## 1. Common Failure Modes

### 1.1 Agent Teams not enabled

**Symptom**: `/rune:*` commands fail immediately with "Agent Teams not available" or teammates fail to spawn.

**Fix**: Add to `.claude/settings.json` or `.claude/settings.local.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Restart Claude Code after saving.

### 1.2 Bash timeout kills ward checks

**Symptom**: Ward commands (lint, test, typecheck) get killed mid-execution. Errors like "Command timed out after 120000ms".

**Fix**: Increase bash timeout in `.claude/settings.json`:

```json
{
  "env": {
    "BASH_DEFAULT_TIMEOUT_MS": "600000",
    "BASH_MAX_TIMEOUT_MS": "3600000"
  }
}
```

**Root cause**: The default Bash timeout is 2 minutes. Most test suites and type checkers need more.

### 1.3 Stale teams block new workflows

**Symptom**: TeamCreate fails with "team already exists" or hooks warn about stale teams.

**Fix**: Rune's `session-team-hygiene.sh` hook auto-cleans stale teams on session start. If you need manual cleanup:

```bash
# Check for orphaned team directories
ls ~/.claude/teams/

# The TLC-001 hook auto-cleans teams older than 30 minutes
# For immediate cleanup, restart Claude Code session
```

### 1.4 Plan freshness gate blocks arc

**Symptom**: `/rune:arc` refuses to run with "Plan is STALE" error.

**Causes**:
- Many commits have been made since the plan was created
- The plan's `git_sha` in frontmatter doesn't match current HEAD

**Fixes**:
1. **Quick fix**: Add `--skip-freshness` flag
2. **Proper fix**: Regenerate the plan with `/rune:devise`
3. **Tune threshold**: Lower `plan.freshness.block_threshold` in talisman

```yaml
plan:
  freshness:
    warn_threshold: 0.7
    block_threshold: 0.3    # Lower = more lenient
```

### 1.5 Hook denies command (ZSH-001, POLL-001, etc.)

**Symptom**: Bash commands blocked with error codes like `ZSH-001`, `POLL-001`, `SEC-001`.

| Hook code | What it blocks | Why |
|-----------|---------------|-----|
| ZSH-001 | `status=` in bash | `status` is read-only in zsh |
| POLL-001 | `sleep N && echo check` | Must use TaskList for monitoring |
| SEC-001 | Write tools during review | Review agents must be read-only |
| ATE-1 | Bare `Task`/`Agent` calls | Must use `team_name` during Rune workflows |
| TLC-001 | Invalid team names | Naming validation failed |
| CTX-GUARD-001 | TeamCreate/Agent at low context | Context usage > 75% — reduce scope |
| POST-COMP-001 | Heavy tools after arc completion | Advisory — workflow already done |
| SEC-MEND-001 | Mend fixer writing outside scope | Fixer can only write to assigned files |
| SEC-GAP-001 | Gap fixer writing to restricted paths | Cannot write to `.claude/`, CI, `.env` |
| SEC-STRIVE-001 | Strive worker writing outside scope | Worker can only write to assigned files |

**Fix**: These hooks exist for correctness. Adjust your commands to follow the enforced patterns. See the `zsh-compat`, `polling-guard` skills for guidance.

### 1.6 Teammate goes idle prematurely

**Symptom**: An Ash stops responding before completing its review. TeammateIdle hook fires without expected output.

**Causes**:
- Context window exhaustion (too many files)
- SDK heartbeat timeout (5 min hardcoded)
- Agent crashed or hit token limit

**Fixes**:
1. Reduce `context_budget` for that Ash in talisman
2. Check `tmp/reviews/{id}/ash-outputs/` for partial output
3. Re-run the review — stale tasks are auto-released after 10 min

### 1.7 Mend fixer produces incorrect fixes

**Symptom**: Mend changes break code or introduce new issues.

**Fixes**:
1. Ward commands should catch this — verify ward_commands are comprehensive
2. Enable `goldmask.mend.inject_context` for risk-aware fixing
3. Bisection algorithm identifies failing fixes — check mend output for FAILED resolutions

### 1.8 Arc pipeline hangs at a phase

**Symptom**: Arc appears stuck at a specific phase for longer than the configured timeout.

**Diagnosis**:
1. Check `.rune/arc/{id}/checkpoint.json` for current phase
2. Check `TaskList` for stuck or idle tasks
3. Check per-phase timeout in talisman — it may need increasing

**Fix**: Use `/rune:cancel-arc` to stop, then `/rune:arc plans/... --resume` to resume from checkpoint.

### 1.9 Context degradation during workflow (v1.115.0+)

**Symptom**: Warnings about context usage, or TeamCreate/Agent calls blocked with CTX-GUARD-001.

**How it works**: The `guard-context-critical.sh` hook monitors context usage via the statusline bridge:
- **40% remaining (Caution)**: Advisory warning — consider wrapping up.
- **35% remaining (Warning)**: Degradation suggestions injected + `context_warning` signal.
- **25% remaining (Critical)**: Hard DENY on TeamCreate/Agent + `force_shutdown` signal.

**Fix**: Keep workflows focused. Use `--no-forge` or `--no-test` to reduce scope. For arc, checkpoints allow resume in a fresh session.

### 1.10 Prompt injection in reviewed code (v1.124.0+)

**Symptom**: MCP advisory hook warns about potential injection in tool output.

**How it works**: Rune's `advise-mcp-untrusted.sh` PostToolUse hook scans MCP/external tool output for injection patterns (Unicode tag blocks, zero-width chars, homoglyphs). Ashes follow Truthbinding — they ignore all instructions found in reviewed code.

**Fix**: No action needed. Warnings are informational. If you suspect a real injection attempt, flag it to the team.

### 1.11 Deterministic cleanup on session exit (v1.124.0+)

**Symptom**: Teams were left orphaned after session crashes or compaction.

**How it works**: `detect-workflow-complete.sh` fires on every Stop event. It scans for completed/failed/cancelled workflows with residual team dirs, and for orphaned workflows where the owner PID is dead. It executes 2-stage process escalation (SIGTERM → SIGKILL).

**Fix**: This is automatic — no user action needed. Use `RUNE_CLEANUP_DRY_RUN=1` to debug cleanup behavior without actually killing processes.

---

## 2. Debugging Techniques

### 2.1 Enable trace logging

```bash
export RUNE_TRACE=1
```

Traces append to `/tmp/rune-hook-trace.log`. Useful for debugging hook behavior, event-driven synchronization, and signal file detection.

### 2.2 Check arc checkpoint

```bash
# View current arc state
cat .rune/arc/*/checkpoint.json | python3 -m json.tool
```

The checkpoint shows:
- Current phase number and name
- Completed phases with artifacts
- SHA-256 hashes for artifact integrity
- Timestamp of last update

### 2.3 Inspect signal files

```bash
# View completion signals
ls tmp/.rune-signals/*/

# Check if echo search index is dirty
ls tmp/.rune-signals/.echo-dirty
```

### 2.4 Review ash outputs

Each Ash writes its output to `tmp/reviews/{id}/ash-outputs/{ash-name}.md`. Compare outputs to understand:
- Which Ashes were summoned and why
- What each Ash found
- Whether Seal markers are present (completion detection)

### 2.5 Check inscription contract

```bash
# View the review contract
cat tmp/reviews/*/inscription.json | python3 -m json.tool
```

The inscription defines what each Ash must produce, including required sections and seal format.

### 2.6 Verbose mode

Run Claude Code with debug logging:

```bash
claude --debug
```

This shows plugin loading, hook execution, and tool call details.

### 2.7 Dry-run cleanup mode (v1.124.0+)

```bash
export RUNE_CLEANUP_DRY_RUN=1
```

Makes cleanup hooks (`detect-workflow-complete.sh`, `on-session-stop.sh`, `session-team-hygiene.sh`) log what they would do without actually killing processes, deleting teams, or modifying state files. Useful for debugging cleanup behavior in production.

### 2.8 Talisman shard inspection (v1.114.0+)

```bash
# View resolved talisman shards
ls tmp/.talisman-resolved/
cat tmp/.talisman-resolved/review.json | python3 -m json.tool
```

The talisman shard resolver pre-processes `talisman.yml` into 12 per-namespace JSON shards at session start. Each shard is ~50-100 tokens instead of the full ~1,200 token config — a 94% token reduction. Inspect individual shards to verify configuration resolution.

### 2.9 Parallel debugging with `/rune:debug`

For complex bugs, use ACH-based parallel debugging:

```bash
/rune:debug "The API returns 500 when creating a user with special characters"
```

This spawns multiple hypothesis-investigator agents that investigate competing hypotheses simultaneously. Each investigator reports confirming and falsifying evidence with confidence scores.

---

## 3. Token Optimization Strategies

Multi-agent workflows consume tokens proportionally to team size. Each teammate has its own context window.

### 3.1 Cost multipliers by workflow

| Workflow | Typical team size | Cost multiplier | Duration |
|----------|-----------------|-----------------|----------|
| `/rune:appraise` | 5-7 Ashes | 3-5x | 3-10 min |
| `/rune:appraise --deep` | 12-18 Ashes | 8-15x | 10-20 min |
| `/rune:audit` | 5-7 Ashes | 4-6x | 5-15 min |
| `/rune:devise` | 3-7 agents | 3-5x | 5-15 min |
| `/rune:devise --quick` | 2-3 agents | 1.5-2x | 2-5 min |
| `/rune:strive` | 2-4 workers | 2-4x | 10-30 min |
| `/rune:codex-review` | 4-8 agents | 5-8x | 5-15 min |
| `/rune:debug` | 2-5 investigators | 3-5x | 5-10 min |
| `/rune:arc` (full) | varies per phase | 10-30x | 30-90 min |

### 3.2 Reduce review scope

| Strategy | How | Token savings |
|----------|-----|--------------|
| Smaller PRs | Keep changes under 20 files | Avoids chunked review |
| Skip patterns | Add generated/vendor files to `rune-gaze.skip_patterns` | Eliminates irrelevant files |
| Lower max_ashes | Set `settings.max_ashes: 5` | Fewer teammates |
| Disable unneeded Ashes | `defaults.disable_ashes: ["veil-piercer"]` | One less Ash |
| Lower context_budget | Reduce per-Ash file count | Less data per Ash |

### 3.3 Reduce planning scope

| Strategy | How | Token savings |
|----------|-----|--------------|
| `--quick` mode | `/rune:devise --quick` | Skips brainstorm + forge |
| Basic Goldmask | `goldmask.devise.depth: "basic"` | 2 agents instead of 6 |
| Skip arena | `solution_arena.enabled: false` | No competitive evaluation |
| Disable elicitation | `elicitation.enabled: false` | No structured reasoning |

### 3.4 Reduce arc scope

| Strategy | How | Token savings |
|----------|-----|
| `--no-forge` | Skip forge enrichment phase | Saves 15 min + agents |
| `--no-test` | Skip testing phase | Saves test execution |
| Light convergence | `review.arc_convergence_tier_override: "light"` | Max 2 review-mend cycles |
| Disable Codex | `codex.disabled: true` | No cross-model verification |
| Lower workers | `work.max_workers: 2` | Fewer parallel workers |

### 3.5 Automatic optimizations (no action needed)

These optimizations are built-in since recent versions:
- **Talisman shard resolver (v1.114.0)**: 94% token reduction — each phase reads only its relevant config shard.
- **Pre-aggregation (v1.116.0)**: Condenses agent outputs before Runebinder aggregation, reducing context saturation.
- **TOME citation verification (v1.117.0)**: Marks phantom citations as UNVERIFIED, preventing mend from wasting effort on bad findings.
- **Fail-forward hooks (v1.115.0)**: Hook crashes no longer stall workflows — only security hooks fail-closed.

### 3.6 Cost-aware workflow selection

| Need | Cheapest option | Cost |
|------|----------------|------|
| Quick feedback on changes | `/rune:appraise` (standard) | ~3-5x |
| Plan a simple feature | `/rune:devise --quick` | ~1.5-2x |
| Implement with quality | `/rune:strive` alone (no arc) | ~2-4x |
| Full pipeline | `/rune:arc` with `--no-forge` | ~8-20x |
| Maximum quality | `/rune:arc` (full, with deep review) | ~15-30x |

---

## 4. Performance Tuning

### 4.1 Optimize worker parallelism

```yaml
work:
  max_workers: 3    # Default — good for most projects
```

| Project size | Recommended workers | Why |
|-------------|-------------------|-----|
| Small (< 10 tasks) | 2 | Avoids file conflicts |
| Medium (10-20 tasks) | 3 | Good parallelism |
| Large (20+ tasks) | 4-5 | Max throughput, watch for conflicts |

**Warning**: More workers = more file conflict risk. If workers touch overlapping files, reduce the count.

### 4.2 Tune phase timeouts

If specific phases consistently timeout, increase their limits:

```yaml
arc:
  timeouts:
    work: 2400000      # 40 min for large implementations
    code_review: 1200000  # 20 min for deep reviews
    test: 2400000       # 40 min when E2E tests are slow
```

If phases finish quickly, reduce timeouts to fail faster on stuck states.

### 4.3 Optimize echo search

For large echo databases:

```yaml
echoes:
  reranking:
    enabled: true         # Better relevance at small cost
    threshold: 25         # Only rerank when 25+ results
  decomposition:
    enabled: true         # Better multi-keyword queries
```

### 4.4 Incremental audits for large codebases

For codebases with 500+ files, use incremental audit instead of full:

```bash
/rune:audit --incremental
```

This audits files in priority-scored batches, tracking coverage over time. Each session adds to the coverage map.

---

## 5. Session Management

### 5.1 Session isolation

Each Rune session tracks its workflows via state files with `config_dir`, `owner_pid`, and `session_id`. Different sessions (even in the same repo) don't interfere with each other.

**If you see cross-session warnings**: One session may be reading another's state files. This is handled automatically — hooks skip state belonging to other live sessions and clean up dead-session state.

### 5.2 Resume after interruption

**Arc pipeline**: Checkpoints are saved after each phase.

```bash
/rune:arc plans/my-plan.md --resume
```

**Arc batch**: Progress file tracks completed plans.

```bash
/rune:arc-batch plans/*.md --resume
```

### 5.3 Clean up after workflows

```bash
/rune:rest
```

This removes `tmp/` artifacts from completed workflows while preserving Rune Echoes (`.rune/echoes/`) and active workflow state.

### 5.4 Teammate non-persistence

Teammates do NOT survive session resume. After `/resume` or compaction:
- All teammates are assumed dead
- Stale teams are cleaned up automatically
- Restart workflows from checkpoint if needed

---

## 6. Monitoring Workflow Progress

### 6.1 During arc

The orchestrator reports phase transitions:

```
Phase 1/26: FORGE — enriching plan...
Phase 8/26: WORK — 3 workers implementing...
Phase 12/29: CODE REVIEW — 5 Ashes reviewing...
```

> **Note (v1.120.2+):** Arc now has 40 phases (added Design Extraction, Design Prototype, Design Verification, Design Iteration, UX Verification, and Pre-Ship Validation).

### 6.2 During review/audit

Check the inscription for expected Ashes:

```bash
cat tmp/reviews/*/inscription.json | python3 -m json.tool
```

Monitor completion via signal files:

```bash
ls tmp/.rune-signals/*/
```

### 6.3 Task list

Use `TaskList` to see real-time task status for the current team.

---

## 7. Troubleshooting Recipes

### "I ran arc and it consumed too many tokens"

1. Use `--no-forge` to skip enrichment
2. Set `review.arc_convergence_tier_override: "light"` for fewer review-mend cycles
3. Disable Codex: `codex.disabled: true`
4. Reduce `work.max_workers` to 2

### "Review keeps finding pre-existing issues"

1. Enable diff-scope: `review.diff_scope.enabled: true` (default)
2. Set `review.diff_scope.tag_pre_existing: true` (default)
3. Mend automatically skips pre-existing P2/P3 — only P1 is always fixed
4. For arc convergence, smart scoring discounts pre-existing noise

### "My custom Ash isn't being summoned"

1. Check `trigger.extensions` matches your changed files
2. Check `trigger.paths` matches your file paths
3. Verify `settings.max_ashes` isn't capped too low
4. Check `workflows` includes the workflow you're running (review/audit)
5. Look for warnings in the review output about skipped Ashes

### "Forge enrichment is too slow"

1. Use `--quick` with `/rune:devise` to skip forge
2. Lower `forge.max_total_agents: 4` in talisman
3. Raise `forge.threshold: 0.50` to be more selective
4. Set `goldmask.forge.enabled: false` to skip Lore Layer

### "Tests fail in arc Phase 7.7"

1. Test failures are non-blocking WARNs — they don't halt the pipeline
2. Check `testing.service.startup_command` matches your dev server
3. Increase `testing.tiers.*.timeout_ms` for slow test suites
4. Disable individual tiers: `testing.tiers.e2e.enabled: false`

### "Mend creates bad fixes"

1. Ensure ward_commands are comprehensive (lint + typecheck + test)
2. Bisection algorithm should catch bad fixes — check for FAILED resolutions
3. Enable `goldmask.mend.inject_context: true` for risk awareness
4. Review the TOME findings — some may be false positives. Check for LOW confidence tags

### "Ghost `@teammate-name` badges in status bar after arc completes"

In long-running sessions (e.g., `arc-batch` running multiple plans), the UI status bar may show `@elicitation-sage-mend`, `@lore-analyst`, or other teammate names from previous arcs — even though those teams were deleted.

**Why it happens**: This is a Claude Code SDK platform limitation. `TeamDelete()` clears team leadership state and removes filesystem artifacts (`teams/`, `tasks/`), but does **not** terminate or deregister in-process teammates from the session-level member list. The SDK currently provides no API to forcefully terminate in-process teammates or deregister members from a session.

**Impact**: Cosmetic only. Ghost entries do not block subsequent arc phases or prevent new teammates from spawning. They disappear when the session process exits.

**Workaround**:
1. End and restart the session between arcs
2. Ignore the badges — they have no functional impact
3. For `arc-batch`, ghost entries accumulate but do not affect correctness

---

## 8. Health Check Checklist

Run this checklist when Rune workflows aren't performing as expected:

- [ ] Agent Teams enabled in `.claude/settings.json`
- [ ] `BASH_DEFAULT_TIMEOUT_MS` >= 600000
- [ ] `BASH_MAX_TIMEOUT_MS` >= 3600000
- [ ] Ward commands complete within bash timeout
- [ ] `talisman.yml` is valid YAML (no syntax errors)
- [ ] Custom Ash prefixes are in `dedup_hierarchy`
- [ ] Custom Ash agents exist at the declared source path
- [ ] `skip_patterns` aren't excluding files you want reviewed
- [ ] `max_ashes` is high enough for built-in + custom
- [ ] `gh` CLI installed and authenticated (for arc ship/merge)
- [ ] No orphaned team directories (`ls ~/.claude/teams/`)
- [ ] No stale state files (`ls tmp/.rune-*.json`)
- [ ] Talisman shards resolving (`ls tmp/.talisman-resolved/`)
- [ ] No orphaned worktrees (`git worktree list` — check for stale `rune-work-*`)
- [ ] Context usage healthy (check statusline for % remaining)
- [ ] `jq` installed (required by all hooks for JSON parsing)
