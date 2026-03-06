---
name: ux-design-process
description: |
  UX design intelligence for code review and planning. Provides heuristic
  evaluation checklists (Nielsen Norman 10 + Baymard 207 adapted), interaction
  pattern libraries, flow validation, cognitive walkthrough protocols, and
  aesthetic quality scoring. Routes to greenfield (new project) or brownfield
  (existing codebase) UX processes based on context.
  Trigger keywords: UX, usability, heuristic evaluation, user experience,
  interaction design, cognitive walkthrough, accessibility, touch targets,
  user flow, design review, UX audit, Nielsen, Baymard, usability testing.
user-invocable: true
disable-model-invocation: false
argument-hint: "[--greenfield | --brownfield | --audit]"
---

# /rune:ux-design-process -- UX Design Intelligence

UX-informed code review and planning support. Provides structured heuristic evaluation,
interaction pattern validation, flow analysis, and aesthetic quality assessment.

**Load skills**: `frontend-design-patterns`, `context-weaving`

## Configuration

UX design intelligence is gated by talisman configuration:

```yaml
# .claude/talisman.yml
ux:
  enabled: false            # Default: false (opt-in for initial release)
  cognitive_walkthrough: false  # Default: false (expensive -- uses Opus model)
  touch_target_minimum: 44  # px -- 48px recommended
  finding_prefix: true      # Emit UXH/UXF/UXI/UXC prefixed findings
  blocking: false           # UX findings are non-blocking by default
```

**Important**: `ux.enabled` defaults to `false`. Users must explicitly opt in via talisman.yml.
When the `ux:` section is missing entirely from talisman.yml, all UX features default to disabled (`enabled: false`, `cognitive_walkthrough: false`, `blocking: false`, `touch_target_minimum: 44`, `finding_prefix: true`).

## Process Routing

Determine project context and route to the appropriate UX process:

```
1. Check talisman.yml: ux.enabled === true
   - If false: exit with "UX intelligence is disabled. Enable via talisman.yml: ux.enabled: true"

2. Determine project context:
   - --greenfield flag OR no existing components/ directory → greenfield process
   - --brownfield flag OR existing components/ directory   → brownfield process
   - --audit flag                                          → heuristic audit (both processes)

3. Route:
   - Greenfield → see [greenfield-process.md](references/greenfield-process.md)
   - Brownfield → see [brownfield-process.md](references/brownfield-process.md)
   - Audit      → see [heuristic-checklist.md](references/heuristic-checklist.md)
```

## UX Finding Prefixes

All UX findings use standardized prefixes for integration with the Rune dedup hierarchy:

| Prefix | Domain | Agent | Description |
|--------|--------|-------|-------------|
| `UXH` | Heuristic | ux-heuristic-reviewer | Nielsen/Baymard heuristic violations |
| `UXF` | Flow | ux-flow-validator | User flow breakages, dead ends, loops |
| `UXI` | Interaction | ux-interaction-auditor | Micro-interaction and state issues |
| `UXC` | Cognitive | ux-cognitive-walker | Cognitive load and learnability issues |

Severity levels per finding:

| Level | Meaning | Example |
|-------|---------|---------|
| P0 | Blocks user flow | Form submit does nothing, nav leads to 404 |
| P1 | Degrades experience | Missing loading state, no error recovery |
| P2 | Cosmetic / improvement | Inconsistent spacing, suboptimal label text |

See [ux-scoring.md](references/ux-scoring.md) for the full scoring rubric.

## Architecture (3 Layers)

```
Layer 1: UX Research & Context  -- Understand user needs and project constraints
Layer 2: Evaluation & Analysis  -- Apply heuristics, validate flows, audit interactions
Layer 3: Scoring & Integration  -- Score findings, integrate with Rune review pipeline
```

## Layer 1: UX Research & Context

### Greenfield Projects

For new projects, the UX process covers user research, persona development, information
architecture, wireframing guidance, and visual design principles.

See [greenfield-process.md](references/greenfield-process.md) for the full greenfield workflow.

### Brownfield Projects

For existing codebases, the UX process covers heuristic evaluation, usability audit,
incremental improvement workflow, design debt assessment, and progressive enhancement.

See [brownfield-process.md](references/brownfield-process.md) for the full brownfield workflow.

## Layer 2: Evaluation & Analysis

### Heuristic Evaluation

50+ checklist items organized by Nielsen Norman's 10 heuristics, adapted from Baymard's
207 usability guidelines for code-level review context. Each item includes an ID, category,
description, code-level check instruction, and severity weight.

See [heuristic-checklist.md](references/heuristic-checklist.md) for the full checklist.

### UX Pattern Library

Catalog of UX patterns for agent guidance: loading states (skeleton, spinner, progressive),
error handling (inline, toast, modal, boundary), form validation, navigation patterns,
empty states, confirmation dialogs, and undo patterns.

See [ux-pattern-library.md](references/ux-pattern-library.md) for the pattern catalog.

### Interaction Patterns

Micro-interaction and state transition patterns: hover/focus/active states, loading
transitions, error recovery flows, optimistic updates, debounce/throttle, gesture
handling, scroll behavior, and drag-and-drop feedback.

See [interaction-patterns.md](references/interaction-patterns.md) for interaction patterns.

### Aesthetic Direction

Visual design principles for code-level enforcement: color coherence, typography hierarchy,
whitespace rhythm, visual weight balance, and contrast ratios (WCAG AA compliance).

See [aesthetic-direction.md](references/aesthetic-direction.md) for aesthetic principles.

### Web Interface Rules

Adapted from Vercel Web Interface Guidelines: semantic HTML, keyboard accessibility,
touch target sizes, responsive breakpoints, animation performance, reduced motion
preferences, and color-blind safe palettes.

See [web-interface-rules.md](references/web-interface-rules.md) for interface rules.

## Layer 3: Scoring & Integration

### Finding Severity

UX findings follow the UXH/UXF/UXI/UXC prefix scheme and are scored P0-P2.
UX prefixes are positioned below FRONT in the Rune dedup hierarchy.

See [ux-scoring.md](references/ux-scoring.md) for the scoring framework.

### Integration with Rune Review Pipeline

UX review agents participate in the Roundtable Circle as conditional Ashes:

```
Activation: talisman.yml → ux.enabled === true
Trigger: changed files include frontend components (*.tsx, *.jsx, *.vue, *.svelte)
Position: After standard Wave 1 Ashes, before Wave 2 investigation
Blocking: false (by default -- configurable via talisman.yml → ux.blocking)
```

### Cognitive Walkthrough (Optional)

When `ux.cognitive_walkthrough: true`, the ux-cognitive-walker agent performs a
step-by-step cognitive walkthrough of user flows in changed components. This is
expensive (uses Opus model) and is OFF by default.

See [heuristic-checklist.md](references/heuristic-checklist.md) for cognitive walkthrough items.

## Cross-References

- [frontend-design-patterns](../frontend-design-patterns/SKILL.md) -- Design-to-code translation patterns
- [appraise](../appraise/SKILL.md) -- Multi-agent code review (UX agents join as conditional Ashes)
- [devise](../devise/SKILL.md) -- Planning (Phase 0.3 UX Research integration)
- [roundtable-circle](../roundtable-circle/SKILL.md) -- Review orchestration framework
- [arc-phase-ux-verification](../arc/references/arc-phase-ux-verification.md) -- Arc Phase 5.3 UX verification algorithm

## References

- [greenfield-process.md](references/greenfield-process.md) -- New project UX workflow
- [brownfield-process.md](references/brownfield-process.md) -- Existing codebase UX workflow
- [heuristic-checklist.md](references/heuristic-checklist.md) -- 50+ heuristic evaluation items
- [ux-pattern-library.md](references/ux-pattern-library.md) -- UX pattern catalog
- [interaction-patterns.md](references/interaction-patterns.md) -- Micro-interaction patterns
- [aesthetic-direction.md](references/aesthetic-direction.md) -- Visual design principles
- [web-interface-rules.md](references/web-interface-rules.md) -- Vercel-adapted interface rules
- [ux-scoring.md](references/ux-scoring.md) -- Finding severity scoring framework
