# Best Practices Research: AI Agent Plan Quality in Multi-Agent Code Generation

## 1. How Modern AI Coding Agent Frameworks Handle Plan-to-Code Translation

### Framework Survey

| Framework | Planning Approach | Key Pattern |
|-----------|-------------------|-------------|
| **OpenAI Codex** | Dynamic discovery: reads AGENTS.md/README.md, then greps for code, decomposes task iteratively. No upfront comprehensive plan. | Environment-first: agent gathers context before acting. Struggles with spec ambiguity (Martin Fowler's analysis found only 2/6 runs discovered reusable components). |
| **Devin** | Collaborative planning mode with human. Recommends "Plan -> Implement chunk -> Test -> Fix -> Checkpoint review -> Next chunk." | Checkpoint-gated: treats developer as architect guiding junior developers. Uses dedicated knowledge management for consistency. |
| **SWE-agent** | Localization-first: begins with reproduction code and/or localizing the issue to specific lines, then patches. | Reproduce -> Localize -> Patch -> Verify. Agentless variant proved simplicity can yield competitive results. |
| **AutoCodeRover** | AST-based code search combined with LLM reasoning. Localizes before planning a fix. | Structural search (AST) for localization produces better plans than text-only search. Achieved 19% on SWE-bench-lite at low cost. |
| **MASAI** | Modular sub-agents with well-defined objectives. Five specialized sub-agents compose via output-to-input chaining. | Modular decomposition: avoids monolithic plans by giving each sub-agent a focused objective with a tuned strategy. |
| **Claude Code (Agent Teams)** | Team lead creates task list, spawns specialized teammates, coordinates via messaging. Supports plan-mode-required for risky tasks. | Separation of planning from implementation via delegate mode. Quality gates (hooks) verify task completion. |
| **Cursor Agent** | Interactive plan mode: presents plan before execution, human approves or modifies. | Human-in-the-loop plan approval before code generation begins. |

### Key Insight

All high-performing frameworks share a common pattern: **localization before generation**. The plan-to-code gap narrows when agents first identify exactly where and what to change, rather than generating code from abstract requirements. MASAI's sub-agent architecture achieves this by having separate agents for localization vs. patch generation.

---

## 2. Plans: Pseudocode/Code vs. Prose -- Trade-offs

### Research Findings

The PGPO paper (ACL 2025 Findings) directly investigated this question and found that **pseudocode-style plans (P-code Plans) outperform natural language plans** on agent reasoning benchmarks.

**P-code Plan structure** (from PGPO):
```
(id, name, [parameter], [return_value], [control_flow])
```
Each planning step is structured like a function call with unique ID, abstracted subtask name, parameters, optional return values, and optional control flow.

### Comparison Table

| Dimension | Prose Plans | Pseudocode Plans | Hybrid (Recommended) |
|-----------|-------------|------------------|----------------------|
| **Precision** | Ambiguous; worker must interpret intent | Structurally precise; reduces misinterpretation | Prose for "why", pseudocode for "what" |
| **Generalization** | Verbose, task-specific | Abstract logic transfers across similar tasks | Best of both worlds |
| **Bug surface** | Bugs hide in ambiguity (worker fills gaps wrong) | Bugs are visible and reviewable (logic errors in structure) | Bugs are catchable at both levels |
| **Efficiency** | Verbose, consumes more tokens | Concise, lower token cost | Moderate token cost |
| **Reviewability** | Hard to diff or verify mechanically | Can be statically analyzed | Prose reviewed by humans, pseudocode by machines |
| **Worker autonomy** | High (too high: worker guesses) | Low (worker follows structure) | Calibrated per task complexity |

### Recommendation

Use a **hybrid approach**: prose describes the intent, constraints, and acceptance criteria; pseudocode or structured specs describe the transformation logic, data flow, and control flow. This matches what Addy Osmani calls "what and why over how" for the prose layer, with executable detail for the structural layer.

---

## 3. Preventing Plan Bugs from Propagating to Implementation

### Pattern 1: Simulation-Driven Plan Verification (CODESIM)

**Source**: CODESIM (NAACL 2025 Findings)

The planning agent generates a plan, then **simulates input/output step-by-step** before any code is written. If simulation reveals logical errors, the plan is revised before reaching the coding agent.

**Results**: HumanEval 95.1%, MBPP 90.7% -- state-of-the-art at time of publication.

**Application**: Before a worker agent begins coding, have a verification agent (or the planner itself) trace through the plan with concrete example inputs and expected outputs. This catches logical errors without writing any code.

### Pattern 2: Separate Test Generation (AgentCoder)

**Source**: AgentCoder (EMNLP 2024)

Three-agent architecture:
1. **Programmer agent** -- generates code from plan
2. **Test designer agent** -- generates tests *independently* from the plan (not from code)
3. **Test executor agent** -- runs tests against code, feeds failures back

**Critical insight**: Tests generated independently from code avoid confirmation bias. The test designer works from the *specification*, not the implementation.

**Results**: 96.3% pass@1 on HumanEval with GPT-4.

### Pattern 3: Spec-as-Contract (Spec-Driven Development)

**Source**: Augment Code, Addy Osmani, GitHub Spec Kit

Treat the plan/spec as a **contract** with:
- Exact data models and API signatures
- Conformance test suites (YAML-based, language-independent)
- Acceptance criteria that are machine-verifiable

**Key principle**: "Outdated specs produce broken implementations" -- the spec is the forcing function. If the spec is wrong, the implementation fails visibly rather than silently drifting.

### Pattern 4: Closed-Loop Error Suppression

**Source**: Towards Data Science analysis of multi-agent error amplification

The "17x error trap" occurs when agents operate as a loosely coordinated "bag of agents." Errors in one agent's output multiply across downstream agents.

**Prevention architecture**:
- **Functional planes**: Organize agents into structured layers, not flat hierarchies
- **Closed-loop feedback**: Each agent's output is validated before becoming another agent's input
- **Agent taxonomy**: Use well-defined archetypes rather than ad-hoc custom agents

### Pattern 5: Incremental Chunk Verification (Devin Pattern)

**Source**: Devin agents101 guide

```
Plan -> Implement chunk -> Test -> Fix -> Checkpoint review -> Next chunk
```

Never implement the entire plan at once. Each chunk is verified before proceeding. This bounds error propagation to one chunk at a time.

### Pattern 6: Cross-Agent Alignment Checking (RTADev)

**Source**: RTADev (ACL 2025 Findings)

Five sequential agents, each producing a deliverable. After each deliverable, **all previous agents verify consistency** with their own outputs. Only after unanimous approval does the deliverable enter the "certified repository."

---

## 4. Optimal Level of Specificity in AI Agent Plans

### The Specificity Spectrum

```
Too Vague                                              Too Specific
"Fix the auth bug"  <------>  "On line 47 of auth.ts,
                               change jwt.verify(token,
                               secret) to jwt.verify(
                               token, secret, {algorithms:
                               ['HS256']})"
```

### Industry Consensus: Implementation-Level Intent, Not Implementation-Level Code

The sweet spot identified across multiple sources:

| Specify | Do Not Specify |
|---------|---------------|
| Data models and schemas | Exact variable names |
| API contracts (inputs/outputs/errors) | Line-by-line code changes |
| Authentication flows (e.g., "OAuth 2.0 PKCE") | Import statements |
| Acceptance criteria with concrete examples | Internal helper function organization |
| Error handling strategy | Specific error message strings |
| Performance constraints ("< 200ms response") | Micro-optimization choices |
| File boundaries ("create src/auth/provider.ts") | Internal file structure |

### Addy Osmani's Framework (Verified Source)

From "How to write a good spec for AI agents":

1. **Start with what and why**, not how
2. **Include six core areas**: commands (with flags), testing frameworks, project structure, code style examples, git workflows, explicit boundaries
3. **Use concrete instances**: "React 18 with TypeScript, Vite, and Tailwind CSS" beats "React project"
4. **Three-tier boundary system**: Always do / Ask first / Never do
5. **Living document**: Update spec as decisions are made; spec is ground truth

### Goose Framework's Planning Spectrum (Verified Source)

From Block's Goose blog, three strategies for different specificity needs:

| Strategy | Specificity | Best For |
|----------|------------|----------|
| **Architect** (/plan mode) | High -- interactive dialogue produces detailed multi-phase plans | Well-scoped greenfield projects |
| **Director** (instruction files) | Medium -- pre-written markdown guides execution | CI/CD automation, repeatable tasks |
| **Explorer** (conversational) | Low -- organic discovery with project rules as guardrails | Unfamiliar codebases, prototyping |

### The "Goldilocks Zone" for Multi-Agent Systems

Based on the research, the recommended specificity level for plans consumed by worker agents:

1. **Interface contracts are mandatory**: Every function/API the worker will create or modify must have its signature, input types, output types, and error cases specified
2. **Behavioral examples are mandatory**: At least one concrete input -> output example per function
3. **Implementation strategy is optional but recommended**: Describe the algorithm or approach in 1-2 sentences, not in code
4. **Exact code is prohibited in plans**: Plans containing literal code become the bug. When the plan is wrong, workers implement the bug faithfully

---

## 5. TDD and Design-by-Contract Applied to AI Agent Plans

### TDD for Agent Plans

**Principle**: Plans should define test cases, not implementation.

**Application pattern**:

```
PLAN STRUCTURE (recommended):
1. Intent        -- What and why (prose)
2. Contract      -- Interfaces, types, signatures (structured)
3. Test cases    -- Concrete input/output pairs (executable)
4. Constraints   -- Performance, security, style bounds (prose)
5. Anti-patterns -- What NOT to do (prose)

NOT in the plan:
- Implementation code
- Pseudocode for function bodies
- Specific algorithms (unless the algorithm IS the requirement)
```

The AgentCoder research validates this: when test cases are generated independently from implementation, pass rates increase dramatically (96.3% vs 90.2% for state-of-the-art at the time).

### Design-by-Contract for Agent Plans

**Principle**: Every plan section is a contract with preconditions, postconditions, and invariants.

**Application**:

```
## Function: authenticateUser(credentials: Credentials): AuthResult

### Preconditions (what must be true before)
- credentials.email is a valid email format
- credentials.password is non-empty
- Rate limiter has not exceeded 5 attempts per minute per IP

### Postconditions (what must be true after)
- On success: returns AuthResult with valid JWT, sets httpOnly cookie
- On failure: returns AuthResult with error code, increments rate limiter
- In all cases: audit log entry created

### Invariants (what must always hold)
- Password is never logged or stored in plaintext
- JWT expiry is always <= 15 minutes
- Refresh token expiry is always <= 7 days
```

This approach works because:
1. Workers can verify their own implementation against contracts
2. Test agents can generate tests directly from pre/postconditions
3. Review agents can check contract compliance without understanding internals
4. Contract violations are detectable by static analysis or simple assertion checks

### Conformance Testing Pattern (Addy Osmani, verified)

Build **language-independent conformance suites** (often YAML-based) derived directly from the spec:

```yaml
# conformance/auth.yaml
tests:
  - name: "Valid login returns JWT"
    input:
      email: "user@example.com"
      password: "valid-password"
    expected:
      status: 200
      body:
        token: { type: "string", pattern: "^eyJ" }
        expiresIn: { lte: 900 }

  - name: "Invalid password returns 401"
    input:
      email: "user@example.com"
      password: "wrong"
    expected:
      status: 401
      body:
        error: "INVALID_CREDENTIALS"
```

These conformance suites are more rigorous than ad-hoc unit tests because they are derived directly from the spec and can be reused across implementations.

---

## Common Pitfalls

| Pitfall | How to Avoid |
|---------|-------------|
| **Plan contains literal code** | Workers implement bugs faithfully. Use contracts + test cases instead of code. |
| **Monolithic plan** | Errors compound over agent running time (Stack Overflow 2026). Decompose into verifiable chunks. |
| **Tests generated from implementation** | Confirmation bias. Generate tests from spec independently (AgentCoder pattern). |
| **No plan simulation** | Logical errors pass to coding phase. Simulate with concrete I/O before coding (CODESIM pattern). |
| **Flat agent topology** | 17x error amplification in "bag of agents." Use structured layers with closed-loop validation. |
| **Static spec** | Spec drifts from reality silently. Treat spec as living document; agents maintain it actively. |
| **Over-specified plan** | Plan becomes the implementation, containing its own bugs. Specify contracts and constraints, not code. |
| **Under-specified plan** | Workers fill gaps with assumptions. Include at minimum: interface contracts + behavioral examples. |
| **No checkpoint verification** | Entire implementation may be wrong. Verify each chunk before proceeding (Devin pattern). |

---

## Actionable Summary for Multi-Agent Plugin Systems

### For Plan Authors (Planner Agents)

1. Structure plans as: Intent -> Contracts -> Test Cases -> Constraints -> Anti-patterns
2. Never include literal implementation code in plans
3. Include at least one concrete input/output example per function
4. Define pre/postconditions for every interface
5. Simulate the plan with example data before handing to workers

### For Worker Agents

1. Verify understanding of contracts before coding
2. Generate tests from contracts before writing implementation
3. Implement in chunks, verifying each against test cases
4. Report contract ambiguities back to planner rather than guessing

### For Verification Agents

1. Generate tests independently from implementation (AgentCoder pattern)
2. Check contract compliance, not implementation details
3. Use conformance suites derived from the spec
4. Verify cross-agent output consistency (RTADev alignment checking)

### For System Architects

1. Use closed-loop feedback between agents, not fire-and-forget delegation
2. Bound error propagation with chunk-level verification gates
3. Treat specs as enforceable contracts, not advisory documents
4. Apply quality gate hooks (TaskCompleted, TeammateIdle) to catch issues before propagation

---

## References

### Verified Sources (Accessed 2026-02-13)

- [AgentCoder: Multi-Agent Code Generation with Effective Testing and Self-optimisation](https://arxiv.org/html/2312.13010v3) -- Three-agent architecture separating code generation from test generation
- [CODESIM: Multi-Agent Code Generation through Simulation-Driven Planning](https://aclanthology.org/2025.findings-naacl.285/) -- Plan verification via step-by-step I/O simulation (NAACL 2025)
- [PGPO: Pseudocode-style Planning Guided Preference Optimization](https://arxiv.org/abs/2506.01475) -- P-code Plans outperform NL plans (ACL 2025 Findings)
- [MASAI: Modular Architecture for Software-engineering AI Agents](https://arxiv.org/abs/2406.11638) -- Modular sub-agent architecture with focused objectives
- [Addy Osmani: How to write a good spec for AI agents](https://addyosmani.com/blog/good-spec/) -- Spec structure, conformance testing, three-tier boundaries
- [Augment Code: Spec-Driven AI Code Generation with Multi-Agent Systems](https://www.augmentcode.com/guides/spec-driven-ai-code-generation-with-multi-agent-systems) -- Specification-as-contract enforcement
- [Augment Code: Spec-Driven Development & AI Agents Explained](https://www.augmentcode.com/guides/spec-driven-development-ai-agents-explained) -- Three-phase SDD methodology
- [Block/Goose: Does Your AI Agent Need a Plan?](https://block.github.io/goose/blog/2025/12/19/does-your-ai-agent-need-a-plan/) -- Planning spectrum: Architect/Director/Explorer strategies
- [Martin Fowler: Autonomous coding agents (Codex example)](https://martinfowler.com/articles/exploring-gen-ai/autonomous-agents-codex-example.html) -- Analysis of Codex agent planning limitations
- [Devin: Coding Agents 101](https://devin.ai/agents101) -- Checkpoint-gated implementation pattern
- [Stack Overflow: Are bugs inevitable with AI coding agents?](https://stackoverflow.blog/2026/01/28/are-bugs-and-incidents-inevitable-with-ai-coding-agents/) -- AI generates 1.7x more bugs; plan quality matters
- [TDS: Why Your Multi-Agent System is Failing (17x Error Trap)](https://towardsdatascience.com/why-your-multi-agent-system-is-failing-escaping-the-17x-error-trap-of-the-bag-of-agents/) -- Error amplification in flat agent topologies
- [RTADev: Intention Aligned Multi-Agent Framework](https://aclanthology.org/2025.findings-acl.80.pdf) -- Cross-agent alignment verification (ACL 2025)
- [SWE-agent Architecture](https://swe-agent.com/latest/background/architecture/) -- Localization-first agent design
- [Arize AI: Optimizing Coding Agent Rules](https://arize.com/blog/optimizing-coding-agent-rules-claude-md-agents-md-clinerules-cursor-rules-for-improved-accuracy/) -- Rules files for agent behavior configuration

### Local Codebase Context

- `.rune/echoes/planner/MEMORY.md` -- Documents design-vs-implementation gap detection pattern relevant to plan quality
