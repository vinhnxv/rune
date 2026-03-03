# Workflow Chains

Multi-step workflow definitions for `/rune:tarnished`.

## Chain Execution Protocol

1. Present the chain to user before executing
2. Execute step 1
3. After step completes, confirm before proceeding to step 2
4. If any step fails or user declines, stop the chain gracefully
5. Between steps, re-check prerequisites for the next step

## Defined Chains

### brainstorm-then-plan

**Triggers**: "brainstorm then plan", "brainstorm rồi plan", "explore then plan", "khám phá rồi plan"

```
Step 1: /rune:brainstorm {idea}
   ↓ (brainstorm complete, workspace at tmp/brainstorm-{timestamp}/)
   ↓ Discover workspace: Glob("tmp/brainstorm-*") → use most recent match
Step 2: /rune:devise --brainstorm-context {discovered workspace path} {idea}
```

### brainstorm-then-arc

**Triggers**: "brainstorm then ship", "brainstorm rồi ship", "explore and build"

```
Step 1: /rune:brainstorm {idea}
   ↓ (brainstorm complete)
   ↓ Discover workspace: Glob("tmp/brainstorm-*") → use most recent match
Step 2: /rune:devise --brainstorm-context {discovered workspace path} {idea}
   ↓ (plan created at plans/*.md)
Step 3: /rune:arc {plan path from step 2}
```

### discuss-then-plan

**Triggers**: "discuss then plan", "thảo luận rồi tạo plan", "think about it then plan"

```
Step 1: /rune:elicit {topic}
   ↓ (user completes elicitation session)
Step 2: /rune:devise {topic + elicitation output as context}
```

### plan-then-work

**Triggers**: "plan and implement", "plan rồi triển khai", "plan then build"

```
Step 1: /rune:devise {feature description}
   ↓ (plan created at plans/*.md)
Step 2: /rune:strive {plan path from step 1}
```

### plan-then-arc

**Triggers**: "plan and ship", "plan rồi ship", "do everything from scratch"

```
Step 1: /rune:devise {feature description}
   ↓ (plan created at plans/*.md)
Step 2: /rune:arc {plan path from step 1}
```

### review-then-fix

**Triggers**: "review and fix", "review rồi sửa", "check and fix"

```
Step 1: /rune:appraise
   ↓ (TOME created at tmp/reviews/*/TOME.md)
Step 2: /rune:mend {TOME path from step 1}
```

### audit-then-fix

**Triggers**: "audit and fix", "audit rồi sửa", "full scan and fix"

```
Step 1: /rune:audit
   ↓ (TOME created at tmp/audit/*/TOME.md)
Step 2: /rune:mend {TOME path from step 1}
```

### work-then-review

**Triggers**: "implement then review", "triển khai rồi review"

```
Step 1: /rune:strive {plan path}
   ↓ (code committed)
Step 2: /rune:appraise
```

### research-then-plan

**Triggers**: "research then plan", "tìm hiểu rồi plan"

```
Step 1: Inline research (Tarnished gathers context directly)
   - Read relevant codebase files
   - Check git history
   - Web search if needed
   ↓ (research summary ready)
Step 2: /rune:devise {feature + research context}
```

### full-pipeline

**Triggers**: "ship it", "do everything", "làm hết", "end to end"

```
Step 1: /rune:arc {plan path}
   (This is already a full pipeline — no chaining needed)
```

Note: If no plan exists, suggest `/rune:devise` first.

## Chain Presentation Format

When presenting a chain to the user before execution:

```
The Tarnished charts the path forward:

  Step 1: Plan → /rune:devise "add user auth"
  Step 2: Implement → /rune:strive {plan from step 1}

Proceed with this workflow?
```

Use AskUserQuestion with options:
- "Proceed" — Execute the chain
- "Just step 1" — Only run the first step
- "Modify" — Let user adjust the chain
