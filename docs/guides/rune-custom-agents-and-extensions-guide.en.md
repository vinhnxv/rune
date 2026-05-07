# Rune Advanced Guide: Custom Agents & Extensions

Extend Rune's review pipeline with project-specific agents, CLI-backed external models, and Forge Gaze integration.

Related guides:
- [Getting started](rune-getting-started.en.md)
- [Talisman deep dive guide](rune-talisman-deep-dive-guide.en.md)
- [Code review and audit guide](rune-code-review-and-audit-guide.en.md)
- [Troubleshooting and optimization guide](rune-troubleshooting-and-optimization-guide.en.md)

---

## 1. Architecture Overview

Rune's review pipeline uses **Ashes** — consolidated teammate agents that each embed multiple review perspectives.You can extend this with **custom Ashes** that join the same Roundtable Circle lifecycle:

```
Built-in Ashes (7)  +  Custom Ashes (talisman.yml)  =  Total Ashes (up to max_ashes)
```

Custom Ashes participate in:
- **Truthbinding** — prompt injection protection
- **Inscription** — structured output contracts
- **Dedup** — finding deduplication via prefix hierarchy
- **TOME aggregation** — unified findings report
- **Truthsight verification** — optional output validation

---

## 2. Creating a Custom Ash

### Step 1: Write the agent definition

Create a `.md` file with YAML frontmatter. Place it at:
- `.claude/agents/my-reviewer.md` — project-level (source: `local`)
- `~/.claude/agents/my-reviewer.md` — user-global (source: `global`)

```yaml
---
name: domain-logic-reviewer
description: |
  Reviews domain model integrity, business rule correctness,
  and service layer patterns. Use proactively when domain/
  service/model files change.
tools: Read, Grep, Glob
model: sonnet
---

You are a domain logic specialist reviewer.

## Focus Areas

1. **Business rule correctness** — validate state transitions, invariants, and guards
2. **Domain model integrity** — check entity relationships, value objects, aggregate boundaries
3. **Service layer patterns** — verify proper separation of concerns, no domain logic leaking into controllers

## Review Protocol

For each file:
1. Read the file completely
2. Identify domain rules and business logic
3. Check for missing validations, incorrect state transitions, broken invariants
4. Report findings using the structured format provided in your inscription

## Output Format

Use the finding format from your inscription contract. Each finding must include:
- File path and line number
- Severity (P1/P2/P3)
- Evidence from the actual source code (Rune Trace)
- Confidence level (HIGH/MEDIUM/LOW)
```

### Step 2: Register in talisman.yml

```yaml
ashes:
  custom:
    - name: "domain-logic-reviewer"
      agent: "domain-logic-reviewer"    # Matches filename without .md
      source: local                     # local | global | plugin
      workflows: [review, audit]        # Which workflows summon this Ash
      trigger:
        extensions: [".py", ".rb", ".go"]
        paths: ["src/domain/", "src/services/", "app/models/"]
      context_budget: 20                # Max files to review
      finding_prefix: "DOM"             # Unique 2-5 char uppercase prefix
      required_sections:                # Sections expected in output
        - "P1 (Critical)"
        - "P2 (High)"
        - "P3 (Medium)"
        - "Reviewer Assumptions"
        - "Self-Review Log"
```

### Step 3: Add prefix to dedup hierarchy

```yaml
settings:
  dedup_hierarchy:
    - SEC          # Ward Sentinel (highest)
    - BACK         # Forge Warden
    - DOM          # Your custom prefix — place by priority
    - DOC          # Knowledge Keeper
    - QUAL         # Pattern Weaver
    - FRONT        # Glyph Scribe
```

Higher position in the hierarchy means the finding "wins" when two Ashes report the same issue (5-line proximity window).

---

## 3. Trigger Configuration

### File-based triggers (review/audit)

```yaml
trigger:
  extensions: [".py", ".ts"]      # File extensions to match
  paths: ["src/api/", "api/"]     # Path prefixes to match
  min_files: 5                    # Only summon if N+ matching files
  always: true                    # Always summon (skip matching)
```

All trigger conditions are **AND** — the Ash is summoned only when ALL conditions match.

### Topic-based triggers (forge)

When an Ash participates in `/rune:forge` or `/rune:devise`, Forge Gaze uses topic-keyword matching:

```yaml
trigger:
  topics: [api, contract, endpoints, rest, graphql]  # Keywords matched against plan section titles
```

---

## 4. Forge Gaze Integration

To make your custom Ash participate in plan enrichment, add `forge` to its workflows and configure the `forge:` section:

```yaml
ashes:
  custom:
    - name: "api-contract-reviewer"
      agent: "api-contract-reviewer"
      source: local
      workflows: [review, audit, forge]    # "forge" enables Forge Gaze
      trigger:
        extensions: [".py", ".ts"]         # For review/audit
        paths: ["src/api/"]
        topics: [api, contract, endpoints, rest, graphql]  # For forge
      forge:
        subsection: "API Contract Analysis"
        perspective: "API design, contract compatibility, and endpoint patterns"
        budget: enrichment                  # enrichment (~5k tokens) | research (~15k tokens)
      context_budget: 15
      finding_prefix: "API"
```

### Budget tiers

| Budget | Token cost | Agent type | Use case |
|--------|-----------|------------|----------|
| `enrichment` | ~5k tokens | Review agents | Quick analysis, pattern checking |
| `research` | ~15k tokens | Research agents (web search) | External docs, best practices |

---

## 5. CLI-Backed Ashes (External Models)

Use non-Claude models as review Ashes by invoking their CLI:

```yaml
ashes:
  custom:
    - name: "gemini-oracle"
      cli: "gemini"                    # CLI binary name
      model: "gemini-2.5-pro"         # Model name
      output_format: "json"            # jsonl | text | json
      finding_prefix: "GEM"
      timeout: 300                     # CLI timeout in seconds
      workflows: [review, audit]
      trigger:
        always: true
      context_budget: 20
```

### Constraints

- **Security**: Binary name must match `CLI_BINARY_PATTERN`. Model name must match `MODEL_NAME_PATTERN`.
- **Hallucination guard**: All CLI-backed Ashes include a 4-step verification guard (diff relevance, code verification).

### Prerequisites

The CLI binary must be installed and authenticated separately. Rune does NOT manage API keys for external models.

---

## 6. Agent Source Resolution

| Source | Resolution path | Best for |
|--------|----------------|----------|
| `local` | `.claude/agents/{name}.md` | Project-specific reviewers, committed with the repo |
| `global` | `~/.claude/agents/{name}.md` | Personal reviewers shared across projects |
| `plugin` | `{plugin}:{category}:{agent}` | Cross-plugin agents (e.g., `my-plugin:review:checker`) |

### Cross-plugin example

```yaml
ashes:
  custom:
    - name: "compliance-checker"
      agent: "compliance-plugin:review:compliance-checker"
      source: plugin
      workflows: [review, audit]
      trigger:
        extensions: ["*"]
        paths: ["src/api/", "src/auth/"]
      finding_prefix: "COMP"
```

**Security**: Path traversal (`../`) in agent names is rejected at load time.

---

## 7. Persona-Based Reviewers

Use Rune's built-in agents as opinionated persona Ashes:

```yaml
ashes:
  custom:
    - name: "senior-engineer"
      agent: "rune:review:senior-engineer-reviewer"
      source: plugin
      workflows: [review]
      finding_prefix: "SENIOR"
```

This gives you an opinionated senior engineer perspective that challenges over-engineering, questions abstractions, and enforces simplicity.

---

## 8. Disabling Built-in Ashes

Replace built-in Ashes with your custom versions:

```yaml
defaults:
  disable_ashes:
    - "knowledge-keeper"    # Replaced by your custom doc reviewer

ashes:
  custom:
    - name: "my-doc-reviewer"
      agent: "my-doc-reviewer"
      source: local
      workflows: [review, audit]
      trigger:
        extensions: [".md", ".rst", ".txt"]
      finding_prefix: "MDOC"
```

---

## 9. Writing Effective Agent Prompts

### Structure

```markdown
---
name: my-reviewer
description: |
  One paragraph explaining WHAT this agent does and WHEN to use it.
  Include trigger keywords so Claude matches correctly.
tools: Read, Grep, Glob
model: sonnet
---

# Role statement (1-2 sentences)

## Focus Areas (3-5 bullets)

## Review Protocol (step-by-step)

## Anti-patterns to detect (specific, actionable)

## Output Format (match inscription contract)
```

### Best practices

| Do | Don't |
|----|-------|
| Be specific about what to look for | Give vague instructions like "review for quality" |
| Include concrete examples of bad patterns | Leave the agent to guess what you care about |
| Specify the output format | Assume the agent knows your finding format |
| Keep under 500 lines | Write novel-length instructions |
| Use `tools: Read, Grep, Glob` (read-only) | Give write tools to review agents |
| Test with `/rune:appraise` on a real diff | Deploy without testing |

### Tool restrictions for safety

Review agents should be **read-only**. The `enforce-readonly.sh` hook blocks write tools during review/audit when the `.readonly-active` marker exists:

```yaml
tools: Read, Grep, Glob    # Read-only — no Bash, Write, or Edit
```

---

## 10. Testing Your Custom Ash

### 1. Run a review with your agent

```bash
# Make some changes to files matching your trigger
/rune:appraise
```

### 2. Check the TOME output

Look for your finding prefix in `tmp/reviews/{id}/TOME.md`:

```bash
# Search for your custom findings
grep "DOM-" tmp/reviews/*/TOME.md
```

### 3. Verify inscription compliance

Check that your agent produced all required sections by reviewing `tmp/reviews/{id}/ash-outputs/`.

### 4. Test dedup behavior

Create a finding that overlaps with a built-in Ash. The finding from the higher-priority prefix should win.

---

## 11. Complete Example: E-commerce Domain Reviewer

### Agent file (`.claude/agents/ecommerce-reviewer.md`)

```yaml
---
name: ecommerce-reviewer
description: |
  E-commerce domain specialist. Reviews order lifecycle, payment processing,
  inventory management, and pricing logic. Detects missing validations in
  checkout flows, incorrect state transitions, and race conditions in
  inventory updates.
tools: Read, Grep, Glob
model: sonnet
---

You are an e-commerce domain specialist reviewer.

## Focus Areas

1. **Order lifecycle** — state machine correctness (pending → paid → shipped → delivered)
2. **Payment processing** — idempotency, retry handling, partial refunds
3. **Inventory management** — race conditions, overselling, stock reservation
4. **Pricing logic** — discount stacking, tax calculation, currency handling
5. **Checkout flow** — cart validation, address verification, payment method checks

## Anti-Patterns

- Missing idempotency keys on payment API calls
- Inventory check outside transaction boundary
- Price calculated client-side without server validation
- Order state transitions without guard conditions
- Missing rollback on partial payment failure

## Evidence

Every finding must include a Rune Trace with the exact file path, line number, and code snippet.
```

### Talisman registration

```yaml
ashes:
  custom:
    - name: "ecommerce-reviewer"
      agent: "ecommerce-reviewer"
      source: local
      workflows: [review, audit, forge]
      trigger:
        extensions: [".py", ".ts", ".rb"]
        paths: ["src/orders/", "src/payments/", "src/inventory/", "src/pricing/"]
        topics: [order, payment, inventory, pricing, checkout, cart, e-commerce]
      forge:
        subsection: "E-commerce Domain Analysis"
        perspective: "order lifecycle, payment idempotency, and inventory safety"
        budget: enrichment
      context_budget: 20
      finding_prefix: "ECOM"
      required_sections:
        - "P1 (Critical)"
        - "P2 (High)"
        - "P3 (Medium)"
        - "Reviewer Assumptions"
        - "Self-Review Log"

settings:
  dedup_hierarchy:
    - SEC
    - BACK
    - ECOM     # Between backend and quality — domain issues take priority
    - DOC
    - QUAL
    - FRONT
```

---

## 12. Limits and Constraints

| Constraint | Value | Notes |
|-----------|-------|-------|
| Max total Ashes | `settings.max_ashes` (default 9) | Includes built-in + custom |
| Context budget per Ash | `context_budget` (default 20 files) | Higher = more tokens |
| Finding prefix | 2-5 uppercase chars | Must be unique across all Ashes |
| Agent prompt | < 500 lines | Move details to supporting files |
| Dedup window | 5 lines | Findings within 5 lines of each other are deduped |
