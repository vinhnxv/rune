# Reference: Flow Analysis Categories

Detailed reference tables for the flow-seer 4-phase analysis protocol.

## Gap Categories (12)

| # | Category | Key Checks |
|---|----------|------------|
| 1 | **Error Handling** | Failure at each step, error messages, retry behavior, graceful degradation |
| 2 | **State Management** | All states defined, stale/expired/corrupted state, state transition completeness |
| 3 | **Input Validation** | Rules specified, min/max/format/required, sanitization, type coercion |
| 4 | **User Feedback** | Loading states, progress indicators, success/error notifications, empty states |
| 5 | **Security** | Auth checks at each step, CSRF, rate limiting, input sanitization, secrets handling |
| 6 | **Accessibility** | Keyboard navigation, screen reader support, color contrast, focus management |
| 7 | **Data Persistence** | Save timing, partial saves, draft/auto-save, data loss prevention |
| 8 | **Timeout & Rate Limiting** | Session timeout behavior, API rate limits, retry policies, backoff strategies |
| 9 | **Resume & Cancellation** | Partial flow resume, cancellation handling, rollback behavior, draft recovery |
| 10 | **Integration Contracts** | API request/response shapes, error codes, versioning, webhook schemas |
| 11 | **Concurrency** | Multi-user, multi-tab, race conditions, optimistic locking, conflict resolution |
| 12 | **Internationalization** | Date/time formats, RTL support, translation-ready strings, locale handling |

### Category Applicability Guide

Skip categories clearly irrelevant to the feature type:
- **Backend-only features**: Skip 4 (User Feedback), 6 (Accessibility)
- **API/CLI features**: Skip 6 (Accessibility), rename "Device/Context" to "Client/Context"
- **Read-only features**: Skip 7 (Data Persistence), 9 (Resume & Cancellation)

If more than 6 categories skipped, flag as potential under-analysis.

### IEEE 29148:2018 Quality Mapping

| Gap Type | IEEE Quality Characteristic |
|----------|---------------------------|
| Missing error handling | complete, correct |
| Ambiguous requirements | unambiguous |
| Untestable criteria | verifiable |
| Inconsistent terminology | unambiguous, singular |
| Missing edge cases | complete |
| Implicit assumptions | unambiguous, necessary |

## Permutation Dimensions (7)

| Dimension | Common Variations |
|-----------|------------------|
| **User Type** | First-time, returning, admin, anonymous, API consumer |
| **Entry Point** | Direct URL, navigation, deep link, redirect, API call |
| **Client/Context** | Desktop, mobile, tablet, screen reader, API client |
| **Network Condition** | Online, offline, slow/degraded, intermittent |
| **Prior State** | Fresh session, resumed, expired, concurrent |
| **Data State** | Empty/first-use, populated, at-limit, corrupted/invalid, high-volume |
| **Timing** | Immediate, delayed, timeout, concurrent with other operations |

### Permutation Coverage Strategy (NIST-based)

- **Tier 1 (Default)**: Pairwise (2-way) coverage — catches ~70-90% of interaction bugs
- **Tier 2 (Thorough)**: 3-way combinatorial — for high-risk or safety-critical flows
- **Tier 3 (Exhaustive)**: Full enumeration — only for flows with <5 parameters having <=3 values each

## Severity Mapping

Flow-seer uses domain-specific severity labels that map to the Rune convention:

| Flow-Seer Severity | Rune Convention | Meaning |
|--------------------|-----------------|---------|
| CRITICAL | P1 | Blocks implementation |
| HIGH | P2 | Will cause bugs if unaddressed |
| MEDIUM | P3 | Degrades UX |
| LOW | P3 | Nice-to-have improvement |

## Finding Confidence Levels

| Level | Meaning |
|-------|---------|
| **Confirmed gap** | Explicitly missing from spec — traceable to spec omission |
| **Requirement conflict** | Two or more spec statements contradict each other |
| **Speculative concern** | Might be an issue — not definitively missing |

## Question Categories (BABOK-based)

| Category | Template |
|----------|----------|
| **Clarification** | "What does [ambiguous term] mean in the context of [flow X]?" |
| **Confirmation** | "Is it correct that [implicit assumption] applies to [scenario Y]?" |
| **Discovery** | "How should the system behave when [missing edge case] occurs?" |
| **Validation** | "Who is responsible for [unspecified decision] in [flow Z]?" |

## EARS Classification (for Phase 1 flows)

Tag each discovered flow with an EARS classification:

| Type | Pattern | Example |
|------|---------|---------|
| **Ubiquitous** | Always active, no trigger | "The system shall encrypt all data at rest" |
| **State-driven** | While in state X | "While logged in, the user shall see..." |
| **Event-driven** | When event Y occurs | "When payment fails, the system shall..." |
| **Optional** | Where condition Z | "Where dark mode is enabled, colors shall..." |
| **Unwanted** | If exception W, then | "If session expires during save, then..." |

If zero "Unwanted behavior" flows are found, the spec likely omits error handling.
