# Rune vs Orchestrate: Deep Gap Analysis

**Date**: 2026-03-01
**Source**: https://github.com/haowjy/orchestrate
**Purpose**: Competitive analysis — identify learnings, gaps, mismatches compared to Rune plugin

---

## Architecture Comparison at a Glance

| Dimension | **Rune** | **Orchestrate** |
|---|---|---|
| **Philosophy** | Enterprise orchestration — deep, specialized, opinionated | Unix composability — small primitives, flexible routing |
| **Agents** | 90 (40 review, 24 investigation, 13 utility, 5 research, 4 testing, 4 work) | 4 (orchestrator, coder, reviewer, researcher) |
| **Skills** | 43 | 8 (2 core + 6 optional) |
| **Hook scripts** | 38 | 4 |
| **MCP servers** | 3 (echo-search, figma-to-react, context7) | 0 |
| **Models supported** | Claude (native) + Codex (bolted-on) + CLI Ashes | Claude + Codex + OpenCode (native routing for all) |
| **Team coordination** | Agent Teams (TeamCreate/SendMessage/TaskUpdate) | Shell `&` + `wait` (PID-based parallelism) |
| **Run tracking** | tmp/ state files, TOME aggregation | JSONL append-only index, per-run artifacts |
| **Config** | talisman.yml (82 keys, 13 shards) | config.toml (minimal, pinned skills only) |
| **Memory** | Echo system with FTS5 search MCP | None |
| **Pipeline** | 26-phase Arc (planning → merge) | Supervisor loop (understand → compose → launch → evaluate) |
| **Session safety** | config_dir + owner_pid + session_id isolation | None |
| **Runtime** | Bash + Python (MCP servers) | Bash + jq (zero-dependency) |

---

## Orchestrate: Key Architectural Patterns

### Core Concept: `model + skills + prompt`

Everything is a composable run. No heavyweight abstractions. The `run-agent.sh` script is the single entry point:

```bash
run-agent.sh --model MODEL --skills SKILL1,SKILL2 -p "PROMPT"
run-agent.sh --agent AGENT -p "PROMPT"     # Agent profile = named defaults
run-agent.sh --model MODEL --dry-run -p "PROMPT"  # Preview without executing
```

### Multi-Model Routing (Auto-Detect)

```
claude-*, opus*, sonnet*, haiku*  →  claude -p
gpt-*, o1*, o3*, o4*, codex*     →  codex exec
opencode-*, provider/model       →  opencode run
```

### Variant Abstraction (Reasoning Effort)

| Provider | Variants |
|----------|----------|
| Anthropic | high, max |
| OpenAI | none, minimal, low, medium, high, xhigh |
| Google | low, high |

### Per-Run Structured Artifacts

```
.orchestrate/runs/agent-runs/<run-id>/
├── params.json         # Configuration snapshot
├── input.md            # Composed prompt
├── prompt.raw.md       # Prompt before output/report sections
├── output.jsonl        # Raw CLI output
├── stderr.log          # CLI diagnostics
├── report.md           # Agent's summary
├── files-touched.nul   # NUL-delimited paths (machine)
└── files-touched.txt   # Newline-delimited paths (human)
```

### Append-Only Run Index

`.orchestrate/index/runs.jsonl` — two rows per run:
- **Start row** (before execution): `status: "running"` — crash visibility
- **Finalize row** (after execution): `status: "completed"|"failed"` with exit code, duration, tokens, git metadata

### Structured Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Agent/model error |
| 2 | Infrastructure error |
| 3 | Timeout |
| 130 | Interrupted (SIGINT) |
| 143 | Terminated (SIGTERM) |

### Trust Model (Layered)

```
environment policy > agent profile permissions > skill tool requests
```

- **Agent profiles** (committed, trusted) → define permission ceiling
- **Skills** (untrusted prompt content) → declare desired tools, capped by agent
- **Environment policy** (`.orchestrate/policy.toml`) → caps all agents

### Fan-Out Reviews

```bash
# Multiple model families reviewing in parallel
run-agent.sh --agent reviewer --model claude-opus-4-6 --session "$SID" &
run-agent.sh --agent reviewer --model gpt-5.3-codex --session "$SID" &
run-agent.sh --agent reviewer --model google/gemini-3.1-pro-preview --session "$SID" &
wait
```

Disagree? Run a tiebreak with a different model. Bounded: 3 rework cycles max.

### Scratchpad Convention

Disposable verification code in `.scratch/`. Workers write smoke tests, API probes, integration checks. Promote to committed tests when they catch real issues.

### Dogfooding Policy

Coder agent requires: "Prefer exercising changes through the product's own user-facing workflow (CLI/UI/API) instead of only unit-level checks." Must report explicit blockers if dogfooding isn't possible.

### Sticky Skills (Session Continuity)

`session-start.sh` hook scans transcript for skill invocations, replays them after compact/clear. Detects active orchestration plans. Allows per-project allowlists.

### Model Guidance System

Pluggable guidance with override precedence:
- `references/default-model-guidance.md` — base recommendations
- `references/model-guidance/*.md` — project overrides (replace default entirely)

Default picks: Codex for implementation, fan-out for reviews, Opus for architecture, Haiku for lightweight tasks.

---

## Things Rune Can Learn from Orchestrate

### 1. First-Class Multi-Model Routing (HIGH PRIORITY)

**Gap**: Codex is second-class in Rune (CLI-backed Ashes with hallucination guards, `max_cli_ashes` sub-cap). No Google Gemini, Llama, or OpenCode support. Adding a new model requires talisman config + custom Ash definition.

**Pattern to adopt**: A universal model router that maps model names to CLI invocations. `claude-*` → claude, `gpt-*` → codex, `provider/model` → opencode. This would replace the brittle `codex-cli` detection pattern.

### 2. Per-Run Structured Artifacts (HIGH PRIORITY)

**Gap**: Agent outputs are unstructured. TOME aggregates findings but there's no per-agent artifact trail. When a reviewer produces unexpected output, there's no `input.md` to inspect what prompt it received.

**Pattern to adopt**: Write `params.json` + `input.md` before each agent spawn. Capture per-agent output to structured files. Build a run index for stats, retry, and crash detection.

### 3. Scratchpad / Smoke Test Convention (MEDIUM)

**Gap**: No convention for disposable verification code. Workers skip verification or add it inline. The `testing` skill is heavy (3-tier orchestration).

**Pattern to adopt**: A lightweight `scratchpad` skill or convention within strive workers — "after implementing, write a smoke test to `.scratch/` and run it."

### 4. Dogfooding Policy (MEDIUM)

**Gap**: Workers verify via linting/tests but don't explicitly dogfood through the actual product workflow. A feature could pass tests but fail end-to-end.

**Pattern to adopt**: Add a "dogfooding" step to rune-smith workers — require exercising the change through the actual user-facing path.

### 5. Dry-Run Mode (MEDIUM)

**Gap**: No way to preview what an agent will receive before spawning it. Debugging agent behavior requires reading skills + CLAUDE.md + hooks + inscription.json mentally.

**Pattern to adopt**: `--dry-run` flag for devise/strive/appraise that shows composed prompts without spawning agents.

### 6. Variant / Reasoning Effort Abstraction (LOW-MEDIUM)

**Gap**: Cost tiers map agents to models but don't abstract reasoning effort. No equivalent of "use this model at high reasoning effort."

### 7. Lightweight Spec Alignment (LOW)

**Gap**: `/rune:inspect` spawns 4 Inspector Ashes for a full audit. Overkill for a quick "did we build the right thing?" sanity check.

**Pattern to adopt**: A lightweight `spec-check` mode — 1 agent, 2-minute runtime, simple aligned/misaligned output.

### 8. Clean Trust Model (ARCHITECTURAL)

**Gap**: Skills and agents are both treated as trusted (plugin code). But CLI-backed Ashes load external model output, blurring the trust boundary. Hallucination guard is a mitigation, not a proper trust model.

**Pattern to adopt**: Formal layered trust — `environment > agent profile > skill requests`. External model output treated as untrusted prompt content with capability ceiling.

### 9. Run JSONL Index (MEDIUM)

**Gap**: No append-only run tracking. Can't do `stats`, `retry @last-failed`, or detect crashed runs.

**Pattern to adopt**: JSONL index with start/finalize rows per agent run.

---

## Things Orchestrate Lacks That Rune Has

| Capability | Rune | Orchestrate |
|---|---|---|
| **Agent specialization** | 90 domain-specific agents (40 review, 24 investigation) | 4 generic agents |
| **Agent Teams** | TeamCreate/SendMessage/TaskUpdate coordination | Shell `&` + `wait` only |
| **End-to-end pipeline** | 26-phase Arc (planning → merge) | Manual supervisor loop |
| **Session isolation** | config_dir + owner_pid + session_id guards | None |
| **Persistent memory** | Echo system with FTS5 search MCP | None |
| **Hook infrastructure** | 38 hooks across 11 events | 4 hooks across 3 events |
| **MCP servers** | 3 custom (echo-search, figma-to-react, context7) | None |
| **Configuration depth** | 82-key talisman with 13 pre-resolved shards | Minimal config.toml |
| **Context management** | Glyph budgets, context weaving, pre-compact checkpoints | "Split into smaller runs" discipline |
| **Plan enrichment** | Forge Gaze topic-aware matching | None |
| **Impact analysis** | Goldmask cross-layer (Impact + Wisdom + Lore) | None |
| **Design sync** | Figma-to-React pipeline | None |

---

## Philosophical Mismatches

| Aspect | Rune's Choice | Orchestrate's Choice | Assessment |
|---|---|---|---|
| **Agent count** | 90 specialized | 4 generic + model variety | Context-dependent. Specialization wins for deep reviews; generics win for flexibility |
| **Coordination** | Agent Teams (SDK-native) | Shell parallelism (PID-based) | Rune — real coordination > fire-and-forget |
| **Config** | 82-key talisman | Near-zero config | Rune for power users, Orchestrate for simplicity |
| **Runtime deps** | Python + Node + Bash | Bash + jq only | Orchestrate — fewer deps = more portable |
| **Model routing** | Per-agent model assignment | Per-run model selection | Orchestrate — more flexible, less opinionated |
| **State management** | Session isolation, state files | Stateless runs + JSONL index | Both valid — different tradeoffs |
| **Trust model** | Skills = trusted plugin code | Skills = untrusted prompt content | Orchestrate — cleaner separation |

---

## Recommended Actions for Rune (Priority Order)

| # | Action | Effort | Impact | Source |
|---|---|---|---|---|
| **1** | Add per-agent structured artifacts (params.json, input.md, output) | Medium | High | Orchestrate run artifacts |
| **2** | Build universal model router (`run-model.sh`) | High | High | Orchestrate run-agent routing |
| **3** | Add scratchpad/smoke-test convention to strive | Low | Medium | Orchestrate scratchpad skill |
| **4** | Add `--dry-run` to devise/strive/appraise | Low | Medium | Orchestrate dry-run flag |
| **5** | Add dogfooding policy to rune-smith workers | Low | Medium | Orchestrate coder agent |
| **6** | Build lightweight spec-check (1 agent, 2 min) | Low | Low-Med | Orchestrate spec-aligning |
| **7** | Formalize trust model for CLI-backed Ashes | Medium | Medium | Orchestrate trust layers |
| **8** | Add run JSONL index for stats/retry/crash detection | Medium | Medium | Orchestrate run-index.sh |

---

## Summary

**Orchestrate** is a lean, composable, multi-model supervisor toolkit. Its strength is treating all models as first-class citizens with a clean `model + skills + prompt` primitive and excellent run observability (per-run artifacts, JSONL index, dry-run mode).

**Rune** is a deep, specialized orchestration system. Its strength is domain expertise (90 agents), safety infrastructure (38 hooks, session isolation), persistent memory, and end-to-end automation (26-phase Arc).

The two are complementary. Rune's biggest learning opportunity is Orchestrate's **multi-model routing** and **per-run observability**. Orchestrate's biggest gap is **everything Rune has beyond basic routing** — team coordination, memory, safety, specialization, and pipelines.
