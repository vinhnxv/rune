# Interaction Patterns

Micro-interaction and state transition patterns for UX review. Each pattern includes: name, trigger, feedback type, timing, and code signals to detect.

Referenced by the ux-interaction-auditor agent.

## Hover / Focus / Active States

### State Transition Matrix

| Element | Hover | Focus | Active | Disabled |
|---------|-------|-------|--------|----------|
| Button | Background change | Outline/ring | Scale down (0.98) | Opacity 0.5 + cursor: not-allowed |
| Link | Underline / color change | Outline/ring | Color darken | Opacity 0.5 + pointer-events: none |
| Card | Shadow elevation | Outline/ring | Shadow reduce | Opacity 0.5 |
| Input | Border color change | Border color + ring | -- | Background gray + cursor: not-allowed |
| Icon button | Background circle | Outline/ring | Scale down | Opacity 0.5 |

### Code Signals

```
Check for:
- Interactive elements without :hover styles (no visual feedback)
- :hover without :focus-visible equivalent (accessibility gap)
- :active state causing layout shift (size change instead of transform)
- Disabled state without cursor: not-allowed or aria-disabled

Flag:
- Hover effects on touch devices (no :hover on mobile)
- Focus styles removed (outline: none) without replacement
- Inconsistent hover behavior across similar components
```

### Timing Guidelines

| Transition | Duration | Easing |
|-----------|----------|--------|
| Hover in | 150ms | ease-out |
| Hover out | 200ms | ease-in |
| Focus ring | 0ms (instant) | -- |
| Active press | 50-100ms | ease-in |
| Color change | 150ms | ease-in-out |
| Shadow change | 200ms | ease-out |

## Loading Transitions

### Transition Types

| Type | When to Use | Implementation |
|------|-------------|---------------|
| Fade in | Content replacing skeleton | opacity 0 -> 1, 200ms |
| Slide up | New list items appearing | transform translateY(8px) -> 0, 200ms |
| Scale in | Modal/dialog appearance | transform scale(0.95) -> 1, 200ms |
| Cross-fade | Content swap (tab change) | Old opacity out, new opacity in, 150ms |
| Expand | Accordion/collapsible open | height 0 -> auto, 200-300ms |

### Loading-to-Content Transition Pattern

```
Phase 1: Skeleton visible (while loading)
Phase 2: Data arrives → skeleton fades out (150ms)
Phase 3: Content fades in (200ms, staggered for lists)

Code signals:
- Content appears instantly without transition (jarring)
- Skeleton and content visible simultaneously (double render)
- Content pop-in without any transition (CLS risk)
```

### Stagger Pattern for Lists

```
When loading multiple items (list, grid), stagger their appearance:
- First item: 0ms delay
- Each subsequent item: +50ms delay
- Maximum total stagger: 300ms (cap at 6 items)
- Items beyond cap appear simultaneously

Code signals:
- All list items appear at once (no stagger)
- Stagger delay too long (> 100ms per item -- feels slow)
- Infinite stagger (no cap -- 20 items = 2 second delay)
```

## Error Recovery Flows

### Error State Transitions

```
Normal → Error:
  1. Operation fails
  2. Error state appears (inline, toast, or modal)
  3. Recovery action available (retry, edit, go back)

Error → Recovery:
  1. User takes recovery action
  2. Loading state during retry
  3. Success: error state clears, confirmation shown
  4. Failure: error state updates with new message

Key rule: Never leave the user in a dead-end error state
```

### Recovery Action Patterns

| Error Type | Recovery Action | Feedback |
|-----------|-----------------|----------|
| Network timeout | "Retry" button | Loading spinner on retry |
| Validation failure | Highlight invalid fields | Inline error messages |
| Auth expired | "Sign in again" link | Redirect to login |
| Rate limited | "Try again in X seconds" | Countdown timer |
| Server error | "Try again later" or "Contact support" | Error ID for support reference |
| Conflict (409) | "Reload" or "Merge changes" | Show diff if possible |

## Optimistic Updates

### Pattern

```
1. User takes action (toggle, like, delete)
2. UI updates immediately (optimistic state)
3. Request sent to server
4. On success: no visible change (already correct)
5. On failure: revert UI + show error toast

Timing:
- UI update: instant (0ms)
- Error revert: within 3 seconds
- Error toast: appears on revert

Code signals:
- setState before API call (correct pattern)
- Rollback logic in catch/error handler
- Optimistic ID generation (temporary client-side ID)
```

### When to Use vs Avoid

```
Use optimistic updates for:
- Toggle states (like, bookmark, pin)
- Status changes (read/unread, archive)
- Reordering (drag-and-drop position)
- Quick edits (inline text edit)

Avoid optimistic updates for:
- Financial transactions (payment, transfer)
- Destructive actions (delete, remove member)
- Complex mutations (multi-field form submit)
- Actions with side effects (send email, publish)
```

## Debounce and Throttle

### Decision Guide

| Pattern | When to Use | Typical Delay |
|---------|-------------|---------------|
| **Debounce** | Search-as-you-type, resize handlers, form auto-save | 300-500ms |
| **Throttle** | Scroll handlers, mouse move, window resize metrics | 100-200ms |
| **Neither** | Button clicks, form submits, toggle actions | Immediate |

### Code Signals

```
Check for:
- API calls on every keystroke without debounce
- Scroll event handlers without throttle (performance)
- Debounce delay > 1000ms (feels unresponsive)
- Debounce delay < 150ms (effectively no debounce)

Flag:
- fetch() inside onChange without debounce wrapper
- addEventListener('scroll', handler) without throttle
- addEventListener('resize', handler) without debounce
```

## Gesture Handling

### Touch Gesture Patterns

| Gesture | Action | Keyboard Equivalent |
|---------|--------|-------------------|
| Tap | Select/activate | Enter/Space |
| Long press | Context menu | Shift+F10 or right-click |
| Swipe left/right | Delete/archive | Delete key |
| Swipe down | Refresh | F5/Ctrl+R |
| Pinch | Zoom | Ctrl+/Ctrl- |
| Drag | Reorder/move | Arrow keys with modifier |

### Gesture Requirements

```
Every gesture MUST have:
1. A non-gesture alternative (button, keyboard shortcut)
2. Visual affordance (handle icon for drag, swipe hint)
3. Feedback during gesture (element follows finger/cursor)
4. Cancellation mechanism (move back to origin to cancel)
```

## Scroll Behavior

### Scroll Patterns

| Pattern | When to Use | Implementation |
|---------|-------------|---------------|
| Smooth scroll | Anchor links within page | `scroll-behavior: smooth` or `scrollIntoView({ behavior: 'smooth' })` |
| Scroll to top | Long pages after navigation | Floating button appears after scrolling > 1 viewport |
| Sticky header | Navigation during scroll | `position: sticky; top: 0` with shadow on scroll |
| Infinite scroll | Social feeds, image galleries | Intersection Observer at sentinel element |
| Virtual scroll | Large lists (1000+ items) | Virtualization library (tanstack-virtual, react-window) |

### Scroll Anti-Patterns

```
Flag these:
- Scroll hijacking (overriding native scroll behavior)
- Infinite scroll without "load more" button fallback
- No scroll restoration on back navigation
- Scroll-linked animations that cause jank
- Hidden scrollbars that remove scroll affordance
```

## Drag-and-Drop Feedback

### Feedback Requirements

| Phase | Visual Feedback | Accessibility |
|-------|----------------|---------------|
| Idle | Drag handle icon visible | aria-roledescription="sortable" |
| Grab | Cursor change, element elevation | aria-grabbed="true" |
| Drag | Ghost/shadow follows cursor, drop zones highlight | aria-dropeffect on targets |
| Over valid target | Target highlights (border, background) | Announced by screen reader |
| Over invalid target | "No drop" cursor | aria-dropeffect="none" |
| Drop | Element animates to new position | Focus moves to dropped element |
| Cancel | Element returns to origin (animation) | Focus returns to original position |

### Code Signals

```
Check for:
- Drag without visual feedback (element just disappears)
- No keyboard alternative for reorder
- Drop without animation (element teleports)
- No indication of valid/invalid drop zones
- Drag handle too small (< 44px touch target)
```
