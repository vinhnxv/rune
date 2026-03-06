# Aesthetic Thinking — Design Quality in Code

Bridge between aesthetic evaluation (aesthetic-direction.md in ux-design-process) and frontend code review. Provides actionable rules for detecting visual quality issues through static code analysis.

## Design Token Enforcement

Every visual property must reference a design token. Code-level checks:

| Property | Token Source | Anti-Pattern |
|----------|-------------|--------------|
| Color | `--color-*`, Tailwind palette | Hex/RGB literals (`#3B82F6`, `rgb(59,130,246)`) |
| Spacing | `--spacing-*`, Tailwind scale | Arbitrary values (`p-[17px]`, `margin: 13px`) |
| Font size | `--text-*`, Tailwind text scale | Pixel literals (`font-size: 15px`) |
| Border radius | `--radius-*`, Tailwind rounded | Mixed radius values (`rounded-[7px]`) |
| Shadow | `--shadow-*`, Tailwind shadow | Custom box-shadow with raw values |

**Detection rule**: Grep for arbitrary value brackets `[...]` in Tailwind classes. More than 3 arbitrary values per component suggests token gaps in the design system.

## Anti-Slop Detection Rules

Static patterns that indicate AI-generated "slop" in frontend code:

### Rule AESTH-S01: Typography Monotony

```
Check: All headings use the same font-weight class
Signal: grep -c "font-semibold" > 5 AND grep -c "font-bold" == 0 AND grep -c "font-medium" == 0
Fix: Establish heading weight progression (bold > semibold > medium)
```

### Rule AESTH-S02: Spacing Uniformity

```
Check: Only 1-2 distinct spacing values used across a component
Signal: All padding uses "p-4" or "p-6" with no variation
Fix: Use at least 3 spacing scale values to create visual rhythm
```

### Rule AESTH-S03: Color Palette Overflow

```
Check: More than 5 distinct color values in a single component
Signal: Multiple Tailwind color utilities from different palettes (blue-500, green-400, purple-600, red-500, yellow-300)
Fix: Limit to primary + secondary + accent + neutrals (semantic colors)
```

### Rule AESTH-S04: Transition-All Laziness

```
Check: transition-all used instead of targeted transition property
Signal: className contains "transition-all"
Fix: Use transition-colors, transition-shadow, transition-transform, or transition-opacity
```

## Visual Hierarchy Validation

Code-level checks for heading weight progression:

```
Expected hierarchy (by weight/size):
  h1/display: text-3xl+ font-bold (or font-extrabold)
  h2/title:   text-2xl font-bold (or font-semibold)
  h3/section: text-xl font-semibold
  h4/label:   text-lg font-medium
  body:       text-base font-normal
  caption:    text-sm font-normal text-muted

Violation: h2 and h3 use the same size+weight combination
Violation: body text is larger than h4 heading
```

## Spacing Rhythm Checks

Validate that spacing follows a consistent scale:

```
Base-4 scale: 4, 8, 12, 16, 20, 24, 32, 40, 48, 64 (px)
Base-8 scale: 8, 16, 24, 32, 40, 48, 64, 80, 96 (px)
Tailwind:     1, 2, 3, 4, 5, 6, 8, 10, 12, 16 (units = 4px each)

Check: All spacing values fit within the chosen scale
Violation: mix of 13px, 17px, 23px (off-scale values)
Violation: Inner padding > outer margin (content appears cramped)
```

## Relationship to Other References

- For full aesthetic evaluation methodology: see `ux-design-process/references/aesthetic-direction.md`
- For anti-slop guardrail details: see `frontend-design-patterns/references/anti-slop-guardrails.md`
- For design token reference: see `frontend-design-patterns/references/design-token-reference.md`
- For component reuse strategy: see `frontend-design-patterns/references/component-reuse-strategy.md`
