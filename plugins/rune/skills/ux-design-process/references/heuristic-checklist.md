# UX Heuristic Evaluation Checklist

Comprehensive heuristic evaluation checklist adapted for code review context. Based on Nielsen Norman's 10 Usability Heuristics and Baymard Institute's 207 usability guidelines.

Each item includes: ID, category, description, code-level check instruction, severity weight, and priority label.

## Severity Weights and Priority Labels

| Weight | Priority | Meaning | Severity Prefix |
|--------|----------|---------|----------------|
| 3 | Critical | User cannot complete core tasks without this | UXH-P0 |
| 2 | High | Significant usability impact — degrades experience | UXH-P1 |
| 1 | Medium | Nice-to-have polish — cosmetic or improvement | UXH-P2 |

> **Note:** Full finding IDs append a sequence number: `UXH-P0-001`, `UXH-P1-002`, etc. See [ux-scoring.md](ux-scoring.md) for the complete ID format.

## H1: Visibility of System Status

The system should always keep users informed about what is going on through appropriate feedback within reasonable time.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H1-01 | Loading indicators for async operations | Verify `isLoading`/`isPending` state renders a visible indicator (skeleton, spinner, or progress bar) | 3 | Critical |
| H1-02 | Progress feedback for multi-step processes | Check wizard/stepper components show current step and total steps | 2 | High |
| H1-03 | Form submission feedback | Verify submit handlers show loading state and success/error confirmation | 3 | Critical |
| H1-04 | Real-time validation feedback | Check form inputs provide inline validation (not just on submit) | 2 | High |
| H1-05 | Active state indicators | Verify navigation items show active/selected state for current page | 1 | Medium |
| H1-06 | Upload progress | File upload components show progress percentage or bar | 2 | High |
| H1-07 | Background process status | Long-running tasks show progress notification or status badge | 2 | High |

## H2: Match Between System and Real World

The system should speak the users' language, following real-world conventions and making information appear in natural, logical order.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H2-01 | User-facing terminology | Check labels, buttons, and messages use domain language (not developer jargon) | 2 | High |
| H2-02 | Natural reading order | Verify DOM order matches visual layout order (flex/grid order property checked) | 2 | High |
| H2-03 | Date/time localization | Check date formatting uses locale-aware methods (Intl.DateTimeFormat or equivalent) | 1 | Medium |
| H2-04 | Number formatting | Verify numbers use locale-appropriate separators | 1 | Medium |
| H2-05 | Icon semantics | Check icons have clear meaning or are paired with text labels | 2 | High |
| H2-06 | Logical grouping | Related form fields are grouped with fieldset/legend or visual sections | 1 | Medium |

## H3: User Control and Freedom

Users often choose functions by mistake and need a clearly marked "emergency exit" to leave the unwanted state.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H3-01 | Undo support for destructive actions | Verify delete/remove actions offer undo or confirmation dialog | 3 | Critical |
| H3-02 | Cancel / back navigation | Check multi-step flows have back buttons and cancel options | 3 | Critical |
| H3-03 | Modal dismissal | Verify modals can be closed via X button, Escape key, and backdrop click | 2 | High |
| H3-04 | Form reset | Check long forms have clear/reset capability | 1 | Medium |
| H3-05 | Editable submitted data | Verify users can edit previously submitted information | 2 | High |
| H3-06 | Bulk action undo | Check bulk operations (select all + delete) have confirmation | 3 | Critical |

## H4: Consistency and Standards

Users should not have to wonder whether different words, situations, or actions mean the same thing.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H4-01 | Consistent button styles | Verify primary/secondary/destructive buttons use design system tokens | 2 | High |
| H4-02 | Consistent terminology | Check same action uses same label across the app | 2 | High |
| H4-03 | Platform conventions | Verify standard keyboard shortcuts (Ctrl+S, Ctrl+Z, Escape) work as expected | 1 | Medium |
| H4-04 | Link vs button semantics | Check navigation uses `<a>`, actions use `<button>` | 2 | High |
| H4-05 | Consistent layout patterns | Verify similar pages use the same layout template | 1 | Medium |
| H4-06 | Icon consistency | Same concept uses the same icon throughout the app | 1 | Medium |
| H4-07 | Spacing consistency | Verify spacing values come from design token scale (not arbitrary px values) | 1 | Medium |

## H5: Error Prevention

A careful design which prevents a problem from occurring in the first place is better than good error messages.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H5-01 | Confirmation for destructive actions | Verify delete, remove, overwrite actions have confirmation dialogs | 3 | Critical |
| H5-02 | Input constraints | Check inputs have appropriate type, min, max, pattern, maxLength attributes | 2 | High |
| H5-03 | Disabled invalid actions | Verify submit buttons are disabled when form is invalid | 2 | High |
| H5-04 | Autosave for long forms | Check forms with 5+ fields have autosave or draft persistence | 1 | Medium |
| H5-05 | Default safe values | Verify toggle/checkbox defaults are non-destructive | 2 | High |
| H5-06 | Format hints | Check inputs show expected format (placeholder or helper text) | 1 | Medium |
| H5-07 | Double-submit prevention | Verify form submit disables button and prevents duplicate requests | 3 | Critical |

## H6: Recognition Rather Than Recall

Minimize the user's memory load by making objects, actions, and options visible.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H6-01 | Visible labels | Verify all form inputs have persistent labels (not placeholder-only) | 3 | Critical |
| H6-02 | Breadcrumb navigation | Check multi-level pages show breadcrumb trail | 1 | Medium |
| H6-03 | Recent items / history | Verify search and selection fields show recent entries | 1 | Medium |
| H6-04 | Contextual help | Check complex inputs have tooltip or helper text | 2 | High |
| H6-05 | Default selections | Verify dropdowns and selects show sensible defaults | 1 | Medium |
| H6-06 | Autocomplete support | Check text inputs for known values offer autocomplete suggestions | 1 | Medium |

## H7: Flexibility and Efficiency of Use

Accelerators -- unseen by the novice user -- may speed up expert interaction.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H7-01 | Keyboard shortcuts | Verify common actions have keyboard shortcuts (documented) | 1 | Medium |
| H7-02 | Bulk actions | Check list views support multi-select and bulk operations | 1 | Medium |
| H7-03 | Search and filter | Verify data lists have search, sort, and filter capabilities | 2 | High |
| H7-04 | Responsive input methods | Check touch, mouse, and keyboard all work for interactions | 2 | High |
| H7-05 | Customizable views | Verify users can adjust display density, columns, or preferences where applicable | 1 | Medium |

## H8: Aesthetic and Minimalist Design

Dialogues should not contain information which is irrelevant or rarely needed.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H8-01 | Information hierarchy | Verify primary content is visually prominent, secondary content subdued | 2 | High |
| H8-02 | Whitespace usage | Check components have adequate padding and margin (not cramped) | 1 | Medium |
| H8-03 | Progressive disclosure | Verify advanced options are hidden behind expandable sections | 1 | Medium |
| H8-04 | Minimal modal content | Check modals contain only essential information and actions | 1 | Medium |
| H8-05 | Meaningful empty states | Verify empty views explain what to do next (not just "No data") | 2 | High |

## H9: Help Users Recognize, Diagnose, and Recover from Errors

Error messages should be expressed in plain language, precisely indicate the problem, and constructively suggest a solution.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H9-01 | Specific error messages | Verify error messages describe the problem specifically (not generic "An error occurred") | 3 | Critical |
| H9-02 | Recovery suggestions | Check error messages include a recovery action ("Try again", "Go back", "Contact support") | 2 | High |
| H9-03 | Field-level errors | Verify validation errors appear next to the relevant field (not only at form top) | 2 | High |
| H9-04 | Error state persistence | Check error messages remain visible until user takes corrective action | 2 | High |
| H9-05 | Network error recovery | Verify offline/network errors offer retry button | 3 | Critical |
| H9-06 | Non-destructive errors | Check that errors don't clear user input (form data preserved) | 3 | Critical |

## H10: Help and Documentation

Even though it is better if the system can be used without documentation, it may be necessary to provide help.

| ID | Check | Code-Level Instruction | Weight | Priority |
|----|-------|----------------------|--------|----------|
| H10-01 | Onboarding for new users | Check first-use experience has guided tour or tooltips | 1 | Medium |
| H10-02 | Contextual help links | Verify complex features link to documentation or help | 1 | Medium |
| H10-03 | Searchable help | Check help/documentation is searchable | 1 | Medium |
| H10-04 | Tooltip explanations | Verify non-obvious icons and controls have tooltips | 2 | High |

## Cognitive Walkthrough Items

These items are only evaluated when `ux.cognitive_walkthrough: true` in talisman.yml. They require step-by-step analysis of user flows and use the UXC prefix.

| ID | Check | Walkthrough Question | Weight | Priority |
|----|-------|---------------------|--------|----------|
| CW-01 | Goal visibility | Will the user know what to do to achieve their goal? | 3 | Critical |
| CW-02 | Action discoverability | Will the user notice the correct action is available? | 3 | Critical |
| CW-03 | Action-goal mapping | Will the user associate the correct action with their goal? | 2 | High |
| CW-04 | Progress feedback | Will the user understand the system's response as progress toward their goal? | 2 | High |
| CW-05 | Error recovery path | If the user makes a mistake, can they recover without starting over? | 3 | Critical |
| CW-06 | Learnability | After completing the task once, will the user remember how next time? | 1 | Medium |

## Scoring

```
Total possible weight = sum of all applicable item weights
Total failed weight = sum of weights for FAIL items
UX Score = 10 * (1 - total_failed_weight / total_possible_weight)

Score interpretation:
  9.0-10.0 = Excellent UX
  7.0-8.9  = Good UX (minor improvements possible)
  5.0-6.9  = Fair UX (significant issues)
  3.0-4.9  = Poor UX (major usability barriers)
  0.0-2.9  = Critical UX (unusable for many users)
```
