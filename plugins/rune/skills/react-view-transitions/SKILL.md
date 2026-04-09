---
name: react-view-transitions
description: |
  React View Transition API guide — smooth page transitions, shared element
  morphs, Suspense reveals, list reordering animations. Covers ViewTransition
  component placement rules, transition types, CSS recipes, and Next.js
  integration. React 19 canary feature.
  Trigger keywords: view transition, ViewTransition, startViewTransition,
  page transition, shared element, morph animation, route animation.
user-invocable: false
disable-model-invocation: false
---

# React View Transitions

Guide for the React View Transition API — animate DOM changes declaratively using the browser's native View Transition mechanism. React 19 canary feature.

## When This Loads

Auto-loaded by the Stacks context router when:
- `ViewTransition` import detected in changed files
- `react@canary` or `react@experimental` in `package.json`
- Changed files involve page transitions, route animations, or shared element morphs

## Core Concept

`<ViewTransition>` wraps DOM nodes and animates them when they enter, exit, update, or share identity across navigations. It uses the browser's `document.startViewTransition()` under the hood.

## Placement Rules

### Rule 1: Before DOM Nodes, Not Wrapping

```tsx
// CORRECT: ViewTransition goes before the DOM node
<ViewTransition>
  <div className="card">{content}</div>
</ViewTransition>

// WRONG: ViewTransition wrapping a component (no DOM node)
<ViewTransition>
  <Card />  // ← If Card returns a fragment, transition breaks
</ViewTransition>
```

### Rule 2: Default to None

Always set `default="none"` on ViewTransition wrappers that should only animate on specific triggers:

```tsx
<ViewTransition default="none" enter="slide-in" exit="slide-out">
  <Page />
</ViewTransition>
```

Without `default="none"`, every state update that touches this subtree triggers an animation — including unrelated re-renders.

### Rule 3: One ViewTransition Per Animated Element

Each independently animated element gets its own `<ViewTransition>`. Don't nest them.

## Animation Triggers

| Trigger | When It Fires | Use Case |
|---------|---------------|----------|
| `enter` | Element mounts into the DOM | Page enters, modal opens |
| `exit` | Element unmounts from the DOM | Page leaves, modal closes |
| `update` | Element's content changes without mount/unmount | Tab content swap, counter increment |
| `share` | Element with same `name` appears in new location | Avatar morphs between list and detail view |

## Shared Element Morph Pattern

Shared element transitions animate an element from one position/size to another across navigations.

```tsx
// List view: thumbnail
<ViewTransition name={`photo-${photo.id}`}>
  <img src={photo.thumb} className="w-16 h-16 rounded" />
</ViewTransition>

// Detail view: full image — same `name` creates morph
<ViewTransition name={`photo-${photo.id}`}>
  <img src={photo.full} className="w-full aspect-video rounded-lg" />
</ViewTransition>
```

**Critical**: The `name` must be unique per instance. Two elements with the same `name` mounted simultaneously will break.

## Transition Types

Use `addTransitionType` for directional navigation:

```tsx
function navigate(url, direction) {
  startTransition(() => {
    addTransitionType(direction) // 'slide-forward' or 'slide-back'
    router.push(url)
  })
}
```

```css
/* CSS matches on transition type */
::view-transition-group(page) {
  animation-duration: 300ms;
}

@supports (view-transition-class: page) {
  [data-transition-type="slide-forward"] ::view-transition-old(page) {
    animation: slide-out-left 300ms;
  }
  [data-transition-type="slide-forward"] ::view-transition-new(page) {
    animation: slide-in-right 300ms;
  }
}
```

## Known Limitations

1. **Browser back button**: `popstate` is synchronous — React cannot intercept it to wrap in a transition. Back navigation won't animate.
2. **Cross-document**: Only works within a single-page app (SPA). MPA transitions use the browser-native View Transition API directly.
3. **Suspense interaction**: `<ViewTransition>` works with `<Suspense>` reveals — the transition animates when the fallback is replaced by content.

## Accessibility

Always provide reduced motion alternatives:

```css
@media (prefers-reduced-motion: reduce) {
  ::view-transition-old(*),
  ::view-transition-new(*) {
    animation: none !important;
  }
}
```

## Reference Files

- [css-recipes.md](references/css-recipes.md) — Copy-paste CSS animations (fade, slide, morph, scale)
- [nextjs.md](references/nextjs.md) — Next.js App Router integration guide
