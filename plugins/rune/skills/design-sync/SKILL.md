---
name: design-sync
description: |
  Figma design synchronization workflow. Extracts design specs from Figma URLs,
  creates Visual Spec Maps (VSM), guides implementation workers, and reviews
  fidelity between design and code. 3-phase pipeline: PLAN (extraction) ->
  WORK (implementation) -> REVIEW (fidelity check).

  <example>
  user: "/rune:design-sync https://www.figma.com/design/abc123/MyApp?node-id=1-3"
  assistant: "Initiating design sync — extracting Figma specs and creating VSM..."
  </example>

  <example>
  user: "/rune:design-sync --review-only"
  assistant: "Running design fidelity review against existing VSM..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "<url1> [<url2> ...] [--plan-only] [--resume-work] [--review-only] [--urls <file>]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Agent
  - TaskCreate
  - TaskUpdate
  - TaskGet
  - TaskList
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
---

**Runtime context** (preprocessor snapshot):
- Active workflows: !`grep -rl '"active"' tmp/.rune-*-*.json 2>/dev/null | wc -l | tr -d ' '`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:design-sync — Figma Design Synchronization

Extracts design specifications from Figma, creates Visual Spec Maps (VSM), coordinates implementation, and reviews design-to-code fidelity.

**Load skills**: `frontend-design-patterns`, `figma-to-react`, `context-weaving`, `rune-orchestration`, `team-sdk`, `polling-guard`, `zsh-compat`

## Usage

```
/rune:design-sync <url1>                             # Full pipeline: extract → implement → review
/rune:design-sync <url1> <url2> [<url3>...]          # Multi-URL: process multiple Figma files
/rune:design-sync --urls urls.txt                    # File-based input: one Figma URL per line
/rune:design-sync <figma-url> --plan-only            # Extract VSM only (no implementation)
/rune:design-sync --resume-work                      # Resume from existing VSM
/rune:design-sync --review-only                      # Review fidelity of existing implementation
```

## Prerequisites

1. **Figma MCP server** configured in `.mcp.json` with `FIGMA_TOKEN` environment variable
2. **design_sync.enabled** set to `true` in talisman.yml (default: false)
3. Frontend framework detected in project (React, Vue, Next.js, Vite)

## Pipeline Overview

```
Phase 0: Pre-Flight → Validate URL, check MCP availability, read talisman config
    |
Phase 1: Design Extraction (PLAN) → Fetch Figma data, create VSM files
         figma_to_react() → REFERENCE CODE (~50-60% match) stored, NOT applied directly
    |
Phase 1.5: User Confirmation → Show VSM summary, confirm or edit before implementation
    |
[Phase 1.3: Component Match — conditional on builderProfile.capabilities.search]
           → Analyze reference code for component intent
           → Search UI builder MCP for real library components
           → Enrich VSM with real component matches (~85-95% match path)
           → Propagate match_score + confidence (high/medium/low) per region
    |
Phase 1.4: Verification Gate → Compare VSM regions vs extraction coverage (PASS/WARN/BLOCK)
    |
Phase 2: Implementation (WORK) → Create components from VSM using swarm workers
         With builder: workers receive enriched VSM + real library component code
         Without builder: workers apply figma-to-react reference code directly (fallback)
    |
Phase 2.5: Design Iteration → Optional screenshot→analyze→fix loop for fidelity
    |
Phase 3: Fidelity Review (REVIEW) → Score implementation against VSM
    |
Phase 4: Cleanup → Shutdown workers, persist echoes, report results
```

> **figma-to-react output is REFERENCE CODE** (~50-60% match). When a UI builder MCP is
> available (`builderProfile !== null`), it is analyzed for visual intent and used as
> search queries against the real component library — NOT applied to workers directly.
> When no builder is available, the reference code is used as-is (graceful fallback).

## Phase 0: Pre-Flight

Validates talisman config (`design_sync.enabled`), parses arguments and collects Figma URLs (from positional args or `--urls` file), validates URLs with strict/lenient patterns, detects MCP provider (auto-probe cascade: rune → official → desktop), checks agent-browser availability, sets up session directories, writes state file with session isolation, and handles `--resume-work`/`--review-only` flags.

See [phase0-preflight.md](references/phase0-preflight.md) for the full pre-flight implementation code, URL validation constants, and MCP provider fallback strategy.
See [figma-url-parser.md](references/figma-url-parser.md) for URL format details.

## Phase 1: Design Extraction

Extract Figma design data and create Visual Spec Maps (VSM). Creates extraction team, fetches components per Figma URL (with per-URL subdirectories for multi-URL support), creates one task per top-level component/frame, summons design-syncer workers, and monitors via TaskList polling.

See [phase1-design-extraction.md](references/phase1-design-extraction.md) for the full extraction algorithm.

### VSM Output Format

See [vsm-spec.md](references/vsm-spec.md) for the complete Visual Spec Map schema.

## Phase 1.3: Component Match (Conditional)

Only runs when `builderProfile.capabilities.search` is available. Zero overhead otherwise.

Searches builder library for real component matches against each VSM region. Uses reference code from `figma_to_react()` as visual intent source. Protected by circuit breaker (3 consecutive MCP failures → skip remaining) and phase timeout (60s). Writes `enriched-vsm.json` with match scores and confidence levels. Unmatched regions fall back to Tailwind-based implementation in Phase 2.

See [component-match.md](references/component-match.md) for the full algorithm.

## Phase 1.4: Verification Gate

Validates VSM coverage before proceeding to implementation. Computes mismatch percentage between extracted and expected regions. Three verdicts: PASS (silent), WARN (advisory), BLOCK (user confirmation required). Zero-region guard stops pipeline when extraction produced no usable data. Stores `verificationGateResult` for Phase 2 worker prompt injection. BLOCK verdicts are persisted to echoes for pattern detection.

See [verification-gate.md](references/verification-gate.md) for the full algorithm, threshold validation, and output formats.

## Phase 1.5: User Confirmation

```
if NOT flags.planOnly:
  // Show VSM summary to user
  vsmFiles = Glob("tmp/design-sync/{timestamp}/vsm/*.md")
  summary = generateVsmSummary(vsmFiles)
  AskUserQuestion("VSM extraction complete:\n\n{summary}\n\nProceed to implementation? [yes/edit/stop]")

if flags.planOnly:
  // Write completion report, cleanup team, STOP
  updateState({ status: "completed", phase: "plan-only" })
  STOP
```

## Phase 2: Implementation

Create components from VSM using swarm workers. Steps: backend impact assessment → framework detection + codegen profile resolution → builder profile resolution → VSM task creation with sanitized prompts → worker spawning.

Key features: backend impact 4-branch decision tree, codegen profile auto-detection (shadcn/untitled-ui/generic with talisman override), builder context injection for enriched VSM, SEC-01/SEC-06 prompt sanitization, verification gate status propagation to workers.

See [phase2-implementation-steps.md](references/phase2-implementation-steps.md) for the full step-by-step implementation code.
See [phase2-design-implementation.md](references/phase2-design-implementation.md) for implementation guidance.
See [framework-codegen-profiles.md](../frontend-design-patterns/references/framework-codegen-profiles.md) for codegen transformation rules per framework.

## Phase 2.5: Design Iteration (Optional)

If agent-browser is available and design_sync.iterate_enabled is true:

```
if agentBrowserAvailable AND config?.design_sync?.iterate_enabled:
  // Create iteration tasks for each implemented component
  for each component in implementedComponents:
    TaskCreate({
      subject: "Iterate on {component_name} design fidelity",
      description: "Run screenshot→analyze→improve loop. Max {config.design_sync.max_iterations ?? 5} iterations.",
      metadata: { phase: "iteration", vsm_path: component.vsm_path }
    })

  // Summon design-iterator workers
  maxIterators = config?.design_sync?.max_iteration_workers ?? 2
  for i in range(maxIterators):
    Agent(team_name="rune-design-sync-{timestamp}", name="design-iter-{i+1}", ...)
      // Spawn design-iterator with VSM + screenshot context
```

See [screenshot-comparison.md](references/screenshot-comparison.md) for browser integration.

## Phase 3: Fidelity Review

Score implementation against design specifications.

```
// Step 1: Create fidelity review tasks
for each component in implementedComponents:
  TaskCreate({
    subject: "Review fidelity of {component_name}",
    description: "Score implementation against VSM. 6 dimensions: tokens, layout, responsive, a11y, variants, states.",
    metadata: { phase: "review", vsm_path: component.vsm_path }
  })

// Step 2: Summon design-implementation-reviewer
Agent(team_name="rune-design-sync-{timestamp}", name="design-reviewer-1", ...)
  // Spawn design-implementation-reviewer with VSM + component paths

// Step 3: Aggregate fidelity scores
// Read reviewer output, compute overall fidelity score
```

See [phase3-fidelity-review.md](references/phase3-fidelity-review.md) for the review protocol.
See [fidelity-scoring.md](references/fidelity-scoring.md) for the scoring algorithm.

## Phase 4: Cleanup

Standard 5-component team cleanup: generate completion report → persist echoes → dynamic member discovery with shutdown_request → TeamDelete with retry-with-backoff (4 attempts) → process-level kill + filesystem fallback when TeamDelete fails → update state → report to user.

See [phase4-cleanup.md](references/phase4-cleanup.md) for the full cleanup implementation code.

## Configuration

```yaml
# talisman.yml
design_sync:
  enabled: false                         # Master toggle (default: false)
  figma_provider: auto                   # MCP provider: auto|rune|official|desktop (default: auto)
                                         #   auto     — probe Rune first, then Official, then fail
                                         #   rune     — Rune figma-to-react MCP only (no FIGMA_TOKEN needed)
                                         #   official — Official Figma MCP only (requires FIGMA_TOKEN)
                                         #   desktop  — Figma Desktop bridge (requires Dev Mode Shift+D)
  max_extraction_workers: 2              # Extraction phase workers
  max_implementation_workers: 3          # Implementation phase workers
  max_iteration_workers: 2              # Iteration phase workers
  max_iterations: 5                      # Max design iterations per component
  iterate_enabled: false                 # Enable screenshot→fix loop (requires agent-browser)
  fidelity_threshold: 80                 # Min fidelity score to pass review
  codegen_profile: null                  # Force codegen profile: null (auto-detect) | shadcn | untitled-ui | generic
  token_snap_distance: 20               # Max RGB distance for color snapping
  figma_cache_ttl: 1800                  # Figma API cache TTL (seconds)
  verification_gate:
    enabled: true                        # Enable cross-verification gate
    warn_threshold: 20                   # Mismatch % that triggers WARN
    block_threshold: 40                  # Mismatch % that triggers BLOCK
  trust_hierarchy:
    enabled: true
    low_confidence_threshold: 0.60       # Below this = LOW confidence
    high_confidence_threshold: 0.80      # Above this = HIGH confidence
  backend_impact:
    enabled: false                       # Default: disabled (opt-in). Enable to auto-assess backend changes.
    auto_scope: frontend-only            # Default scope assumption
```

**`verification_gate`**: Controls the cross-verification gate that compares extracted design specs against implementation output. When mismatch percentage exceeds `warn_threshold`, the gate emits a WARN verdict (proceed with advisory). When it exceeds `block_threshold`, the gate emits a BLOCK verdict (halt and require manual review).

**`trust_hierarchy`**: Configures confidence thresholds for the 6-level source trust hierarchy used by implementation workers. Sources with confidence below `low_confidence_threshold` are tagged LOW and require manual verification. Sources above `high_confidence_threshold` are tagged HIGH and trusted for automated implementation.

**`backend_impact`**: Controls the backend impact decision tree that determines whether a design change requires backend modifications. `auto_scope` sets the default assumption — `frontend-only` means changes are assumed UI-only unless the decision tree detects API, data model, or integration impacts across its 4 branches.

## State Persistence

All state files follow session isolation rules:

```json
{
  "status": "active",
  "phase": "extraction",
  "config_dir": "/Users/user/.claude",
  "owner_pid": "12345",
  "session_id": "abc-123",
  "started_at": "20260225-120000",
  "figma_url": "https://www.figma.com/design/...",
  "figma_urls": [
    "https://www.figma.com/design/abc123/MyApp?node-id=1-3",
    "https://www.figma.com/design/xyz789/Components"
  ],
  "url_statuses": [
    { "url": "https://www.figma.com/design/abc123/MyApp?node-id=1-3", "status": "completed", "vsm_count": 3 },
    { "url": "https://www.figma.com/design/xyz789/Components", "status": "pending", "vsm_count": 0 }
  ],
  "parsed_url": { "fileKey": "abc123", "nodeId": "1-3", "type": "design" },
  "mcp_provider": "rune",
  "work_dir": "tmp/design-sync/20260225-120000",
  "components": [],
  "fidelity_scores": {}
}
```

## Error Handling

### MCP Provider Errors

| Error | Rune MCP | Official MCP | Desktop MCP |
|-------|----------|--------------|-------------|
| Provider not detected | `figma_fetch_design` probe failed — check `.mcp.json` for Rune server entry | `mcp__claude_ai_Figma__get_metadata` probe failed — check `FIGMA_TOKEN` env var | `mcp__figma_desktop__get_selection` probe failed — Open Figma Desktop → Enable Dev Mode (Shift+D) |
| Auth failure | Rune MCP uses bundled token — check `scripts/figma-to-react/start.sh` config | `FIGMA_TOKEN` invalid or expired — regenerate at figma.com/settings | Desktop bridge requires active Figma Desktop session |
| File not found | File key invalid or not accessible to configured account | Same | Same — file must be open in Desktop |
| Rate limit | Rune MCP handles internally | Figma REST API rate-limited (429) — retry after delay | N/A (local IPC) |
| Node not found | `node-id` in URL does not exist — use `figma_list_components` to discover valid IDs | Same | Selection-based — ensure node is selected in Figma |

### Setup Options (when no provider detected)

1. **Rune MCP** (recommended, no personal token needed): Add to `.mcp.json`:
   ```json
   { "mcpServers": { "figma-to-react": { "command": "bash", "args": ["scripts/figma-to-react/start.sh"] } } }
   ```
2. **Official Figma MCP** (requires personal token): Set `FIGMA_TOKEN=figd_...` in env, configure official MCP server
3. **Desktop MCP**: Open Figma Desktop → Dev Mode (`Shift+D`) → enable MCP bridge in settings

### Error Response Convention

Error response type depends on execution context:

| Context | Error Response Type | Mechanism | Examples |
|---------|--------------------|-----------|----|
| **design-sync** (this skill, interactive) | INTERACTIVE | `AskUserQuestion(...)` + `STOP` | No Figma URL provided; design_sync not enabled; no MCP provider; invalid URL format |
| **arc orchestration** (e.g., arc-phase-design-extraction) | NON-BLOCKING | `warn(...)` + `continue` | MCP unavailable during arc Phase 6; URL parse failure on one of many URLs |

**Guidelines**:
- design-sync is user-facing: always surface errors interactively so the user can take immediate corrective action
- Arc orchestration is automated: log warnings and skip non-critical failures to avoid blocking an entire pipeline run
- `AskUserQuestion` is reserved for design-sync standalone contexts — never use it in arc subphases
- For arc contexts where a fatal condition is reached (e.g., zero valid URLs after filtering), log the error and set the phase result to `skipped` rather than `failed`

**Decision rule**: If a human is waiting for a response → INTERACTIVE. If running as part of automated orchestration → NON-BLOCKING.

## References

- [phase1-design-extraction.md](references/phase1-design-extraction.md) — Figma parsing and VSM creation
- [phase2-design-implementation.md](references/phase2-design-implementation.md) — VSM-guided implementation
- [phase3-fidelity-review.md](references/phase3-fidelity-review.md) — Fidelity review protocol
- [vsm-spec.md](references/vsm-spec.md) — Visual Spec Map schema
- [design-token-mapping.md](references/design-token-mapping.md) — Color snapping and token mapping
- [figma-url-parser.md](references/figma-url-parser.md) — URL format and file key extraction
- [figma-url-reader.md](references/figma-url-reader.md) — Dual-format frontmatter reader (figma_url scalar + figma_urls array)
- [fidelity-scoring.md](references/fidelity-scoring.md) — Scoring algorithm
- [screenshot-comparison.md](references/screenshot-comparison.md) — Agent-browser integration
- [framework-codegen-profiles.md](../frontend-design-patterns/references/framework-codegen-profiles.md) — Framework-specific codegen transformation rules
- [verification-gate.md](references/verification-gate.md) — Cross-verification gate algorithm (PASS/WARN/BLOCK verdicts)
- [worker-trust-hierarchy.md](references/worker-trust-hierarchy.md) — Source trust order (6 levels) for implementation workers
- [visual-first-protocol.md](references/visual-first-protocol.md) — Visual-first extraction principle with 4-level hierarchy
- [element-inventory-template.md](references/element-inventory-template.md) — Element inventory with source tracking (Code/Visual/Both/Manual)
- [backend-impact.md](references/backend-impact.md) — Backend impact decision tree (4 branches)
- [state-detection-algorithm.md](references/state-detection-algorithm.md) — 5-signal weighted composite algorithm for multi-URL frame classification
- [migration-guide.md](references/migration-guide.md) — Migration guide for accuracy-parity features (thresholds, rollback, troubleshooting)
