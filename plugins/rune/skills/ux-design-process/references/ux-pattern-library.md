# UX Pattern Library

Catalog of UX patterns for agent guidance. Each pattern includes: name, when to use, code signals to detect, and anti-patterns to flag.

Referenced by the ux-pattern-analyzer utility agent.

## Loading State Patterns

### Skeleton Screen

```
When to use:
- Known content layout (lists, cards, profiles, tables)
- Loading duration 200ms-3s
- Content-heavy pages

Code signals:
- Component renders placeholder shapes matching final layout
- Uses CSS animation (pulse or shimmer) for visual feedback
- Matches dimensions of actual content to prevent CLS

Anti-patterns:
- Skeleton that doesn't match actual content layout (causes layout shift)
- Skeleton without animation (looks like broken UI)
- Showing skeleton for < 200ms (flash of skeleton)
```

### Spinner

```
When to use:
- Unknown content layout (search results)
- Write operations (submit, save, upload)
- Short indeterminate waits (500ms-2s)

Code signals:
- SVG or CSS-animated circular indicator
- Often paired with disabled button or overlay
- May include descriptive text ("Saving...")

Anti-patterns:
- Full-page spinner blocking all interaction
- Spinner without timeout handling
- Multiple spinners visible simultaneously
```

### Progressive Loading

```
When to use:
- Large data sets (paginated lists, infinite scroll)
- Image galleries (progressive JPEG, lazy loading)
- Long pages (above-the-fold first, below lazy)

Code signals:
- Intersection Observer for lazy loading
- Pagination or cursor-based fetching
- Image srcset/sizes for responsive loading

Anti-patterns:
- Loading all data on mount (no virtualization)
- No loading indicator at scroll boundary
- Images without width/height causing reflow
```

## Error Handling Patterns

### Inline Error

```
When to use:
- Field-level validation errors
- Input constraint violations
- Real-time validation feedback

Code signals:
- Error message positioned below or beside the input
- Input border/outline changes color (red/orange)
- aria-invalid="true" and aria-describedby on input

Anti-patterns:
- Error message far from the input it refers to
- Error disappears before user reads it
- Only color used to indicate error (accessibility gap)
```

### Toast / Snackbar

```
When to use:
- Transient success/info messages
- Non-critical errors with auto-recovery
- Background operation completion

Code signals:
- Fixed position element (bottom or top)
- Auto-dismiss after 3-8 seconds
- Optional action button ("Undo", "View")
- aria-live="polite" for screen readers

Anti-patterns:
- Toast for critical errors (user may miss it)
- Multiple toasts stacking and obscuring content
- No dismiss button on error toasts
- Toast without aria-live region
```

### Modal Error

```
When to use:
- Critical errors requiring user decision
- Authentication failures
- Permission denials

Code signals:
- Focus trap inside modal
- Escape key and backdrop click to dismiss
- Clear action buttons (Retry, Cancel, Go Back)
- role="alertdialog" for critical errors

Anti-patterns:
- Modal for non-critical errors (interrupts workflow)
- Modal without keyboard dismissal
- Generic "Something went wrong" without recovery path
```

### Error Boundary

```
When to use:
- Catching unexpected render errors
- Isolating component failures
- Preventing white-screen-of-death

Code signals:
- React ErrorBoundary or equivalent framework pattern
- Fallback UI with retry button
- Error logging to monitoring service

Anti-patterns:
- Single error boundary at app root only (cascading failure)
- Fallback UI that is blank or says "Error"
- No recovery action in fallback (reload page only option)
```

## Form Validation Patterns

### Live Validation (onInput/onChange)

```
When to use:
- Simple format checks (email, phone, URL)
- Character count limits
- Password strength meters

Code signals:
- Validation runs on input/change event
- Debounced for performance (100-300ms)
- Shows validation state while typing

Anti-patterns:
- Showing error before user finishes typing
- Validating on every keystroke without debounce
- Blocking form submission based on live validation only
```

### Blur Validation (onBlur)

```
When to use:
- Most form fields (balanced UX)
- Fields requiring complete input to validate
- Cross-field validation

Code signals:
- Validation runs when field loses focus
- Error shown only after user has finished input
- "Touched" state tracking per field

Anti-patterns:
- Validating empty required fields on blur of a different field
- Not re-validating when user corrects the input
```

### Submit Validation (onSubmit)

```
When to use:
- Server-side validation (uniqueness, authorization)
- Complex multi-field validation rules
- Final validation before API call

Code signals:
- Validation runs on form submit event
- Error summary at top of form
- Scrolls to first error field
- Submit button shows loading state

Anti-patterns:
- Only validating on submit (no inline feedback)
- Clearing form data on validation failure
- Not scrolling to the error location
```

## Navigation Patterns

### Breadcrumb

```
When to use:
- Hierarchical content (3+ levels deep)
- E-commerce product categories
- Documentation / knowledge base

Code signals:
- Ordered list of links showing path
- Current page is not a link (text only)
- Separator between items (/ or >)
- Schema.org BreadcrumbList markup

Anti-patterns:
- Breadcrumb for flat navigation (unnecessary)
- Clickable current page item
- Missing from mobile view (should be simplified, not removed)
```

### Tabs

```
When to use:
- Parallel content sections (same level)
- Settings categories
- Data views (list, grid, chart)

Code signals:
- role="tablist" container with role="tab" items
- aria-selected on active tab
- Arrow key navigation between tabs
- Tab panels with role="tabpanel"

Anti-patterns:
- Tabs for sequential steps (use stepper instead)
- More than 7 tabs (use dropdown or sidebar)
- Tabs that navigate to different pages (use nav links)
```

### Stepper / Wizard

```
When to use:
- Sequential multi-step processes
- Onboarding flows
- Checkout / payment flows

Code signals:
- Step indicator showing current/total steps
- Next/Back buttons
- Step validation before advancing
- Progress saved between steps

Anti-patterns:
- No back button
- Losing data when going back
- No indication of total steps
- Forcing linear order when steps are independent
```

## Empty State Patterns

```
When to use:
- First-time use (no data created yet)
- Search with no results
- Filtered view with no matches
- Deleted all items

Components:
- Illustration or icon (optional, adds warmth)
- Descriptive heading ("No projects yet")
- Explanation of what to do next
- Primary CTA button ("Create your first project")

Code signals:
- Conditional render when data array is empty
- Different message for "no data" vs "no search results"
- CTA links to the creation flow

Anti-patterns:
- Blank white space with no explanation
- "No data" without action guidance
- Same empty state for all contexts (not specific enough)
- Empty state that looks like a loading failure
```

## Confirmation Dialog Patterns

```
When to use:
- Destructive actions (delete, remove, overwrite)
- Irreversible operations
- Actions affecting other users
- Bulk operations

Components:
- Clear description of what will happen
- Destructive action button (red/warning color)
- Cancel button (visually secondary)
- Optional: type resource name to confirm

Code signals:
- Modal or dialog with role="alertdialog"
- Destructive button requires explicit click (not Enter key default)
- Cancel is the default focused button
- Action description includes affected resource name/count

Anti-patterns:
- Confirmation for routine actions (save, close tab)
- Generic "Are you sure?" without specifics
- Destructive button as primary/default focus
- No way to cancel (only "OK")
```

## Undo Patterns

```
When to use:
- Reversible destructive actions (soft delete)
- Bulk edits
- Move/reorganize operations
- Send actions (email, message)

Components:
- Toast/snackbar with "Undo" action button
- Time-limited window (5-10 seconds)
- Visual confirmation of the action taken
- Grace period before permanent execution

Code signals:
- Soft delete (mark as deleted, don't remove)
- Delayed execution with cancel window
- Toast with action button and countdown
- Server-side undo endpoint or optimistic rollback

Anti-patterns:
- Undo window too short (< 3 seconds)
- No visual indication that undo is available
- Undo button disappears on interaction with other elements
- Undo that doesn't fully restore state
```
