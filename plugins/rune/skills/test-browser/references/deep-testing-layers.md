# Deep Testing Layers — Interaction, Data, Visual, UX

## Overview

Beyond smoke-testing (page loads, no console errors), deep testing verifies that
routes actually **work** — forms submit, data persists, layouts render correctly,
and UX flows make sense. These layers activate with `--deep` flag or when
`testing.browser.deep: true` in talisman.

Each layer produces findings tagged with a category prefix for the report:
- `INT-` — Interaction issues
- `DATA-` — Data persistence issues
- `VIS-` — Visual/layout issues
- `UX-` — UX logic issues

## Layer 1: Interaction Testing

Verify that interactive elements on the page actually work.

```
runInteractionTests(route, snapshot, sessionName) → InteractionResult[]

  findings = []

  // 1. Discover interactive elements from snapshot
  //    agent-browser snapshot -i returns @e refs for all interactive elements
  elements = parseSnapshotElements(snapshot)
  //  → [{ ref: "@e1", tag: "input", type: "text", label: "Email", ... },
  //     { ref: "@e2", tag: "button", text: "Submit", ... }, ...]

  // 2. Classify elements
  forms = elements.filter(e => e.tag == "form" || e.parentForm)
  buttons = elements.filter(e => e.tag == "button" || (e.tag == "input" && e.type == "submit"))
  inputs = elements.filter(e => e.tag == "input" || e.tag == "textarea" || e.tag == "select")
  links = elements.filter(e => e.tag == "a" && e.href)

  // 3. Form fill test — try filling all visible inputs
  for each input in inputs:
    if input.type == "hidden" || input.disabled: continue

    testValue = generateTestValue(input)
    // See "Test Value Generation" below

    try:
      Bash(`agent-browser fill ${input.ref} "${testValue}"`)
      // Verify the value was accepted
      Bash(`agent-browser wait 500`)
      newSnapshot = Bash(`agent-browser snapshot -i -s "${input.formSelector ?? 'body'}"`)

      // Check for immediate validation errors
      if hasInlineError(newSnapshot, input):
        // This is expected for invalid input — not a finding
        // But if the error message is missing or unclear, that IS a finding
        errorMsg = extractInlineError(newSnapshot, input)
        if not errorMsg or errorMsg.length < 3:
          findings.push({
            id: "INT-VALIDATION-MSG",
            severity: "medium",
            message: "Input '${input.label ?? input.ref}' shows validation error without clear message",
            element: input.ref
          })
    catch err:
      findings.push({
        id: "INT-FILL-FAIL",
        severity: "high",
        message: "Cannot fill input '${input.label ?? input.ref}': ${err.message}",
        element: input.ref
      })

  // 4. Button click test — verify buttons are clickable and respond
  for each button in buttons:
    if button.disabled: continue
    if button.type == "submit": continue  // tested in form submission flow

    try:
      // Check button is visible and not obscured
      isClickable = Bash(`agent-browser eval "
        const el = document.querySelector('[data-ref=\"${button.ref}\"]') ||
                    document.querySelectorAll('button, [type=button]')[${button.index}];
        if (!el) 'not-found';
        const rect = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') 'hidden';
        if (rect.width === 0 || rect.height === 0) 'zero-size';
        if (style.pointerEvents === 'none') 'no-pointer';
        'clickable';
      "`)

      if isClickable != "clickable":
        findings.push({
          id: "INT-BUTTON-HIDDEN",
          severity: "medium",
          message: "Button '${button.text ?? button.ref}' is ${isClickable}",
          element: button.ref
        })
    catch err:
      // Non-critical — button may be part of a complex widget
      pass

  // 5. Link health check — verify internal links resolve
  for each link in links.slice(0, 5):  // cap at 5 to avoid overwhelming
    if link.href.startsWith("http") and not link.href.includes(baseUrl): continue  // skip external
    if link.href.startsWith("#") or link.href.startsWith("javascript:"): continue

    // Don't navigate — just verify href is well-formed
    if not link.href or link.href == "/" and route == "/":
      continue
    if link.text == "" and not link.ariaLabel:
      findings.push({
        id: "INT-LINK-NO-TEXT",
        severity: "low",
        message: "Link to '${link.href}' has no visible text or aria-label",
        element: link.ref
      })

  return findings
```

### Test Value Generation

```
generateTestValue(input) → string

  switch input.type:
    case "email":    return "test@example.com"
    case "password": return "TestPass123!"
    case "tel":      return "+1234567890"
    case "number":   return "42"
    case "url":      return "https://example.com"
    case "date":     return "2025-01-15"
    case "time":     return "14:30"
    case "search":   return "test query"
    case "color":    return "#ff0000"

  // Infer from label/name/placeholder
  label = (input.label ?? input.name ?? input.placeholder ?? "").toLowerCase()
  if label.includes("name"):   return "Test User"
  if label.includes("email"):  return "test@example.com"
  if label.includes("phone"):  return "+1234567890"
  if label.includes("address"):return "123 Test Street"
  if label.includes("zip") or label.includes("postal"): return "12345"
  if label.includes("city"):   return "Test City"
  if label.includes("price") or label.includes("amount"): return "99.99"

  // Select elements — pick first non-empty option
  if input.tag == "select":
    return input.options?.[1]?.value ?? input.options?.[0]?.value ?? ""

  // Default: generic text
  return "Test input value"
```

## Layer 2: Data Persistence Verification

After filling and submitting a form, verify data actually saved.

```
runDataPersistenceTests(route, snapshot, sessionName) → DataResult[]

  findings = []

  // 1. Detect forms with submit actions
  forms = detectSubmittableForms(snapshot)
  if forms.length == 0: return []

  for each form in forms:
    // 2. Fill all required fields
    requiredFields = form.fields.filter(f => f.required || f.ariaRequired)
    allFields = form.fields.filter(f => !f.hidden && !f.disabled)
    fieldsToFill = requiredFields.length > 0 ? requiredFields : allFields

    filledValues = {}
    for each field in fieldsToFill:
      value = generateTestValue(field)
      try:
        Bash(`agent-browser fill ${field.ref} "${value}"`)
        filledValues[field.name ?? field.label ?? field.ref] = value
      catch: continue

    if Object.keys(filledValues).length == 0: continue

    // 3. Start HAR recording to capture API calls
    Bash(`agent-browser network har start 2>/dev/null || true`)

    // 4. Submit the form
    submitBtn = form.submitButton
    if submitBtn:
      Bash(`agent-browser click ${submitBtn.ref}`)
    else:
      // Try pressing Enter on last input
      lastField = fieldsToFill[fieldsToFill.length - 1]
      Bash(`agent-browser type ${lastField.ref} "" --submit`)

    Bash(`agent-browser wait --load networkidle`)
    Bash(`agent-browser wait 1000`)  // extra wait for async state updates

    // 5. Stop HAR and check for API response
    harPath = `tmp/test-browser/${sessionName}/har-${route.replace(/\//g, "-")}.har`
    Bash(`agent-browser network har stop "${harPath}" 2>/dev/null || true`)

    // 6. Check submission result
    postSnapshot = Bash(`agent-browser snapshot -i`)
    postSnapshotLower = postSnapshot.toLowerCase()

    // Success indicators
    SUCCESS_PATTERNS = ["success", "saved", "created", "updated", "thank you",
                        "submitted", "confirmed", "done", "complete"]
    hasSuccess = SUCCESS_PATTERNS.some(p => postSnapshotLower.includes(p))

    // Error indicators
    ERROR_PATTERNS = ["error", "failed", "invalid", "required", "please enter",
                      "cannot", "unable", "try again"]
    hasError = ERROR_PATTERNS.some(p => postSnapshotLower.includes(p))

    if hasError and not hasSuccess:
      findings.push({
        id: "DATA-SUBMIT-ERROR",
        severity: "high",
        message: "Form submission on '${route}' resulted in error state",
        filledFields: Object.keys(filledValues),
        postSnapshot: postSnapshot.substring(0, 500)
      })
      continue

    // 7. Verify persistence — navigate away and back
    Bash(`agent-browser open "${baseUrl}/" --session "${sessionName}"`)
    Bash(`agent-browser wait --load networkidle`)
    Bash(`agent-browser open "${baseUrl}${route}" --session "${sessionName}"`)
    Bash(`agent-browser wait --load networkidle`)

    returnSnapshot = Bash(`agent-browser snapshot -i`)

    // Check if any filled values appear in the page after navigation
    persistedCount = 0
    for each [fieldName, value] in filledValues:
      if returnSnapshot.includes(value) or returnSnapshot.includes(fieldName):
        persistedCount++

    if persistedCount == 0 and hasSuccess:
      findings.push({
        id: "DATA-NO-PERSIST",
        severity: "high",
        message: "Form on '${route}' reported success but no data found after navigation",
        filledFields: Object.keys(filledValues)
      })
    else if persistedCount > 0:
      log INFO: "Data persistence verified: ${persistedCount}/${Object.keys(filledValues).length} fields"

    // 8. Check localStorage/sessionStorage for client-side state
    storageCheck = Bash(`agent-browser eval "
      const ls = Object.keys(localStorage).length;
      const ss = Object.keys(sessionStorage).length;
      JSON.stringify({ localStorage: ls, sessionStorage: ss });
    " 2>/dev/null || echo "{}"`)

  return findings
```

## Layer 3: Visual & Layout Inspection

Analyze screenshots and DOM for layout, spacing, and alignment issues.

```
runVisualInspection(route, sessionName) → VisualResult[]

  findings = []

  // 1. Take annotated full-page screenshot
  annotatedPath = `tmp/test-browser/${sessionName}/${route.replace(/\//g, "-")}-annotated.png`
  Bash(`agent-browser screenshot --annotate --full-page "${annotatedPath}" 2>/dev/null || true`)

  // 2. Evaluate layout metrics via JS
  layoutReport = Bash(`agent-browser eval -b "
    const issues = [];
    const all = document.querySelectorAll('*');

    for (const el of all) {
      const style = getComputedStyle(el);
      const rect = el.getBoundingClientRect();

      // Skip invisible elements
      if (style.display === 'none' || rect.width === 0) continue;

      // Check: element overflows viewport (horizontal scroll)
      if (rect.right > window.innerWidth + 5) {
        issues.push({
          type: 'overflow',
          tag: el.tagName.toLowerCase(),
          class: el.className?.substring?.(0, 50) || '',
          right: Math.round(rect.right),
          viewport: window.innerWidth
        });
      }

      // Check: element has negative margins causing overlap
      const mt = parseFloat(style.marginTop);
      const ml = parseFloat(style.marginLeft);
      if (mt < -50 || ml < -50) {
        issues.push({
          type: 'negative-margin',
          tag: el.tagName.toLowerCase(),
          class: el.className?.substring?.(0, 50) || '',
          marginTop: mt,
          marginLeft: ml
        });
      }

      // Check: overlapping siblings (z-index conflicts)
      if (el.nextElementSibling) {
        const sibRect = el.nextElementSibling.getBoundingClientRect();
        const overlap = rect.bottom - sibRect.top;
        if (overlap > 10 && style.position !== 'absolute' && style.position !== 'fixed') {
          issues.push({
            type: 'sibling-overlap',
            tag: el.tagName.toLowerCase(),
            class: el.className?.substring?.(0, 50) || '',
            overlapPx: Math.round(overlap)
          });
        }
      }

      // Check: text truncation without ellipsis
      if (el.scrollWidth > el.clientWidth + 2 && style.overflow === 'hidden'
          && style.textOverflow !== 'ellipsis' && el.textContent?.trim().length > 0) {
        issues.push({
          type: 'text-truncated-no-ellipsis',
          tag: el.tagName.toLowerCase(),
          class: el.className?.substring?.(0, 50) || '',
          text: el.textContent.substring(0, 30)
        });
      }

      // Check: interactive elements too small (< 44px touch target)
      if (['A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA'].includes(el.tagName)) {
        if (rect.height < 44 || rect.width < 44) {
          issues.push({
            type: 'small-touch-target',
            tag: el.tagName.toLowerCase(),
            class: el.className?.substring?.(0, 50) || '',
            width: Math.round(rect.width),
            height: Math.round(rect.height)
          });
        }
      }
    }

    // Check: inconsistent spacing between siblings
    const containers = document.querySelectorAll('[class*=list], [class*=grid], [class*=stack], ul, ol, nav');
    for (const container of containers) {
      const children = Array.from(container.children).filter(c => {
        const s = getComputedStyle(c);
        return s.display !== 'none' && c.getBoundingClientRect().height > 0;
      });
      if (children.length < 3) continue;

      const gaps = [];
      for (let i = 1; i < children.length; i++) {
        const gap = children[i].getBoundingClientRect().top - children[i-1].getBoundingClientRect().bottom;
        gaps.push(Math.round(gap));
      }

      const uniqueGaps = [...new Set(gaps)];
      if (uniqueGaps.length > 1) {
        const variance = Math.max(...gaps) - Math.min(...gaps);
        if (variance > 8) {
          issues.push({
            type: 'inconsistent-spacing',
            container: container.tagName.toLowerCase() + '.' + (container.className?.split(' ')[0] || ''),
            gaps: gaps,
            variance: variance
          });
        }
      }
    }

    JSON.stringify(issues.slice(0, 20));
  "`)

  // 3. Parse and convert to findings
  try:
    layoutIssues = JSON.parse(layoutReport)
  catch:
    layoutIssues = []

  SEVERITY_MAP = {
    "overflow": "high",
    "negative-margin": "medium",
    "sibling-overlap": "high",
    "text-truncated-no-ellipsis": "low",
    "small-touch-target": "medium",
    "inconsistent-spacing": "low",
  }

  for each issue in layoutIssues:
    findings.push({
      id: "VIS-${issue.type.toUpperCase().replace(/-/g, '_')}",
      severity: SEVERITY_MAP[issue.type] ?? "low",
      message: formatVisualIssue(issue),
      element: "${issue.tag}.${issue.class}",
      details: issue
    })

  // 4. Responsive spot check — test 3 breakpoints
  BREAKPOINTS = [
    { name: "mobile", width: 375, height: 812 },
    { name: "tablet", width: 768, height: 1024 },
    { name: "desktop", width: 1440, height: 900 },
  ]

  originalViewport = Bash(`agent-browser eval "JSON.stringify({w: window.innerWidth, h: window.innerHeight})"`)

  for each bp in BREAKPOINTS:
    Bash(`agent-browser set viewport ${bp.width} ${bp.height}`)
    Bash(`agent-browser wait 500`)

    // Screenshot per breakpoint
    bpScreenshot = `tmp/test-browser/${sessionName}/${route.replace(/\//g, "-")}-${bp.name}.png`
    Bash(`agent-browser screenshot "${bpScreenshot}"`)

    // Quick overflow check at this breakpoint
    overflowCheck = Bash(`agent-browser eval -b "
      document.documentElement.scrollWidth > document.documentElement.clientWidth ? 'overflow' : 'ok'
    "`)

    if overflowCheck == "overflow":
      findings.push({
        id: "VIS-RESPONSIVE-OVERFLOW",
        severity: "high",
        message: "Horizontal overflow at ${bp.name} (${bp.width}px)",
        screenshot: bpScreenshot
      })

  // Restore original viewport
  original = JSON.parse(originalViewport)
  Bash(`agent-browser set viewport ${original.w} ${original.h}`)

  return findings
```

### Visual Issue Formatting

```
formatVisualIssue(issue) → string

  switch issue.type:
    case "overflow":
      return "Element '${issue.tag}.${issue.class}' overflows viewport (right: ${issue.right}px > ${issue.viewport}px)"
    case "negative-margin":
      return "Element '${issue.tag}.${issue.class}' has large negative margin (top: ${issue.marginTop}px, left: ${issue.marginLeft}px)"
    case "sibling-overlap":
      return "Element '${issue.tag}.${issue.class}' overlaps next sibling by ${issue.overlapPx}px"
    case "text-truncated-no-ellipsis":
      return "Text '${issue.text}...' is truncated without ellipsis in '${issue.tag}.${issue.class}'"
    case "small-touch-target":
      return "Interactive element '${issue.tag}.${issue.class}' is ${issue.width}x${issue.height}px (< 44px minimum)"
    case "inconsistent-spacing":
      return "Inconsistent spacing in '${issue.container}': gaps = [${issue.gaps.join(', ')}]px (${issue.variance}px variance)"
    default:
      return "${issue.type} in ${issue.tag}.${issue.class}"
```

## Layer 4: UX Logic Inspection

Analyze the page for UX patterns, states, and flow coherence.

```
runUXInspection(route, snapshot, sessionName) → UXResult[]

  findings = []

  // 1. Empty state detection
  // If the page has lists/tables/grids that are empty, check for empty state UI
  emptyCheck = Bash(`agent-browser eval -b "
    const results = [];
    const containers = document.querySelectorAll(
      'table tbody, [class*=list], [class*=grid], [role=list], [role=table], ul, ol'
    );
    for (const c of containers) {
      const visibleChildren = Array.from(c.children).filter(ch => {
        const s = getComputedStyle(ch);
        return s.display !== 'none' && ch.getBoundingClientRect().height > 0;
      });
      if (visibleChildren.length === 0) {
        // Check if there's an empty state message nearby
        const parent = c.parentElement;
        const parentText = parent?.textContent?.toLowerCase() || '';
        const hasEmptyMsg = ['no data', 'no results', 'empty', 'nothing',
                             'no items', 'get started', 'no records'].some(p => parentText.includes(p));
        if (!hasEmptyMsg) {
          results.push({
            tag: c.tagName.toLowerCase(),
            class: c.className?.substring?.(0, 50) || '',
            hasEmptyState: false
          });
        }
      }
    }
    JSON.stringify(results);
  "`)

  try:
    emptyContainers = JSON.parse(emptyCheck)
    for each container in emptyContainers:
      findings.push({
        id: "UX-NO-EMPTY-STATE",
        severity: "medium",
        message: "Empty container '${container.tag}.${container.class}' has no empty state message",
        element: container.tag
      })

  // 2. Loading state detection
  // Check for loading indicators that are stuck or missing
  loadingCheck = Bash(`agent-browser eval -b "
    const results = [];

    // Stuck spinners/skeletons (still visible after networkidle)
    const spinners = document.querySelectorAll(
      '[class*=spinner], [class*=loading], [class*=skeleton], [class*=shimmer], ' +
      '[aria-busy=true], [role=progressbar]'
    );
    for (const s of spinners) {
      const style = getComputedStyle(s);
      if (style.display !== 'none' && style.visibility !== 'hidden'
          && s.getBoundingClientRect().height > 0) {
        results.push({
          type: 'stuck-loading',
          tag: s.tagName.toLowerCase(),
          class: s.className?.substring?.(0, 50) || '',
          ariaLabel: s.getAttribute('aria-label') || ''
        });
      }
    }

    // Missing loading feedback on async buttons
    const asyncBtns = document.querySelectorAll('button[type=submit], form button');
    for (const btn of asyncBtns) {
      const hasLoadingState = btn.querySelector('[class*=spinner]')
        || btn.classList.toString().includes('loading')
        || btn.dataset.loading !== undefined
        || btn.getAttribute('aria-busy') !== null;
      if (!hasLoadingState && !btn.disabled) {
        results.push({
          type: 'no-loading-feedback',
          tag: 'button',
          text: btn.textContent?.trim().substring(0, 30) || '',
        });
      }
    }

    JSON.stringify(results);
  "`)

  try:
    loadingIssues = JSON.parse(loadingCheck)
    for each issue in loadingIssues:
      if issue.type == "stuck-loading":
        findings.push({
          id: "UX-STUCK-LOADING",
          severity: "high",
          message: "Loading indicator still visible after page load: '${issue.class}'",
          element: issue.tag
        })
      else if issue.type == "no-loading-feedback":
        findings.push({
          id: "UX-NO-LOADING-FEEDBACK",
          severity: "low",
          message: "Submit button '${issue.text}' has no loading/disabled state for async operations",
          element: "button"
        })

  // 3. Accessibility quick check
  a11yCheck = Bash(`agent-browser eval -b "
    const results = [];

    // Images without alt text
    document.querySelectorAll('img').forEach(img => {
      if (!img.alt && !img.getAttribute('aria-label') && !img.getAttribute('role') !== 'presentation') {
        results.push({ type: 'img-no-alt', src: img.src?.substring(0, 60) || '' });
      }
    });

    // Form inputs without labels
    document.querySelectorAll('input, select, textarea').forEach(input => {
      if (input.type === 'hidden') return;
      const id = input.id;
      const hasLabel = id && document.querySelector('label[for=\"' + id + '\"]');
      const hasAriaLabel = input.getAttribute('aria-label') || input.getAttribute('aria-labelledby');
      const hasPlaceholder = input.placeholder;
      const wrappedInLabel = input.closest('label');
      if (!hasLabel && !hasAriaLabel && !wrappedInLabel) {
        results.push({
          type: 'input-no-label',
          inputType: input.type,
          name: input.name || '',
          hasPlaceholder: !!hasPlaceholder
        });
      }
    });

    // Buttons without accessible text
    document.querySelectorAll('button, [role=button]').forEach(btn => {
      const text = btn.textContent?.trim();
      const ariaLabel = btn.getAttribute('aria-label');
      const ariaLabelledby = btn.getAttribute('aria-labelledby');
      const title = btn.title;
      if (!text && !ariaLabel && !ariaLabelledby && !title) {
        results.push({ type: 'btn-no-text', class: btn.className?.substring(0, 30) || '' });
      }
    });

    // Color contrast (basic heuristic — check text color vs background)
    // Full contrast analysis requires more sophisticated tooling
    // Just flag potential issues with very light text
    const body = document.body;
    const bodyBg = getComputedStyle(body).backgroundColor;

    // Heading hierarchy
    const headings = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6'));
    let prevLevel = 0;
    for (const h of headings) {
      const level = parseInt(h.tagName[1]);
      if (level > prevLevel + 1 && prevLevel > 0) {
        results.push({
          type: 'heading-skip',
          from: 'h' + prevLevel,
          to: h.tagName.toLowerCase(),
          text: h.textContent?.trim().substring(0, 30) || ''
        });
      }
      prevLevel = level;
    }

    // Focus trap detection — check if tabbing is possible
    const focusable = document.querySelectorAll(
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex=\"-1\"])'
    );
    if (focusable.length === 0 && document.querySelectorAll('a, button, input').length > 0) {
      results.push({ type: 'no-focusable', total: document.querySelectorAll('a, button, input').length });
    }

    JSON.stringify(results.slice(0, 15));
  "`)

  try:
    a11yIssues = JSON.parse(a11yCheck)
    for each issue in a11yIssues:
      switch issue.type:
        case "img-no-alt":
          findings.push({
            id: "UX-IMG-NO-ALT",
            severity: "medium",
            message: "Image without alt text: '${issue.src}'"
          })
        case "input-no-label":
          label = issue.hasPlaceholder ? " (has placeholder but no proper label)" : ""
          findings.push({
            id: "UX-INPUT-NO-LABEL",
            severity: "medium",
            message: "Input '${issue.inputType}' name='${issue.name}' has no associated label${label}"
          })
        case "btn-no-text":
          findings.push({
            id: "UX-BTN-NO-TEXT",
            severity: "medium",
            message: "Button has no accessible text (class: '${issue.class}')"
          })
        case "heading-skip":
          findings.push({
            id: "UX-HEADING-SKIP",
            severity: "low",
            message: "Heading level skipped: ${issue.from} → ${issue.to} ('${issue.text}')"
          })
        case "no-focusable":
          findings.push({
            id: "UX-NO-FOCUSABLE",
            severity: "high",
            message: "Page has ${issue.total} interactive elements but none are keyboard-focusable"
          })

  // 4. Error state test — trigger validation and check UX
  // Try submitting an empty form to see error handling
  forms = snapshot.match(/<form/gi)
  if forms and forms.length > 0:
    // Find required inputs that are empty
    requiredInputs = Bash(`agent-browser eval -b "
      const inputs = document.querySelectorAll('input[required], select[required], textarea[required]');
      JSON.stringify(Array.from(inputs).map(i => ({
        ref: i.dataset.ref,
        name: i.name,
        type: i.type
      })).slice(0, 5));
    "`)

    try:
      reqInputs = JSON.parse(requiredInputs)
      if reqInputs.length > 0:
        // Try submitting empty form
        submitBtn = Bash(`agent-browser find role/button "Submit" 2>/dev/null || true`).trim()
        if not submitBtn:
          submitBtn = Bash(`agent-browser find role/button "Save" 2>/dev/null || true`).trim()

        if submitBtn:
          // Click submit without filling required fields
          Bash(`agent-browser click ${submitBtn} 2>/dev/null || true`)
          Bash(`agent-browser wait 500`)

          errorSnapshot = Bash(`agent-browser snapshot -i`)
          errorSnapshotLower = errorSnapshot.toLowerCase()

          // Check for inline error messages
          hasInlineErrors = ["required", "please", "must", "invalid", "cannot be blank",
                            "this field"].some(p => errorSnapshotLower.includes(p))

          if not hasInlineErrors:
            // Check for HTML5 validation bubbles (they don't appear in DOM)
            // If no custom errors AND the form might have native validation:
            findings.push({
              id: "UX-NO-ERROR-MSG",
              severity: "medium",
              message: "Form with ${reqInputs.length} required fields shows no visible error messages on empty submit",
              note: "May rely on browser-native validation popups (not visible in DOM snapshot)"
            })

  // 5. Confirm dialog detection — destructive actions should confirm
  destructiveButtons = Bash(`agent-browser eval -b "
    const btns = document.querySelectorAll('button, [role=button]');
    const destructive = [];
    const DESTRUCTIVE = ['delete', 'remove', 'destroy', 'cancel', 'revoke', 'archive'];
    for (const btn of btns) {
      const text = btn.textContent?.trim().toLowerCase() || '';
      if (DESTRUCTIVE.some(d => text.includes(d)) && !btn.disabled) {
        destructive.push({ text: btn.textContent.trim().substring(0, 30) });
      }
    }
    JSON.stringify(destructive);
  "`)

  try:
    destBtns = JSON.parse(destructiveButtons)
    for each btn in destBtns:
      findings.push({
        id: "UX-DESTRUCTIVE-NO-CONFIRM",
        severity: "low",
        message: "Destructive button '${btn.text}' detected — verify it shows a confirmation dialog",
        note: "Cannot verify confirm dialog without clicking — flagged for manual review"
      })

  return findings
```

## Layer 5: Cross-Screen Workflow Continuity

The most common real-world bugs happen BETWEEN screens: data created on the
Create screen doesn't appear on the List/Edit screen, or data saved via Edit
doesn't persist when viewed on the Detail screen. This layer tests the full
CRUD lifecycle across related screens.

```
runWorkflowContinuityTests(routes, sessionName, baseUrl) → WorkflowResult[]

  findings = []

  // 1. Detect CRUD route groups — cluster related routes
  routeGroups = detectCRUDGroups(routes)
  // → [{ resource: "users", create: "/users/new", list: "/users",
  //       edit: "/users/:id/edit", detail: "/users/:id" }, ...]

  for each group in routeGroups:
    log INFO: "Testing workflow continuity for resource: '${group.resource}'"

    // ==== PHASE A: CREATE → LIST (does new data appear?) ====

    if group.create:
      // A1. Navigate to create screen
      Bash(`agent-browser open "${baseUrl}${group.create}" --session "${sessionName}"`)
      Bash(`agent-browser wait --load networkidle`)
      createSnapshot = Bash(`agent-browser snapshot -i`)

      // A2. Fill form with identifiable test data
      testMarker = `RuneTest_${Date.now().toString(36)}`  // unique marker for verification
      formFields = parseSnapshotElements(createSnapshot).filter(e =>
        e.tag == "input" || e.tag == "textarea" || e.tag == "select")

      filledData = {}
      for each field in formFields:
        if field.type == "hidden" || field.disabled: continue
        value = generateTestValue(field)
        // Inject marker into text fields for later verification
        if field.type == "text" || field.tag == "textarea" || !field.type:
          value = `${testMarker} ${value}`
        try:
          Bash(`agent-browser fill ${field.ref} "${value}"`)
          filledData[field.name ?? field.label ?? field.ref] = value
        catch: continue

      if Object.keys(filledData).length == 0:
        findings.push({
          id: "FLOW-NO-FILLABLE-FIELDS",
          severity: "medium",
          message: "Create screen '${group.create}' has no fillable form fields",
          route: group.create
        })
        continue

      // A3. Start HAR to capture the API call
      Bash(`agent-browser network har start 2>/dev/null || true`)

      // A4. Submit the form
      submitBtn = findSubmitButton(createSnapshot)
      if submitBtn:
        Bash(`agent-browser click ${submitBtn}`)
      else:
        // Try Enter key on last field
        lastRef = formFields[formFields.length - 1]?.ref
        if lastRef: Bash(`agent-browser type ${lastRef} "" --submit 2>/dev/null || true`)

      Bash(`agent-browser wait --load networkidle`)
      Bash(`agent-browser wait 2000`)

      // A5. Stop HAR and check API response
      harPath = `tmp/test-browser/${sessionName}/workflow-${group.resource}-create.har`
      Bash(`agent-browser network har stop "${harPath}" 2>/dev/null || true`)

      postCreateSnapshot = Bash(`agent-browser snapshot -i`)
      postCreateLower = postCreateSnapshot.toLowerCase()

      // Check for error response
      ERROR_PATTERNS = ["error", "failed", "invalid", "required", "please enter",
                        "cannot", "unable", "try again", "500", "422", "400"]
      createFailed = ERROR_PATTERNS.some(p => postCreateLower.includes(p))
        && !["success", "created", "saved"].some(p => postCreateLower.includes(p))

      if createFailed:
        findings.push({
          id: "FLOW-CREATE-FAILED",
          severity: "high",
          message: "Create form on '${group.create}' failed to submit — cannot continue workflow test",
          route: group.create,
          postSnapshot: postCreateSnapshot.substring(0, 300)
        })
        // Screenshot the error state
        Bash(`agent-browser screenshot "tmp/test-browser/${sessionName}/workflow-${group.resource}-create-error.png"`)
        continue

      // A6. Check if redirected to list/detail (common pattern)
      currentUrl = Bash(`agent-browser eval "window.location.pathname"`)
      redirectedToList = currentUrl.includes(group.list ?? group.resource)
      redirectedToDetail = currentUrl.match(/\/\d+/) || currentUrl.includes("/show")

      // A7. Navigate to list screen and verify data appears
      if group.list:
        Bash(`agent-browser open "${baseUrl}${group.list}" --session "${sessionName}"`)
        Bash(`agent-browser wait --load networkidle`)
        listSnapshot = Bash(`agent-browser snapshot -i`)

        // Search for our test marker in the list
        markerFound = listSnapshot.includes(testMarker)

        if not markerFound:
          // Also check if any of the filled values appear
          anyValueFound = Object.values(filledData).some(v => listSnapshot.includes(v))

          if not anyValueFound:
            findings.push({
              id: "FLOW-CREATE-NOT-IN-LIST",
              severity: "critical",
              message: "Data created on '${group.create}' does NOT appear on list screen '${group.list}'",
              route: group.list,
              createdData: Object.keys(filledData),
              note: "Possible causes: API did not persist data, list not refreshed, or data appears on a different page/tab"
            })
            Bash(`agent-browser screenshot "tmp/test-browser/${sessionName}/workflow-${group.resource}-list-missing.png"`)
          else:
            log INFO: "Created data found on list screen (partial match)"
        else:
          log INFO: "Created data verified on list screen '${group.list}' (marker found)"

    // ==== PHASE B: LIST → DETAIL/EDIT (can we access the record?) ====

    if group.list and (group.detail or group.edit):
      // B1. From the list, try to click into the first item
      Bash(`agent-browser open "${baseUrl}${group.list}" --session "${sessionName}"`)
      Bash(`agent-browser wait --load networkidle`)
      listSnapshot = Bash(`agent-browser snapshot -i`)

      // Find clickable items in the list (links to detail/edit)
      listLinks = parseSnapshotElements(listSnapshot).filter(e =>
        e.tag == "a" && e.href && (
          e.href.includes(group.resource) ||
          e.href.match(/\/\d+/) ||
          e.href.includes("/edit") ||
          e.href.includes("/show") ||
          e.href.includes("/detail")
        )
      )

      if listLinks.length > 0:
        // Click the first item
        Bash(`agent-browser click ${listLinks[0].ref}`)
        Bash(`agent-browser wait --load networkidle`)

        detailSnapshot = Bash(`agent-browser snapshot -i`)
        detailUrl = Bash(`agent-browser eval "window.location.pathname"`)

        // B2. Check if detail/edit page loaded with actual data
        if detailSnapshot.length < 100:
          findings.push({
            id: "FLOW-DETAIL-EMPTY",
            severity: "high",
            message: "Detail/edit screen at '${detailUrl}' appears empty after clicking from list",
            route: detailUrl
          })
        else:
          log INFO: "Detail screen loaded at '${detailUrl}' (${detailSnapshot.length} chars)"

          // B3. If it's an edit page, verify fields are pre-populated
          editFields = parseSnapshotElements(detailSnapshot).filter(e =>
            (e.tag == "input" || e.tag == "textarea" || e.tag == "select") &&
            e.type != "hidden" && !e.disabled)

          if editFields.length > 0:
            emptyFields = editFields.filter(f => !f.value || f.value.trim() == "")
            if emptyFields.length > 0 and emptyFields.length == editFields.length:
              findings.push({
                id: "FLOW-EDIT-NOT-POPULATED",
                severity: "critical",
                message: "Edit screen at '${detailUrl}' has ${emptyFields.length} empty fields — data not loaded from API",
                fields: emptyFields.map(f => f.name ?? f.label ?? f.ref),
                note: "Common causes: API endpoint returns empty, wrong ID in URL, field binding mismatch"
              })
            else if emptyFields.length > 0:
              findings.push({
                id: "FLOW-EDIT-PARTIAL-POPULATE",
                severity: "medium",
                message: "Edit screen at '${detailUrl}': ${emptyFields.length}/${editFields.length} fields are empty",
                emptyFields: emptyFields.map(f => f.name ?? f.label ?? f.ref)
              })
      else:
        findings.push({
          id: "FLOW-LIST-NO-LINKS",
          severity: "medium",
          message: "List screen '${group.list}' has no clickable items linking to detail/edit",
          note: "Possible causes: list is empty, links use JS navigation instead of <a> tags"
        })

    // ==== PHASE C: EDIT → SAVE → VERIFY (does edit actually persist?) ====

    if group.edit or (group.detail and detailUrl?.includes("edit")):
      editUrl = group.edit ?? detailUrl
      Bash(`agent-browser open "${baseUrl}${editUrl}" --session "${sessionName}"`)
      Bash(`agent-browser wait --load networkidle`)
      editSnapshot = Bash(`agent-browser snapshot -i`)

      editFields = parseSnapshotElements(editSnapshot).filter(e =>
        (e.tag == "input" || e.tag == "textarea") &&
        e.type != "hidden" && !e.disabled && e.type != "password")

      if editFields.length > 0:
        // C1. Modify one field with a new marker
        editMarker = `RuneEdit_${Date.now().toString(36)}`
        targetField = editFields[0]  // modify first editable field
        originalValue = targetField.value ?? ""

        Bash(`agent-browser fill ${targetField.ref} "${editMarker}"`)

        // C2. Save
        saveBtn = findSubmitButton(editSnapshot)
        if saveBtn:
          Bash(`agent-browser click ${saveBtn}`)
          Bash(`agent-browser wait --load networkidle`)
          Bash(`agent-browser wait 1000`)

          // C3. Navigate away and back to edit page
          Bash(`agent-browser open "${baseUrl}${group.list ?? '/'}" --session "${sessionName}"`)
          Bash(`agent-browser wait --load networkidle`)
          Bash(`agent-browser open "${baseUrl}${editUrl}" --session "${sessionName}"`)
          Bash(`agent-browser wait --load networkidle`)

          verifySnapshot = Bash(`agent-browser snapshot -i`)

          if not verifySnapshot.includes(editMarker):
            findings.push({
              id: "FLOW-EDIT-NOT-PERSISTED",
              severity: "critical",
              message: "Edit on '${editUrl}': modified field '${targetField.name ?? targetField.label}' did not persist after save + navigation",
              expected: editMarker,
              note: "Form appears to submit but API may not save, or field binding is one-way"
            })
          else:
            log INFO: "Edit persistence verified for '${editUrl}'"

  return findings
```

### CRUD Route Group Detection

```
detectCRUDGroups(routes) → CRUDGroup[]

  groups = {}

  for each route in routes:
    // Extract resource name from route
    // /users/new → resource = "users"
    // /users/:id/edit → resource = "users"
    // /admin/products → resource = "products"

    parts = route.split("/").filter(Boolean)

    // Skip pure static routes
    if parts.length == 0: continue

    // Identify resource and action
    resource = null
    action = null

    for each (part, idx) in parts:
      if ["new", "create", "add"].includes(part):
        resource = parts[idx - 1] ?? parts[0]
        action = "create"
        break
      if ["edit", "update", "modify"].includes(part):
        resource = parts.filter(p => !p.match(/^\d+$/) && !["edit","update","modify"].includes(p)).pop()
        action = "edit"
        break
      if part.match(/^\d+$/) || part.match(/^:/) || part == "[id]":
        resource = parts[idx - 1]
        action = "detail"
        break

    if not resource:
      // Pure list route: /users, /products
      resource = parts[parts.length - 1]
      action = "list"

    if not groups[resource]:
      groups[resource] = { resource }

    groups[resource][action] = route

  // Only return groups with at least 2 related routes (create+list, edit+detail, etc.)
  return Object.values(groups).filter(g =>
    Object.keys(g).filter(k => k != "resource").length >= 2
  )
```

### Submit Button Discovery

```
findSubmitButton(snapshot) → string | null

  elements = parseSnapshotElements(snapshot)

  // Priority order for submit button detection
  // 1. button[type=submit]
  submitBtn = elements.find(e => e.tag == "button" && e.type == "submit")
  if submitBtn: return submitBtn.ref

  // 2. input[type=submit]
  submitInput = elements.find(e => e.tag == "input" && e.type == "submit")
  if submitInput: return submitInput.ref

  // 3. Button with submit-like text
  SUBMIT_TEXTS = ["submit", "save", "create", "add", "update", "send", "confirm",
                   "register", "sign up", "log in", "continue", "next", "done",
                   "lưu", "tạo", "gửi", "đăng ký", "tiếp tục"]
  for each el in elements:
    if el.tag == "button":
      textLower = (el.text ?? "").toLowerCase()
      if SUBMIT_TEXTS.some(t => textLower.includes(t)):
        return el.ref

  // 4. Last button in a form
  formButtons = elements.filter(e => e.tag == "button" && e.parentForm)
  if formButtons.length > 0:
    return formButtons[formButtons.length - 1].ref

  return null
```

## Activation

Deep testing layers activate when:
1. `--deep` flag is passed to `/rune:test-browser`
2. `testing.browser.deep: true` in talisman.yml
3. Always for backend-traced routes (since we want to verify the API impact is real)

```
shouldRunDeep = deepFlag || talismanDeep || traceSource[route]?.startsWith("backend")
```

Layer 5 (Workflow Continuity) activates when:
- Deep mode is active AND
- 2+ routes in the route list belong to the same resource (detected by `detectCRUDGroups`)

```
shouldRunWorkflow = shouldRunDeep && detectCRUDGroups(routes).length > 0
```

## Performance Budget

Deep testing adds significant time per route:
- Layer 1 (Interaction): ~5-10s (form fill + button checks)
- Layer 2 (Data Persistence): ~10-15s (submit + navigate away + return)
- Layer 3 (Visual): ~5-10s (JS eval + 3 breakpoints)
- Layer 4 (UX): ~5-10s (JS eval + empty submit test)
- Layer 5 (Workflow): ~20-40s per CRUD group (create + list verify + edit verify)

Total per route with deep (no workflow): ~40-60s (vs ~5-10s without deep).
Total per CRUD group with workflow: ~60-100s.
Cap `--max-routes` at 3 for deep testing to stay under 5 minutes.
