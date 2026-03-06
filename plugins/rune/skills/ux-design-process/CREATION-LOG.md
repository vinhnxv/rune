# UX Design Process -- Creation Log

## Problem Statement

Code reviews and planning workflows lacked structured UX evaluation capabilities. Frontend changes were reviewed for code quality (linting, type safety, test coverage) but not for usability, accessibility, or interaction design quality. Common UX issues -- missing loading states, inadequate error recovery, small touch targets, inaccessible controls -- were caught late or not at all. The existing frontend-design-patterns skill covers design-to-code translation but not UX evaluation methodology.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Extend frontend-design-patterns with UX content | Would exceed 500 lines. UX evaluation is a distinct concern from design-to-code translation. Different trigger conditions (UX needs opt-in, design patterns auto-load). |
| Single UX checklist reference file | Insufficient scope. UX evaluation spans heuristics, flow analysis, interaction auditing, and cognitive walkthrough -- each requiring dedicated reference material and potentially a dedicated review agent. |
| Always-on UX review agents | Too expensive for most projects. UX review adds 4 potential agents to the Roundtable Circle. Must be opt-in (ux.enabled: false default) per reviewer concern C4. |
| External UX linting tools | No existing tool covers the full spectrum of UX evaluation at the code review level. Tools like axe-core handle accessibility but not flow analysis, cognitive load, or interaction patterns. |

## Key Design Decisions

- **ux.enabled defaults to false**: Initial release is opt-in only. Users must explicitly enable in talisman.yml. This prevents unexpected review overhead and allows gradual adoption. (Reviewer concern C4)
- **Cognitive walkthrough OFF by default**: UXC agent uses Opus model for step-by-step task analysis, making it the most expensive UX agent. Separate toggle (`ux.cognitive_walkthrough: true`) required.
- **Touch targets: 44px minimum, 48px recommended**: Following WCAG 2.5.5 AAA (44px) with 48px as the recommended target for primary actions. Industry standard from Material Design and Apple HIG.
- **Non-blocking findings by default**: UX findings use `blocking: false` to avoid blocking merges. Configurable via `ux.blocking_findings` and `ux.blocking_severity` in talisman.
- **Finding prefix scheme (UXH/UXF/UXI/UXC)**: Four prefixes map to four UX review domains. Positioned below FRONT in the dedup hierarchy. Each prefix has its own severity scoring rubric.
- **8 reference files**: Separated by concern area (greenfield, brownfield, heuristics, patterns, interactions, aesthetics, web rules, scoring) for on-demand loading. Keeps SKILL.md under 200 lines.

## External References Incorporated

| Source | Used In | Adaptation |
|--------|---------|------------|
| Nielsen Norman 10 Usability Heuristics | heuristic-checklist.md | Adapted from design evaluation to code-level review items with severity weights |
| Baymard Institute 207 Heuristics | heuristic-checklist.md | Subset adapted for code review context (original targets e-commerce UX) |
| Vercel Web Interface Guidelines | web-interface-rules.md | Translated from design guidelines to code-checkable rules with WCAG mapping |
| Atomic Design (Brad Frost) | greenfield-process.md | Component hierarchy for greenfield projects (Atoms > Molecules > Organisms) |
| Carbon Design System | ux-pattern-library.md | Loading state patterns and duration-based pattern selection |
| NNGroup Skeleton Screens | ux-pattern-library.md | Skeleton screen vs spinner decision criteria |
| WCAG 2.1 AA/AAA | web-interface-rules.md, aesthetic-direction.md | Contrast ratios, touch targets, focus management, reduced motion |

## Iteration History

| Date | Version | Change | Trigger |
|------|---------|--------|---------|
| 2026-03-06 | v1.0 | Initial skill with 8 reference files | UX Design Intelligence feature plan |
