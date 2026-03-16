# Spec Continuity

> The plan file is not consumed once and forgotten — it is the persistent reference document for ALL phases of the pipeline.

**Source**: `docs/discipline-engineering.md` § 8 — The Discipline Pipeline: Spec Continuity

---

## 8.1 The Missing Principle

Most multi-agent pipelines treat the plan file as an **input to the work phase** — read once during task decomposition, then effectively invisible to all subsequent phases. Each phase operates only on what it can see locally: code changes, test results, review findings, build output. No phase looks back at the plan to ask: *"Is this what was specified?"*

This creates **structural blindness**:

```
CURRENT PIPELINE (spec consumed and forgotten):

  Plan ──► [Work Phase reads plan] ──► code changes
                                          │
                                          ▼
           [Review Phase sees: code]  ──► findings
                                          │
                                          ▼
           [Test Phase sees: code]    ──► test results
                                          │
                                          ▼
           [Pre-Ship sees: artifacts] ──► verdict

  PROBLEM: After work phase, NO PHASE reads the plan.
  The plan's acceptance criteria are invisible to review, test, and ship.
```

**Consequences:**

- **Review** examines code quality but cannot detect missing features. A reviewer that sees clean, well-tested code for 7 of 10 requirements gives a passing review — the 3 missing requirements are invisible.
- **Testing** generates strategies from changed files. Tests verify what *was implemented*, not what *was specified*. 3 unimplemented edge cases have no tests and no one notices.
- **Gap Analysis** performs identifier matching only — it cannot detect semantic omissions: requirements understood but simplified, edge cases specified but skipped, error handling required but omitted.
- **Pre-Ship Validation** checks artifact integrity, not specification compliance. It answers "did the pipeline complete?" not "did the pipeline deliver what was specified?"

**Spec Continuity** is the principle that the plan file must be the **persistent reference document for ALL phases** — not consumed once and forgotten, but continuously compared against at every decision point.

---

## 8.2 The Spec-Aware Pipeline

```
    PLAN FILE (Specification)
         │
         │ ◄── PERSISTENT REFERENCE: every phase reads this
         │
    ┌────▼────────────────────────────────────────────────────┐
    │ ENRICHMENT PHASE                                         │
    │ Reads plan: YES (primary input)                          │
    │ Discipline: Sections → atomic tasks with YAML criteria   │
    │ Spec role: Source of acceptance criteria                  │
    └────┬─────────────────────────────────────────────────────┘
         │
    ┌────▼────────────────────────────────────────────────────┐
    │ WORK PHASE                                               │
    │ Reads plan: YES (decompose, task review, convergence)    │
    │ Discipline: Echo-back, evidence collection, proofs       │
    │ Spec role: Source of truth for task review and          │
    │            convergence check                             │
    └────┬─────────────────────────────────────────────────────┘
         │
    ┌────▼────────────────────────────────────────────────────┐
    │ GAP ANALYSIS PHASE                                       │
    │ Reads plan: YES — MANDATORY                              │
    │ Discipline: Cross-reference EVERY acceptance criterion   │
    │             from the plan against implementation evidence│
    │ Output: Spec Compliance Matrix (criterion × status)      │
    │ Gate: RED count > 0 → BLOCK                             │
    └────┬─────────────────────────────────────────────────────┘
         │
    ┌────▼────────────────────────────────────────────────────┐
    │ REVIEW PHASE (Spec-Aware)                                │
    │ Reads plan: YES — MANDATORY                              │
    │ Reviewers receive: code changes + plan file + plan type  │
    │ Review asks: "Does the code match the spec?"             │
    └────┬─────────────────────────────────────────────────────┘
         │
    ┌────▼────────────────────────────────────────────────────┐
    │ REMEDIATION PHASE (Spec-Aware Mend)                      │
    │ Reads plan: YES                                          │
    │ Fix agents understand: WHY the finding matters,          │
    │   WHAT the correct behavior should be, WHERE the         │
    │   requirement came from                                   │
    └────┬─────────────────────────────────────────────────────┘
         │
    ┌────▼────────────────────────────────────────────────────┐
    │ TEST PHASE (Spec-Aware Testing)                          │
    │ Reads plan: YES — MANDATORY                              │
    │ Test strategy derived FROM PLAN, not from code           │
    │ Gate: Untested CRITICAL criteria → BLOCK                 │
    └────┬─────────────────────────────────────────────────────┘
         │
    ┌────▼────────────────────────────────────────────────────┐
    │ PRE-SHIP VALIDATION (Final Spec Compliance)              │
    │ Reads plan: YES — MANDATORY                              │
    │ Final cross-reference: plan criteria × evidence chain    │
    │ Gate: SCR < threshold → BLOCK                            │
    └────┬─────────────────────────────────────────────────────┘
         │
         ▼
    VERIFIED DELIVERY (with evidence chain per criterion)
```

---

## 8.3 Scope of Work (SOW) Contracts

Every agent operating in the pipeline must know three things: **what** it is responsible for, **what** it is NOT responsible for, and **how** its completion will be verified.

### 8.3.2 SOW Contract Structure

Every agent in the pipeline operates under an explicit Scope of Work:

```
SCOPE OF WORK CONTRACT:

  Agent: {agent-name}
  Phase: {pipeline-phase}
  Plan:  {path-to-plan-file}

  RESPONSIBLE FOR:
    - Specific criteria IDs: [AC-1, AC-2, AC-3]
    - Specific files: [src/auth.ts, src/middleware/jwt.ts]
    - Specific dimensions: [security, error-handling]

  NOT RESPONSIBLE FOR:
    - Other criteria (handled by other agents)
    - Files outside scope
    - Architectural decisions (plan already made)

  COMPLETION CRITERIA:
    - Every item in RESPONSIBLE FOR addressed with evidence
    - Findings reference specific plan criteria when applicable
    - Report explicitly states which criteria were reviewed

  PLAN CONTEXT:
    - Plan type: {new-feature / bug-fix / refactor}
    - Relevant plan sections: {section titles}
    - Acceptance criteria for this scope: {criteria list}
```

### 8.3.3 SOW Coverage Check

At the end of each phase, the orchestrator verifies that the **union of all agent SOWs covers the complete specification**:

```
SOW COVERAGE CHECK:

  all_criteria    = extract_criteria(plan_file)
  covered_criteria = union(agent_1.SOW, agent_2.SOW, ..., agent_N.SOW)

  uncovered  = all_criteria - covered_criteria
  duplicated = intersection(agent_1.SOW, agent_2.SOW)  // OK if intentional

  IF uncovered is not empty:
    → GAP: criteria {list} not assigned to any agent
    → Create additional scope or reassign

  IF duplicated and not intentional:
    → WARN: criteria {list} assigned to multiple agents
    → Deduplicate to avoid conflicting assessments
```

### 8.3.4 SOW by Phase

Per-phase SOW table — each phase owns a distinct slice of the plan criteria:

| Phase | Agent Type | SOW Source | Completion Signal |
|-------|-----------|-----------|-------------------|
| Enrichment | Forge agent | Plan sections → atomic task files with YAML criteria | Task files with extracted criteria |
| Work | Worker | Task file acceptance criteria | Evidence per criterion |
| Gap Analysis | Inspector | All plan criteria | Compliance matrix |
| Review | Reviewer | Assigned files + plan criteria for those files | Findings with plan criterion references |
| Testing | Test runner | Plan criteria → test mapping | Test results per criterion |
| Remediation | Fixer | Specific findings + originating plan criteria | Fix evidence per finding |
| Pre-Ship | Validator | Full plan criteria list | Final compliance matrix |

---

## 8.4 Spec Compliance Matrix

The Gap Analysis phase produces a **Spec Compliance Matrix**: a criterion × status table that maps every plan acceptance criterion to a coverage verdict.

| Status | Meaning | Pipeline Action |
|--------|---------|----------------|
| **GREEN** | Criterion met with evidence | ✓ No action required |
| **YELLOW** | Criterion partially met (implemented but test gap) | ⚠ Flag as test gap; block if critical |
| **RED** | Criterion not addressed at all | ✗ BLOCK — cannot proceed to review |
| **ORANGE** | Criterion met but evidence incomplete (drift from spec) | ⚠ Flag for remediation |

**Example matrix:**

```
Spec Compliance Matrix (Gap Analysis Phase):

  Criterion | Status | Evidence | Notes
  ──────────┼────────┼──────────┼──────────────────────────────
  AC-1      | GREEN  | commit a1b2 | Token validation implemented + tested
  AC-2      | GREEN  | commit c3d4 | Refresh flow implemented + tested
  AC-3      | RED    | (none)  | token_expired error code not implemented
  AC-4      | RED    | (none)  | token_revoked error code not implemented
  AC-5      | YELLOW | commit e5f6 | invalid_issuer implemented, no test
  AC-6      | ORANGE | commit g7h8 | Returns generic 401, not structured code
  ──────────┴────────┴──────────┴──────────────────────────────
  Gate: 2 RED criteria → BLOCK (must address before review phase)
```

---

## 8.5 Spec-Aware Testing

Blind testing reports pass rates for *tests that exist*. Spec-aware testing reports coverage against *criteria that were specified*.

**Blind testing (current anti-pattern):**

```
1. Detect changed files: src/auth.ts, src/middleware/jwt.ts
2. Find test files: tests/auth.test.ts
3. Run tests: 15/15 pass
4. Report: "All tests pass. 100% pass rate."

INVISIBLE: Plan specified 5 edge cases.
           Only 2 have tests. 3 edge cases are untested.
           The 15/15 pass rate is misleading.
```

**Spec-aware testing (discipline):**

```
1. Read plan file: extract ALL acceptance criteria
2. For each criterion:
   a. Map to expected test (by file target + criterion description)
   b. Check: does a test exist that verifies this criterion?
   c. If yes: run test, record result
   d. If no: record as UNTESTED CRITERION

3. Also run changed-file tests (existing behavior preservation)

4. Report:
   Criteria coverage: 12/18 criteria have corresponding tests
   UNTESTED CRITERIA:
     - AC-7: "Expired token returns 401 with 'token_expired'" — NO TEST
     - AC-8: "Revoked token returns 401 with 'token_revoked'" — NO TEST
     - ...
   Spec compliance: 12/18 = 67% (NOT 100%)
```

**Test plan generation protocol:**

1. Read ALL acceptance criteria from plan
2. For each criterion:
   - Does a test exist that verifies this criterion?
   - If yes: run it, verify it passes
   - If no: FLAG as untested requirement
3. Additionally: run changed-file tests (existing)
4. Test report includes:
   - Criteria coverage: N/M criteria have tests
   - Test results: pass/fail per criterion
   - Untested criteria: list with severity

**Gate:**
- Untested CRITICAL criteria → **BLOCK**
- Untested LOW criteria → **WARN**

---

## 8.6 The Spec Continuity Invariant

**Every phase in the pipeline MUST receive the plan file path and MUST read the plan's acceptance criteria as part of its input.** This is not optional. This is not "when applicable." This is structural.

The invariant stated formally:

```
FOR EVERY phase P in pipeline:
  P.input    MUST include plan_file_path
  P.execution MUST read plan acceptance criteria
  P.output   MUST reference plan criteria in its report

VIOLATION: Any phase that does not reference the plan
           in its output is operating blind and its
           results cannot be trusted for spec compliance.
```

**Why plan context matters for every reviewer:**

```
Without plan context:
  Reviewer sees: A clean auth middleware that validates JWT tokens.
  Reviewer says: "LGTM. Code is clean, well-tested."
  Reality: Plan required 5 error codes. Only 2 implemented. Reviewer can't know.

With plan context:
  Reviewer sees: Auth middleware + Plan AC requiring 5 error codes.
  Reviewer says: "AC-3, AC-4, AC-5 not implemented. 2/5 error codes present."
  Reality: 3 gaps caught before shipping.
```

The difference is not reviewer quality — it is reviewer context. A reviewer without the spec is reviewing blind. A reviewer with the spec is reviewing against a contract.

This invariant transforms the pipeline from a sequence of independent phases into a coherent system where every phase contributes to a single question: **"Does the output match the specification?"**

---

## 8.7 Token-Cost IPC Accounting

Inter-process communication (IPC) between agents has a measurable token cost. Every token spent on communication is a token NOT spent on reasoning. These five IPC principles ensure orchestration prompts remain lean and agents retain maximum reasoning capacity.

### Principle 1: Reference Don't Inline

Pass file paths and identifiers instead of inlining full content into spawn prompts.

**Anti-pattern (WRONG):**
```
Agent({
  prompt: `Review this code:
    ${fullFileContent}          // 2000 tokens of inlined source
    ${fullPlanContent}          // 1500 tokens of inlined plan
    Against these criteria:
    ${allCriteriaYAML}          // 800 tokens of inlined criteria
  `
})
```

**Correct pattern (instead, reference by path):**
```
Agent({
  prompt: `Review the code at src/auth.ts against the plan at plans/auth-feature.md.
    Read the file and extract acceptance criteria before reviewing.`
})
```

**Why**: Inlined content displaces reasoning capacity. A 4000-token spawn prompt leaves 4000 fewer tokens for the agent's actual analysis. Agents can Read files on demand — they do not need content pre-loaded into their prompt.

### Principle 2: Consumer Pays Token Cost

The agent that needs information reads it — the orchestrator does not pre-fetch and relay.

**Anti-pattern (WRONG):**
```
// Orchestrator reads file, then passes content to agent
const content = Read("src/auth.ts")
Agent({ prompt: `Here is the file content: ${content}. Review it.` })
```

**Correct pattern (instead, let consumer read):**
```
// Agent reads what it needs
Agent({ prompt: `Read and review src/auth.ts for security issues.` })
```

**Why**: Pre-fetching wastes the orchestrator's context window. The consumer agent has its own context window — let it bear the cost of reading what it needs.

### Principle 3: Write-Once Communication

Agents write output to files exactly once. Subsequent consumers read from files — never relay through the orchestrator.

**Anti-pattern (WRONG):**
```
// Agent A returns findings inline → orchestrator relays to Agent B
const findings = agentA.result  // 3000 tokens into orchestrator context
Agent({ prompt: `Fix these findings: ${findings}` })  // 3000 tokens again
```

**Correct pattern (instead, use file handoff):**
```
// Agent A writes to file → Agent B reads from file
// Agent A's prompt includes: "Write findings to tmp/review/findings.md"
// Agent B's prompt includes: "Read findings from tmp/review/findings.md"
```

**Why**: Relaying through the orchestrator doubles the token cost (once to receive, once to send). File-based handoff costs zero orchestrator tokens.

### Principle 4: Aggregation as Dedicated Role

When multiple agent outputs must be combined, delegate to a dedicated aggregator agent — do not aggregate in the orchestrator's context.

**Anti-pattern (WRONG):**
```
// Orchestrator reads all 7 agent outputs and synthesizes
for (const file of outputFiles) {
  const content = Read(file)  // 7 × 2000 = 14000 tokens consumed
  // ... merge logic in orchestrator context
}
```

**Correct pattern (instead, delegate aggregation):**
```
Agent({
  name: "runebinder",
  prompt: `Aggregate findings from tmp/review/*.md into tmp/review/TOME.md`
})
// Orchestrator reads only TOME.md (~1000 tokens)
```

**Why**: The orchestrator's context is the most expensive resource in the pipeline. Aggregation in a dedicated agent isolates the token cost to a separate context window.

### Principle 5: Minimal State Carry-Forward

Between pipeline phases, carry only identifiers, paths, and verdicts — not full content.

**Anti-pattern (WRONG):**
```
// Phase transition carries full artifacts
nextPhase({
  findings: fullTOMEContent,      // 5000 tokens
  metrics: fullMetricsJSON,       // 2000 tokens
  plan: fullPlanContent            // 3000 tokens
})
```

**Correct pattern (instead, carry references):**
```
nextPhase({
  tomePath: "tmp/review/TOME.md",
  metricsPath: "tmp/work/metrics.json",
  planPath: "plans/auth-feature.md",
  verdict: "PASS",
  scr: 0.97
})
```

**Why**: Full content accumulates across phases. By phase 5 of an arc pipeline, carried content can exceed 20000 tokens — all static, displacing active reasoning.

### Spawn Prompt Size Guideline

Orchestrator spawn prompts should target **≤ 500 tokens**. A spawn prompt contains: role instructions, task reference (path), output conventions, and quality gates. It should NOT contain: file contents, plan contents, criteria lists, or findings from prior phases.

Spawn prompts exceeding 500 tokens are a signal that content is being inlined instead of referenced. Apply Principle 1 (Reference Don't Inline) to reduce prompt size.

---

## Summary

| Concept | Rule |
|---------|------|
| Spec Continuity | Plan file = persistent reference for ALL phases |
| SOW Contract | Every agent: RESPONSIBLE FOR + NOT RESPONSIBLE FOR + COMPLETION CRITERIA |
| SOW Coverage Check | `uncovered = all_criteria − union(all SOWs)` must be empty |
| Compliance Matrix | GREEN / YELLOW / RED / ORANGE per criterion |
| Spec Continuity Invariant | Every phase MUST read plan, MUST reference criteria in output |
| Testing protocol | Derive test plan from spec criteria, not from changed files |
| RED gate | Any RED criterion blocks progression to review phase |
| Token-Cost IPC | Reference Don't Inline, Consumer Pays, Write-Once, Aggregation as Role, Minimal Carry-Forward |
