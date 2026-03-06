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

### Progress Bar

```
When to use:
- Determinate operations (file upload, multi-step process)
- Long-running tasks where completion % is known
- Bulk operations (importing records, processing queue)

Code signals:
- Progress element or role="progressbar" with aria-valuenow
- Width/value updates tied to actual progress events
- Percentage or step count displayed alongside bar

Anti-patterns:
- Fake progress (animated bar with no real progress data)
- Progress bar that reaches 99% and stalls indefinitely
- No text alternative for screen readers (missing aria attributes)
```

### Optimistic Update

```
When to use:
- High-confidence mutations (like, bookmark, toggle)
- Low-latency perceived actions
- Social interactions (follow, react, vote)

Code signals:
- UI updates before server response arrives
- Rollback on error (revert to previous state)
- Background sync with retry logic

Anti-patterns:
- Optimistic update on destructive actions (delete without confirm)
- No rollback mechanism on failure
- Inconsistent state between UI and server after error
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

### Retry with Backoff

```
When to use:
- Network request failures (API calls, file uploads)
- Transient server errors (503, 429)
- WebSocket reconnection

Code signals:
- Exponential backoff timer (1s, 2s, 4s, 8s...)
- Max retry count with final error state
- User-visible retry button after max attempts
- Jitter added to prevent thundering herd

Anti-patterns:
- Infinite retries without max limit
- Fixed interval retries (no backoff)
- Silent retries with no user feedback
- Retrying non-idempotent operations (POST without guard)
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

### Multi-Step Form Persistence

```
When to use:
- Long forms split across multiple steps/pages
- Checkout flows, onboarding wizards
- Forms where users may leave and return

Code signals:
- State persisted to sessionStorage/localStorage between steps
- "Save draft" functionality for longer forms
- Restore state on page reload or back navigation

Anti-patterns:
- Losing all data on browser refresh
- No draft save for forms taking > 2 minutes
- State only in component memory (lost on unmount)
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

### Command Palette / Spotlight

```
When to use:
- Power-user navigation shortcut
- Application-wide search (actions + content)
- Keyboard-first interfaces

Code signals:
- Triggered by Cmd+K / Ctrl+K keyboard shortcut
- Fuzzy search over actions and pages
- Recent items and frequently used shown by default
- role="combobox" with listbox results

Anti-patterns:
- No keyboard shortcut to open
- Results don't include actions (only navigation)
- No recent/frequent items shown on empty query
- Slow search (> 100ms perceived delay)
```

### Sidebar Navigation

```
When to use:
- Application with many sections (dashboards, admin panels)
- Persistent navigation needed across views
- Nested navigation hierarchy

Code signals:
- Collapsible sidebar with toggle button
- Active state indicator on current section
- Nested items with expand/collapse
- Responsive: drawer on mobile, sidebar on desktop

Anti-patterns:
- Sidebar always expanded on mobile (consumes screen)
- No visual indicator for current page
- Deeply nested items without grouping (> 3 levels)
```

## Empty State Patterns

### First-Use Empty State

```
When to use:
- First-time use (no data created yet)
- New account onboarding
- Feature discovery

Components:
- Illustration or icon (optional, adds warmth)
- Descriptive heading ("No projects yet")
- Explanation of what to do next
- Primary CTA button ("Create your first project")

Code signals:
- Conditional render when data array is empty
- CTA links to the creation flow
- Different from error or loading states

Anti-patterns:
- Blank white space with no explanation
- "No data" without action guidance
- Same empty state for all contexts (not specific enough)
- Empty state that looks like a loading failure
```

### Search Empty State

```
When to use:
- Search with no results
- Filtered view with no matches

Code signals:
- Different message for "no results" vs "no data"
- Suggests alternative search terms or filter changes
- "Clear filters" action button when filters active

Anti-patterns:
- "No results" without helpful suggestions
- Same message whether user searched or filtered
- No way to clear search/filters from the empty state
```

## Confirmation Dialog Patterns

### Destructive Confirmation

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

### Type-to-Confirm

```
When to use:
- High-impact destructive actions (delete account, drop database)
- Actions that cannot be undone even with soft-delete
- Operations affecting many users or resources

Code signals:
- Input field requiring exact text match (resource name or "DELETE")
- Submit button disabled until text matches
- Clear instructions on what to type

Anti-patterns:
- Type-to-confirm for low-stakes actions (annoying friction)
- Case-sensitive matching without telling the user
- Allowing paste (reduces intentionality for critical actions)
```

## Undo Patterns

### Toast Undo

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

## Accessibility Patterns

### Focus Management

```
When to use:
- Modal open/close (trap and restore focus)
- Route changes in SPAs
- Dynamic content additions (chat messages, notifications)
- After destructive actions (focus moves to next item)

Code signals:
- Focus trap in modals (focus cycles within modal)
- Focus restored to trigger element on modal close
- tabIndex="-1" on programmatically focused containers
- Skip-to-content link as first focusable element

Anti-patterns:
- Focus lost after modal close (goes to body)
- No focus management on route change (screen reader loses position)
- Visible focus indicator removed (outline: none without replacement)
- Tab order doesn't match visual order
```

### Keyboard Navigation

```
When to use:
- All interactive elements (buttons, links, menus)
- Custom components (dropdowns, date pickers, sliders)
- Data tables with actions
- Drag-and-drop interfaces (keyboard alternative required)

Code signals:
- All interactive elements reachable via Tab
- Arrow keys for within-component navigation (menus, tabs, grids)
- Enter/Space to activate, Escape to dismiss
- Visible focus indicators on all interactive elements

Anti-patterns:
- Click-only interactions (no keyboard equivalent)
- Custom elements without role and keyboard handlers
- Focus indicators hidden globally (CSS outline: none)
- Tab traps (focus enters but can't leave)
```

### Screen Reader Announcements

```
When to use:
- Dynamic content updates (live scores, chat, notifications)
- Form validation results
- Loading state changes
- Page transitions in SPAs

Code signals:
- aria-live="polite" for non-urgent updates
- aria-live="assertive" for urgent updates (errors)
- role="status" for status messages
- role="alert" for error messages

Anti-patterns:
- No aria-live regions for dynamic content
- Using assertive for non-urgent content (interrupts user)
- Too many simultaneous announcements (overwhelming)
- Announcing every minor UI change
```

## Responsive Patterns

### Responsive Table

```
When to use:
- Data tables on mobile viewports
- Tables with 4+ columns
- Dashboard and admin data grids

Code signals:
- Horizontal scroll with sticky first column
- Or: card layout transformation on small screens
- Or: column priority hiding (show key columns, hide others)
- Proper scope attributes on th elements

Anti-patterns:
- Table overflows viewport with no scroll indicator
- Hiding critical data columns on mobile
- Tiny text to fit all columns (unreadable)
- No alternative mobile layout for wide tables
```

### Responsive Images

```
When to use:
- Hero images, content images, product photos
- Any image displayed across breakpoints
- Art direction needs (different crop per viewport)

Code signals:
- srcset with width descriptors for resolution switching
- sizes attribute matching CSS layout
- picture element with source for art direction
- Explicit width/height attributes to prevent CLS

Anti-patterns:
- Single large image served to all viewports
- Missing width/height (causes layout shift)
- Images without alt text (accessibility gap)
- Lazy loading above-the-fold images (delays LCP)
```

## Data Display Patterns

### Virtualized List

```
When to use:
- Lists with 100+ items
- Infinite scroll feeds
- Large data tables (1000+ rows)

Code signals:
- Only renders visible items + buffer
- Uses react-virtual, react-window, or equivalent
- Container has fixed height with overflow scroll
- Item height measured or estimated

Anti-patterns:
- Rendering all items in DOM (performance degradation)
- No buffer rows (flicker on fast scroll)
- Variable height items without measurement (jumping scroll)
```

### Search with Autocomplete

```
When to use:
- Search inputs with known result sets
- Address/location search
- User/entity lookup fields

Code signals:
- Debounced input (200-300ms) before API call
- Dropdown with role="listbox" and role="option" items
- Keyboard navigation (arrow keys, Enter to select)
- Highlight matching text in suggestions

Anti-patterns:
- API call on every keystroke (no debounce)
- Dropdown without keyboard navigation
- No loading indicator during search
- Results that flash/change rapidly (visual noise)
```

### Infinite Scroll with Pagination Fallback

```
When to use:
- Content feeds (social, news, activity logs)
- Search results with many pages
- Product listings

Code signals:
- Intersection Observer triggers next page load
- "Load more" button as fallback/alternative
- URL updates with page/cursor for shareability
- Scroll position preserved on back navigation

Anti-patterns:
- No way to reach footer (infinite scroll blocks it)
- Lost scroll position on navigate-back
- No pagination fallback (accessibility issue)
- Loading indicator not visible (user doesn't know more is coming)
```

## Feedback Patterns

### Skeleton-to-Content Transition

```
When to use:
- After skeleton loading completes
- Content appearing in stages
- Above-the-fold content rendering

Code signals:
- Smooth opacity/fade transition from skeleton to content
- Content replaces skeleton in-place (no layout shift)
- Staggered reveal for multiple items

Anti-patterns:
- Abrupt skeleton disappearance (jarring flash)
- Layout shift when skeleton replaced by different-sized content
- All content appears simultaneously (wall of content)
```

### Micro-Interaction Feedback

```
When to use:
- Button clicks, toggles, form submissions
- Drag-and-drop interactions
- Swipe gestures on mobile

Code signals:
- Visual state change within 100ms of interaction
- Button shows pressed/active state
- Haptic feedback on mobile (vibration API)
- prefers-reduced-motion respected for animations

Anti-patterns:
- No visual feedback on interaction (feels unresponsive)
- Animations that block interaction (can't click during animation)
- Animation duration > 300ms for micro-interactions
- Ignoring prefers-reduced-motion preference
```
