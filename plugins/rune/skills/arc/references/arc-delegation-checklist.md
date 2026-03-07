# Arc Delegation Checklist

Canonical reference for which Phase 0 steps to execute when arc delegates to another command.
Each step is annotated: **RUN** (execute as-is), **SKIP** (arc handles this or not needed),
or **ADAPT** (run with arc-specific modifications).

> **Contributor note**: When adding new arc phases that delegate to commands, add a section to this file.

<!-- Cross-reference: appraise.md and audit.md Phase 0 sections contain DELEGATION-CONTRACT comments pointing here. -->

## Security Note

Arc must sanitize all variables before passing to delegated Phase 0 steps.
Use `SAFE_PATH_PATTERN` validation for file paths and write file lists to temp files
rather than inline interpolation (see appraise.md SEC-006). Variables from previous
phase artifacts (plan paths, file lists, team names) are validated at arc pre-flight,
but re-validate if transforming or concatenating.

## Phase 0: Pre-flight Parameters (Passthrough)

These parameters are parsed during arc pre-flight and passed through to the delegated command
at each phase. Arc itself does not act on them — it forwards them as-is.

| Parameter | Flags | Destination phases | Action |
|-----------|-------|--------------------|--------|
| `--dirs <csv>` | Directory include filter | Phase 6 (appraise), Phase 8 (audit) | **ADAPT** — Arc passes `--dirs` to the delegated command. Only applies to file-discovery phases. |
| `--exclude-dirs <csv>` | Directory exclude filter | Phase 6 (appraise), Phase 8 (audit) | **ADAPT** — Arc passes `--exclude-dirs` to the delegated command alongside `--dirs`. |
| `--prompt <string>` | Inline custom inspection criteria | Phase 6 (appraise), Phase 8 (audit) | **ADAPT** — Arc passes `--prompt` to the delegated command. The command resolves it via `resolveCustomPromptBlock()` in orchestration-phases.md. |
| `--prompt-file <path>` | File containing custom inspection criteria | Phase 6 (appraise), Phase 8 (audit) | **ADAPT** — Arc passes `--prompt-file` to the delegated command. Takes precedence over `--prompt` when both are set. |

### Phase 0 passthrough rules

- `--dirs` / `--exclude-dirs` feed into `dirScope` (parameter #20 in orchestration-phases.md). Arc resolves these at pre-flight for validation only — do NOT apply dir filtering to arc's own file discovery. Forward to delegated commands verbatim.
- `--prompt` / `--prompt-file` feed into `customPromptBlock` (parameter #21 in orchestration-phases.md). Arc does NOT modify prompt content. If `--prompt-file` is provided, validate the file exists at pre-flight (arc aborts early if missing); arc does NOT read the file contents — the delegated command reads it.
- Both sets of parameters are **SKIP** for arc phases that do not delegate to appraise/audit (forge, strive, mend, goldmask, etc.).
- Security: apply `SAFE_PATH_PATTERN` validation to `--prompt-file` path (same as other file path parameters). Block path traversal (`..`) and absolute paths outside the project root.

## Phase 1: FORGE → `/rune:forge`

Already explicit in arc-phase-forge.md. Listed here for completeness.

| Step | Action | Reason |
|------|--------|--------|
| Scope confirmation (forge Phase 3) | **SKIP** | Arc is automated — no user prompt |
| Post-enhancement options (forge Phase 6) | **SKIP** | Arc continues to Phase 2 automatically |
| Forge Gaze topic matching | **RUN** | Section-level agent selection |
| Codex Oracle detection | **RUN** | Per `codex-detection.md`, if `forge` in `talisman.codex.workflows` |
| Custom Ash loading | **RUN** | `ashes.custom[]` filtered by `workflows: [forge]` |

## Phase 2: PLAN REVIEW (independent implementation)

Arc Phase 2 does NOT delegate to `/rune:devise` Phase 4 — it creates its own team (see
arc-phase-plan-review.md). This section documents feature parity with plan-review.md.

| Step | Action | Reason |
|------|--------|--------|
| Scroll review (4A) | **RUN** | Arc summons scroll-reviewer (already implemented) |
| Iterative refinement (4B) | **SKIP** | Arc has Phase 2.5 (PLAN REFINEMENT) for concerns |
| Automated verification gate (4B.5) | **SKIP** | Arc has Phase 2.7 (VERIFICATION GATE) |
| Technical review — decree-arbiter (4C) | **RUN** | Arc summons decree-arbiter (already implemented) |
| Technical review — knowledge-keeper (4C) | **RUN** | Arc summons knowledge-keeper (already implemented) |
| Codex Plan Reviewer (4C) | **RUN** | Per `codex-detection.md`, if `plan` in `talisman.codex.workflows` |
| State Weaver (4C) | **RUN** | Arc summons state-weaver if `gates.state_weaver.enabled !== false`. Validates plan phase transitions and I/O contracts |
| Horizon Sage (4C) | **RUN** | Arc summons horizon-sage if `gates.horizon.enabled !== false` |
| Evidence Verifier (4C) | **RUN** | Arc summons evidence-verifier if `gates.evidence.enabled !== false` |
| Custom Ash for plan review | **SKIP** | No custom Ash workflow for plan review currently |

## Phase 5: WORK → `/rune:strive`

| Step | Action | Reason |
|------|--------|--------|
| Parse plan (work Phase 0) | **RUN** | Work needs to extract tasks from enriched plan |
| Environment setup (work Phase 0.5) | **ADAPT** | Branch already created by arc pre-flight; work detects and uses existing branch |
| Forge team (work Phase 1) | **RUN** | Work creates its own team |
| Codex Oracle detection | **RUN** | Per `codex-detection.md`, if `work` in `talisman.codex.workflows` |
| Session-scoped todos | **RUN** | No `--todos-dir` flag needed (removed). Strive detects arc context by scanning `.claude/arc/*/checkpoint.json` for `work` phase `in_progress` + `todos_base`. When found, redirects todos to `tmp/arc/{id}/todos/work/` instead of `tmp/work/{timestamp}/todos/work/` |

## Phase 6: CODE REVIEW (deep) → `/rune:appraise --deep`

| Step | Action | Reason |
|------|--------|--------|
| Branch detection | **ADAPT** | Arc already knows the branch; pass as context, but review still needs `default_branch` for diff |
| Default branch detection | **RUN** | Review needs this to compute diff base |
| Changed files scope building | **RUN** | Review needs file inventory for Ash assignment |
| Scope summary display | **SKIP** | Arc is automated — no user display needed |
| Abort conditions check | **RUN** | If no changed files, review should no-op gracefully |
| Custom Ash loading | **RUN** | `ashes.custom[]` filtered by `workflows: [review]` (no-op if none configured) |
| Codex Oracle detection | **RUN** | Per `codex-detection.md`, if `review` in `talisman.codex.workflows` |
| Session-scoped todos | **RUN** | No `--todos-dir` flag needed (removed). Roundtable-circle Phase 5.4 detects arc context by scanning `.claude/arc/*/checkpoint.json` for `code_review` phase `in_progress` + `todos_base`. When found, redirects todos to `tmp/arc/{id}/todos/review/` instead of `tmp/reviews/{id}/todos/review/` |

### Arc context adaptations for Phase 6

- `--deep` flag: **ALWAYS** — arc always passes `--deep` for multi-wave review (replaces former Phase 8 audit)
- Dry-run mode: **SKIP** — arc never does dry-run
- `--partial` flag: **SKIP** — arc always reviews full scope
- User-facing scope selection prompt: **SKIP** — arc is automated

## Phase 7: MEND → `/rune:mend`

| Step | Action | Reason |
|------|--------|--------|
| TOME path resolution | **ADAPT** | Arc provides TOME path from Phase 6 artifact |
| Parse TOME findings | **RUN** | Mend needs to group findings by file |
| Custom Ash for mend | **SKIP** | No custom Ash workflow for mend |
| Session-scoped todos | **RUN** | No `--todos-dir` flag needed (removed). Mend resolves `todos_base` via 3-step resolution (arc checkpoint → review state file → TOME path). In arc context, todos live at `tmp/arc/{id}/todos/review/` (created by appraise via arc context detection). Mend scans all source subdirectories for cross-source `finding_id` matching |

## Phase 2.5: PLAN REFINEMENT — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 2.7: VERIFICATION — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 2.8: SEMANTIC VERIFICATION → `codex-phase-handler` teammate

Delegated to codex-phase-handler teammate in team `arc-codex-sv-{id}`.

| Step | Action | Reason |
|------|--------|--------|
| Gate check (4 conditions + cascade breaker) | **RUN** | Tarnished checks before spawning teammate |
| TeamCreate + TaskCreate + Agent | **RUN** | Spawn codex-phase-handler with 2 parallel aspects (tech-deps, scope-timeline) |
| Codex execution | **SKIP** | Teammate handles via `codex-exec.sh -o` |
| Output aggregation | **SKIP** | Teammate aggregates aspect outputs into report |
| Metadata extraction | **SKIP** | Teammate extracts and sends via SendMessage |
| Checkpoint update | **ADAPT** | Tarnished updates checkpoint from teammate's metadata |
| Cascade tracker | **ADAPT** | Tarnished calls `updateCascadeTracker()` using teammate's `error_class` |
| Team cleanup | **RUN** | shutdown_request + TeamDelete with retry |
| Skip path (Codex unavailable) | **RUN** | Tarnished writes skip file directly — no team created |

## Phase 3: DESIGN EXTRACTION — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 4.5: TASK DECOMPOSITION → `codex-phase-handler` teammate

Delegated to codex-phase-handler teammate in team `arc-codex-td-{id}`.

| Step | Action | Reason |
|------|--------|--------|
| Gate check (4 conditions + cascade breaker) | **RUN** | Tarnished checks before spawning teammate |
| TeamCreate + TaskCreate + Agent | **RUN** | Spawn codex-phase-handler with single aspect (task validation) |
| Plan content sanitization | **ADAPT** | Teammate sanitizes plan content inline (10k char limit) per codex-phase-handler Content Sanitization rules |
| Codex execution | **SKIP** | Teammate handles via `codex-exec.sh -o` |
| CDX-TASK finding count extraction | **SKIP** | Teammate extracts and sends via SendMessage |
| Checkpoint update | **ADAPT** | Tarnished updates checkpoint from teammate's metadata |
| Cascade tracker | **ADAPT** | Tarnished calls `updateCascadeTracker()` using teammate's `error_class` |
| Team cleanup | **RUN** | shutdown_request + TeamDelete with retry |
| Skip path (Codex unavailable) | **RUN** | Tarnished writes skip file directly — no team created |

## Phase 5.2: DESIGN VERIFICATION — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 5.5: GAP ANALYSIS — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 5.6: CODEX GAP ANALYSIS → `codex-phase-handler` teammate

Delegated to codex-phase-handler teammate in team `arc-codex-ga-{id}`.

| Step | Action | Reason |
|------|--------|--------|
| Gate check (4 conditions + cascade breaker) | **RUN** | Tarnished checks before spawning teammate |
| TeamCreate + TaskCreate + Agent | **RUN** | Spawn codex-phase-handler with 2 parallel aspects (completeness, integrity) |
| Codex execution | **SKIP** | Teammate handles via `codex-exec.sh -o` |
| CDX-GAP finding count + remediation threshold | **SKIP** | Teammate computes `codex_needs_remediation` flag and sends via SendMessage |
| Checkpoint update | **ADAPT** | Tarnished updates checkpoint with `codex_needs_remediation`, `codex_finding_count`, `codex_threshold` from metadata |
| Cascade tracker | **ADAPT** | Tarnished calls `updateCascadeTracker()` using teammate's `error_class` |
| Team cleanup | **RUN** | shutdown_request + TeamDelete with retry |
| Skip path (Codex unavailable) | **RUN** | Tarnished writes skip file directly — no team created |

## Phase 5.8: GAP REMEDIATION → `/rune:*` (gap-fix team)

Delegated to the respective gap-fix team (`arc-gap-fix-{id}`). Uses the same RUN/SKIP/ADAPT delegation contract as Phase 5 (WORK).

| Step | Action | Reason |
|------|--------|--------|
| Team lifecycle | **RUN** | Gap remediation creates `arc-gap-fix-{id}` team with fixers |
| File scope | **ADAPT** | Scope limited to FIXABLE gaps from VERDICT.md (not full task list) |
| Codex Oracle detection | **SKIP** | Gap remediation does not use Codex Oracle |
| Session-scoped todos | **RUN** | Fixers write todos to `{workflowOutputDir}/todos/gap/` |

## Phase 5.7: GOLDMASK VERIFICATION → `/rune:goldmask`

Delegates to the standalone `/rune:goldmask` skill, which manages its own team and agents.

| Step | Action | Reason |
|------|--------|--------|
| Team lifecycle | **SKIP** | Goldmask skill creates/deletes its own team with `goldmask-` prefix |
| Agent summoning | **SKIP** | Goldmask skill summons its own investigation agents |
| Output collection | **RUN** | Arc copies `tmp/goldmask/GOLDMASK.md` → `tmp/arc/{id}/goldmask-verification.md` |
| Prediction comparison | **RUN** | If plan-time `risk-map.json` exists, compare predictions vs actuals |
| Cleanup | **ADAPT** | `prePhaseCleanup()` handles `goldmask-` prefixed teams via ARC_TEAM_PREFIXES |

### Arc context adaptations for Phase 5.7

- User-facing prompt: **SKIP** — arc is automated, goldmask runs silently
- Output path: **ADAPT** — copy goldmask output to arc artifact directory

## Phase 6.5: GOLDMASK CORRELATION (orchestrator-only)

Orchestrator-only phase — no delegation, no team creation. Reads Phase 5.7 + Phase 6 outputs.

| Step | Action | Reason |
|------|--------|--------|
| prePhaseCleanup | **SKIP** | Orchestrator-only, no team to clean |
| TOME path resolution | **ADAPT** | Use round-aware path (`tome-round-{N}.md`) for convergence cycles |
| Correlation logic | **RUN** | Deterministic file-level matching between TOME and Goldmask findings |
| Human review flagging | **RUN** | Caution >= 0.75 or WIDE blast radius → flag for Phase 7 mend |

### Convergence cycle behavior

On re-review rounds (`round > 0`), `goldmask_correlation` is reset to `pending` by verify-mend.md so it re-correlates with the new TOME. Goldmask verification is NOT re-run (blast radius doesn't change between mend cycles).

## Phase 7.5: VERIFY MEND — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 7.6: DESIGN ITERATION — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 7.7: TEST → `/rune:*` (test team)

Delegated to the respective test team (`arc-test-{id}`).

| Step | Action | Reason |
|------|--------|--------|
| Team lifecycle | **RUN** | Test phase creates `arc-test-{id}` team with test runners |
| Scope | **ADAPT** | Diff-scoped test execution (changed files only, not full suite) |
| E2E detection | **RUN** | Detects E2E tests and applies extended timeout (dynamic 40 min) |
| Session-scoped todos | **RUN** | Test runners write todos to `{workflowOutputDir}/todos/test/` |

## Phase 7.8: TEST COVERAGE CRITIQUE → `codex-phase-handler` teammate

Delegated to codex-phase-handler teammate in team `arc-codex-tc-{id}`.

| Step | Action | Reason |
|------|--------|--------|
| Gate check (4 conditions + cascade breaker) | **RUN** | Tarnished checks before spawning teammate |
| TeamCreate + TaskCreate + Agent | **RUN** | Spawn codex-phase-handler with single aspect (test critique) |
| Codex execution | **SKIP** | Teammate handles via `codex-exec.sh -o` |
| CDX-TEST finding count extraction | **SKIP** | Teammate extracts and sends via SendMessage |
| Checkpoint update | **ADAPT** | Tarnished updates checkpoint from teammate's metadata |
| Cascade tracker | **ADAPT** | Tarnished calls `updateCascadeTracker()` using teammate's `error_class` |
| Team cleanup | **RUN** | shutdown_request + TeamDelete with retry |
| Skip path (Codex unavailable) | **RUN** | Tarnished writes skip file directly — no team created |

## Phase 8.5: PRE-SHIP VALIDATION — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 8.55: RELEASE QUALITY CHECK → `codex-phase-handler` teammate

Delegated to codex-phase-handler teammate in team `arc-codex-rq-{id}`.

| Step | Action | Reason |
|------|--------|--------|
| Gate check (4 conditions + cascade breaker) | **RUN** | Tarnished checks before spawning teammate |
| TeamCreate + TaskCreate + Agent | **RUN** | Spawn codex-phase-handler with single aspect (release quality) |
| Codex execution | **SKIP** | Teammate handles via `codex-exec.sh -o` |
| CDX-RELEASE finding count extraction | **SKIP** | Teammate extracts and sends via SendMessage |
| Checkpoint update | **ADAPT** | Tarnished updates checkpoint from teammate's metadata |
| Cascade tracker | **ADAPT** | Tarnished calls `updateCascadeTracker()` using teammate's `error_class` |
| Team cleanup | **RUN** | shutdown_request + TeamDelete with retry |
| Skip path (Codex unavailable) | **RUN** | Tarnished writes skip file directly — no team created |

## Phase 9.1: BOT REVIEW WAIT — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 9.2: PR COMMENT RESOLUTION — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 9: SHIP — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

## Phase 9.5: MERGE — ORCHESTRATOR-ONLY

No delegation. Runs inline in arc orchestrator context.

- **Delegation**: None (orchestrator-only)
- **Pre-flight steps**: N/A
- **Post-phase cleanup**: Standard checkpoint update

<!-- Phase 8 (AUDIT) delegation removed in v1.67.0. Audit coverage is now handled by
     Phase 6 `/rune:appraise --deep` (multi-wave review with investigation + dimension Ashes).
     See arc-phase-code-review.md for the updated delegation contract. -->
