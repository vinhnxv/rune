# Visual Quality Checks — Mode B Heuristics

UI quality audit checklist for verifying components without a Figma/VSM design spec.
Used by `storybook-reviewer` in Mode B (UI Quality Audit).

## Checklist

| ID | Category | Check | What to Look For |
|----|----------|-------|-----------------|
| SBK-B-001 | Rendering | Render integrity | No error boundary fallback, no blank areas, component fully visible |
| SBK-B-002 | Text | Text overlap | No characters colliding or extending outside container bounds |
| SBK-B-003 | Text | Overflow clipping | No text or images cut off at container edges unexpectedly |
| SBK-B-004 | Layout | Zero-dimension elements | No invisible containers (0px width/height) hiding child content |
| SBK-B-005 | Responsive | Mobile horizontal scroll | No horizontal scrollbar at 375px viewport width |
| SBK-B-006 | Responsive | Touch targets | All interactive elements >= 44x44px at mobile viewports |
| SBK-B-007 | Responsive | Layout transitions | Column/row transitions work correctly at breakpoints |
| SBK-B-008 | Accessibility | Color contrast | Text visually distinct from background (WCAG AA minimum) |
| SBK-B-009 | Spacing | Spacing consistency | Uniform gaps between sibling elements, no irregular spacing |
| SBK-B-010 | Elevation | Shadow/border presence | Cards, modals, dropdowns have expected shadow or border |
| SBK-B-011 | States | Loading state | Shows skeleton, spinner, or placeholder — not blank screen |
| SBK-B-012 | States | Error state | Shows error message with recovery action — not empty container |
| SBK-B-013 | States | Disabled state | Reduced opacity or muted color, cursor indicates non-interactive |

## Priority Classification

| Priority | Applies To | Description |
|----------|-----------|-------------|
| P1 | SBK-B-001, SBK-B-008 | Render failure or accessibility violation — must fix |
| P2 | SBK-B-002 through SBK-B-007, SBK-B-011, SBK-B-012 | Functional issues — should fix |
| P3 | SBK-B-009, SBK-B-010, SBK-B-013 | Polish issues — nice to fix |

## Verification Method

### DOM Snapshot (Structural)

Use `agent-browser snapshot -i` to get the accessibility tree:
- Check element roles and ARIA labels
- Verify bounding box dimensions (detect zero-dimension elements)
- Check text content is present and not truncated
- Verify interactive elements have appropriate roles

### Screenshot (Visual)

Use `agent-browser screenshot` to capture PNG, then read with `Read()`:
- Check overall visual composition
- Verify text is readable against background
- Check spacing and alignment visually
- Detect visual anomalies (clipping, overflow, gaps)

### Combined Approach

For each component story:
1. Navigate to story URL via agent-browser
2. Capture DOM snapshot for structural checks (SBK-B-004, SBK-B-006)
3. Capture screenshot for visual checks (SBK-B-001 through SBK-B-003, SBK-B-008 through SBK-B-010)
4. Check state stories separately (SBK-B-011 through SBK-B-013)

## Responsive Breakpoints

Standard breakpoints to test:

| Name | Width | Priority |
|------|-------|----------|
| Mobile | 375px | Required |
| Tablet | 768px | Recommended |
| Desktop | 1280px | Required |

Test at least Mobile and Desktop. Tablet is recommended for complex layouts.

## Scoping Caveat

Screenshot analysis is approximate:
- Size/spacing accuracy: +/- 10-20% for unlabeled elements
- Color detection: reliable for high-contrast, approximate for subtle differences
- Font properties: font-family and weight detectable, exact size approximate

For exact measurements, verify from source code (CSS/Tailwind classes).
Findings based on screenshot analysis should note "visual estimate" when
precise measurements cannot be confirmed from the DOM snapshot.
