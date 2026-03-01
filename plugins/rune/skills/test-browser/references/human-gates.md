# Human Verification Gates

Some authentication and verification flows require out-of-band human action that cannot be
automated. Human gates pause E2E testing and request user intervention before continuing.

**Standalone mode** (`/rune:test-browser`): gates are surfaced via AskUserQuestion — user
can complete, skip, or abort.

**Arc Phase 7.7 mode** (when `standalone=false`): gates are auto-skipped and the route is
marked `PARTIAL` in the test report. No interactive channel is available in the arc pipeline.

## Gate Patterns

```
HUMAN_GATE_PATTERNS = [
  {
    id: "oauth-sso",
    label: "OAuth / SSO Login",
    urlPatterns: [
      /\/oauth\/callback/,
      /\/auth\/callback/,
      /accounts\.google\.com/,
      /login\.microsoftonline\.com/,
      /github\.com\/login\/oauth/
    ],
    contentPatterns: [
      /sign in with google/i,
      /sign in with github/i,
      /single sign.?on/i,
      /sso/i
    ],
    reason: "OAuth redirects to third-party provider — cannot automate without credentials vault"
  },
  {
    id: "payment",
    label: "Payment / Checkout",
    urlPatterns: [
      /\/checkout/,
      /\/payment/,
      /js\.stripe\.com/,
      /paypal\.com/
    ],
    contentPatterns: [
      /card number/i,
      /credit card/i,
      /stripe/i,
      /payment method/i,
      /billing/i
    ],
    reason: "Payment forms in test mode require test card numbers and real-time validation"
  },
  {
    id: "email-verification",
    label: "Email Verification",
    urlPatterns: [
      /\/verify-email/,
      /\/confirm-email/,
      /\/email-confirm/
    ],
    contentPatterns: [
      /check your email/i,
      /verification link/i,
      /confirm your email/i,
      /we.ve sent/i
    ],
    reason: "Requires access to a real inbox — no in-browser automation possible"
  },
  {
    id: "sms-2fa",
    label: "SMS / Two-Factor Authentication",
    urlPatterns: [
      /\/two-factor/,
      /\/2fa/,
      /\/mfa/,
      /\/otp/
    ],
    contentPatterns: [
      /enter the code/i,
      /verification code/i,
      /sent a text/i,
      /authenticator app/i,
      /6.digit/i
    ],
    reason: "OTP codes require access to phone or authenticator app"
  },
  {
    id: "external-api-key",
    label: "External API Authorization",
    urlPatterns: [
      /\/connect\//,
      /\/authorize/,
      /\/webhook\/callback/
    ],
    contentPatterns: [
      /api key/i,
      /access token/i,
      /authorize access/i,
      /grant permission/i
    ],
    reason: "External API authorization requires user consent on a third-party service"
  }
]
```

## Detection Function

```
detectHumanGate(route, snapshotText) → gate | null

  url = new URL(route)

  for each gate in HUMAN_GATE_PATTERNS:
    // URL pattern check
    for each pattern in gate.urlPatterns:
      if pattern matches url.pathname OR pattern matches url.hostname:
        return gate

    // Page content check (snapshot text as fallback)
    if snapshotText is non-empty:
      for each pattern in gate.contentPatterns:
        if pattern matches snapshotText:
          return gate

  return null  // No gate detected — proceed normally
```

**Note**: URL check runs first. Content check runs only when URL does not match.
This avoids false positives from pages that mention "email verification" in UI copy
without actually being a verification gate.

## Gate Execution (Standalone Mode Only)

```
executeHumanGate(gate, route, standalone) → "completed" | "skipped" | "aborted"

  if standalone is false:
    log: "PARTIAL: Auto-skipping human gate '${gate.label}' (arc mode)"
    return "skipped"

  --- Interactive path (standalone only) ---
  // ⚠ LIMITATION: AskUserQuestion blocks indefinitely until user responds.
  // There is no built-in timeout. If the user walks away, the session hangs.
  // Mitigation: document this clearly to the user in the prompt below.
  response = AskUserQuestion(
    `Human verification required for route: ${route}

Gate type: ${gate.label}
Reason: ${gate.reason}

Please complete the verification in your browser, then return here.

Options:
  - YES  → I completed the action, continue testing
  - SKIP → Skip this route (mark as PARTIAL in report)
  - ABORT → Stop the entire test run`
  )

  normalized = response.trim().toUpperCase()

  if normalized starts with "Y":
    return "completed"

  if normalized starts with "S":
    log: "PARTIAL: User chose to skip gate '${gate.label}' for route '${route}'"
    return "skipped"

  if normalized starts with "A":
    log: "ABORT: User chose to abort test run at gate '${gate.label}'"
    return "aborted"

  // Unrecognized response → default to skip (safe)
  log: "PARTIAL: Unrecognized gate response '${response}'. Defaulting to skip."
  return "skipped"
```

## Route Status Mapping

| Gate result | Route status in report |
|-------------|----------------------|
| `"completed"` | Continues — route passes/fails on its own merit |
| `"skipped"` | `PARTIAL` — route included in report with gate note |
| `"aborted"` | All subsequent routes cancelled — run marked `ABORTED` |

## Integration into E2E Test Loop

```
for each route in testRoutes:
  // Navigate and take initial snapshot
  navigate(route)
  snapshotText = agent-browser snapshot -i --text

  // Check for human gate BEFORE running assertions
  gate = detectHumanGate(route, snapshotText)
  if gate is not null:
    result = executeHumanGate(gate, route, standalone)
    if result == "aborted":
      break  // Exit route loop
    if result == "skipped":
      routeReport[route] = { status: "PARTIAL", reason: gate.label }
      continue  // Next route
    // result == "completed" → fall through, run normal assertions

  // Normal assertion flow...
  runAssertions(route)
```

## Talisman Configuration

```yaml
testing:
  human_gates:
    enabled: true          # set false to auto-skip ALL gates (CI mode)
    auto_skip_in_arc: true # default true — always auto-skip in arc Phase 7.7
```

When `enabled: false`, `detectHumanGate` always returns `null` — useful for fully
automated CI environments where human interaction is impossible.
