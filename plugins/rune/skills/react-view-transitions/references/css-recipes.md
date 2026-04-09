# View Transition CSS Recipes

Copy-paste CSS animations for common view transition patterns.

## Fade (Default)

```css
::view-transition-old(*) {
  animation: fade-out 200ms ease-out;
}

::view-transition-new(*) {
  animation: fade-in 200ms ease-in;
}

@keyframes fade-out {
  from { opacity: 1; }
  to { opacity: 0; }
}

@keyframes fade-in {
  from { opacity: 0; }
  to { opacity: 1; }
}
```

## Slide (Horizontal)

```css
/* Forward navigation */
::view-transition-old(page) {
  animation: slide-out-left 300ms ease-in-out;
}

::view-transition-new(page) {
  animation: slide-in-right 300ms ease-in-out;
}

/* Back navigation */
::view-transition-old(page) {
  animation: slide-out-right 300ms ease-in-out;
}

::view-transition-new(page) {
  animation: slide-in-left 300ms ease-in-out;
}

@keyframes slide-out-left {
  from { transform: translateX(0); }
  to { transform: translateX(-100%); }
}

@keyframes slide-in-right {
  from { transform: translateX(100%); }
  to { transform: translateX(0); }
}

@keyframes slide-out-right {
  from { transform: translateX(0); }
  to { transform: translateX(100%); }
}

@keyframes slide-in-left {
  from { transform: translateX(-100%); }
  to { transform: translateX(0); }
}
```

## Slide (Vertical)

```css
::view-transition-old(panel) {
  animation: slide-up-out 250ms ease-in;
}

::view-transition-new(panel) {
  animation: slide-up-in 250ms ease-out;
}

@keyframes slide-up-out {
  from { transform: translateY(0); opacity: 1; }
  to { transform: translateY(-20px); opacity: 0; }
}

@keyframes slide-up-in {
  from { transform: translateY(20px); opacity: 0; }
  to { transform: translateY(0); opacity: 1; }
}
```

## Scale (Modal / Card)

```css
::view-transition-old(modal) {
  animation: scale-out 200ms ease-in;
}

::view-transition-new(modal) {
  animation: scale-in 200ms ease-out;
}

@keyframes scale-out {
  from { transform: scale(1); opacity: 1; }
  to { transform: scale(0.95); opacity: 0; }
}

@keyframes scale-in {
  from { transform: scale(0.95); opacity: 0; }
  to { transform: scale(1); opacity: 1; }
}
```

## Shared Element Morph

The browser handles morph animation automatically when two `<ViewTransition>` elements share the same `name`. Customize the morph timing:

```css
::view-transition-group(avatar) {
  animation-duration: 300ms;
  animation-timing-function: cubic-bezier(0.4, 0, 0.2, 1);
}

/* Control old/new crossfade during morph */
::view-transition-old(avatar) {
  animation: fade-out 150ms ease-out;
}

::view-transition-new(avatar) {
  animation: fade-in 150ms ease-in 150ms; /* delay = old fade duration */
}
```

## List Reorder

```css
::view-transition-group(list-item) {
  animation-duration: 250ms;
  animation-timing-function: cubic-bezier(0.2, 0, 0, 1);
}
```

## Reduced Motion

Always include:

```css
@media (prefers-reduced-motion: reduce) {
  ::view-transition-old(*),
  ::view-transition-new(*),
  ::view-transition-group(*) {
    animation: none !important;
  }
}
```

## Cross-Fade with Blur

```css
::view-transition-old(page) {
  animation: blur-fade-out 300ms ease-out;
}

::view-transition-new(page) {
  animation: blur-fade-in 300ms ease-in;
}

@keyframes blur-fade-out {
  from { opacity: 1; filter: blur(0); }
  to { opacity: 0; filter: blur(4px); }
}

@keyframes blur-fade-in {
  from { opacity: 0; filter: blur(4px); }
  to { opacity: 1; filter: blur(0); }
}
```
