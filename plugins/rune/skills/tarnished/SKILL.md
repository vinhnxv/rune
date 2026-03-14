---
name: tarnished
description: |
  Intelligent master command for all Rune workflows. Parses natural language
  to route to the correct /rune:* skill, chains multi-step workflows, and
  checks prerequisites automatically. The Tarnished's unified entry point.

  Use when the user says "/tarnished plan ...", "/tarnished work ...",
  "/tarnished review ...", or any natural language describing what they
  want Rune to do. Handles Vietnamese and English input.

  Common usage:
    /rune:tarnished plan add user authentication
    /rune:tarnished work plans/my-plan.md
    /rune:tarnished review
    /rune:tarnished review and fix
    /rune:tarnished arc plans/my-plan.md
    /rune:tarnished arc-batch plans/*.md
    /rune:tarnished arc-issues --label "rune:ready"
    /rune:tarnished thảo luận rồi tạo plan cho feature X

  Also serves as a Rune expert — can explain how Rune works, recommend
  workflows, teach best practices, and guide developers through complex
  scenarios. Ask "/rune:tarnished help" or "/rune:tarnished what should I do?"

  Keywords: tarnished, master command, route, guide, what should I do,
  figure it out, do everything, help me, which command, rune help,
  how does rune work, explain, teach, recommend, best practice,
  brainstorm, explore idea, khám phá, thảo luận, mcp, mcp integration,
  untitledui, setup mcp, tích hợp mcp, cài đặt mcp.

  <example>
  user: "/rune:tarnished plan add dark mode"
  assistant: "The Tarnished heeds your call. Routing to /rune:devise..."
  </example>

  <example>
  user: "/rune:tarnished arc plans/feat-auth-plan.md"
  assistant: "The Tarnished heeds your call. Routing to /rune:arc..."
  </example>

  <example>
  user: "/rune:tarnished arc-batch plans/*.md"
  assistant: "The Tarnished heeds your call. Routing to /rune:arc-batch..."
  </example>

  <example>
  user: "/rune:tarnished review and fix"
  assistant: "The Tarnished charts a two-step path: appraise → mend..."
  </example>

  <example>
  user: "/rune:tarnished"
  assistant: "The Tarnished awaits your command. What would you have me do?"
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[plan|work|review|arc|arc-batch|...] [args]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - AskUserQuestion
  - Skill
---

# /rune:tarnished — The Tarnished's Command

The unified entry point for all Rune workflows. Understands natural language,
routes to the correct skill, checks prerequisites, and chains multi-step workflows.

**References**:
- [Rune knowledge](references/rune-knowledge.md) — deep Rune expertise for guidance and education
- [Intent patterns](references/intent-patterns.md) — classification rules and keyword mapping
- [Workflow chains](references/workflow-chains.md) — multi-step chain definitions
- [Skill catalog](references/skill-catalog.md) — full Rune skill reference with prerequisites

## Execution Flow

### Phase 1: Parse Input

Read `$ARGUMENTS`. Three paths:

**Path A — Empty input** (no arguments):
```
→ Enter interactive mode
→ Scan current project state (plans/, tmp/, git status)
→ AskUserQuestion: "What would you have the Tarnished do?"
  Options based on current state:
  - If uncommitted changes exist: "Review my changes" (→ appraise)
  - If plans/ has recent plans: "Implement latest plan" (→ strive)
  - If TOME exists: "Fix review findings" (→ mend)
  - If docs/brainstorms/ has recent brainstorms: "Continue brainstorming" (→ brainstorm)
  - Always: "Brainstorm an idea" (→ brainstorm)
  - Always: "Plan a new feature" (→ devise)
```

**Path B — Fast-path keyword** (first word matches a known skill):
```
→ Extract first word from $ARGUMENTS
→ Match against fast-path keyword table (see intent-patterns.md)
→ If match: route immediately to target skill with remaining args
→ Example: "plan add auth" → Skill("rune:devise", args: "add auth")
```

Fast-path keywords: `plan`, `work`, `review`, `brainstorm`, `explore`, `devise`,
`strive`, `appraise`, `audit`, `arc`, `arc-batch`, `arc-issues`, `arc-hierarchy`,
`forge`, `mend`, `inspect`, `goldmask`, `elicit`, `rest`, `echoes`, `clean`,
`ship`, `fix`, `debug`, `cancel`, `mcp`, `untitledui`, `design-sync`, `elevate`,
`file-todos`, `learn`, `resolve-comments`, `resolve-comment`, `resolve-todos`,
`skill-testing`, `team-status`, `test-browser`, `ux`, `team-delegate`.

**Path C — Natural language** (no keyword match):
```
→ Read references/intent-patterns.md for classification rules
→ Classify intent into: direct | chain | contextual | exploratory | meta
→ Route based on classification (see Phase 2)
```

### Phase 2: Classify & Route

#### Direct Intent (single skill)

The input clearly maps to one Rune skill. Route immediately.

```
Invoke via: Skill("{skill-name}", args: "{extracted args}")
```

#### Chain Intent (multi-step)

Connectors detected: "then", "and", "after that", "rồi", "sau đó", "xong thì".

```
1. Read references/workflow-chains.md
2. Match to a defined chain pattern
3. Present the chain to user:

   The Tarnished charts the path:
     Step 1: {description} → /rune:{skill1}
     Step 2: {description} → /rune:{skill2}

4. AskUserQuestion:
   - "Proceed with full chain"
   - "Just step 1"
   - "Modify the plan"

5. Execute step by step with confirmation between steps
```

#### Contextual Intent (needs prerequisite check)

Input implies a skill but doesn't specify required input (e.g., "implement it" without a plan path).

```
1. Read references/skill-catalog.md for prerequisite map
2. Scan for required artifacts:
   - Plans: Glob("plans/*.md") → sort by date → latest
   - TOMEs: Glob("tmp/reviews/*/TOME.md") or Glob("tmp/audit/*/TOME.md")
   - Git changes: Bash("git diff --stat HEAD")
3. If prerequisite found → route with artifact path
4. If prerequisite missing → guide user:
   "No plan found. Would you like to create one first?"
   → AskUserQuestion with options
```

#### Exploratory Intent (discussion/research first)

User wants to think before acting.

```
1. If idea exploration / brainstorm intent → Skill("rune:brainstorm", args: "{topic}")
2. If structured reasoning needed → Skill("rune:elicit", args: "{topic}")
3. If research needed → gather context inline (Read, Grep, Glob)
4. After exploration, suggest next step:
   "Ready to create a plan?"
   → AskUserQuestion
```

#### Meta Intent (about Rune)

User asks about capabilities or status.

```
"help" / "what can you do":
  → Display capability summary from skill-catalog.md
  → Highlight most common commands

"status" / "what's next":
  → Scan artifacts:
    - plans/ for recent plans
    - tmp/reviews/ for recent TOMEs
    - tmp/work/ for recent work sessions
    - git status for uncommitted changes
  → Suggest logical next step
```

### Phase 3: Execute

For **single-step** routing:
```
Invoke: Skill("{target-skill}", args: "{passthrough args}")
```

For **chain** execution:
```
1. Invoke step 1: Skill("{skill1}", args: "{args1}")
2. After completion, check next step prerequisites
3. AskUserQuestion: "Step 1 complete. Proceed to step 2?"
4. If yes → Invoke step 2: Skill("{skill2}", args: "{args2}")
5. Repeat until chain complete
```

## Persona

Use Rune's Elden Ring-inspired tone, brief and purposeful:

```
The Tarnished heeds your call.
→ Routing to /rune:devise — planning "add user authentication"...
```

```
The Tarnished charts the path:
  Step 1: Review → /rune:appraise
  Step 2: Mend   → /rune:mend {TOME from step 1}
Shall we proceed?
```

```
The Tarnished surveys the Lands Between...
  📋 1 plan found: plans/2026-02-25-feat-auth-plan.md
  📝 No active reviews
  🔀 12 files changed (uncommitted)
What would you have me do?
```

## Guidance Mode

When the user asks questions about Rune (how it works, what to do, best practices),
load [rune-knowledge.md](references/rune-knowledge.md) and provide educational guidance.

### Help / Capability Overview
```
/rune:tarnished help
/rune:tarnished what can you do?
/rune:tarnished rune là gì?
```
→ Read references/rune-knowledge.md
→ Present a concise overview tailored to the user's apparent experience level
→ Suggest the most relevant next action based on current project state

### Workflow Recommendation
```
/rune:tarnished what should I do next?
/rune:tarnished tôi nên làm gì tiếp?
```
→ Scan project state (plans/, tmp/, git status, git log)
→ Read references/rune-knowledge.md "Decision Tree" section
→ Recommend the logical next step with explanation

### Best Practice Guidance
```
/rune:tarnished how do I review code?
/rune:tarnished explain the arc pipeline
/rune:tarnished khi nào nên dùng audit vs review?
```
→ Read references/rune-knowledge.md for relevant section
→ Read references/skill-catalog.md for details
→ Explain with context from the user's actual codebase

### MCP Integration Guidance
```
/rune:tarnished mcp
/rune:tarnished how to add mcp
/rune:tarnished setup untitledui
/rune:tarnished tích hợp mcp
```
→ Read references/rune-knowledge.md "MCP Integration" section
→ For setup: route to `/rune:talisman guide integrations`
→ For UntitledUI-specific: explain setup + route to talisman guide

### Troubleshooting
```
/rune:tarnished the review found too many issues
/rune:tarnished arc failed at mend phase
/rune:tarnished how to resume?
```
→ Read references/rune-knowledge.md "Common Pitfalls" section
→ Provide specific, actionable guidance

## Edge Cases

1. **Ambiguous intent**: When classification is uncertain, ask — don't guess.
   Use AskUserQuestion with the top 2-3 interpretations.

2. **Conflicting chain**: e.g., "plan and review" (review needs code, not a plan).
   Explain the dependency and suggest the correct chain.

3. **Already running workflow**: Check for `tmp/.rune-*.json` state files.
   Warn if a workflow is active and suggest waiting or cancelling.

4. **Flag passthrough**: Flags like `--quick`, `--deep`, `--approve` pass through
   to the target skill unchanged. Example:
   `/rune:tarnished plan --quick add auth` → `Skill("rune:devise", args: "--quick add auth")`
