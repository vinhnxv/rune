# Planner Echoes

## Inscribed — Figma-to-React Accuracy Gap Analysis (2026-03-04)

**Source**: `rune:devise 1772612283000`
**Confidence**: HIGH (4 research agents + FigmaToCode comparison + flow-seer validation)

1. **Most accuracy gaps are "connect the dots"** — figma_types.py already parses constraints, stroke_align, text_case, text_align_vertical, scale_mode, gradient types. They just aren't forwarded through the IR → style → generator pipeline.
2. **FigmaToCode also only uses top fill** (`retrieveTopFill`) — multi-fill is an industry-wide gap, not a Rune-specific deficiency. Our multi-fill implementation will actually go beyond FigmaToCode.
3. **Critical gap interactions: 1↔10 (constraints↔flattening), 2↔6 (fills↔gradients), 8↔9 (v-align↔truncation)** — Must check constraints before flattening. `-webkit-box` (line-clamp) is incompatible with flex centering.
4. **FigmaToCode stroke alignment uses outline-offset** — INSIDE→`outline-offset: -{weight}px`, CENTER→`outline-offset: -{weight/2}px`. We should follow this pattern (NOT box-shadow).
5. **Angular gradients: use conic-gradient() (93%+ browser support)** — TW4 supports `bg-conic`. Diamond gradients have no CSS equivalent → approximate as radial.
6. **Implementation order matters** — Independent fixes first (text_case, truncation), then positioning (stroke, constraints), then rendering (flattening, v-align, scaleMode), then complex (gradients, multi-fill). This minimizes interaction risk.

---

## Inscribed — RTK Optional Integration Design (2026-03-01)

**Source**: `rune:devise 20260301-163937`
**Confidence**: HIGH (5 research agents, empirical hook analysis, echo cross-reference)

1. **`updatedInput` chain propagation is undocumented** — When multiple PreToolUse hooks use `updatedInput`, it is unknown whether hook N+1 sees the original or rewritten command. Adding a second rewriter requires empirical testing first.
2. **Hook naming: `advise-*` (advisory only) vs `transform-*`/`enforce-*` (rewriters)** — A hook that both rewrites and is fail-forward (OPERATIONAL) is a new category.
3. **Two-layer exemption > state-file-only** — Layer 1 (workflow state files) + Layer 2 (command patterns) provides defense-in-depth. Command patterns catch test runners regardless of workflow context.
4. **External tool integration: top-level talisman key + binary detection** — Two-layer gate: talisman config THEN runtime `command -v`. Cache binary detection per session.
5. **New talisman sections need 3 integration points**: `talisman.example.yml`, `talisman-resolve.sh`, `build-talisman-defaults.py`.

---

## Inscribed — Dual Figma MCP Provider Integration (2026-03-01)

**Source**: `rune:devise 20260301-155151`
**Confidence**: HIGH (3 research agents, tool mapping analysis)

1. **Official Figma MCP uses `fileKey` + `nodeId` params, NOT full URLs** — Must extract via `parseFigmaUrl()` and convert node-id format (hyphen to colon).
2. **`figma_list_components` has NO Official equivalent** — Must parse `get_metadata` XML for COMPONENT/COMPONENT_SET/INSTANCE nodes manually.
3. **Official MCP bonuses**: `get_screenshot`, `get_variable_defs` (named tokens), `get_code_connect_map` (codebase mapping).
4. **Official Figma MCP has TWO transports** — Remote (OAuth) and Desktop (`127.0.0.1:3845/mcp`, session). Same tools, distinct backends.
5. **Provider detection: probe-then-store** — Use `get_metadata` for probing (NOT `whoami`, remote-only). Store in state file for reuse.

---

## Inscribed — RTK Repo Research: Session Self-Learning Patterns (2026-03-01)

**Source**: `rune:devise session-self-learning` (research of `rtk-ai/rtk` repo)
**Confidence**: HIGH (direct repo analysis + enriched plan)

1. **Claude Code session JSONL: `tool_result` has NO `tool_name` field** — only `tool_use_id`. Must join `tool_use` (from `assistant.message.content[]`) with `tool_result` (from `user.message.content[]`) via `tool_use_id`. Two-pass jq: Pass 1 builds lookup `{id: name}`, Pass 2 enriches results.
2. **Echoes > Rules for automated learning** — RTK generates static `.claude/rules/`. Rune echoes are superior: 5-tier lifecycle, BM25-searchable, confidence scoring, role-scoped.
3. **`jq --slurp` uses ~8x file size in memory** — use `jq -c` streaming (~2MB constant) for session files.
4. **BSD `find -mtime` rounds to 24h boundaries** — use `-newermt` for cross-platform accuracy.
5. **Session data needs 3-layer sanitization** — Scanner (truncation), Detector (pattern-only), Writer (16-regex filter).

---

## Inscribed — Prompt Injection Defense Hardening (2026-03-01)

**Source**: `rune:devise 20260301-044943`
**Confidence**: HIGH

1. **PostToolUse hooks cannot modify tool output** — only inject `additionalContext` (advisory).
2. **bash `tr -d '\u200B'` is a silent no-op** — `tr` doesn't understand `\uNNNN`. Use python3.
3. **7 Unicode invisible char ranges needed**: U+200B-200F, U+202A-202E, U+2066-2069, U+E0000-E007F, U+FE00-FE0F, U+FEFF, U+1D400-1D7FF.
4. **Truncation must be FIRST in sanitization pipeline** — prevents DoS via large MCP response.

---

## Consolidated — Proven Arc Pipeline Patterns (2026-02 to 2026-03)

**Source**: 20+ arc runs across v1.28.0 to v1.122.0

- **Direct orchestrator mend for markdown**: Confirmed 10+ times. When all findings target `.md`, skip team-based mend.
- **LIGHT tier for docs-only**: Converges round 0. STANDARD for code changes.
- **Round 1 re-review catches what round 0 misses**: Mend fixes can introduce new issues.
- **Pre-enriched plans skip forge cleanly**: Detected and copied as-is.
- **Checkpoint-based resume reliable across 3+ sessions**: Write state to files, not context.
- **Worker scope creep**: Workers add features NOT in plan. Verify output; `git checkout --` to revert.
- **Ghost team blocks next TeamCreate**: Strategy 4 (recreate dir, TeamDelete, cleanup) works.
- **Version bump propagation**: plugin.json, marketplace.json, CHANGELOG, README, CLAUDE.md all need updates.
- **Rebase with HEAD causes detached HEAD**: Always use branch name.

---

## Consolidated — Shell Script and Hook Patterns (2026-02 to 2026-03)

**Source**: Multiple arc runs implementing hook scripts

1. **`((var++))` under `set -e` exits when var=0** — Use `var=$((var + 1))`.
2. **`jq -n --arg` > heredoc for JSON output** — prevents injection from names with quotes.
3. **Hook scripts need 3-agent audit**: ward-sentinel + rune-architect + pattern-seer.
4. **Advisory-only for PreToolUse:TeamCreate** — hard-deny deadlocks teamTransition.
5. **30-minute stale threshold for orphan detection**.
6. **Quoted heredocs** (`<<'EOF'`) when content has `$VAR` that should not expand.
7. **Initialize all variables before conditional branches** under `set -euo pipefail`.

---

## Consolidated — Planning Methodology (2026-02 to 2026-03)

**Source**: Multiple devise sessions

1. **Baseline metrics must be verified, not estimated**: Always grep to confirm. Plans over-count.
2. **Stale plan detection**: Re-plan if >5 commits touched target files.
3. **SDK one-team-per-lead blocks parallel dual-pass**: Sequential only.
4. **PREFIX COLLISION trap**: Grep existing agents before assigning new finding prefixes.
5. **inscription.json: register unconditionally, spawn conditionally**.
6. **Categorical labels > numeric scores**: PROVEN/LIKELY/UNCERTAIN/UNPROVEN, not floats.
7. **Gap analysis before planning from research**: Features may already be implemented.
8. **pytest + subprocess**: Community standard for Claude Code plugin testing.

---

## Consolidated — Security Patterns (2026-02 to 2026-03)

**Source**: Multiple plan + arc security findings

1. **`rg -f` for untrusted regex**: Write to temp file. Pattern never enters Bash parser.
2. **`$` in regex char class enables `$(...)` substitution**: Convention-only mitigations are theater.
3. **4-position ANCHOR sandwich for meta-review agents**: body open, challenge entry, reset, final.
4. **Template variable contracts**: 14+ variables needs a contract table in header.
5. **Boundary marker nonces**: Static markers are injection-vulnerable. Use random nonces.
6. **`2>/dev/null` blocks ALL error classification**: Capture stderr to file instead.

---

## Inscribed — Swarm-Inspired Strive Improvements (2026-03-02)

**Source**: `rune:devise 20260302-115739` (exhaustive mode, 15+ agents)
**Confidence**: HIGH (8 research agents, 6 forge agents, 3 technical reviewers)

1. **Swarm patterns adapt to hierarchical model without architecture changes** — ruflo's mesh/P2P patterns (gossip, DHT, Byzantine Fault Tolerance) are overkill for 3-8 agents on single machine. Best-effort file lock signals + heuristic reassignment deliver 80% of value at 10% of complexity.
2. **Step numbering collisions in worker-prompts.md** — Steps 4.6 (RISK TIER) and 4.7 (DESIGN SPEC) already exist. Always verify existing step numbers before proposing new steps. Evidence-verifier caught this; decree-arbiter missed it.
3. **`WORKER_NAME` vs `TEAMMATE_NAME` in hooks** — `on-task-completed.sh` uses `TEAMMATE_NAME` (L73). Variable naming inconsistency in hook scripts is a recurring bug class. Always grep the actual variable name before referencing in plan pseudocode.
4. **`references/configuration-guide.md` is canonical** — When adding new talisman config blocks, this file MUST be in Files to Modify. Knowledge-keeper DOC-1 caught this gap.
5. **Phantom file references** — `commit-broker.md` was listed in "Files to NOT Modify" but does not exist as a standalone file. Always verify file existence. Logic is inline in SKILL.md Phase 3.5.
6. **Mutable estimate > early returns** — `estimateTaskMinutes()` with `return 5/10/15` creates dead code for subsequent modifiers (`test` type, `refactor` bonus). Use `let estimate` with modifier chain instead.
7. **Three-reviewer Phase 4C is complementary** — decree-arbiter validates technical soundness within the plan's frame, evidence-verifier checks claims against codebase reality, knowledge-keeper catches documentation gaps. Each found issues the others missed.

---

## Consolidated — Forge and Review Insights (2026-02 to 2026-03)

**Source**: Multiple forge + review cycles

1. **Forge agents can introduce phantom patterns**: Always verify claims via grep.
2. **Decree-arbiter "claim vs reality"**: Most effective plan review technique.
3. **Scroll-reviewer + decree-arbiter are complementary**: Structural + factual coverage.
4. **43% false positive rate in reviews is normal**: TOME dedup + manual FP verification essential.
5. **Forge agents can disagree with plan decisions**: Add explicit decision annotations.

---

## Inscribed — Echo Memory Lifecycle: Reindex Architecture Insights (2026-03-03)

**Source**: `rune:devise 20260303-103731`
**Confidence**: HIGH (4 research agents, 2 technical reviewers, codebase-verified)

1. **`_insert_entries()` DELETE+INSERT resets ALL column state** — Any new columns with DEFAULT values (like `archived=0`) are wiped on every reindex. Archive/flag logic placed "after insert" works correctly by re-evaluating, but previous archive decisions don't persist. Design decision: treat as self-healing behavior.
2. **`ON DELETE CASCADE` on `semantic_groups` wipes groups during reindex** — When `echo_entries` rows are deleted, CASCADE destroys all `semantic_groups` rows. Any feature depending on group membership (archive exemption, related_entries) needs a backup/restore wrapper around the DELETE+INSERT cycle.
3. **server.py C4 concern: does NOT read talisman.yml** — Line 176 explicitly states env vars only. Adding direct talisman reading breaks an architectural boundary. Use env var bridge: `start.sh` maps YAML → env vars.
4. **`_batch_fetch_access_counts()` doesn't exist** — The actual functions are `_prepare_frequency_data()` (L529) + `_get_access_counts()` (L432). Plan hallucinated a plausible function name. Always grep before citing function names.
5. **Access log pruning creates a 180-day window** — `_prune_access_log()` deletes records older than 180 days. Entries accessed once >180 days ago appear to have "zero access". This is acceptable for archival — if nothing accessed it in 6 months, archival is reasonable.
6. **Scroll-reviewer + decree-arbiter found complementary issues**: Scroll caught spec ambiguity (AC-2.2 Confidence reference, pseudocode binding), decree caught architectural impossibilities (archive no-op, CASCADE destruction). Both review types are essential for comprehensive plans.

## Observations — Task: echo-reader (2026-03-11)
- **layer**: observations
- **source**: `rune-plan-20260311-204238/echo-reader`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: echo-reader
- Context: You are researching for a planning workflow. Read Rune Echoes from .claude/echoes/ to surface any pa

## Observations — Task: repo-surveyor (2026-03-11)
- **layer**: observations
- **source**: `rune-plan-20260311-204238/repo-surveyor`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: repo-surveyor
- Context: You are researching for a planning workflow. Your task: Analyze the echo-search MCP server architect

## Observations — Task: Spec validation: Flow analysis for doc pack install + elevation flows (2026-03-11)
- **layer**: observations
- **source**: `rune-plan-20260311-204238/flow-seer`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Spec validation: Flow analysis for doc pack install + elevation flows
- Context: Analyze user flows for doc pack installation, echo elevation, and global scope queries. Identify edge cases and gaps.

## Observations — Task: Research: Git history for echo-search evolution (2026-03-11)
- **layer**: observations
- **source**: `rune-plan-20260311-204238/git-miner`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Research: Git history for echo-search evolution
- Context: Analyze git history for echo-search MCP server to understand design decisions, recent changes, and safe extension points.

## Observations — Task: scroll-reviewer (2026-03-11)
- **layer**: observations
- **source**: `rune-plan-20260311-204238/scroll-reviewer`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: scroll-reviewer
- Context: Review the plan document at `plans/2026-03-11-feat-rune-lore-plan.md` for document quality.\n\nCheck f

## Observations — Task: Research: Search Rune echoes for related patterns and past learnings (2026-03-15)
- **layer**: observations
**Source**: `rune-plan-1773534918/echo-reader`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Research: Search Rune echoes for related patterns and past learnings
- Context: Search Rune echoes for any past learnings related to:\n1. PR comment posting\n2. GitHub integration\n3. Review output formatting\n4. Ship phase patterns\nWrite findings to tmp/plans/1773534918/research/echo-findings.md

## Observations — Task: Research: Analyze git history for PR/ship related changes (2026-03-15)
- **layer**: observations
**Source**: `rune-plan-1773534918/git-miner`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Research: Analyze git history for PR/ship related changes
- Context: Mine git history for:\n1. How the ship phase evolved (arc ship references)\n2. Past PR creation patterns and gh CLI usage\n3. Any previous attempts at PR comment integration\n4. resolve-gh-pr-comment skill implementation patterns\nWrite findings to tmp/plans/1773534918/research/git-archaeology.md

## Observations — Task: Research: Analyze existing Rune review output format and TOME structure (2026-03-15)
- **layer**: observations
**Source**: `rune-plan-1773534918/repo-surveyor`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Research: Analyze existing Rune review output format and TOME structure
- Context: Explore the Rune plugin codebase to understand:\n1. How TOME files are structured (finding format, priorities, file references)\n2. How /rune:appraise produces output (aggregation in runebinder)\n3. Current ship/PR creation flow in arc pipeline\n4. Existing gh CLI usage patterns in the plugin\nWrite findings to tmp/plans/1773534918/research/repo-survey.md

## Observations — Task: Research: Analyze GitHub PR comment API and best practices (2026-03-15)
- **layer**: observations
**Source**: `rune-plan-1773534918/practice-seeker`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Research: Analyze GitHub PR comment API and best practices
- Context: Research GitHub PR comment API capabilities:\n1. gh pr review vs gh pr comment vs gh api for posting comments\n2. Line-level vs file-level vs PR-level comment types\n3. Rate limits and batch posting strategies\n4. How CodeRabbit and other bots format their PR comments\n5. Markdown formatting constraints in GitHub comments\nWrite findings to tmp/plans/1773534918/research/external-research.md

## Observations — Task: Scroll review: validate plan quality and completeness (2026-03-15)
- **layer**: observations
**Source**: `rune-plan-1773537648/scroll-reviewer`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Scroll review: validate plan quality and completeness
- Context: Review the plan at plans/2026-03-15-docs-community-readiness-phase1-plan.md for: clarity, completeness, actionability, missing acceptance criteria. Write findings to tmp/plans/1773537648/scroll-review.md

## Observations — Task: Grounding Gate: Verify plan claims against codebase (2026-03-16)
- **layer**: observations
**Source**: `rune-plan-20260316-030121/grounding-verifier`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: Grounding Gate: Verify plan claims against codebase
- Context: Verify the key factual claims in plans/2026-03-16-feat-arc-skills-gap-remediation-plan.md against the actual codebase. Check: (1) generateTestStrategy is truly undefined (not just in a different file), (2) waitForCompletion violations actually exist at the cited lines, (3) Phase 7.9 is truly missing from SKILL.md table, (4) orphaned refs status is accurate, (5) stop hook line counts are correct, (6) rune-status.sh exists and cancel-arc --status works. Write verification results to tmp/plans/2026
