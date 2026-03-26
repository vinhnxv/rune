# Domain-Specific Design Recommendations

Per-domain design guidance injected into worker and reviewer prompts when
`designContext.domain.confidence >= 0.70`. Domain hints are the **lowest trust level** —
below Figma specs, VSM tokens, library patterns, and project design system rules.

When domain hints conflict with any higher-trust source, the higher-trust source wins.
"general" domain produces no additional hints (zero noise).

## E-commerce

**Color palette**: Use warm, trust-building tones. Primary CTA (Add to Cart, Buy Now) should
be the highest-contrast element. Avoid red for primary actions (red = error/sale).
**Typography**: Product titles need clear hierarchy. Price should be bold and larger than
description text. Strike-through for original price on sale items.
**Layout**: Product grids with consistent card heights. Sticky cart summary on checkout.
Image-heavy layouts with zoom-on-hover for product detail.
**UX priorities**: Fast add-to-cart, persistent cart count, clear shipping info, trust badges
near payment forms, breadcrumb navigation for category depth.
**Anti-patterns**: Don't hide the price. Don't require login before adding to cart.
Don't use carousels for critical product information.

## SaaS

**Color palette**: Professional, low-saturation palette. Use accent color sparingly for
CTAs and status indicators. Neutral backgrounds for data-dense views.
**Typography**: Clear data hierarchy. Monospace for metrics/counts. Compact line heights
for tables and lists.
**Layout**: Sidebar navigation with collapsible sections. Dashboard cards with consistent
grid. Full-width data tables with sticky headers.
**UX priorities**: Onboarding progress indicators, empty states with action prompts,
keyboard shortcuts for power users, inline editing, bulk actions.
**Anti-patterns**: Don't overwhelm new users with all features. Don't use modals for
multi-step workflows (use dedicated pages). Don't hide settings in deep menus.

## Fintech

**Color palette**: Conservative, trust-oriented. Green for gains, red for losses (never
reversed). High contrast for numerical data. Subtle backgrounds for data regions.
**Typography**: Tabular/monospace numbers for alignment. Right-align currency values.
Clear decimal precision (always show cents for currency).
**Layout**: Data tables with sortable columns and fixed headers. Account summary cards
at top. Transaction lists with clear date grouping.
**UX priorities**: Security indicators (padlock, encryption badges), confirmation dialogs
for transfers, real-time balance updates, audit trail visibility, clear error states
for failed transactions.
**Anti-patterns**: Don't auto-submit financial forms. Don't use ambiguous date formats.
Don't truncate account numbers without reveal option.

## Healthcare

**Color palette**: Calming blues and greens. High contrast for readability (WCAG AAA
preferred). Clear status colors for patient conditions (avoid red/green only — colorblind
accessibility critical).
**Typography**: Large base font size (16px minimum). Clear label-value pairs for medical
data. Avoid abbreviations without tooltips.
**Layout**: Clean, uncluttered layouts. Clear section separation. Form-heavy pages with
logical field grouping. Timeline views for patient history.
**UX priorities**: Accessibility-first (screen reader, keyboard, high contrast). Clear
consent flows. Prominent emergency contacts. HIPAA-compliant form handling (no
autocomplete on sensitive fields).
**Anti-patterns**: Don't use small fonts for medical data. Don't rely on color alone for
status. Don't auto-fill patient identifiers.

## Creative

**Color palette**: Minimal chrome — let user content be the hero. Dark mode by default
for design tools. Accent colors for tool selection and active states.
**Typography**: Small, unobtrusive UI labels. Content area uses user-defined typography.
Tool labels should not compete with canvas.
**Layout**: Canvas-centric with collapsible panels. Floating toolbars. Minimal persistent
UI. Full-bleed media displays.
**UX priorities**: Undo/redo with history, keyboard shortcuts for every tool, drag-and-drop
everywhere, real-time preview, non-destructive editing, save indicators.
**Anti-patterns**: Don't add excessive UI chrome around the creative workspace. Don't
interrupt flow with modals. Don't block the canvas with loading states.

## Education

**Color palette**: Friendly, approachable colors. Use progress-indicating colors (partially
filled = amber, complete = green). Distinct colors per course/module.
**Typography**: Readable body text (18px for content). Clear heading hierarchy for lessons.
Code blocks with syntax highlighting for technical courses.
**Layout**: Content-first with sidebar navigation for course structure. Progress bars at
section level. Card-based module/lesson grids.
**UX priorities**: Progress tracking (completion %, streaks), interactive elements (quizzes,
code editors), bookmarking, note-taking, clear "next lesson" navigation.
**Anti-patterns**: Don't hide progress. Don't use pagination for short content (scroll
preferred). Don't require completion of optional content to advance.

## Content

**Color palette**: Clean, reading-focused. High contrast text on light backgrounds.
Accent color for links and interactive elements only.
**Typography**: Optimal reading width (60-75 characters). Clear distinction between heading
levels. Proper list styling. Block quotes visually distinct.
**Layout**: Article-width content column with optional sidebar (TOC, related articles).
Featured images with proper aspect ratios. Card grids for article listings.
**UX priorities**: Reading time estimates, table of contents for long articles, share
buttons, related content suggestions, clear author attribution, print-friendly layout.
**Anti-patterns**: Don't interrupt reading with popups. Don't use infinite scroll for
articles (pagination preferred). Don't auto-play media.

## General

No domain-specific hints are injected. Workers follow standard design patterns from
the project's design system and component library only.

## Integration

### Worker Prompt Injection

Domain hints are appended as a suffix to worker prompts when:
1. `designContext.domain.confidence >= 0.70`
2. `designContext.domain.inferred !== "general"`

```
IF designContext.domain AND designContext.domain.confidence >= 0.70
   AND designContext.domain.inferred !== "general":
  domainHints = loadDomainHints(designContext.domain.inferred)
  workerPrompt += "\n\n## Domain Context: {domain}\n{domainHints}"
```

### Trust Hierarchy Position

```
Priority (highest → lowest):
1. Figma design specs (VSM tokens, layout, variants)
2. Project design system rules (tokens, constraints)
3. Library component patterns (adapter conventions)
4. Domain design hints (this guide)  ← LOWEST
```

When domain hints conflict with any source above, the higher-trust source always wins.
Domain hints provide background context, not overriding directives.

## Cross-References

- [design-token-reference.md](design-token-reference.md) — Figma-to-CSS/Tailwind token mapping (higher trust)
- [component-reuse-strategy.md](component-reuse-strategy.md) — REUSE > EXTEND > CREATE decision tree
- [domain-inference.md](../../design-system-discovery/references/domain-inference.md) — How domain is detected
