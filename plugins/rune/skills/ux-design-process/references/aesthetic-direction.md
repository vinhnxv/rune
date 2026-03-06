# Aesthetic Direction -- Visual Design Principles

Visual design principles for code-level enforcement. Covers color coherence, typography hierarchy, whitespace rhythm, visual weight balance, and contrast ratios. Includes anti-slop patterns for detecting generic, monotonous design output.

Referenced by the aesthetic-quality-reviewer extension and aesthetic-thinking.md in frontend-design-patterns.

## Color Coherence

### Color System Requirements

```
1. Maximum 5 semantic color categories:
   - Primary (brand action)
   - Secondary (supporting action)
   - Neutral (text, borders, backgrounds)
   - Semantic (success, warning, error, info)
   - Accent (highlights, badges, decorative)

2. Each category has a scale (50-950 or light-to-dark)
3. All colors reference design tokens (no hardcoded hex/rgb)
4. Adjacent color combinations verified for contrast
```

### Contrast Ratio Requirements (WCAG AA)

| Element | Minimum Ratio | Criterion |
|---------|--------------|-----------|
| Normal text (< 18px / < 14px bold) | 4.5:1 | WCAG 1.4.3 |
| Large text (>= 18px / >= 14px bold) | 3:1 | WCAG 1.4.3 |
| UI components (borders, icons, controls) | 3:1 | WCAG 1.4.11 |
| Focus indicators | 3:1 | WCAG 2.4.7 |
| Placeholder text | 4.5:1 (recommended) | Best practice |

### Color-Blind Safety

```
Code-level checks:
- Never use color alone to convey information
- Pair color indicators with icons, text, or patterns
- Common unsafe pairs: red/green, blue/purple, yellow/light-green
- Test with simulated protanopia, deuteranopia, tritanopia

Safe patterns:
- Error: red + "X" icon + error text
- Success: green + checkmark icon + success text
- Warning: yellow/orange + warning triangle + warning text
- Info: blue + "i" icon + info text
```

## Typography Hierarchy

### Font Family Rules

```
Maximum 2-3 font families per project:
1. Heading font (display/serif/sans-serif)
2. Body font (readable sans-serif preferred for UI)
3. Monospace font (code blocks, data, technical content)

Code signals to flag:
- More than 3 font-family declarations
- font-family not referencing a design token or CSS custom property
- System font stack missing fallbacks
```

### Type Scale

| Name | Size | Use Case | Line Height |
|------|------|----------|-------------|
| xs | 12px | Captions, helper text | 1.5 (18px) |
| sm | 14px | Secondary text, labels | 1.5 (21px) |
| base | 16px | Body text | 1.5 (24px) |
| lg | 18px | Subtitles, emphasis | 1.4 (25px) |
| xl | 20px | Section headings | 1.3 (26px) |
| 2xl | 24px | Page headings | 1.25 (30px) |
| 3xl | 30px | Hero headings | 1.2 (36px) |

### Typography Anti-Patterns

```
Flag these in code review:
- Font size < 12px (hard to read for many users)
- Line height < 1.2 for body text (cramped)
- Line length > 75 characters (hard to track across lines)
- ALL CAPS for paragraphs (reduces readability by 10-20%)
- Centered text for paragraphs > 3 lines
- Font weight used for emphasis without semantic markup (<strong>)
```

## Whitespace Rhythm

### Spacing Principles

```
1. Use a consistent base unit (4px or 8px)
2. Spacing between elements should follow the scale
3. More space = less relationship (proximity principle)
4. Group related items with tight spacing
5. Separate sections with generous spacing

Code-level check:
- All margin/padding values should be multiples of the base unit
- Arbitrary values (13px, 7px, 19px) indicate rhythm violation
- Gap/spacing should reference design tokens
```

### Spacing Scale

| Token | Value (4px base) | Use Case |
|-------|-----------------|----------|
| space-0 | 0px | Tight coupling |
| space-1 | 4px | Inline elements, icon-to-text |
| space-2 | 8px | Related items within a group |
| space-3 | 12px | Form field spacing |
| space-4 | 16px | Component internal padding |
| space-5 | 20px | Between sections |
| space-6 | 24px | Card padding |
| space-8 | 32px | Section separation |
| space-10 | 40px | Page section gaps |
| space-12 | 48px | Major layout divisions |
| space-16 | 64px | Page-level vertical rhythm |

### Whitespace Anti-Patterns

```
Flag these:
- Monotonous spacing (same gap everywhere -- looks flat)
- No breathing room around text blocks
- Components touching without separation
- Inconsistent padding within similar components
- Cramped form fields (spacing < 12px between fields)
```

## Visual Weight Balance

### Weight Hierarchy

```
Elements carry visual weight based on:
1. Size (larger = heavier)
2. Color saturation (saturated = heavier)
3. Density (dense content = heavier)
4. Position (top-left carries more attention in LTR layouts)
5. Contrast (high contrast = heavier)

Balance rules:
- Primary action buttons should be the heaviest element in their context
- Secondary actions should be visually lighter than primary
- Navigation should not outweigh content area
- Modals should have clear visual weight hierarchy (title > content > actions)
```

### Visual Weight Signals in Code

```
Check for:
- Multiple elements competing for attention (all bold, all colored, all large)
- Destructive actions styled as primary (should be outlined or subtle)
- Headers and CTAs that are the same visual weight
- Dense content blocks without visual anchors (headings, images, whitespace)
```

## Anti-Slop Patterns

Signals that AI-generated or rushed design output produces monotonous, generic UI:

### Detection Checklist

| Signal | Description | Fix |
|--------|-------------|-----|
| Monotonous spacing | Every gap is 16px or 24px | Use varied spacing per context |
| Generic font stack | `-apple-system, sans-serif` with no customization | Define intentional type scale |
| Predictable layout | Every page is single-column centered | Vary layout by content type |
| Identical cards | All cards same height, same padding, same structure | Vary card types by content |
| Default shadows | `box-shadow: 0 2px 4px rgba(0,0,0,0.1)` everywhere | Use elevation scale per depth |
| No visual rhythm | No variation in element sizes or spacing | Create intentional rhythm |
| Cookie-cutter icons | All icons same size, same color, same style | Vary icon treatment by context |

### Quality Indicators

```
Good aesthetic quality signals:
- Intentional contrast between sections (alternating backgrounds)
- Visual hierarchy within components (title > subtitle > body > meta)
- Consistent but varied spacing (tighter within groups, looser between)
- Restrained color usage (accent colors used sparingly)
- Meaningful animation (not decorative -- conveys state change)
- Content-appropriate density (data-heavy = denser, content = spacious)
```
