# Phase 1.5: Plan Ordering (Opt-In Smart Ordering)

Input-type-aware ordering with 3 modes. Queue files respect user order by default. Glob inputs present ordering options. CLI flags override all modes.

See [smart-ordering.md](smart-ordering.md) for the full algorithm when smart ordering is selected.

```javascript
// ── Phase 1.5: Plan Ordering (opt-in smart ordering) ──
// Decision tree: CLI flags > resume guard > talisman mode > input-type heuristic

// readTalismanSection: "arc"
const arcConfig = readTalismanSection("arc")
const smartOrderingConfig = arcConfig?.batch?.smart_ordering || {}
const smartOrderingEnabled = smartOrderingConfig.enabled !== false  // default: true
const smartOrderingMode = smartOrderingConfig.mode || "off"        // "ask" | "auto" | "off" — default "off" ensures smart ordering is truly opt-in

// Validate mode (single check)
const validModes = ["ask", "auto", "off"]
const modeIsValid = validModes.includes(smartOrderingMode)
if (!modeIsValid) {
  warn(`Unknown smart_ordering.mode: '${smartOrderingMode}', defaulting to 'off'.`)
}
const effectiveMode = modeIsValid ? smartOrderingMode : "off"

// ── Priority 1: CLI flags (always win) ──
if (noSmartSort) {
  log("Plan ordering: --no-smart-sort flag — preserving raw order")
} else if (forceSmartSort && planPaths.length === 1) {
  warn("--smart-sort flag ignored: only 1 plan file, no ordering needed")
} else if (forceSmartSort && planPaths.length > 1) {
  log("Plan ordering: --smart-sort flag — applying smart ordering")
  Read("references/smart-ordering.md")
  // Execute smart ordering algorithm
}
// ── Priority 1.5: Resume guard (before talisman — prevents reordering partial batches) ──
else if (resumeMode) {
  log("Plan ordering: resume mode — preserving batch order")
}
// ── Priority 2: Kill switch ──
else if (!smartOrderingEnabled) {
  log("Plan ordering: disabled by talisman (arc.batch.smart_ordering.enabled: false)")
}
// ── Priority 3: Talisman mode ──
else if (effectiveMode === "off") {
  log("Plan ordering: talisman mode='off' — preserving raw order")
} else if (effectiveMode === "auto" && planPaths.length > 1) {
  log("Plan ordering: talisman mode='auto' — auto-applying smart ordering")
  Read("references/smart-ordering.md")
  // Execute smart ordering algorithm
}
// ── Priority 4: Input-type heuristic (mode="ask" or default) ──
else if (inputType === "resume") {
  // skip — resume mode already handled above (Priority 1.5 resume guard)
} else if (inputType === "queue") {
  log("Plan ordering: queue file detected — respecting user-specified order")
} else if (inputType === "glob" && planPaths.length > 1) {
  // Present ordering options to user
  const answer = AskUserQuestion({
    questions: [{
      question: `How should the ${planPaths.length} plans be ordered for execution?`,
      header: "Order",
      options: [
        {
          label: "Smart ordering (Recommended)",
          description: "Dependency-aware: isolated plans first, then by version target. Reduces merge conflicts."
        },
        {
          label: "Alphabetical",
          description: "Sort by filename A→Z. Deterministic and predictable."
        },
        {
          label: "As discovered",
          description: "Keep the default glob expansion order."
        }
      ],
      multiSelect: false
    }]
  })

  if (answer === "Smart ordering (Recommended)") {
    Read("references/smart-ordering.md")
    // Execute smart ordering algorithm
  } else if (answer === "Alphabetical") {
    planPaths.sort((a, b) => a.localeCompare(b))
    log(`Plan ordering: alphabetical — ${planPaths.length} plans sorted A→Z`)
  } else if (answer === "As discovered") {
    log("Plan ordering: discovery order — preserving glob expansion order")
  } else {
    warn(`Plan ordering: unrecognized answer '${answer}', using discovery order`)
    log("Plan ordering: discovery order — preserving glob expansion order")
  }
} else {
  warn("Plan ordering: no applicable rule matched, preserving order")
}
// Single plan or no action needed
```
