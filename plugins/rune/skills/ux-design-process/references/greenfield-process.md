# Greenfield UX Design Process

UX design process for new projects. Covers the full design lifecycle from user research through visual design, with decision trees for common UX patterns.

## Process Overview

```
Phase 1: Research & Discovery   -- Understand users, context, and constraints
Phase 2: Information Architecture -- Structure content and navigation
Phase 3: Wireframing & Prototyping -- Define layout and interaction patterns
Phase 4: Visual Design           -- Apply aesthetic direction and design system
Phase 5: Validation              -- Verify against heuristics and user needs
```

## Phase 1: Research & Discovery

### User Research Questions

Before writing code, answer these questions (adapt to project scope):

| Question | Output | Source |
|----------|--------|--------|
| Who are the primary users? | User personas (1-3) | Stakeholder input, analytics |
| What tasks do users need to complete? | Task list with priority | User interviews, requirements |
| What devices do they use? | Device matrix | Analytics, market data |
| What accessibility needs exist? | WCAG level requirement | Legal, organizational policy |
| What are the key success metrics? | KPIs (task completion, time-on-task) | Business requirements |

### Persona Template

```yaml
persona:
  name: "[Role-based name]"
  role: "[Primary user role]"
  goals:
    - "[Primary goal]"
    - "[Secondary goal]"
  frustrations:
    - "[Pain point with current solutions]"
  tech_proficiency: "[low | medium | high]"
  devices: ["desktop", "mobile", "tablet"]
  accessibility_needs: "[none | screen-reader | keyboard-only | low-vision | motor]"
```

### Context Constraints Checklist

```
- [ ] Target browsers and versions
- [ ] Minimum screen width (320px mobile, 768px tablet, 1024px desktop)
- [ ] Offline support needed?
- [ ] Internationalization (i18n) required?
- [ ] Right-to-left (RTL) language support?
- [ ] Performance budget (LCP < 2.5s, FID < 100ms, CLS < 0.1)
- [ ] Content management requirements
```

## Phase 2: Information Architecture

### Content Inventory

Map all content types and their relationships:

```
1. List all content types (pages, components, data entities)
2. Group by user task relevance
3. Define hierarchy (primary nav > secondary nav > utility nav)
4. Identify cross-cutting concerns (search, notifications, settings)
```

### Navigation Pattern Decision Tree

```
Question 1: How many top-level sections?
  1-5 sections → Tab bar (mobile) / Horizontal nav (desktop)
  6-10 sections → Hamburger menu + search
  10+ sections → Sidebar navigation with categories

Question 2: How deep is the hierarchy?
  1 level → Flat navigation (tabs or links)
  2 levels → Dropdown menus or expandable sections
  3+ levels → Sidebar with tree view or breadcrumb trail

Question 3: Are there user-specific views?
  Yes → Role-based navigation (show/hide sections)
  No → Universal navigation

Question 4: Is there a primary action?
  Yes → Floating action button or persistent CTA
  No → Standard navigation only
```

### URL Structure

```
/                           -- Landing / dashboard
/[resource]                 -- List view
/[resource]/[id]            -- Detail view
/[resource]/[id]/edit       -- Edit view
/[resource]/new             -- Create view
/settings                   -- User settings
/settings/[category]        -- Settings subsection
```

## Phase 3: Wireframing & Prototyping

### Layout Decision Tree

```
Question 1: What is the primary content type?
  Data table / list     → Table layout with sorting + filtering
  Media gallery         → Grid layout with responsive columns
  Long-form content     → Single column with sidebar TOC
  Dashboard             → Card grid with responsive breakpoints
  Form / wizard         → Centered single column (max-width: 640px)

Question 2: How many actions per page?
  1 primary action      → Single CTA button, prominently placed
  2-3 actions           → Primary + secondary button hierarchy
  Many actions          → Toolbar or action menu (overflow pattern)
  Context-dependent     → Contextual menu (right-click or kebab menu)
```

### Common Page Templates

| Template | When to Use | Key Components |
|----------|-------------|----------------|
| List + Detail | CRUD operations | Search, filters, table, detail panel |
| Dashboard | Overview / monitoring | Cards, charts, KPIs, quick actions |
| Wizard / Stepper | Multi-step processes | Step indicator, form sections, progress |
| Settings | Configuration | Sidebar categories, form groups, save/cancel |
| Empty State | First use / no data | Illustration, description, primary CTA |

## Phase 4: Visual Design

### Design System Bootstrap

For greenfield projects, establish these design tokens before building components:

```
1. Color palette
   - Primary, secondary, accent colors
   - Semantic colors: success, warning, error, info
   - Neutral scale (8-10 shades for text, borders, backgrounds)
   - Verify WCAG AA contrast ratios (4.5:1 text, 3:1 large text/UI)

2. Typography scale
   - Max 2-3 font families (heading, body, monospace)
   - Type scale: xs, sm, base, lg, xl, 2xl, 3xl
   - Line height: 1.25 (headings), 1.5 (body), 1.75 (small text)

3. Spacing scale
   - Base unit: 4px or 8px
   - Scale: 0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24
   - Consistent rhythm prevents visual noise

4. Border radius scale
   - none, sm (2px), md (4-6px), lg (8-12px), full (9999px)

5. Shadow / elevation scale
   - sm (subtle cards), md (dropdowns), lg (modals), xl (floating elements)
```

See [aesthetic-direction.md](aesthetic-direction.md) for detailed visual design principles.

### Component Hierarchy (Atomic Design)

```
Atoms     → Button, Input, Label, Icon, Badge, Avatar
Molecules → Search bar, Form field (label + input + error), Card header
Organisms → Navigation bar, Form section, Data table, Modal dialog
Templates → Page layouts combining organisms
Pages     → Template instances with real data
```

**Rule**: Build atoms first, compose upward. Never start with a full page.

## Phase 5: Validation

### Pre-Implementation Checklist

```
- [ ] All four UI states defined (loading, error, empty, success)
- [ ] Keyboard navigation path documented
- [ ] Touch targets >= 44px (48px recommended)
- [ ] Focus order matches visual reading order
- [ ] Error messages are specific and actionable
- [ ] Loading states appropriate for expected duration
- [ ] Empty states have clear call-to-action
- [ ] Responsive behavior defined for 3 breakpoints minimum
- [ ] Color contrast verified (WCAG AA)
- [ ] Animations respect prefers-reduced-motion
```

### Heuristic Pre-Check

Before implementation, validate the design against the top-5 most commonly violated heuristics:

1. **Visibility of system status** -- Does the design show loading, progress, and confirmation?
2. **Error prevention** -- Are destructive actions guarded with confirmation?
3. **Recognition over recall** -- Are labels, hints, and defaults provided?
4. **Consistency** -- Do similar components behave the same way?
5. **Help users recover from errors** -- Can users undo, go back, or retry?

See [heuristic-checklist.md](heuristic-checklist.md) for the full 50+ item checklist.

## Decision Trees Summary

| Decision | Key Factor | Reference |
|----------|-----------|-----------|
| Navigation pattern | Section count + hierarchy depth | Phase 2 |
| Layout template | Primary content type | Phase 3 |
| Component level | Composition complexity | Phase 4 (Atomic Design) |
| Loading pattern | Expected duration | [ux-pattern-library.md](ux-pattern-library.md) |
| Error display | Error type + severity | [ux-pattern-library.md](ux-pattern-library.md) |
