# Anti-Rationalization Engineering

Anti-rationalization is not a prompt technique. It is an engineering discipline: the systematic
identification, cataloging, and structural elimination of paths by which agents bypass requirements.

Source: `docs/discipline-engineering.md` Section 6.

---

## The Iron Law

```
IF agent produces thought matching [pattern]:
THEN the required behavior is [behavior].
THIS IS NOT NEGOTIABLE.
```

Every pattern below is an instantiation of this law. The law is NON-NEGOTIABLE. It cannot be
suspended, overridden, or reasoned around by an agent at runtime.

---

## 6.1 Rationalization Taxonomy

Seven categories of rationalization are observed in multi-agent systems. Each has a distinct
structural countermeasure — not a suggestion, but a mechanism the agent cannot bypass.

| Category | Agent's Internal Logic | Why It's Dangerous | Structural Countermeasure |
|---|---|---|---|
| **Scope Minimization** | "The basic version covers the important cases" | Silently drops edge cases from the requirement | Criteria are atomic and enumerated. Cannot partially satisfy. |
| **Implicit Deferral** | "I'll handle this in a follow-up" | No follow-up mechanism exists. Deferred = deleted. | No task state for "deferred." Task is IN_PROGRESS or COMPLETE. |
| **Confidence Substitution** | "I'm confident this is correct" | Confidence is a language property, not an evidence property | Proofs are machine-executed. Agent confidence is irrelevant. |
| **Selective Attention** | "I'll focus on the core criteria" | Agent self-selects which criteria matter | ALL criteria must pass. No prioritization by agent. |
| **Complexity Avoidance** | "Error handling can be added later" | Error handling is typically in the specification | Error cases are explicit criteria with explicit proofs. |
| **Process Skepticism** | "This is too simple to need the full process" | Process exists because of past failures in "simple" cases | Gates are infrastructure. Cannot be opted out of per-task. |
| **Precedent Appeal** | "We didn't need this last time" | Each task is independently verified. Past is irrelevant. | No exception history. Every task goes through every gate. |

---

## 6.2 Anti-Rationalization Corpus

The corpus is a living catalog of observed rationalizations paired with required behaviors.
It is embedded in every agent's operating context — not as a suggestion but as a structural constraint.

New rationalization patterns discovered in production are added to the corpus. The corpus grows;
it never shrinks.

### Domain 1: Task Execution

| Agent Thought | Required Behavior |
|---|---|
| "This is straightforward, I don't need to echo back" | Echo is mandatory for ALL tasks. No exceptions. |
| "I already know this codebase" | Knowledge doesn't replace verification. Echo and prove. |
| "The criteria are obvious" | If obvious, echo takes seconds. If not, echo catches the gap. |
| "This change is too small to need verification" | Small changes with small proofs. Still required. |
| "I'll add tests after the implementation" | Tests are part of acceptance criteria. Order is irrelevant — all must pass. |

### Domain 2: Completion Claims

| Agent Thought | Required Behavior |
|---|---|
| "I'm confident this works" | Confidence is not evidence. Execute the proof. |
| "Just this one time" | One exception sets a precedent for infinite exceptions. No. |
| "The tests I wrote pass" | Agent-authored tests verify agent-authored code. That's circular. Spec-defined proofs required. |
| "Should work" / "probably fine" | "Should" and "probably" are red flags. Re-verify with evidence. |
| "I'll verify this manually" | Manual verification by the implementer is not independent verification. |

### Domain 3: Process Compliance

| Agent Thought | Required Behavior |
|---|---|
| "This is just a greeting, not a task" | Process applies to ALL interactions. The Iron Law. |
| "I need to explore first, process can come later" | Process guides exploration. Always first. |
| "The process slows me down" | Rework from unverified output is 10x slower than the process. |
| "I already did this before" | Each session is fresh. No memory. Process every time. |
| "Let me just fix this quick" | Quick fixes skip understanding. Understand → Plan → Execute → Verify. |

---

## 6.3 Structural vs. Instructional Anti-Rationalization

There are two approaches to preventing rationalization. Only one works.

**Instructional** (weak):
> "Please make sure to verify your work before marking it complete."

An instruction adds a suggestion to the agent's context. The agent can reason around it.
The agent can decide the instruction doesn't apply to this particular case.
The agent can believe it has satisfied the instruction without satisfying it.

**Structural** (strong):
> The `task-completed` event handler blocks the transition unless the evidence directory
> contains a passing proof for every criterion.

A structural mechanism modifies the *environment*. The agent's belief about its own compliance
is irrelevant. If evidence does not exist, the transition is blocked — regardless of what the
agent thinks.

**The test for any countermeasure**:
> Can the agent bypass this by deciding it doesn't apply?

- If YES → it is instructional. It is a suggestion. It is not a countermeasure.
- If NO → it is structural. It is a constraint. It can count.

Every countermeasure in this framework MUST be structural. "Write your tests" is not a
countermeasure. Blocking `TaskUpdate(status: completed)` until tests exist is a countermeasure.

---

## Application Rules

1. **Corpus is exhaustive within domains** — an agent that identifies a rationalization not in
   the corpus must still apply the Iron Law. "Not listed" is not an exemption.

2. **Patterns are forward-looking** — the corpus does not describe what agents did wrong in the
   past. It describes what must happen when a matching thought is produced, now and in the future.

3. **No precedent immunity** — an agent that complied last time has no different obligation than
   an agent completing its first task. "I've done this correctly before" is itself a Precedent
   Appeal rationalization (Category 7).

4. **All domains apply simultaneously** — an agent completing a task is simultaneously bound by
   Domain 1 (task execution), Domain 2 (completion claims), and Domain 3 (process compliance).
   There is no ordering. All three operate in parallel.

5. **Structural gates are the primary defense** — instructional reminders in this document are
   secondary. The primary anti-rationalization mechanism is the blocking event handler in
   `validate-test-evidence.sh` and the `TaskCompleted` hook infrastructure.
