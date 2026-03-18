# Best Practices Research: Plan-to-Code Compliance Checking

> Research date: 2026-02-13
> Sources: Web research, academic papers, AI agent framework documentation, local codebase patterns

---

## 1. How Leading AI Coding Agents Verify Plan-to-Code Compliance

### Agent-by-Agent Survey

| Agent | Verification Approach | Explicit Plan Compliance? |
|-------|----------------------|---------------------------|
| **OpenAI Codex** | Reason-act loop: interprets task, decomposes into subtasks, generates code, runs tests, iterates on failures. Uses fail2pass + pass2pass test suites from SWE-bench. | **No explicit plan compliance check.** Verification is test-driven: code is correct if tests pass. No mechanism compares implementation back to the original plan/spec. |
| **Devin** | Checkpoint-gated: Plan -> Implement chunk -> Test -> Fix -> Checkpoint review -> Next chunk. Human reviews at checkpoints. | **Partial.** Checkpoints are human-reviewed, creating an implicit plan compliance check. But the verification is manual, not automated. Devin recommends treating the developer as "architect guiding junior developers." |
| **SWE-agent** | Reproduce -> Localize -> Patch -> Verify. State-machine with explicit phases (Searching, Planning, Editing). | **No explicit plan compliance.** Verification is against test suites. The "plan" is implicit in the localization phase, not a first-class artifact that gets checked. |
| **Cursor Agent Mode** | Presents implementation plan before executing. Human approves/modifies. Separates planning model from execution model. | **Plan approval before execution, not after.** No post-implementation check that code matches the approved plan. Verification relies on human review of the diff. |
| **Claude Code (Agent Teams)** | Team lead creates task list, spawns teammates, coordinates. Quality gate hooks (TaskCompleted, TeammateIdle) can block completion. | **Closest to explicit compliance checking** via hooks. TaskCompleted hooks can run verification scripts. But this is infrastructure -- the compliance logic must be user-provided. |
| **Open SWE (LangChain)** | Multi-agent: Planner researches codebase, Coder implements, Reviewer validates. Dedicated Reviewer component. | **Architectural separation of review from implementation.** Reviewer checks implementation but against tests, not against the plan artifact itself. |

### Key Finding

**No major AI coding agent performs automated plan-to-code compliance checking as a first-class feature.** All agents verify implementation correctness via test suites (pass/fail), not plan adherence (did we build what we said we would build?). The closest patterns are:

1. **Devin's human checkpoint review** -- manual plan compliance
2. **Claude Code's TaskCompleted hooks** -- programmable compliance gates
3. **Open SWE's Reviewer agent** -- architectural separation but test-focused

This represents a **gap in the current ecosystem**. Test passing answers "does the code work?" but not "does the code address all planned items?"

---

## 2. Traditional Software Engineering Patterns for Spec Compliance

### Pattern Comparison

| Pattern | What It Verifies | Granularity | Automation Level | Best For |
|---------|-----------------|-------------|------------------|----------|
| **ATDD (Acceptance Test Driven Development)** | Acceptance criteria met before code is written | Feature-level | High (tests are executable) | Ensuring features meet user needs |
| **Requirements Traceability Matrix (RTM)** | Every requirement has corresponding implementation + test | Requirement-level | Medium (tools can automate links) | Regulated industries (DO-178C, ISO 26262) |
| **Spec-Based Testing** | Implementation conforms to formal specification | Function-level | High (can be generated from spec) | API contracts, protocol compliance |
| **Definition of Done (DoD)** | Cross-cutting quality standards met | Item-level (applied uniformly) | Low (typically a manual checklist) | Team-wide quality consistency |
| **Acceptance Criteria** | Specific conditions for individual stories/features | Story-level | Medium (can map to test cases) | Feature-specific validation |

### ATDD: The Gold Standard for AI Agent Pipelines

ATDD is the most directly applicable pattern because:

1. **Tests are written before implementation** -- maps to "plan includes test cases"
2. **Tests are derived from acceptance criteria** -- not from implementation (avoids confirmation bias)
3. **Tests are executable** -- automated verification, no manual review needed
4. **Tests serve as the spec** -- single source of truth for "what was planned"

The AgentCoder research (EMNLP 2024) validates this: when test generation is separated from code generation and derived from the specification, pass rates increase from 90.2% to 96.3%.

### Requirements Traceability Matrix: Heavyweight but Thorough

RTM maps: Requirement -> Design -> Implementation -> Test -> Result

**When it makes sense for AI agents:**
- Regulated domains where audit trails are mandatory
- Multi-sprint features where requirements evolve
- Large teams where different agents/people own different artifacts

**When it is over-engineering for AI agents:**
- Single-session implementations
- Well-scoped tasks with clear test suites
- Rapid prototyping or exploration phases

Modern CI/CD tools (LDRA, Parasoft) can automate RTM by linking commits to requirements and running coverage analysis on every build.

### Definition of Done vs. Acceptance Criteria

This distinction is critical for AI agent pipelines:

| Concept | Scope | Who Defines | When Checked | AI Agent Equivalent |
|---------|-------|-------------|-------------|---------------------|
| **Definition of Done** | All items uniformly | Team/organization | End of sprint/increment | TaskCompleted hook (applies to every task) |
| **Acceptance Criteria** | Per-item, varies | Product owner + team | During and after implementation | Plan section: per-task success conditions |

**Recommendation for AI agent systems**: Use BOTH. The DoD equivalent is a universal quality gate (tests pass, no lint errors, no type errors). The acceptance criteria equivalent is per-task verification derived from the plan.

---

## 3. Right Granularity for Plan Compliance Checking

### The Granularity Spectrum

```
Task-level                Feature-level              Code-level
"All tasks completed?"    "Acceptance criteria met?"  "Exact implementation matches spec?"
     |                         |                           |
  Coarse                   Sweet Spot                  Over-engineering
```

### Analysis by Granularity Level

#### Task-Level (All tasks completed?)

**Pros:**
- Simple to verify: is the task list empty?
- Low overhead
- Works well for decomposed work

**Cons:**
- Tasks can be marked "done" without meeting acceptance criteria
- Quantity != quality (10/10 tasks done, but feature is broken)
- Misses emergent requirements discovered during implementation

**Verdict:** Necessary but insufficient. Good as a first-pass filter.

#### Feature-Level (Acceptance criteria met?)

**Pros:**
- Directly maps to user/stakeholder value
- Can be automated via acceptance tests
- Catches "done but wrong" scenarios
- Natural granularity for human review

**Cons:**
- Requires well-written acceptance criteria (garbage in, garbage out)
- May miss internal quality issues (tech debt, security)

**Verdict:** This is the sweet spot. The PDCA framework (InfoQ, 2025) and AgentCoder research both converge on feature-level acceptance criteria as the right granularity.

#### Code-Level (Exact implementation matches spec?)

**Pros:**
- Maximum precision
- Catches subtle deviations

**Cons:**
- Brittle: any refactoring breaks compliance even if behavior is correct
- Stifles agent autonomy (agents cannot choose better implementations)
- Spec must be as detailed as code, defeating the purpose of abstraction
- Local codebase echo confirms this: "Plans containing literal code become the bug. When the plan is wrong, workers implement the bug faithfully."

**Verdict:** Over-engineering in almost all cases. Use behavioral contracts (pre/postconditions) instead of structural matching.

### Recommended Approach: Two-Tier Verification

```
Tier 1: Task Completion Check (lightweight, automated)
  - Are all planned tasks marked complete?
  - Did any tasks get skipped or abandoned?
  - Were any unplanned tasks added? (scope creep detection)

Tier 2: Acceptance Criteria Verification (substantive, automated where possible)
  - Do acceptance tests pass?
  - Are all acceptance criteria addressed in the implementation?
  - Does the implementation satisfy the plan's intent (not its letter)?
```

This matches the local codebase pattern found in `/Users/vinhnx/Desktop/repos/rune/docs/solutions/architecture/plan-quality-best-practices.md`, which recommends plans structured as: Intent -> Contracts -> Test Cases -> Constraints -> Anti-patterns.

---

## 4. Pipeline Positioning: Where Should Compliance Checking Happen?

### Position Options and Trade-offs

| Position | When | Pros | Cons | Best For |
|----------|------|------|------|----------|
| **During implementation (inline)** | After each task/chunk completes | Catches issues early; bounds error propagation; fast feedback | Higher overhead per task; may slow throughput | Multi-agent teams; high-risk features |
| **Before code review** | After all implementation, before review | Reviewer can focus on quality, not completeness; reduces review burden | Late detection; rework is expensive; entire feature may need rewrite | Solo agent workflows; well-tested codebases |
| **As part of code review** | Integrated into review process | Natural checkpoint; reviewer has full context | Overloads reviewer; mixes completeness with quality concerns | Small teams; simple features |
| **After code review, as separate gate** | Before merge/deploy | Clean separation of concerns; can be automated independently | Very late detection; highest rework cost; blocks the pipeline | Regulated environments; compliance-heavy workflows |
| **Continuous (multi-point)** | At every transition | Maximum coverage; earliest possible detection | Most complex; highest overhead | Critical systems; large multi-agent orchestrations |

### Industry Consensus: Shift Left, Check Often

The PDCA framework (Plan-Do-Check-Act) for AI code generation explicitly recommends:

1. **Check at task boundaries** (after each atomic commit)
2. **Validate at feature boundaries** (after all tasks for a feature)
3. **Gate at merge** (final compliance check before integration)

This "shift left" approach aligns with:
- **Devin's checkpoint pattern**: verify each chunk before proceeding
- **CODESIM's simulation**: verify plan logic before any code is written
- **CI/CD traceability**: continuous verification with every build

### Recommended Pipeline Integration

```
Plan Created
  |
  v
[Pre-Implementation Gate] -- Plan simulation / dry-run verification (CODESIM pattern)
  |
  v
Task 1 Implemented
  |
  v
[Task Completion Check] -- Tier 1: task marked done + acceptance test for this task
  |
  v
Task 2 Implemented
  |
  v
[Task Completion Check] -- Tier 1 again
  |
  ... (repeat for all tasks)
  |
  v
All Tasks Complete
  |
  v
[Feature Compliance Gate] -- Tier 2: all acceptance criteria verified
  |
  v
Code Review (human or agent)
  |
  v
[Merge Gate] -- Final: DoD checklist (tests, lint, types, coverage)
  |
  v
Merged
```

For Claude Code plugin systems specifically, this maps to:
- **Pre-Implementation Gate**: Plan mode approval or plan_mode_required agent setting
- **Task Completion Check**: TaskCompleted hook (exit code 2 blocks completion)
- **Feature Compliance Gate**: Stop hook or SubagentStop hook
- **Merge Gate**: CI/CD pipeline checks

---

## 5. Is "Plan Compliance" the Right Framing?

### Terminology Analysis

| Term | Connotation | Strengths | Weaknesses |
|------|-------------|-----------|------------|
| **Plan Compliance** | Regulatory, rigid | Clear that implementation must match plan | Implies plan is always right; punitive framing |
| **Acceptance Criteria Verification** | User-focused, outcome-oriented | Tied to user value; testable | Narrow -- only covers explicit criteria, misses implicit expectations |
| **Feature Completeness Check** | Progress-oriented | Intuitive; maps to task lists | Completeness != correctness; can be "complete" but wrong |
| **Implementation Gap Detection** | Diagnostic, constructive | Identifies what is missing, not just pass/fail; non-punitive | Doesn't capture quality dimension (gap closed but poorly) |
| **Spec Conformance** | Engineering precision | Well-understood in regulated industries | Requires formal spec; heavyweight |
| **Intent Alignment** | AI-native, goal-oriented | Captures spirit, not just letter; allows agent autonomy | Hard to automate; subjective |

### Recommendation: Use "Implementation Gap Analysis"

The strongest framing combines gap detection with analysis:

**"Implementation Gap Analysis"** because:

1. **Non-punitive**: It identifies gaps, not failures. An agent that finds a gap can fill it.
2. **Bidirectional**: Gaps can be in the implementation (missing feature) OR in the plan (plan was wrong or incomplete). The local codebase pattern "Design-vs-Implementation Gap Detection" in the planner echoes confirms this: "When framework documentation and command implementations diverge -- check git history -- was the design ever implemented? If no command ever used the design, the design is dead code."
3. **Actionable**: A gap has a clear resolution (fill it), unlike "non-compliance" which implies blame.
4. **Granular**: Gaps can be classified by severity (P0 missing feature vs P3 style preference).
5. **Automatable**: Gap detection can be implemented as a structured diff between plan items and implementation evidence.

### Proposed Taxonomy

```
Implementation Gap Analysis Report:
  - MISSING: Plan item with no corresponding implementation
  - PARTIAL: Plan item partially implemented (some acceptance criteria unmet)
  - DIVERGENT: Implementation differs from plan intent (may be better or worse)
  - UNPLANNED: Implementation includes work not in the plan (scope creep or improvement)
  - ADDRESSED: Plan item fully implemented with all acceptance criteria met
```

This taxonomy is more useful than pass/fail because:
- DIVERGENT items need human judgment (agent may have found a better approach)
- UNPLANNED items may be legitimate improvements or scope creep
- PARTIAL items have clear next steps

---

## Common Pitfalls

| Pitfall | How to Avoid |
|---------|-------------|
| **Treating plan as infallible** | Plans are hypotheses. Allow agents to flag plan issues, not just comply blindly. The RTADev pattern (ACL 2025) has all agents verify cross-consistency. |
| **Code-level structural matching** | Use behavioral contracts (pre/postconditions, acceptance tests) not structural matching. Code can be correct in many forms. |
| **Checking only at the end** | Shift left. Check at task boundaries, not just feature boundaries. Devin's chunk-verify pattern prevents cascade failures. |
| **Conflating completeness with correctness** | "All tasks done" != "feature works." Require both task completion AND acceptance criteria verification. |
| **Over-engineering for simple tasks** | A 2-line bug fix does not need a traceability matrix. Scale verification to task complexity. |
| **Ignoring unplanned work** | Agent implementations often include necessary work not in the plan (error handling, edge cases). Classify as UNPLANNED, don't penalize. |
| **Manual-only compliance checking** | Automate what you can. TaskCompleted hooks, acceptance test suites, and structured gap reports reduce human bottleneck. |
| **Single-point-of-failure verification** | Use independent verification: tests generated from spec (not from code), reviewer separate from implementer (AgentCoder pattern). |

---

## Implementation Patterns

### Pattern 1: Hook-Based Task Compliance (Claude Code Native)

```json
{
  "hooks": {
    "TaskCompleted": [{
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/scripts/verify-task-compliance.sh",
        "timeout": 30
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "prompt",
        "prompt": "Review the completed work against the original plan. Identify any MISSING, PARTIAL, DIVERGENT, or UNPLANNED items. Report as structured gap analysis.",
        "model": "haiku",
        "timeout": 60
      }]
    }]
  }
}
```

Exit code 2 from the TaskCompleted hook blocks task completion and sends stderr as feedback, forcing the agent to address the gap.

### Pattern 2: Acceptance Criteria as Executable Contracts

```yaml
# In the plan artifact
task: implement-user-auth
acceptance_criteria:
  - id: AC-1
    description: "POST /auth/login returns JWT on valid credentials"
    test: "curl -X POST /auth/login -d '{...}' | jq '.token' | grep '^eyJ'"
  - id: AC-2
    description: "Invalid credentials return 401"
    test: "curl -s -o /dev/null -w '%{http_code}' -X POST /auth/login -d '{...}' | grep 401"
  - id: AC-3
    description: "Rate limiting after 5 failed attempts"
    test: "for i in {1..6}; do curl -s -o /dev/null -w '%{http_code}' ...; done | tail -1 | grep 429"
```

Each acceptance criterion has a machine-executable test. Gap analysis runs these tests and reports which criteria are ADDRESSED vs MISSING.

### Pattern 3: Two-Phase Verification Agent

```
Phase 1 (Lightweight, runs per-task):
  - Parse plan artifact for this task's acceptance criteria
  - Check: does a corresponding test exist?
  - Check: does the test pass?
  - Report: ADDRESSED / MISSING / PARTIAL

Phase 2 (Comprehensive, runs per-feature):
  - Parse entire plan artifact
  - For each planned item, search implementation for evidence of addressing it
  - For each implementation file, check if it corresponds to a planned item
  - Classify all items: ADDRESSED / MISSING / PARTIAL / DIVERGENT / UNPLANNED
  - Generate structured gap report
```

### Pattern 4: PDCA Cycle for AI Code Generation

Based on the InfoQ PDCA framework:

```
PLAN:  Decompose feature into atomic tasks with acceptance criteria
DO:    Implement one task, produce atomic commit
CHECK: Run acceptance tests for this task; verify task-level compliance
ACT:   If gaps found, fix before proceeding; update plan if plan was wrong

Repeat for each task. After all tasks:
  CHECK (feature-level): Run full acceptance suite
  ACT (feature-level): Address remaining gaps
```

---

## References

### AI Agent Architectures
- [Unrolling the Codex Agent Loop](https://openai.com/index/unrolling-the-codex-agent-loop/) -- OpenAI's description of the reason-act-verify loop
- [Devin Coding Agents 101](https://devin.ai/agents101) -- Checkpoint-gated implementation pattern
- [SWE-agent Architecture](https://swe-agent.com/latest/background/architecture/) -- State-machine based agent design
- [Open SWE: Open-Source Asynchronous Coding Agent](https://blog.langchain.com/introducing-open-swe-an-open-source-asynchronous-coding-agent/) -- Multi-agent with Planner/Reviewer separation
- [Cursor 2.0 Agent-First Architecture](https://www.digitalapplied.com/blog/cursor-2-0-agent-first-architecture-guide) -- Plan approval before execution

### Academic Research
- [AgentCoder: Multi-Agent Code Generation (EMNLP 2024)](https://arxiv.org/html/2312.13010v3) -- Independent test generation from spec increases pass rate to 96.3%
- [CODESIM: Simulation-Driven Planning (NAACL 2025)](https://aclanthology.org/2025.findings-naacl.285/) -- Plan verification via I/O simulation before coding
- [PGPO: Pseudocode-style Planning (ACL 2025)](https://arxiv.org/abs/2506.01475) -- Structured plans outperform prose plans
- [RTADev: Intention Aligned Multi-Agent Framework (ACL 2025)](https://aclanthology.org/2025.findings-acl.80.pdf) -- Cross-agent alignment verification
- [SPEC2CODE: Mapping Specification to Function-Level Code (ASE 2025)](https://conf.researchr.org/details/ase-2025/ase-2025-papers/198/SPEC2CODE-Mapping-Software-Specification-to-Function-Level-Code-Implementation) -- First LLM-driven framework for fine-grained spec-to-code mapping
- [SWE-Search: Enhancing Software Agents (ICLR 2025)](https://proceedings.iclr.cc/paper_files/paper/2025/file/a1e6783e4d739196cad3336f12d402bf-Paper-Conference.pdf) -- Value-function guided search for agent verification

### Traditional SE Practices
- [Scrum.org: Definition of Done vs Acceptance Criteria](https://www.scrum.org/resources/blog/what-difference-between-definition-done-and-acceptance-criteria) -- Canonical distinction between DoD and AC
- [Atlassian: Definition of Done in Agile](https://www.atlassian.com/agile/project-management/definition-of-done) -- Universal quality checklist pattern
- [Parasoft: Requirements Traceability for ISO 26262](https://www.parasoft.com/learning-center/iso-26262/requirements-traceability/) -- Automated RTM in regulated CI/CD
- [LDRA: Continuous Verification in CI/CD](https://ldra.com/capabilities/continuous-integration/) -- Traceability gates in safety-critical pipelines
- [TestRail: Requirements Traceability Matrix Guide](https://www.testrail.com/blog/requirements-traceability-matrix/) -- Practical RTM implementation

### Frameworks and Methodology
- [InfoQ: PDCA Framework for AI Code Generation](https://www.infoq.com/articles/PDCA-AI-code-generation/) -- Plan-Do-Check-Act applied to AI coding
- [Augment Code: Spec-Driven Development](https://www.augmentcode.com/guides/spec-driven-ai-code-generation-with-multi-agent-systems) -- Specification-as-contract enforcement
- [Addy Osmani: How to Write a Good Spec for AI Agents](https://addyosmani.com/blog/good-spec/) -- Spec structure with conformance testing
- [DevOps.com: Compliance in the Age of AI](https://devops.com/compliance-in-the-age-of-ai-why-strong-ci-cd-foundations-matter/) -- CI/CD as compliance foundation

### Local Codebase Context
- `/Users/vinhnx/Desktop/repos/rune/docs/solutions/architecture/plan-quality-best-practices.md` -- Comprehensive plan quality research including AgentCoder, CODESIM, and PGPO patterns
- `/Users/vinhnx/Desktop/repos/rune/.rune/echoes/planner/MEMORY.md` -- "Design-vs-Implementation Gap Detection" pattern: when design and implementation diverge, check whether the design was ever implemented

---

## Summary of Key Recommendations

1. **No major AI agent does explicit plan compliance checking today.** This is a real gap worth filling, but fill it at the right granularity.

2. **Feature-level acceptance criteria verification is the sweet spot.** Task-level is too coarse (complete != correct). Code-level is too brittle (correct implementations vary in form).

3. **Use "Implementation Gap Analysis" framing**, not "plan compliance." Classify gaps as MISSING / PARTIAL / DIVERGENT / UNPLANNED / ADDRESSED. This is non-punitive, bidirectional, and actionable.

4. **Check at task boundaries AND feature boundaries.** Shift-left verification catches issues early. The Devin chunk-verify pattern prevents error cascade.

5. **Derive tests from the plan, not from the code.** Independent test generation (AgentCoder pattern) avoids confirmation bias. Tests are the executable form of acceptance criteria.

6. **Use two-tier verification**: lightweight per-task checks via hooks, comprehensive per-feature checks via dedicated verification agents or scripts.

7. **Plans should contain contracts and test cases, not code.** The local codebase research confirms: "Plans containing literal code become the bug."
