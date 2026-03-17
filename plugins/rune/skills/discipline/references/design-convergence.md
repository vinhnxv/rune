# Design Convergence — Criteria-Based Design Fidelity Iteration

Convergence protocol for design fidelity iteration in arc Phases 5.2 and 7.6.
Mirrors [work-loop-convergence.md](../../strive/references/work-loop-convergence.md) but operates
on DES- prefixed design criteria instead of AC- code criteria.

**Key difference from code convergence**: Design convergence uses per-criterion PASS/FAIL
status as the PRIMARY gate (not score threshold). Score threshold is preserved as a SECONDARY
gate for backward compatibility.

---

## Entry Conditions

The design convergence loop activates ONLY when ALL of the following are true:

1. **Design sync enabled**: `talisman.yml` → `design_sync.enabled === true`
2. **Iterate enabled**: `talisman.yml` → `design_sync.iterate_enabled === true`
3. **DES- criteria exist**: At least one `DES-*` criterion from Phase 5.2 design verification
4. **At least one non-PASS DES- criterion**: If all DES- criteria PASS after Phase 5.2,
   the convergence loop is skipped (success on first pass)
5. **Design findings exist**: `tmp/arc/{id}/design-findings.json` is non-empty

When entry conditions are NOT met, the design iteration phase (7.6) is skipped entirely.

---

## Configuration

| Config Key | Default | Description |
|---|---|---|
| `design_sync.max_iterations` | `3` | Maximum design convergence iterations |
| `design_sync.fidelity_threshold` | `80` | SECONDARY gate — score threshold (0-100 scale, used by Phase 5.2) |
| `design_sync.discipline.fidelity_threshold` | `0.8` | Per-criterion fidelity threshold (0-1 scale, used by design convergence) |
| `design_sync.iterate_enabled` | `true` | Enable design iteration phase |
| `design_sync.discipline.block_on_fail` | `false` | Whether design convergence failure blocks pipeline |

---

## Per-Criterion Status Matrix

Each DES- criterion is tracked with per-iteration status:

| Status | Meaning | Action |
|---|---|---|
| `PASS` | Criterion verified — design proof passed | No action needed |
| `FAIL` | Design proof failed — implementation diverges from spec | Generate correction task |
| `INCONCLUSIVE` | Tool dependency unavailable (F4 graceful degradation) | Exclude from convergence calculation |
| `REGRESSION` | Was PASS in prior iteration, now FAIL | Flag F10 — investigate cross-cutting side effect |
| `STAGNANT` | Failed 2+ consecutive iterations unchanged | Flag F17 — escalate to human |

### Per-Iteration Evidence Artifact

Each iteration writes a design criteria matrix to:
`tmp/arc/{id}/design-criteria-matrix-{iteration}.json`

```json
{
  "iteration": 1,
  "timestamp": "2026-03-17T12:00:00Z",
  "criteria": [
    {
      "id": "DES-Button-tokens",
      "component": "Button",
      "dimension": "tokens",
      "status": "PASS",
      "proof_type": "token_scan",
      "evidence": "No hardcoded hex colors found in src/components/Button.tsx",
      "previous_status": null
    },
    {
      "id": "DES-Card-a11y",
      "component": "Card",
      "dimension": "a11y",
      "status": "FAIL",
      "proof_type": "axe_passes",
      "evidence": "3 WCAG AA violations: missing alt text, low contrast, no focus indicator",
      "failure_code": "F3",
      "previous_status": null
    },
    {
      "id": "DES-Card-responsive",
      "component": "Card",
      "dimension": "responsive",
      "status": "INCONCLUSIVE",
      "proof_type": "responsive_check",
      "evidence": "agent-browser not available: neither agent-browser CLI nor playwright found",
      "failure_code": "F4",
      "previous_status": null
    }
  ],
  "summary": {
    "total": 8,
    "pass": 5,
    "fail": 2,
    "inconclusive": 1,
    "dsr": 0.714
  }
}
```

### DSR (Design Spec-compliance Rate)

```
DSR = pass_count / (total - inconclusive_count)
```

INCONCLUSIVE criteria are excluded from the denominator — they represent tool unavailability,
not implementation failure.

---

## Convergence Logic

### Primary Gate: Per-Criterion PASS/FAIL

The PRIMARY convergence check evaluates individual DES- criteria status:

```
function designConvergenceCheck(matrix):
  actionable = matrix.criteria.filter(c => c.status != "INCONCLUSIVE")
  nonPass = actionable.filter(c => c.status != "PASS")

  if nonPass.length == 0:
    return { converged: true, gate: "criteria", dsr: 1.0 }

  return { converged: false, remaining: nonPass.map(c => c.id), dsr: computeDSR(matrix) }
```

### Secondary Gate: Score Threshold (Backward Compatibility)

The SECONDARY gate uses the aggregate fidelity score from Phase 5.2:

```
function scoreThresholdCheck(fidelityScore, threshold):
  if fidelityScore >= threshold:
    return { converged: true, gate: "score" }
  return { converged: false }
```

**Precedence**: Primary gate (criteria) takes priority. If all DES- criteria PASS but
aggregate score is below threshold, convergence succeeds (criteria-based is authoritative).
If score exceeds threshold but some DES- criteria FAIL, convergence does NOT succeed
(criteria failures override score).

---

## Iteration Protocol

Each design convergence iteration:

```
for iteration in 1..maxIterations+1:
  matrix = readDesignCriteriaMatrix(id, iteration - 1)
  actionable = matrix.filter(c => c.status != "INCONCLUSIVE")
  nonPass = actionable.filter(c => c.status != "PASS")

  // --- Success exit ---
  if nonPass.length == 0:
    writeDesignCriteriaMatrix(id, iteration, matrix, "success")
    return { exit: "success", dsr: 1.0 }

  // --- Budget exit ---
  if iteration > maxIterations:
    dsr = computeDSR(matrix)
    writeDesignCriteriaMatrix(id, iteration, matrix, "budget_exceeded", "F15")
    return { exit: "budget_exceeded", failure_code: "F15", dsr }

  // --- Stagnation exit (F17) ---
  if iteration >= 2:
    prevNonPass = readPreviousNonPassDesign(id, iteration - 1)
    if setEquals(nonPass.ids, prevNonPass.ids):
      dsr = computeDSR(matrix)
      writeDesignCriteriaMatrix(id, iteration, matrix, "stagnation", "F17")
      return { exit: "stagnation", failure_code: "F17", dsr }

  // --- Regression detection (F10) ---
  // NOTE: This reference spec exits on regression for strictness. The arc Phase 7.6
  // implementation (arc-phase-design-iteration.md) logs regressions as warnings but
  // continues the loop — this is intentional to allow other non-regressed criteria
  // to converge. Implementations MAY choose either behavior based on strictness needs.
  if iteration >= 2:
    regressions = findDesignRegressions(id, iteration)
    if regressions.length > 0:
      dsr = computeDSR(matrix)
      writeDesignCriteriaMatrix(id, iteration, matrix, "regression", "F10")
      return { exit: "regression", failure_code: "F10", dsr, regressions }

  // --- Create design fix tasks ---
  for criterion in nonPass:
    createDesignFixTask(iteration, criterion)

  // --- Execute fixes + re-verify ---
  executeDesignFixes(id, iteration)
  reRunDesignProofs(id, iteration)  // re-run execute-discipline-proofs.sh

  writeDesignCriteriaMatrix(id, iteration, updatedMatrix, null)
```

---

## Regression Detection (F10)

A design regression occurs when a DES- criterion that was PASS in a prior iteration
becomes FAIL in the current iteration. This indicates that a design fix for one criterion
caused a side effect on another.

```
function findDesignRegressions(id, currentIteration):
  currentMatrix = readDesignCriteriaMatrix(id, currentIteration)
  regressions = []
  for criterion in currentMatrix.criteria:
    if criterion.status == "FAIL":
      for prevIter in 1..currentIteration:
        prevMatrix = readDesignCriteriaMatrix(id, prevIter)
        prevCriterion = prevMatrix.criteria.find(c => c.id == criterion.id)
        if prevCriterion?.status == "PASS":
          regressions.push({
            criterion_id: criterion.id,
            regressed_from_iteration: prevIter,
            evidence: criterion.evidence
          })
          break
  return regressions
```

**Recovery**: Log regressed criteria with the iteration where they last passed.
Design regressions are non-blocking by default (`discipline.design.block_on_fail: false`).

---

## Stagnation Detection (F17)

Stagnation occurs when the same set of DES- criteria fails across 2 consecutive iterations
with no improvement. This signals a structural problem that automated iteration cannot resolve.

```
function detectDesignStagnation(id, currentIteration):
  if currentIteration < 2: return false
  currentFails = getCurrentNonPassIds(id, currentIteration)
  prevFails = getCurrentNonPassIds(id, currentIteration - 1)
  return setEquals(currentFails, prevFails)
```

**Recovery**: Escalate to human review. Include the stagnant criteria IDs and their
failure evidence across iterations.

---

## Integration with Arc Phases

### Phase 5.2 (Design Verification) — Produces Initial Matrix

Phase 5.2 runs design proofs and writes the initial `design-criteria-matrix-0.json`
(iteration 0 = pre-convergence baseline). This is the input to the convergence loop.

### Phase 7.6 (Design Iteration) — Runs Convergence Loop

Phase 7.6 reads the baseline matrix from Phase 5.2 and iterates using the protocol above.
Each iteration re-runs design proofs via `execute-discipline-proofs.sh` and updates
the criteria matrix.

### Convergence Report

On loop exit, write summary to `tmp/arc/{id}/design-convergence-report.json`:

```json
{
  "design_convergence": {
    "iterations_used": 2,
    "max_iterations": 3,
    "exit_reason": "success",
    "exit_failure_code": null,
    "final_dsr": 1.0,
    "first_pass_dsr": 0.714,
    "regressions_total": 0,
    "stagnation_rounds": 0,
    "primary_gate": "criteria",
    "secondary_gate_score": 92,
    "secondary_gate_threshold": 80
  }
}
```

---

## See Also

- [work-loop-convergence.md](../../strive/references/work-loop-convergence.md) — Code convergence protocol (pattern source)
- [design-proof-types.md](design-proof-types.md) — 6 design proof types executed during convergence
- [failure-codes.md](failure-codes.md) — F10 (regression), F15 (budget), F17 (stagnation)
- [metrics-schema.md](metrics-schema.md) — DSR metric definition
