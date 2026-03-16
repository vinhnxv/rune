# Failure Codes (F1-F17)

Runtime classification codes for discipline proof failures. Each code maps a proof
execution failure to a structured category with detection heuristics and recovery paths.

Used by `execute-discipline-proofs.sh` (classification) and `validate-discipline-proofs.sh`
(aggregation into evidence summary).

Each code has four fields: code, category, detection_signal, and recovery_path.

---

## Code Registry

### F1 — DECOMPOSITION_FAILURE

| Field | Value |
|---|---|
| **Code** | `F1` |
| **Name** | `DECOMPOSITION_FAILURE` |
| **Category** | `proof_execution` |
| **Detection Signal** | Task criteria could not be decomposed into executable proof steps. Criterion JSON is malformed, missing required fields (`criterion_id`, `type`), or contains circular references. |
| **Recovery Path** | Re-parse criteria file. Validate JSON schema before execution. If persistent, escalate to plan author — criteria definition is ambiguous. |

### F2 — COMPREHENSION_MISMATCH

| Field | Value |
|---|---|
| **Code** | `F2` |
| **Name** | `COMPREHENSION_MISMATCH` |
| **Category** | `proof_execution` |
| **Detection Signal** | Proof type and target are valid but the proof evaluated the wrong artifact. Evidence text does not reference the criterion's expected target path or pattern. Detected when evidence string lacks the criterion's `target` or `pattern` substring. |
| **Recovery Path** | Re-read the criterion specification. Verify target path resolution relative to CWD. Re-run proof with corrected target. |

### F3 — PROOF_FAILURE

| Field | Value |
|---|---|
| **Code** | `F3` |
| **Name** | `PROOF_FAILURE` |
| **Category** | `proof_execution` |
| **Detection Signal** | Proof executed but produced FAIL result. Specific sub-signals: (a) empty evidence directory, (b) pattern too long (>200 chars), (c) target file missing, (d) pattern not matched, (e) empty file/pattern field. |
| **Recovery Path** | Read evidence text for the specific sub-signal. Fix the implementation to satisfy the criterion. Re-run proof. |

### F4 — TIMEOUT_INCONCLUSIVE

| Field | Value |
|---|---|
| **Code** | `F4` |
| **Name** | `TIMEOUT_INCONCLUSIVE` |
| **Category** | `proof_execution` |
| **Detection Signal** | Proof command exceeded its timeout limit (60s for `test_passes`, 120s for `builds_clean`). Exit code 124 from `timeout` command. Evidence contains "exited non-zero" with a command that was wrapped in `timeout`. |
| **Recovery Path** | Increase timeout if legitimate long-running test. Optimize the test/build command. If infrastructure-related, check system load. Mark as INCONCLUSIVE for human review. |

### F5 — ESCALATION_EXHAUSTION

| Field | Value |
|---|---|
| **Code** | `F5` |
| **Name** | `ESCALATION_EXHAUSTION` |
| **Category** | `proof_execution` |
| **Detection Signal** | Worker has retried the same criterion multiple times (3+ attempts) without achieving PASS. Detected by convergence tracking — same `criterion_id` appears in multiple round files with FAIL status. |
| **Recovery Path** | Stop retrying. Escalate to the Tarnished with full debug context. Create a blocking task for human review. |

### F6 — DEPENDENCY_FAILURE

| Field | Value |
|---|---|
| **Code** | `F6` |
| **Name** | `DEPENDENCY_FAILURE` |
| **Category** | `infrastructure` |
| **Detection Signal** | Proof depends on an artifact from another task that has not been produced yet. Target file is expected to exist but the producing task is still `pending` or `in_progress`. |
| **Recovery Path** | Check task dependency graph. Wait for upstream task completion. If circular dependency detected, escalate to plan author. |

### F7 — CONTEXT_CORRUPTION

| Field | Value |
|---|---|
| **Code** | `F7` |
| **Name** | `CONTEXT_CORRUPTION` |
| **Category** | `infrastructure` |
| **Detection Signal** | Evidence directory or criteria file is corrupted — JSON parse failure, truncated files, or unexpected file format. Detected when `jq empty` fails on criteria.json or proof output. |
| **Recovery Path** | Regenerate criteria file from plan. Clear and recreate evidence directory. If persistent, check disk space and filesystem integrity. |

### F8 — INFRASTRUCTURE_FAILURE

| Field | Value |
|---|---|
| **Code** | `F8` |
| **Name** | `INFRASTRUCTURE_FAILURE` |
| **Category** | `infrastructure` |
| **Detection Signal** | Proof failed due to missing tooling (jq, grep, timeout not found), unknown proof type, CWD inaccessible, or executor script not found/executable. |
| **Recovery Path** | Install missing tools. Verify proof executor is executable (`chmod +x`). Check CWD accessibility. Verify proof type is one of: `file_exists`, `pattern_matches`, `no_pattern_exists`, `test_passes`, `builds_clean`. |

### F9 — RESERVED

| Field | Value |
|---|---|
| **Code** | `F9` |
| **Name** | `RESERVED` |
| **Category** | `reserved` |
| **Detection Signal** | Reserved for future use. Not emitted by current classification logic. |
| **Recovery Path** | N/A — this code is a placeholder for future expansion. |

### F10 — REGRESSION

| Field | Value |
|---|---|
| **Code** | `F10` |
| **Name** | `REGRESSION` |
| **Category** | `evidence_quality` |
| **Detection Signal** | A criterion that previously passed now fails. Detected by comparing current proof results against a previous round's results where the same `criterion_id` had `result: PASS`. |
| **Recovery Path** | Identify what changed between rounds. Check git diff for unintended modifications. Revert if the regression was caused by a different task's implementation. |

### F11 — EVIDENCE_STALENESS

| Field | Value |
|---|---|
| **Code** | `F11` |
| **Name** | `EVIDENCE_STALENESS` |
| **Category** | `evidence_quality` |
| **Detection Signal** | Evidence timestamp is older than the most recent file modification in the target path. The proof result may be outdated. Detected when `evidence.timestamp` predates `stat -c '%Y'` (or `stat -f '%m'` on macOS) of the target file. |
| **Recovery Path** | Re-run the proof to get fresh evidence. Do not trust cached results when source files have been modified. |

### F12 — EVIDENCE_FABRICATION

| Field | Value |
|---|---|
| **Code** | `F12` |
| **Name** | `EVIDENCE_FABRICATION` |
| **Category** | `evidence_quality` |
| **Detection Signal** | Evidence claims a file exists or a pattern matches, but independent verification fails. The `evidence_path` in summary.json points to a non-existent file, or the claimed pattern match cannot be reproduced. |
| **Recovery Path** | Re-run proof from scratch. Do not trust worker-reported evidence — verify independently. If fabrication is confirmed, flag the worker for review. |

### F13 — ECHO_PARROTING

| Field | Value |
|---|---|
| **Code** | `F13` |
| **Name** | `ECHO_PARROTING` |
| **Category** | `evidence_quality` |
| **Detection Signal** | Worker evidence text is a near-verbatim copy of the criterion description rather than actual proof output. Detected by string similarity (>80% overlap) between `criterion.description` and `evidence` text. |
| **Recovery Path** | Require the worker to provide concrete evidence (file paths, command output, line numbers) rather than restating the requirement. |

### F14 — PLAN_DRIFT

| Field | Value |
|---|---|
| **Code** | `F14` |
| **Name** | `PLAN_DRIFT` |
| **Category** | `evidence_quality` |
| **Detection Signal** | The implementation satisfies the proof but diverges from the plan's intent. Proof passes mechanically but the code does not match the plan's architectural description. Detected by semantic verification (judge model). |
| **Recovery Path** | Review implementation against plan description, not just acceptance criteria. Align code with plan intent. May require plan update if drift is intentional. |

### F15 — BUDGET_EXCEEDED

| Field | Value |
|---|---|
| **Code** | `F15` |
| **Name** | `BUDGET_EXCEEDED` |
| **Category** | `operational` |
| **Detection Signal** | Proof execution consumed more resources than allocated — context window exhaustion, token budget exceeded, or wall-clock time exceeded for the overall proof session. |
| **Recovery Path** | Reduce proof scope. Split large criterion sets into batches. Increase budget allocation in talisman config if justified. |

### F16 — CROSS_CUTTING_ORPHAN

| Field | Value |
|---|---|
| **Code** | `F16` |
| **Name** | `CROSS_CUTTING_ORPHAN` |
| **Category** | `operational` |
| **Detection Signal** | A criterion references artifacts owned by multiple tasks, but no single task's evidence covers it completely. The criterion falls through the cracks of task decomposition. |
| **Recovery Path** | Assign explicit ownership of cross-cutting criteria. Create a dedicated integration task that verifies cross-task interactions. |

### F17 — CONVERGENCE_STAGNATION

| Field | Value |
|---|---|
| **Code** | `F17` |
| **Name** | `CONVERGENCE_STAGNATION` |
| **Category** | `operational` |
| **Detection Signal** | Convergence loop has not made progress for 2+ consecutive rounds. The same set of criteria remain FAIL/PARTIAL across rounds with no improvement in pass count. |
| **Recovery Path** | Break the stagnation — try a different implementation approach. Escalate to the Tarnished if blocked. Consider relaxing criteria or splitting into smaller sub-criteria. |

---

## Category Summary

| Category | Codes | Description |
|---|---|---|
| `proof_execution` | F1, F2, F3, F4, F5 | Failures in the proof execution pipeline itself |
| `infrastructure` | F6, F7, F8 | Environment, tooling, or dependency failures |
| `reserved` | F9 | Reserved for future expansion |
| `evidence_quality` | F10, F11, F12, F13, F14 | Issues with the quality or integrity of evidence |
| `operational` | F15, F16, F17 | Workflow-level operational failures |

---

## Classification Priority

When multiple failure codes could apply, use the **most specific** code:

1. Infrastructure failures (F6-F8) take priority — they indicate the proof could not run at all.
2. Proof execution failures (F1-F5) are next — the proof ran but failed for a structural reason.
3. Evidence quality issues (F10-F14) apply post-execution — the proof ran but the evidence is suspect.
4. Operational failures (F15-F17) are workflow-level — they transcend individual proofs.

---

## Detection Signal Quick Reference (for classify_failure)

Used by `execute-discipline-proofs.sh` `classify_failure()` function:

| Pattern | F-Code | Signal |
|---|---|---|
| Empty evidence / empty target | F3 | `PROOF_FAILURE` — no artifact to verify |
| Pattern length > 200 chars | F3 | `PROOF_FAILURE` — pattern too long |
| Empty file field for pattern proof | F3 | `PROOF_FAILURE` — missing file reference |
| Unknown proof type | F8 | `INFRASTRUCTURE_FAILURE` — unsupported type |
| Command contains shell metacharacters | F8 | `INFRASTRUCTURE_FAILURE` — blocked by security |
| Timeout (exit 124) | F4 | `TIMEOUT_INCONCLUSIVE` |
| File not found | F3 | `PROOF_FAILURE` — target missing |
| Pattern not matched | F3 | `PROOF_FAILURE` — criterion not met |
| Build/test non-zero exit | F3 | `PROOF_FAILURE` — command failed |
| JSON parse failure | F7 | `CONTEXT_CORRUPTION` |
| Criteria field missing | F1 | `DECOMPOSITION_FAILURE` |
