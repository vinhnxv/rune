# Discipline Engineering — Field Notes

## Patterns Observed in Production Multi-Agent Systems

> *This companion document to [discipline-engineering.md](discipline-engineering.md) captures field-observed patterns that validate, extend, or refine the core Discipline Engineering framework. These are recurring patterns discovered independently across production agent systems — empirical evidence that the theory holds in practice.*

**Version**: 1.1.0
**Date**: 2026-03-16
**Status**: Active — Living document

---

## Table of Contents

1. [Purpose](#1-purpose)
2. [The Plan-as-Prompt Paradigm](#2-the-plan-as-prompt-paradigm)
3. [Skill Composition and Contract Boundaries](#3-skill-composition-and-contract-boundaries)
4. [Phantom Completions](#4-phantom-completions)
5. [Context Window as Architectural Constraint](#5-context-window-as-architectural-constraint)
6. [Probabilistic Failure and Recovery](#6-probabilistic-failure-and-recovery)
7. [File-Based State Machines](#7-file-based-state-machines)
8. [The DRY Principle for Agent Instructions](#8-the-dry-principle-for-agent-instructions)
9. [Files as Message Passing — Token-Optimized IPC](#9-files-as-message-passing--token-optimized-ipc)
10. [Convergence Mapping](#10-convergence-mapping)

---

## 1. Purpose

Discipline Engineering was developed from first principles within the Rune project. This document collects field-observed patterns from production multi-agent systems that validate, extend, or refine the core framework.

Each section maps a field pattern to specific Discipline Engineering concepts, noting where the evidence confirms the theory — and where it reveals nuances the theory should absorb.

**Criteria for inclusion**: A pattern must be (a) independently recurring across systems, (b) validated in production use, and (c) mappable to at least one Discipline Engineering principle.

---

## 2. The Plan-as-Prompt Paradigm

### 2.1 The Pattern

When AI agents work on non-trivial tasks, context windows fill up and trigger automatic compaction — a lossy compression of conversation history. The agent forgets architectural decisions, rejected approaches, and agreed-upon details. The conversation appears unchanged to the user, but the agent is operating on degraded context.

The field-proven solution: **write a structured markdown plan before executing**, then start a fresh session and point the agent at the plan file. The plan becomes the sole input — eliminating reliance on conversation history entirely.

> *"The plan IS the prompt. Starting fresh sessions becomes an advantage rather than a restart."*

### 2.2 Mapping to Discipline Engineering

This independently validates two core principles:

| Field Pattern | Discipline Engineering Equivalent | Reference |
|---------------|----------------------------------|-----------|
| Plan file as sole execution input | **Spec Continuity** (Section 8): "The plan file must be the persistent reference for ALL pipeline phases, not consumed once and forgotten" | §8.1 |
| Close session → open fresh → execute from plan | **Context Isolation** (Section 9): Workers receive task files, not conversation history | §9.4 |
| Checkboxes for phase tracking | **State Machine model** (Section 5): Task lifecycle with explicit transitions | §5.1 |
| Execution log in plan file | **Evidence Artifacts** (Section 7): Persisted proof records with timestamps | §7.2 |

### 2.3 What Rune Automates

The manual version of this workflow:
1. Ask the agent to write a plan
2. Review and iterate
3. Manually close and reopen sessions
4. Direct the agent to the plan file

Rune automates this entire loop:
- `/rune:devise` → multi-agent plan generation with research, validation, and review
- `/rune:arc` → fresh agent context per phase via Agent Teams, plan file as persistent input
- Arc checkpoint/resume → file-based state replaces manual checkbox tracking

### 2.4 Insight for Discipline Engineering

Field practitioners managing **hundreds of plans** across multiple projects confirm that plan-centric workflows are sustainable at scale. The pattern holds across project sizes and domains. This validates the Discipline Engineering assertion that **spec continuity is non-negotiable** — not merely a best practice but a structural requirement.

---

## 3. Skill Composition and Contract Boundaries

### 3.1 The Pattern

Skills — markdown files that tell agents how to complete tasks — are the composable unit of agent systems. The composition pattern mirrors microservices:

| Microservices | Skill Engineering |
|---------------|------------------|
| API contracts (typed) | Natural language prompts (untyped) |
| Independent deployment | Independent execution |
| Failure isolation | Context isolation |
| Service discovery | Skill routing |

The critical difference: **contracts are natural language, not type signatures**. Contract violations are semantic, not syntactic — they cannot be caught by a compiler.

### 3.2 Mapping to Discipline Engineering

This maps directly to the **Compliance Hierarchy** (Section 3):

| Level | Microservices | Skill Engineering | Discipline Response |
|-------|--------------|-------------------|---------------------|
| 1 | Type mismatch → compile error | Capability gap → agent can't do it | Decompose into simpler tasks |
| 2 | Runtime error → exception | Context degradation → agent forgets | Context budgets, isolation |
| 3 | Logic bug → wrong result | Comprehension failure → agent misunderstands | Echo protocol, verification |
| 4 | N/A (deterministic) | **Rationalization → agent bypasses knowingly** | Anti-rationalization engineering |

Level 4 has no microservices equivalent. This is the unique challenge of agent systems and the reason Discipline Engineering exists as a distinct discipline. Traditional software doesn't selectively ignore its own requirements.

### 3.3 The Natural Language Contract Problem

When contracts are natural language, enforcement requires **semantic verification** — not just "did the function return 200?" but "did the agent actually do what the instruction means?"

This is why Discipline Engineering requires:
- **Echo Protocol** (Section 6): Agent restates criteria in its own words before execution
- **Separation Principle** (Section 7): Implementer ≠ Verifier — the agent cannot certify its own compliance
- **Machine Proof over Model Proof** (Section 7): Where possible, replace semantic judgment with deterministic checks

### 3.4 Insight for Discipline Engineering

The microservices analogy reveals an architectural truth: **agent systems need the same rigor as distributed systems, but with weaker contract guarantees**. Discipline Engineering compensates for weak contracts through evidence-based verification — the proof replaces the type system.

---

## 4. Phantom Completions

### 4.1 The Pattern

A recurring field pattern: agents write a status file claiming success, but the actual output doesn't exist. The status file is the lie; the filesystem is the truth.

The field-proven fix: **write outputs before status files**, then implement three-level recovery:
1. Verify output exists
2. Retry if missing
3. Log for analysis

### 4.2 Mapping to Discipline Engineering

Phantom completions are a specific instance of **Deception 1: The Completion Illusion** (Section 1.4):

> *"The agent marks the task complete. The orchestrator accepts this signal at face value. No one verifies whether 'complete' means 'all acceptance criteria are met' or 'I wrote some code and it compiles.'"*

Discipline Engineering's response is more comprehensive:

| Field Fix | Discipline Engineering Equivalent |
|-----------|----------------------------------|
| Write output before status | **Evidence-before-transition** invariant: no state transition without proof artifact |
| Verify output exists | **Machine Proof** (file_exists, test_passes, pattern_matches) |
| Retry if missing | **Escalation Chain**: retry → decompose → reassign → human (Section 10) |
| Log for analysis | **Failure Taxonomy** with 17 classified failure codes (Section 10.1) |

### 4.3 The Evidence-First Invariant

The temporal ordering of "output before status" articulates a principle that Discipline Engineering should make explicit:

> **The Evidence-First Invariant**: In any agent workflow, the evidence artifact must be persisted BEFORE the state transition that claims completion. Reversing this order creates a window where the system believes work is done but no proof exists.

This is analogous to the write-ahead log (WAL) in database systems — the proof is the WAL entry, the state transition is the commit.

### 4.4 Failure Code Mapping

Phantom completions map to multiple failure codes in the Discipline taxonomy:

| Scenario | Failure Code |
|----------|-------------|
| Status says done, output file missing | F3 (PROOF_FAILURE) |
| Status says done, output exists but empty/wrong | F12 (EVIDENCE_FABRICATED) |
| Status says done, output is from a previous run | F11 (EVIDENCE_STALE) |

---

## 5. Context Window as Architectural Constraint

### 5.1 The Pattern

Field practitioners identify the context window not as a temporary limitation to be worked around, but as a **fundamental architectural constraint** that shapes system design:

> *Token limitations fundamentally constrain agent orchestration.*

The optimization strategy: move information to external files, reducing spawn prompts from paragraphs to single lines like `"Validate bug 47. Read context.md for instructions."`

### 5.2 Mapping to Discipline Engineering

This validates the **Context Budget** concept (Section 4) and the rationale behind Context Isolation (Section 9.4):

| Context Strategy | Purpose | Discipline Principle |
|-----------------|---------|---------------------|
| External file references instead of inline content | Minimize spawn prompt size | Context Budgets |
| Workers receive only their task file, not full pool | Prevent cross-contamination | Context Isolation |
| Plan file as persistent reference, not conversation replay | Survive compaction | Spec Continuity |
| Single-line spawn prompts | Maximize reasoning tokens | Token Budget Allocation |

### 5.3 The Constraint Principle

Field evidence suggests Discipline Engineering should elevate token budgeting from a practical concern to a **first-class design principle**:

> **The Constraint Principle**: Context window limits are not bugs to be fixed by larger models. They are architectural constraints that enforce good design — separation of concerns, minimal coupling, explicit contracts. A system that works within token limits will work BETTER with larger limits, not differently.

This parallels how memory constraints in early computing drove efficient data structures — the constraint produced better engineering, not just smaller programs.

---

## 6. Probabilistic Failure and Recovery

### 6.1 The Pattern

Field observation reports an approximately **5% failure rate** even with identical inputs. This is fundamentally different from traditional software, where identical inputs produce identical outputs (deterministic). Agent systems are **stochastic** — the same input can produce different outputs, including failures.

### 6.2 Mapping to Discipline Engineering

This validates the entire **Failure Taxonomy** (Section 10) and **Escalation Chain** design:

| Traditional Engineering | Agent Engineering (Discipline) |
|------------------------|-------------------------------|
| Bug → fix → resolved permanently | Failure → fix → may recur stochastically |
| Test passes = code works | Test passes = code worked THIS TIME |
| Retry is suspicious (same input, same output) | Retry is standard recovery (same input, different output) |
| Failure rate is a bug count | Failure rate is a probability distribution |

### 6.3 Implication for Verification

If agent execution is probabilistic, then **single-pass verification is insufficient**. A task that passes verification once may fail on re-execution. This strengthens the case for:

1. **Machine proofs over model proofs** — deterministic checks on output artifacts, not re-asking the agent
2. **Evidence artifacts** — proofs persist beyond the execution that created them
3. **Convergence loops** — multiple iterations catch stochastic failures that single passes miss
4. **The Separation Principle** — the verifier must be independent of the implementer because the implementer's behavior is non-deterministic

### 6.4 The Stochastic Budget

The ~5% figure provides a useful engineering heuristic:

> **The Stochastic Budget**: In a pipeline with N agent executions, expect approximately N × 0.05 failures even when everything is configured correctly. Design recovery capacity accordingly. A 20-task pipeline should budget for 1 failure per run as baseline, not as exception.

This reframes failure from "something went wrong" to "statistical expectation met." Discipline Engineering's escalation chain (retry → decompose → reassign → human) is not error handling — it is **normal operation** for a stochastic system.

---

## 7. File-Based State Machines

### 7.1 The Pattern

For resumable pipelines, practitioners consistently choose **file-based state tracking** over databases or message queues. Checkboxes in markdown files serve as state markers. Directory scanning determines where to resume.

### 7.2 Mapping to Discipline Engineering

This validates the **State Machine** design (Section 5) and the file-based approach used throughout Rune:

| Field Pattern | Rune Implementation | Discipline Principle |
|---------------|---------------------|---------------------|
| Markdown checkboxes `[x]` / `[ ]` | Task files with YAML status fields | Explicit state, no implicit assumptions |
| Directory scanning for resume | Arc checkpoint files in `tmp/arc/` | State survives session boundaries |
| Numbered plan files (01, 02, 03) | Plan frontmatter with phase numbering | Ordered execution with dependencies |
| Subplans (04.1, 04.2) | Arc-hierarchy with DAG dependencies | Decomposition preserves relationships |

### 7.3 Why Files, Not Databases

Multiple practitioners independently chose files over databases for agent state. The reasons converge:

1. **Transparency**: Files are human-readable. A developer can `cat` the state. Databases require queries.
2. **Agent accessibility**: Agents can read/write files natively. Database access requires tool configuration.
3. **Git compatibility**: File state can be versioned. Database state requires migration tooling.
4. **Crash recovery**: Files survive process crashes. In-memory state does not. Database state survives but requires connection recovery.
5. **Simplicity**: No connection strings, no schema migrations, no ORM. The filesystem IS the state store.

### 7.4 Insight for Discipline Engineering

> **The Filesystem-as-Database Principle**: For agent orchestration state, the filesystem is the optimal storage medium — not because it's simpler than a database, but because it's the medium agents already operate in. Every additional abstraction layer between the agent and its state is a potential point of failure and context cost.

---

## 8. The DRY Principle for Agent Instructions

### 8.1 The Pattern

Duplicated knowledge across skills creates maintenance problems in production. The field-proven solution: **separate skills (procedures) from documentation (facts)**.

- Skills define WHAT to do and WHEN
- Documentation files define HOW things work and WHY
- Skills reference documentation; they don't inline it

Updating a shared fact in one place propagates to all skills that reference it.

### 8.2 Mapping to Discipline Engineering

This validates Rune's existing architecture:

| Field Pattern | Rune Implementation |
|---------------|---------------------|
| Skills (procedures) | `skills/<name>/SKILL.md` — orchestration logic |
| Documentation (facts) | `skills/<name>/references/*.md` — detailed knowledge |
| Shared knowledge | `prompts/` — cross-skill templates |
| Single-line references | SKILL.md links to reference files, loaded on demand |

### 8.3 Relevance to Discipline Engineering

The DRY principle for agent instructions connects to **Spec Continuity** (Section 8):

- If a discipline rule is defined in multiple places, updates to one may not propagate to others
- A worker reading a stale copy of a rule will follow stale rules
- The single-source-of-truth principle applies to agent instructions just as it applies to code

> **The Single Spec Principle**: Every discipline rule, every acceptance criterion, every verification requirement must have exactly one authoritative source. All references must be pointers to that source, not copies of it. Copies drift. Pointers don't.

---

## 9. Files as Message Passing — Token-Optimized IPC

### 9.1 The Reframing

Traditional distributed systems use message passing optimized for **network I/O** — latency, throughput, serialization cost, delivery guarantees. Agent systems use file-based communication optimized for an entirely different constraint: **token budgets**.

This is not a simplification. It is a **paradigm shift in inter-process communication**.

| Dimension | Traditional IPC (Network) | Agent IPC (Files) |
|-----------|--------------------------|-------------------|
| **Bandwidth** | Network throughput (Gbps) | Context window (tokens) |
| **Bottleneck** | Serialization + network latency | Token consumption per message |
| **Optimization target** | Minimize latency, maximize throughput | Minimize tokens consumed, maximize reasoning capacity |
| **Message format** | Binary protocols (protobuf, gRPC) | Structured text (markdown, JSON, YAML) |
| **Contract enforcement** | Type systems, schema validation | Semantic verification, echo protocols |
| **Delivery guarantee** | At-least-once, exactly-once | File-exists check (Evidence-First Invariant) |
| **Backpressure** | Queue depth, rate limiting | Context budget exhaustion |
| **Failure mode** | Network partition, timeout | Phantom completion, context corruption |
| **State persistence** | Database, message queue | Filesystem (the medium agents already operate in) |

The critical insight: **in agent systems, every byte of communication that enters the context window displaces a byte of reasoning capacity**. A 2000-token inline prompt costs the same as 2000 tokens of reasoning the agent can no longer do. Network IPC has no equivalent cost — sending a message doesn't reduce the receiver's compute capacity.

### 9.2 The Token-Cost Model of Communication

In network IPC, the cost model is:

```
cost = serialization_time + network_latency + deserialization_time
```

In agent IPC, the cost model is:

```
cost = tokens_consumed_by_message / total_context_window
```

This means communication has a **direct opportunity cost** — every token spent on coordination is a token NOT spent on the actual task. This fundamentally changes how communication should be designed:

| Network IPC Design | Agent IPC Design | Why |
|-------------------|------------------|-----|
| Rich request/response payloads | Minimal spawn prompts with file references | Inline content consumes reasoning tokens |
| Verbose logging at every step | Write evidence to files, not conversation | Logs in context displace task reasoning |
| Chatty protocols (heartbeats, acks) | Write-once completion signals (SEAL) | Each message costs tokens |
| Centralized message broker | Direct file reads from shared directory | No broker overhead in context window |
| Schema-heavy envelopes | Convention-based file naming | Schema metadata wastes tokens |

### 9.3 The Three Communication Patterns in Agent IPC

Field observation reveals three distinct file-based communication patterns, each optimized differently:

#### Pattern 1: Inscription (Orchestrator → Workers)

The orchestrator writes a structured assignment file BEFORE spawning agents. Each agent reads only its slice.

```
Orchestrator writes:  tmp/{workflow}/{id}/inscription.json
Agent A reads:        inscription.teammates[0]  (its file scope, output path)
Agent B reads:        inscription.teammates[1]  (its file scope, output path)
```

**Token optimization**: The spawn prompt is a single line — `"Read your assignment from inscription.json"` — instead of inlining the full assignment (potentially thousands of tokens). The agent reads the file into its own context, paying the token cost only once instead of the orchestrator paying it for every spawn.

**Network IPC equivalent**: Service discovery + task queue. But in network IPC, the queue broker is a separate process. In agent IPC, the "broker" is a file — zero runtime overhead, zero token cost to the orchestrator.

#### Pattern 2: Evidence Handoff (Workers → Aggregator)

Each worker writes structured output to its own file. An aggregator reads all files and produces a unified summary.

```
Worker A writes:      tmp/{workflow}/{id}/worker-a.md
Worker B writes:      tmp/{workflow}/{id}/worker-b.md
Worker C writes:      tmp/{workflow}/{id}/worker-c.md
Aggregator reads:     tmp/{workflow}/{id}/*.md → writes TOME.md
```

**Token optimization**: Workers never communicate with each other. No fan-out, no broadcast, no context pollution. The aggregator is the ONLY entity that pays the token cost of reading all outputs — and it's a specialized agent whose entire context budget is allocated to this task.

**Network IPC equivalent**: Fan-in pattern / scatter-gather. But in network IPC, the coordinator holds connections to all workers. In agent IPC, the "connections" are file paths — the aggregator's context isn't polluted by connection state.

#### Pattern 3: Checkpoint (Phase N → Phase N+1)

Each pipeline phase writes its results to a checkpoint file. The next phase reads it to understand prior state.

```
Phase 2 writes:       .rune/arc/{id}/checkpoint.json  (plan_quality_score: 85)
Phase 3 reads:        checkpoint.json → decides whether to proceed or loop
Phase 3 writes:       checkpoint.json  (updated with phase 3 results)
```

**Token optimization**: Each phase starts with a fresh context window. The checkpoint is the ONLY link between phases — a small JSON file (typically <500 tokens) that carries essential state without carrying the full history of how that state was reached.

**Network IPC equivalent**: Saga pattern / workflow state machine. But in network IPC, saga state lives in a database with connection overhead. In agent IPC, state is a file that the agent reads natively — no driver, no connection, no query language.

### 9.4 Why Most Teams Haven't Internalized This

The file-as-communication-channel pattern is counterintuitive for engineers trained in traditional distributed systems. The mental model mismatch:

1. **"Files are slow"** — In network IPC, files are slower than memory or sockets. In agent IPC, files are FASTER than inline content because they don't consume orchestrator context tokens until read by the intended recipient.

2. **"Files don't scale"** — In network IPC, file-based communication breaks down at high concurrency. In agent IPC, concurrency is bounded by the number of agents (typically <20), not by request throughput. The filesystem handles this trivially.

3. **"Files lack delivery guarantees"** — In network IPC, you need at-least-once/exactly-once semantics. In agent IPC, the Evidence-First Invariant (write output before status) provides a simpler guarantee: if the file exists, the work was done. If it doesn't, it wasn't. No acks, no retries at the protocol level.

4. **"Real systems use message queues"** — Message queues optimize for the wrong thing in agent systems. A queue broker consumes tokens (if in-process) or requires tool configuration (if external). Files are the native medium — agents already have Read/Write tools. No additional infrastructure.

### 9.5 The Token Budget as Backpressure Mechanism

In network IPC, backpressure prevents consumers from being overwhelmed — queue depth limits, rate limiting, circuit breakers. In agent IPC, the context window IS the backpressure mechanism:

- **Context fills up** → agent reasoning degrades → quality drops → this IS the signal that communication volume is too high
- **Spawn prompt is too large** → orchestrator context consumed → fewer agents can be spawned → this IS the capacity limit

The difference: network backpressure is explicit (queue full, 429 response). Agent backpressure is **silent** — the agent doesn't error, it just gets worse. This is why token budgets must be enforced proactively, not reactively.

This connects directly to the **Context Budget** concept in Discipline Engineering (Section 4) — but reframed: context budgets aren't just about preventing degradation. They are **flow control for agent IPC**.

### 9.6 Design Principles for Token-Optimized IPC

Based on field patterns observed across production systems:

> **Principle 1: Reference, Don't Inline**
> Never put content in a spawn prompt that could be read from a file. The spawn prompt should contain only identity (who you are), intent (what to do), and pointers (where to find details).

> **Principle 2: Pay Token Cost at the Consumer, Not the Producer**
> The agent that NEEDS the information should pay the token cost of reading it. The orchestrator should not pay the cost of loading content it only needs to forward.

> **Principle 3: Communication Must Be Write-Once**
> Agents should write their output once to a file and signal completion. No back-and-forth negotiation, no chatty protocols. Each message costs tokens that displace reasoning.

> **Principle 4: Aggregation is a Dedicated Role**
> The entity that reads all outputs should be a specialized agent whose entire context budget is allocated to aggregation — not the orchestrator juggling coordination AND synthesis.

> **Principle 5: State Carries Forward Minimally**
> Between phases, carry only the decisions and metrics — not the reasoning that produced them. A checkpoint says "quality_score: 85" not "I evaluated 30 criteria and found that..."

### 9.7 Rune Implementation Evidence

Rune's architecture embodies all five principles:

| Principle | Rune Implementation |
|-----------|---------------------|
| Reference, Don't Inline | Spawn prompts reference `inscription.json`; agent definition files loaded by agent, not orchestrator |
| Consumer Pays Token Cost | Each Ash reads its own file scope from inscription; orchestrator prompt stays <500 tokens |
| Write-Once Communication | SEAL protocol — single completion signal per agent, no negotiation |
| Aggregation as Dedicated Role | Runebinder agent — sole purpose is reading N findings files and producing unified TOME |
| Minimal State Carry-Forward | Arc checkpoint.json — carries scores, counts, and next-phase pointer, not full reasoning history |

### 9.8 Implications for Discipline Engineering

This reframing suggests two additions to the core framework:

1. **Token-Cost Accounting for Communication**: Every inter-agent communication should be budgeted not by message count or byte size, but by **tokens consumed from the receiver's reasoning capacity**. A 100-token file reference and a 2000-token inline prompt achieve the same information transfer — but the inline version costs 1900 tokens of reasoning capacity.

2. **Silent Backpressure Detection**: Unlike network systems where backpressure is explicit, agent systems degrade silently. Discipline Engineering should require **proactive monitoring of context utilization** — not waiting for quality degradation to signal overload, but enforcing hard limits before the context fills.

---

## 10. Convergence Mapping

### 10.1 Summary of Field-to-Theory Alignment

| Field Pattern | Discipline Engineering Principle | Validation Strength |
|---------------|----------------------------------|-------------------|
| Plan-as-prompt, fresh sessions | Spec Continuity + Context Isolation | **Strong** — independently discovered, same rationale |
| Skills-as-microservices | Compliance Hierarchy (Levels 1-4) | **Strong** — same decomposition, Discipline adds Level 4 (rationalization) |
| Phantom completions | Completion Illusion (Deception 1) + Evidence artifacts | **Strong** — same failure mode, Discipline provides deeper taxonomy |
| Context window as constraint | Context Budgets + Context Isolation | **Strong** — same conclusion, Discipline adds enforcement mechanisms |
| ~5% stochastic failure rate | Failure Taxonomy + Escalation Chain | **Strong** — Discipline reframes failure as expected, not exceptional |
| File-based state | State Machines (Section 5) | **Strong** — same design choice, same rationale |
| DRY for instructions | Spec Continuity + reference architecture | **Moderate** — same principle, different scope (instructions vs. specs) |
| Files as token-optimized IPC | Context Budgets + Context Isolation + Evidence Artifacts | **Strong** — extends theory with new framing: IPC cost = reasoning displacement |

### 10.2 Gaps Identified

Areas where field evidence suggests Discipline Engineering could expand:

1. **Explicit stochastic failure budgets**: Quantify expected failure rates per pipeline and design recovery capacity accordingly (see Section 6.4).
2. **Evidence-First Invariant**: Make the temporal ordering of evidence-before-transition a named principle (see Section 4.3).
3. **The Constraint Principle**: Elevate token budgets from practical concern to design driver (see Section 5.3).
4. **Token-Cost Accounting for IPC**: Budget inter-agent communication by tokens displaced from reasoning capacity, not by message count or byte size (see Section 9.8).
5. **Silent Backpressure Detection**: Agent systems degrade silently when context fills — require proactive monitoring rather than reactive quality checks (see Section 9.5).

---

## Appendix: Document Governance

This is a living document. New field patterns are added as they are discovered and validated.

**Inclusion criteria**:
- Pattern must be independently recurring across production systems
- Pattern must be validated in production use
- Pattern must map to at least one Discipline Engineering principle

**Update process**: New entries follow the established section format — Pattern → Mapping → Insight. Each entry must identify whether it confirms, extends, or challenges existing theory.
