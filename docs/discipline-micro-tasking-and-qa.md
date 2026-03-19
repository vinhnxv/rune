# Discipline Engineering: Micro-Tasking & Inter-Phase QA

## Addendum to Discipline Engineering v2.3.0

> *Extends the foundational Discipline Engineering document with two systems:
> (1) File-based micro-task delegation with mutual accountability, and
> (2) Independent inter-phase QA gates for arc pipeline integrity verification.*

**Version**: 1.0.0
**Date**: 2026-03-19
**Status**: Planned — Implementation pending
**Parent Document**: [discipline-engineering.md](discipline-engineering.md)
---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [Micro-Tasking Model](#2-micro-tasking-model)
3. [File-Based Delegation Protocol](#3-file-based-delegation-protocol)
4. [Teammate Discipline Loop](#4-teammate-discipline-loop)
5. [Team Lead Verification Loop](#5-team-lead-verification-loop)
6. [Mutual Skepticism Protocol](#6-mutual-skepticism-protocol)
7. [Worker Communication Protocol](#7-worker-communication-protocol)
8. [Inter-Phase QA Gates](#8-inter-phase-qa-gates)
9. [QA Scoring System](#9-qa-scoring-system)
10. [Stop Hook Loop-Back Mechanism](#10-stop-hook-loop-back-mechanism)
11. [Cumulative QA Dashboard](#11-cumulative-qa-dashboard)
12. [Trust Model](#12-trust-model)
13. [Configuration Reference](#13-configuration-reference)
14. [Failure Modes & Recovery](#14-failure-modes--recovery)

---

## 1. Design Philosophy

### 1.1 Everything is a File

The team lead (Tarnished/orchestrator) delegates work by creating physical files on disk. Each worker reads their files before starting. Each worker writes back to their files when done. No implicit state — everything is observable on the filesystem.

This principle exists because:
- **Auditability**: Every decision, assignment, and report is a readable file
- **Reproducibility**: Workflow can be reconstructed from disk artifacts alone
- **Debuggability**: When something goes wrong, files show exactly what happened
- **Anti-hallucination**: Claims without file evidence are treated as hallucination

### 1.2 Trust Nothing, Verify Everything

Every agent in the system — team lead, workers, and QA agents — operates under **mutual skepticism**. Nobody trusts anybody blindly. Every claim requires evidence. Every completion requires proof. Every instruction can be questioned.

This is not distrust for its own sake — it's engineering discipline. LLM agents hallucinate. Plans can be wrong. Workers can misunderstand. The only defense is structured verification at every level.

### 1.3 Separation of Execution and Evaluation

The entity that performs work must NOT be the entity that evaluates it. This applies at every level:

| Executor | Evaluator | Mechanism |
|----------|-----------|-----------|
| Worker | Worker itself | Self-Review Checklist (first layer) |
| Worker | Team Lead | Report Verification (second layer) |
| Team Lead | QA Agents | Inter-Phase QA Gate (third layer) |
| QA Agents | Human | Dashboard review + escalation (final layer) |

---

## 2. Micro-Tasking Model

### 2.1 What is Micro-Tasking?

Each teammate receives a **small, well-defined scope of work** — not a vague "implement feature X." A micro-task has:

- **Explicit scope**: Which files to modify, which to leave alone
- **Acceptance criteria**: What "done" looks like (checkable, not subjective)
- **Constraints**: What NOT to do (non-goals, blocked files)
- **Evidence requirements**: What proof to collect

A micro-task is small enough that one worker can:
1. Fully understand it before starting
2. Complete it in one session
3. Self-verify it against all criteria
4. Report on it with concrete evidence

### 2.2 Why Micro-Tasking?

Large tasks fail silently. When a worker receives "implement the auth system" (10 files, 5 ACs), it will:
- Address 60-70% of criteria
- Skip edge cases
- Mark itself "done" with generic evidence
- Not realize it missed anything

When the same work is split into 5 micro-tasks (2 files, 1-2 ACs each), each task:
- Can be fully verified against its specific AC
- Produces targeted evidence
- Fails loudly when incomplete (TaskCompleted hook catches it)
- Can be retried independently without re-doing everything

### 2.3 Micro-Task Lifecycle

```
PENDING → CLAIMED → CRITICAL_REVIEW → IN_PROGRESS → SELF_REVIEW → DONE
                        ↓                                  ↓
                    CHALLENGED                          STUCK
                    (task wrong)                     (cannot finish)
```

---

## 3. File-Based Delegation Protocol

### 3.1 Directory Structure

Every strive run produces this file structure:

```
tmp/work/{timestamp}/
├── delegation-manifest.json     # Master manifest: who does what
├── tasks/                       # Task definition files (1 per task)
│   ├── task-1.1.md
│   ├── task-1.2.md
│   └── task-2.1.md
├── prompts/                     # Worker prompt files (1 per worker)
│   ├── rune-smith-w0-1.md
│   └── rune-smith-w0-2.md
├── context/                     # Scope-of-work files (1 per worker)
│   ├── rune-smith-w0-1.md
│   └── rune-smith-w0-2.md
├── evidence/                    # Per-task evidence
│   ├── 1.1/summary.json
│   └── 2.1/summary.json
├── coverage-matrix.json         # Plan AC → Task mapping verification
├── report-verification.json     # Post-completion report quality check
├── patches/                     # Commit patches
├── worker-logs/                 # Per-worker session logs
├── drift-signals/               # Plan-reality mismatch signals
└── convergence/                 # Convergence loop artifacts
```

### 3.2 Delegation Manifest

The master record of who is assigned what:

```json
{
  "timestamp": "20260319-144026",
  "plan": "plans/2026-03-19-fix-plan.md",
  "total_tasks": 12,
  "total_workers": 3,
  "waves": 2,
  "workers": [
    {
      "name": "rune-smith-w0-1",
      "role": "implementation",
      "wave": 0,
      "tasks": ["1.1", "1.2", "2.1"],
      "file_targets": ["src/auth.ts", "src/auth/middleware.ts"],
      "context_file": "tmp/work/.../context/rune-smith-w0-1.md",
      "prompt_file": "tmp/work/.../prompts/rune-smith-w0-1.md",
      "task_files": [
        "tmp/work/.../tasks/task-1.1.md",
        "tmp/work/.../tasks/task-1.2.md",
        "tmp/work/.../tasks/task-2.1.md"
      ]
    }
  ],
  "communications": [],
  "created_at": "2026-03-19T14:40:00Z"
}
```

### 3.3 Task File Schema

Each task file (`tmp/work/{ts}/tasks/task-{id}.md`):

```yaml
---
task_id: "1.1"
plan_file: "plans/my-feature-plan.md"
plan_section: "### Task 1.1"
status: PENDING          # PENDING → IN_PROGRESS → DONE / STUCK
assigned_to: null        # Worker name when claimed
iteration: 0             # Re-attempt count
risk_tier: 1             # 0=Grace, 1=Ember, 2=Rune, 3=Elden
proof_count: 3           # Number of ACs to verify
created_at: "2026-03-19T12:00:00Z"
updated_at: "2026-03-19T12:00:00Z"
completed_at: null
---

## Source
(Verbatim task description from plan)

## Acceptance Criteria
(AC items this task must satisfy)

## File Targets
(Files this worker is allowed to modify)

## Context
(Additional context: sibling tasks, shared state, constraints)

## Worker Report
(Filled by worker — see Teammate Discipline Loop)
```

### 3.4 Context File Schema

Each worker's scope-of-work (`tmp/work/{ts}/context/{worker}.md`):

```yaml
---
worker: "rune-smith-w0-1"
team: "rune-work-{timestamp}"
wave: 0
role: "implementation"
assigned_tasks: ["1.1", "1.2", "2.1"]
file_targets: ["src/auth.ts", "src/auth/middleware.ts"]
blocked_files: ["src/config.ts"]
---

# Scope of Work — rune-smith-w0-1

## Your Assignments
(Table: Task ID, Description, Risk, Files, AC Count)

## Your Task Files
(Paths to read BEFORE starting)

## Constraints
(What NOT to do)

## Non-Goals
(From plan non-goals section)

## Report Back
(How to complete: update task file, write evidence, TaskUpdate)
```

---

## 4. Teammate Discipline Loop

The inner loop every worker executes for EVERY micro-task:

```
┌───────────────────────────────────────────────────┐
│            TEAMMATE DISCIPLINE LOOP                │
│                                                     │
│  1. RECEIVE & READ                                  │
│     Read context file → Read task file              │
│     Understand: What am I being asked to do?        │
│                                                     │
│  2. CRITICAL REVIEW (before any code)               │
│     ├─ Is this task correct?                        │
│     ├─ Do plan references actually exist?           │
│     ├─ Could the team lead be hallucinating?        │
│     ├─ Are there potential bugs or side effects?    │
│     └─ If concern → CHALLENGE or QUESTION           │
│                                                     │
│  3. ECHO-BACK                                       │
│     Paraphrase each AC in own words                 │
│     Write to task file ## Worker Report             │
│                                                     │
│  4. IMPLEMENT                                       │
│     TDD cycle: test → code → refactor               │
│     Stay within file_targets scope                  │
│                                                     │
│  5. SELF-REVIEW (mandatory)                         │
│     ├─ Did I implement ALL criteria?                │
│     ├─ Did I stay within scope?                     │
│     ├─ Could my changes break anything?             │
│     ├─ Is my evidence concrete (file:line refs)?    │
│     └─ Run checklist → write to task file           │
│                                                     │
│  6. EVIDENCE COLLECTION                             │
│     Write evidence/{task-id}/summary.json           │
│     Must be CONCRETE — generic claims rejected      │
│                                                     │
│  7. COMPLETENESS CHECK                              │
│     100% → proceed to report                        │
│     Fixable gaps → loop to step 4                   │
│     Stuck → STUCK REPORT (explain WHY)              │
│                                                     │
│  8. FINAL REPORT                                    │
│     Update task file: status=DONE, Worker Report    │
│     TaskUpdate(completed) — ONLY after all above    │
│                                                     │
└───────────────────────────────────────────────────┘
```

### 4.1 Self-Review Checklist

Every worker runs this BEFORE marking any task complete:

```markdown
### Self-Review Checklist
- [ ] I read the task file and understood every AC before coding
- [ ] I verified that plan references actually exist in the codebase
- [ ] I implemented ALL acceptance criteria (check each one)
- [ ] I stayed within my file_targets scope
- [ ] My changes don't break existing functionality
- [ ] I checked for edge cases and potential bugs
- [ ] My evidence is CONCRETE (file:line references, not generic claims)
- [ ] I would trust this work if someone else submitted it to me
```

Pass count:
- 8/8 → proceed to completion
- 7/8 → fix the failing item, re-check
- < 7/8 → significant gaps — loop back to implementation

### 4.2 Worker Report Format

```markdown
## Worker Report

### Critical Review
- Plan references verified: YES/NO — what was checked
- Potential risks identified: list or "none"
- Decision: PROCEED / CHALLENGE / QUESTION

### Echo-Back
- AC-1: I will [paraphrase in own words]
- AC-2: I will [paraphrase]

### Implementation Notes
- What was changed and why
- Any deviations from plan

### Evidence
| AC | Status | Evidence |
|----|--------|----------|
| AC-1 | PASS | src/auth.ts:45 — validateJWT() reads header |

### Self-Review Checklist
- [x] item 1...

### Critical Findings
- Issues discovered during implementation

### Time Spent
- Critical review: N min
- Implementation: N min
- Self-review: N min
```

### 4.3 Stuck Report

When a worker cannot complete a task:

```markdown
### Stuck Report
status: STUCK
reason: PLAN_WRONG | PLAN_HALLUCINATED | DEPENDENCY_MISSING |
        SCOPE_TOO_LARGE | BLOCKED_BY_BUG | FALSE_POSITIVE
detail: (specific explanation with evidence)
attempted: (what was tried before getting stuck)
suggestion: (what should happen next)
```

Reasons explained:
- **PLAN_WRONG**: Plan describes behavior that contradicts codebase reality
- **PLAN_HALLUCINATED**: Plan references function/file/API that doesn't exist
- **DEPENDENCY_MISSING**: Task depends on work not yet done
- **SCOPE_TOO_LARGE**: Task should be split into smaller pieces
- **BLOCKED_BY_BUG**: Pre-existing bug prevents implementation
- **FALSE_POSITIVE**: The problem the task addresses doesn't exist

---

## 5. Team Lead Verification Loop

The outer loop the Tarnished executes:

```
PRE-DELEGATION (Phase 1):
  1. Parse plan → extract ALL tasks and ACs
  2. Create task files, context files, prompt files
  3. COVERAGE MATRIX: plan ACs ↔ task files (no gaps allowed)
  4. Write delegation-manifest.json

DURING EXECUTION (Phase 3):
  5. Monitor progress via TaskList
  6. Handle worker QUESTION/CHALLENGE/STUCK messages
  7. Relay blocking questions to human via AskUserQuestion

POST-COMPLETION (Phase 4):
  8. Read each Worker Report — check quality:
     a. Echo-Back substantive? (not copied verbatim)
     b. Evidence concrete? (file:line refs, not generic)
     c. Self-Review complete? (items checked)
     d. Critical Findings present?
  9. FINAL COVERAGE: every plan AC → completed task
  10. If gaps: assign new tasks or spawn additional workers
```

### 5.1 Coverage Matrix

```json
{
  "mapped": ["AC-1", "AC-2", "AC-3"],
  "unmapped": [],
  "fabricated": []
}
```

- **mapped**: AC exists in both plan and task files
- **unmapped**: AC in plan but NOT in any task → DELEGATION ERROR
- **fabricated**: AC in task but NOT in plan → HALLUCINATION

Hard rule: Workers must NOT be spawned until `unmapped.length === 0`.

---

## 6. Mutual Skepticism Protocol

### 6.1 Worker Skepticism (toward Team Lead)

Workers actively question their assignments:

- "Is this task actually needed?"
- "Does this reference actually exist in the codebase?"
- "Could the plan be hallucinating this API/function?"
- "Is the scope correct or impossibly large?"

If a concern is found → worker sends CHALLENGE message with evidence.

### 6.2 Team Lead Skepticism (toward Workers)

The Tarnished actively verifies worker output:

- "Did the worker actually do the work or just mark it done?"
- "Is the evidence real or generic filler?"
- "Did the worker stay within scope?"
- "Are there side effects the worker didn't mention?"

If a concern is found → send REVIEW-REQUIRED message back to worker.

### 6.3 Why Mutual Skepticism?

LLM agents exhibit predictable failure modes:

| Agent | Failure Mode | Defense |
|-------|-------------|---------|
| Team Lead | Delegates based on hallucinated plan references | Workers verify references in Critical Review |
| Workers | Mark done without implementing all ACs | Self-Review Checklist + TaskCompleted hook |
| Workers | Produce generic evidence ("it works") | Quality check requires file:line refs |
| Team Lead | Skips coverage verification | Coverage matrix is mandatory, hard-coded |
| Both | "Going through the motions" | QA agents detect patterns externally |

---

## 7. Worker Communication Protocol

Workers communicate with the Tarnished via SendMessage:

| Type | When | Blocking? | Max per task |
|------|------|-----------|-------------|
| **QUESTION** | Need clarification | Yes — wait for answer | 3 |
| **CHALLENGE** | Task seems wrong | Yes — wait for decision | 1 |
| **STUCK** | Cannot complete | Yes — wait for guidance | 1 |
| **CONCERN** | Potential issue | No — continue working | Unlimited |

### Message Formats

```
QUESTION task-{id}: {question}
CONTEXT: {what you know}
OPTIONS: A: ... B: ...

CHALLENGE task-{id}: {why task is wrong}
EVIDENCE: {proof}
SUGGESTION: {alternative}

STUCK task-{id}: {why can't complete}
ATTEMPTED: {what was tried}
SUGGESTION: {next steps}

CONCERN task-{id}: {potential issue}
IMPACT: {risk level}
```

---

## 8. Inter-Phase QA Gates

### 8.1 The Problem

Arc's phase transition is blind trust. The Tarnished marks a phase "completed" → stop hook advances → nobody verifies the output. Self-evaluation by the executor is a conflict of interest.

### 8.2 The Foundation: Three Documents Per Phase

Before QA can verify anything, it needs a **source of truth**. Three documents work together:

| Document | Written by | When | Purpose |
|----------|-----------|------|---------|
| **Phase Process Manifest** | Developer (committed to repo) | Before any arc runs | Defines what SHOULD happen: steps, order, artifacts, success criteria |
| **Phase Execution Log** | Tarnished (during execution) | During the phase | Records what DID happen: which steps ran, artifacts produced, notes |
| **QA Verdict** | QA Agent (after phase) | After phase completes | Compares manifest vs execution log vs actual filesystem |

```
Phase Process Manifest          Phase Execution Log         Filesystem
(what SHOULD happen)            (what Tarnished CLAIMS)     (what ACTUALLY exists)
         │                              │                          │
         └──────────────┬───────────────┘                          │
                        │                                          │
                   QA Agent compares ◄─────────────────────────────┘
                        │
                   Verdict + Score
```

### 8.2.1 Phase Process Manifest

A YAML file committed to the repo that defines the **exact process** for each phase. QA agents read this as their checklist.

Location: `plugins/rune/skills/arc/references/qa-manifests/{phase}.yaml`

```yaml
phase: work
purpose: |
  Parse plan into micro-tasks, create physical delegation files,
  spawn worker agents, monitor execution, verify completion.

defined_in: plugins/rune/skills/arc/references/arc-phase-work.md

steps:
  - id: WRK-STEP-01
    name: "Parse plan into tasks"
    required: true
    order: 1
    artifact: null
    description: "Extract tasks from enriched plan"

  - id: WRK-STEP-02
    name: "Create task files"
    required: true
    order: 2
    artifact: "tmp/work/{ts}/tasks/task-*.md"
    artifact_check: "count matches plan task count"

  # ... (all steps defined with order + artifact)

success_criteria:
  - "All required steps executed in order"
  - "All artifacts exist and pass checks"
  - "Coverage matrix has zero unmapped ACs"
```

### 8.2.2 Phase Execution Log

Written by the Tarnished **during** phase execution. Records every step as it happens.

Location: `tmp/arc/{id}/execution-logs/{phase}-execution.json`

```json
{
  "phase": "work",
  "manifest": "qa-manifests/work.yaml",
  "started_at": "2026-03-19T14:00:00Z",
  "steps": [
    {
      "id": "WRK-STEP-01",
      "status": "completed",
      "started_at": "...",
      "completed_at": "...",
      "artifact_produced": "12 tasks extracted",
      "notes": "Used enriched plan, AC mapping complete"
    }
  ],
  "skipped_steps": [],
  "completed_steps": 11,
  "total_steps": 11,
  "completion_pct": 100
}
```

**Key rule**: The Tarnished MUST write an execution log entry for EVERY manifest step — even skipped ones (with reason). QA will flag steps that appear in the manifest but not in the log.

### 8.2.3 What QA Verifies (The Full Checklist)

QA agents answer these questions by comparing the 3 documents:

1. **Purpose**: What is this phase supposed to do? (from manifest)
2. **Step definitions**: Where are the steps defined? (manifest references source file)
3. **Evidence of work**: For each step, is there an artifact on disk? (filesystem check)
4. **Process compliance**: Did the phase follow the defined step order? (execution log vs manifest order)
5. **Skipped steps**: Were any required steps skipped? (manifest required=true but missing from log)
6. **Team lead compliance**: Did the Tarnished follow the defined process? (log completeness)
7. **Completion percentage**: How many steps completed out of total? (log.completed_steps / manifest.total_steps)
8. **Documentation completeness**: Are all expected files present after phase? (artifact checks from manifest)
9. **Content quality**: Are artifacts substantive or generic filler? (read + analyze content)
10. **Consistency**: Does the execution log match filesystem reality? (log claims vs actual files)

### 8.3 The Solution

At the end of each significant phase, **independent QA agents** verify the output before the pipeline advances.

```
Phase N → Tarnished executes
  ↓
QA Gate → 3 independent agents verify:
  ├── Artifact Verifier  (files exist? valid?)
  ├── Quality Verifier   (content real? not filler?)
  └── Completeness       (all requirements covered?)
  ↓
Score ≥ 70 → advance to Phase N+1
Score < 70 → LOOP BACK → re-execute Phase N (max 2 retries)
             → after 2 fails → human escalation
```

### 8.3 QA-Gated Phases

| Phase | QA? | Why |
|-------|-----|-----|
| forge | Yes | Must add real content, not copy-paste |
| work | **Yes** | Most critical — verify task files, reports, evidence |
| code_review | Yes | Findings must reference real code |
| mend | Yes | Must actually fix findings |
| test | Yes | Must actually run tests |
| gap_analysis | Yes | Must find real gaps, not hallucinate |
| ship/merge | No | Mechanical — no quality dimension |
| verification | No | Already a verification step |

### 8.4 QA Agent Properties

- **Independent**: Separate team, separate context from Tarnished
- **Read-only**: Can Read, Glob, Grep — cannot Write, Edit, or modify code
- **Binding**: Verdict cannot be overridden by team lead
- **Evidence-based**: Every check item has evidence for its score
- **Phase-specific**: Each phase has its own **dedicated QA agent** with domain expertise

### 8.5 Per-Phase QA Agents (Not Generic)

Each gated phase has its **own QA agent** — not 3 generic agents shared across all phases.

| Phase | Agent | Domain Expertise |
|-------|-------|-----------------|
| forge | `forge-qa-verifier` | Plan enrichment quality — detects copy-paste, verifies new content references codebase |
| work | `work-qa-verifier` | Task delegation & worker output — task files, Worker Reports, evidence quality, coverage matrix |
| code_review | `code-review-qa-verifier` | Review findings — verifies file:line refs exist in codebase, actionable findings, coverage of changed files |
| mend | `mend-qa-verifier` | Fix resolution — maps findings to code changes, verifies P1/P2 addressed |
| test | `test-qa-verifier` | Test execution — proves tests actually ran (runner output, timestamps, not just "all pass") |
| gap_analysis | `gap-analysis-qa-verifier` | Gap detection — verifies gaps are real (not hallucinated), no real gaps missed |

**Why per-phase**: A generic "quality verifier" doesn't know what "quality" means for a TOME vs. a test report vs. a delegation manifest. Phase-specific agents understand the **exact output** they're verifying.

### 8.6 QA Report Per Phase

Each QA gate produces 3 files:
- `tmp/arc/{id}/qa/{phase}-verdict.json` — machine-readable scores and per-check results
- `tmp/arc/{id}/qa/{phase}-report.md` — human-readable report (format below)
- `tmp/arc/{id}/execution-logs/{phase}-execution.json` — written by Tarnished DURING phase (input to QA)

### 8.7 QA Report Format

```markdown
# QA Report — Phase: {phase_name}

## 1. Phase Purpose
{From manifest: what is this phase supposed to do?}

## 2. Process Definition
- Manifest: `qa-manifests/{phase}.yaml`
- Reference: `{manifest.defined_in}`
- Total steps: {N}
- Required steps: {N}

## 3. Process Compliance

| Step | Name | Required | Status | Artifact | Evidence |
|------|------|----------|--------|----------|----------|
| WRK-STEP-01 | Parse plan into tasks | YES | DONE | — | 12 tasks extracted |
| WRK-STEP-02 | Create task files | YES | DONE | tasks/task-*.md | 12 files verified on disk |
| WRK-STEP-03 | Create context files | YES | **SKIPPED** | — | **NOT FOUND in execution log** |

### Skipped Steps
- WRK-STEP-03: REQUIRED step skipped — context files not created
  → Remediation: Team lead must create context files before spawning workers

### Step Order Compliance
Expected order: 01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11
Actual order:   01 → 02 → 04 → 05 → 07 → 08 → 10 → 11
Verdict: FAIL — steps 03, 06, 09 skipped; step 04 ran before 03

## 4. Artifact Verification

| Artifact | Expected | Found | Content Check | Score |
|----------|----------|-------|---------------|-------|
| task files | 12 files | 12 files | YAML frontmatter present | 100 |
| context files | 3 files | 0 files | — | 0 |
| prompt files | 3 files | 3 files | >50 lines each | 100 |
| delegation manifest | 1 file | 1 file | valid JSON, 3 workers | 100 |
| coverage matrix | 1 file | 0 files | — | 0 |
| work summary | 1 file | 1 file | 45 lines | 100 |

## 5. Content Quality

| Check | Score | Evidence |
|-------|-------|----------|
| Worker Reports not empty | 90 | 11/12 task files have >5 lines in Worker Report |
| Evidence has file:line refs | 75 | 9/12 task files have file:line pattern |
| Self-Review completed | 85 | 10/12 have [x] items |
| No "going through motions" | 60 | task-2.1.md uses "implemented as planned" without refs |
| Critical Review exists | 80 | 10/12 have ### Critical Review |

## 6. Completeness

| Check | Score | Evidence |
|-------|-------|----------|
| All plan ACs mapped | 0 | coverage-matrix.json NOT FOUND — cannot verify |
| All tasks status DONE | 100 | 12/12 task files have status: DONE |
| git diff shows changes | 100 | 15 files changed, 420 insertions |
| Manifest matches workers | 100 | 3 workers in manifest, 3 workers in phase-log |

## 7. Score Summary

| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|----------|
| Artifact | 67/100 | 30% | 20.1 |
| Quality | 78/100 | 40% | 31.2 |
| Completeness | 75/100 | 30% | 22.5 |
| **Overall** | **73.8/100** | | |

## 8. Verdict: PASS (73.8/100)

### Warnings (non-blocking)
- WRK-STEP-03 skipped: context files not created
- WRK-STEP-06 skipped: coverage matrix not generated
- task-2.1.md has generic evidence

### Process Compliance Score
- Steps executed: 8/11 (72.7%)
- Required steps executed: 8/11 (72.7%)
- Order compliance: PARTIAL — 3 steps out of order

## 9. Remediation (if score < 70)
{Specific instructions for what to fix on retry}

## 10. Timestamp
Generated: 2026-03-19T15:30:00Z
```

### 8.8 What Team Lead and Teammates Must Do for QA

For QA to work, everyone must **leave evidence**:

| Role | Must Do | File |
|------|---------|------|
| **Team Lead** | Write execution log entry per step | `execution-logs/{phase}-execution.json` |
| **Team Lead** | Create all artifacts listed in manifest | Various (task files, context, manifest, etc.) |
| **Team Lead** | Log skipped steps with reason | `execution-logs/{phase}-execution.json` |
| **Teammate** | Write Worker Report to task file | `tasks/task-{id}.md` |
| **Teammate** | Write evidence JSON | `evidence/{task-id}/summary.json` |
| **Teammate** | Complete Self-Review checklist | `tasks/task-{id}.md` |
| **Teammate** | Log concerns/questions | Via SendMessage (logged to manifest) |

**The principle**: If you didn't write it down, it didn't happen. QA can only verify what's on disk.

### 8.9 QA as Shared Rules — Not Just Verification

QA manifests are NOT "documents for the QA agent." They are the **process definition** that ALL agents must follow. The manifest is the single source of truth for:
- What steps the Tarnished must execute
- What workers must produce
- What QA verifies

This means every agent must be **aware** of QA rules:

#### Tarnished Awareness (injected via arc SKILL.md)

The Tarnished reads a QA Discipline Protocol block at arc start:

```markdown
YOUR OBLIGATIONS as Team Lead:
1. READ the manifest BEFORE starting a gated phase
2. EXECUTE every required step in order
3. WRITE execution log entry after each step
4. CREATE every artifact listed in the manifest
5. NEVER skip a required step without logging a reason
6. WRITE execution log BEFORE marking phase completed
```

The Tarnished knows: "QA will compare my execution log against the manifest. Mismatch = FAIL = loop back."

#### Worker Awareness (injected via worker-prompts.md)

Workers receive a QA Awareness block in their prompt:

```markdown
QA CHECKS YOUR OUTPUT FOR:
- Worker Report with all subsections filled
- Evidence with file:line references
- Self-Review with checked items
- Critical Review showing you questioned the task

PATTERNS THAT TRIGGER QA FAIL:
- Generic phrases without refs
- Copy-paste template text
- Evidence citing non-existent file:line
```

Workers know: "QA will score my output. Score < 70 = phase loops back = I redo."

#### QA Agent Input (injected via orchestration logic)

QA agents receive manifest + execution log as prompt content:

```
Phase Process Manifest: (what SHOULD have happened)
Phase Execution Log: (what Team Lead CLAIMS happened)
Your Job: Compare manifest vs log vs filesystem
```

QA knows: "I have the complete picture — expected, claimed, and actual."

### 8.10 The QA Triad

```
        MANIFEST (rules)
         /          \
        /            \
TARNISHED          WORKERS
reads manifest     read QA awareness
writes exec log    write reports + evidence
  \                  /
   \                /
    QA AGENT
    reads manifest + log + filesystem
    scores 0-100
    verdict: advance or loop back
```

All three sides of the triad reference the same manifest. Nobody can claim ignorance of the rules.

---

## 9. QA Scoring System

### 9.1 Three Dimensions

| Dimension | What it measures |
|-----------|-----------------|
| **Artifact** | Do output files exist? Valid format? Non-empty? |
| **Quality** | Is content substantive? Real evidence? No filler? |
| **Completeness** | All requirements covered? No missing steps? |

### 9.2 Score Scale

| Score | Label | Action |
|-------|-------|--------|
| 90-100 | EXCELLENT | Advance — no issues |
| 70-89 | PASS | Advance — warnings logged |
| 50-69 | MARGINAL | Retry once with remediation context |
| 0-49 | FAIL | Retry up to 2×, then human escalation |

### 9.3 Dimension Weights

| Phase | Artifact | Quality | Completeness |
|-------|----------|---------|--------------|
| work | 30% | **40%** | 30% |
| forge | 20% | **50%** | 30% |
| code_review | 30% | 30% | **40%** |
| mend | 30% | 30% | **40%** |
| test | **40%** | 30% | 30% |

Formula: `overall = artifact × w_a + quality × w_q + completeness × w_c`

### 9.4 Per-Check Scoring

Each check item: 0-100
- **100**: Fully satisfied, strong evidence
- **75**: Satisfied, evidence could be stronger
- **50**: Partially satisfied, issues found
- **25**: Mostly unsatisfied, significant gaps
- **0**: Missing or completely wrong

Dimension score = average of its check items.

### 9.5 "Going Through the Motions" Detection

The Quality Verifier specifically watches for:

| Pattern | Example | Score Penalty |
|---------|---------|---------------|
| Generic claims | "implemented as planned" | -50 (score: 50 max) |
| Self-referential evidence | "I verified this works" | -50 |
| Copy-paste boilerplate | Template text unmodified | -75 |
| Hallucinated references | file:line that doesn't exist | -100 (score: 0) |
| Inflated self-review | All [x] but evidence doesn't support | -50 |
| Placeholder text | "TODO", "TBD" in completed sections | -75 |

---

## 10. Stop Hook Loop-Back Mechanism

### 10.1 Current Behavior (No QA)

```
Stop Hook:
  1. Read checkpoint.json
  2. Find next "pending" phase
  3. Inject prompt → advance
```

### 10.2 New Behavior (With QA)

```
Stop Hook:
  1. Read checkpoint.json
  2. Was previous phase a *_qa phase?
     YES → Read verdict file
       Score ≥ 70? → Find next pending phase → advance
       Score < 70 AND retries < 2?
         → Revert parent phase to "pending"
         → Inject remediation context
         → Loop back (phase re-executes)
       Score < 70 AND retries ≥ 2?
         → Human escalation prompt
     NO → Normal advance
```

### 10.3 Remediation Context

When QA fails and the phase loops back, the re-execution receives specific feedback:

```markdown
## QA REMEDIATION (Retry 1/2)

Previous execution scored 55/100 (MARGINAL). Fix these issues:

### Failed Checks
- WRK-ART-01: Only 8/12 task files found (expected 12)
- WRK-QUA-03: task-2.1.md has generic evidence without file:line refs
- WRK-CMP-01: AC-5 and AC-7 not mapped to any task

### Required Actions
1. Create missing task files for tasks 3.1, 3.2, 4.1, 4.2
2. Worker for task-2.1 must rewrite Evidence section
3. Create tasks for uncovered AC-5 and AC-7
```

---

## 11. Cumulative QA Dashboard

At arc completion, all QA verdicts aggregate into a single dashboard:

```json
{
  "arc_id": "arc-1773901571027",
  "arc_quality_score": 87.6,
  "workflow_integrity": "VERIFIED",
  "total_retries": 0,
  "phases_qa_summary": [
    { "phase": "forge", "score": 92, "verdict": "EXCELLENT", "retries": 0 },
    { "phase": "work", "score": 89, "verdict": "PASS", "retries": 0 },
    { "phase": "code_review", "score": 78, "verdict": "PASS", "retries": 0 },
    { "phase": "mend", "score": 85, "verdict": "PASS", "retries": 0 },
    { "phase": "test", "score": 94, "verdict": "EXCELLENT", "retries": 0 }
  ]
}
```

### Workflow Integrity Levels

| Level | Meaning | Condition |
|-------|---------|-----------|
| **VERIFIED** | Pipeline ran correctly | All phases ≥ 70, ≤ 1 retry per phase |
| **DEGRADED** | Issues occurred but resolved | Some phases 50-69 or needed retries |
| **COMPROMISED** | Pipeline quality uncertain | Any phase needed human escalation or skip |

Dashboard is embedded in PR body for human reviewers.

---

## 12. Trust Model

### Four Layers of Verification

```
Layer 1: SELF-REVIEW (worker reviews own work)
  ↓
Layer 2: TEAM LEAD REVIEW (Tarnished verifies workers)
  ↓
Layer 3: QA GATE (independent agents verify phase output)
  ↓
Layer 4: HUMAN REVIEW (dashboard in PR for final sign-off)
```

Each layer catches what the previous missed:
- Layer 1 catches: obvious incompleteness, scope violations
- Layer 2 catches: generic evidence, empty reports, coverage gaps
- Layer 3 catches: team lead "going through the motions", missing artifacts
- Layer 4 catches: systemic issues invisible to automated checks

### Before vs. After

| Aspect | Before | After |
|--------|--------|-------|
| Worker receives task | Inline prompt (ephemeral) | Physical files on disk (auditable) |
| Worker completes task | `TaskUpdate(completed)` | Self-review → evidence → report → `TaskUpdate` |
| Team lead delegates | Embeds in Agent() call | Creates files → coverage matrix → manifest |
| Phase completes | Stop hook advances blindly | QA agents verify → score → advance or retry |
| Arc quality known? | No | Yes — dashboard with per-phase scores |

---

## 13. Configuration Reference

### Talisman Settings

```yaml
# Discipline settings (existing)
discipline:
  enabled: true
  block_on_fail: true
  scr_threshold: 100
  max_convergence_iterations: 3

# QA Gate settings (new)
qa_gates:
  enabled: true
  pass_threshold: 70
  excellence_threshold: 90
  max_retries: 2
  gated_phases:
    - forge
    - work
    - code_review
    - mend
    - test
    - gap_analysis
  dashboard_in_pr: true
```

---

## 14. Failure Modes & Recovery

| Failure Mode | Detection | Recovery |
|-------------|-----------|---------|
| Task files not created | QA artifact check: WRK-ART-01 | Loop back, create files |
| Worker reports empty | QA quality check: WRK-QUA-01 | Loop back, enforce write-back |
| Evidence is generic | QA quality check: WRK-QUA-03/05 | Loop back, require file:line refs |
| Plan ACs uncovered | Coverage matrix: unmapped > 0 | Create gap tasks before spawning |
| Worker stuck | STUCK message via SendMessage | Team lead guides or reassigns |
| Worker challenges task | CHALLENGE message via SendMessage | Team lead revises or explains |
| QA agents fail to produce verdict | Crash detection in orchestrator | Score 0, trigger retry |
| Phase loops back 2+ times | Max retry counter | Human escalation via AskUserQuestion |
| Stagnation (same failures repeat) | Convergence loop F17 detection | Escalate to human |
| Regression (fixed items break) | Convergence loop F10 detection | Block + investigate |

---

*This document will be updated as the micro-tasking and QA systems are implemented and field-tested.*
