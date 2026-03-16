# Judge Model Protocol

Reference for `semantic_match` proof type — probabilistic verification using a judge model instance.

Source: `docs/discipline-engineering.md` Section 7.2, `proof-schema.md` semantic_match definition.

---

## Overview

The Judge Model Protocol enables verification of **qualitative** acceptance criteria that cannot be checked by deterministic machine proofs (file existence, pattern matching, exit codes). A separate model instance evaluates code against a rubric with no knowledge of the implementer.

**When to use**: Only when no machine proof is feasible. If a criterion can be verified by `pattern_matches`, `test_passes`, or any other machine proof, use that instead.

**Reliability**: LOW-MEDIUM. Results are probabilistic and gated by a confidence threshold.

---

## Inputs

The judge model receives exactly three inputs. Nothing else.

| Input | Source | Description |
|-------|--------|-------------|
| `criterion_text` | Plan acceptance criterion | The human-written criterion being evaluated (e.g., "Error messages must be user-friendly") |
| `code_snippet` | Target file (`head -500`) | The code to evaluate, read directly from the filesystem. Maximum 500 lines. |
| `rubric` | Proof definition | Structured evaluation criteria — maximum 3 clear, measurable points |

### What the Judge Does NOT Receive (Separation Principle)

The judge model operates as an **independent evaluator** with zero implementer context:

- **NO** worker name or agent identity
- **NO** self-assessment or confidence scores from the implementer
- **NO** task history, iteration count, or previous attempts
- **NO** commit messages, PR descriptions, or implementation notes
- **NO** conversation context from the implementation session

This separation prevents the **rationalizer anti-pattern** where a model justifies its own work. The judge evaluates code on its merits alone.

---

## Outputs

The judge returns a JSON response with three fields:

```json
{
  "result": "PASS",
  "confidence": 85,
  "reasoning": "All three rubric criteria are satisfied: functions use descriptive names, error messages include context, and no abbreviations are used."
}
```

| Field | Type | Description |
|-------|------|-------------|
| `result` | `"PASS"` or `"FAIL"` | Binary judgment against the rubric |
| `confidence` | `0-100` (integer) | How certain the judge is about the result |
| `reasoning` | string | Brief explanation citing specific code evidence |

### Result Mapping

| Judge Output | Confidence | Final Result | Failure Code |
|-------------|------------|--------------|--------------|
| PASS | >= 70% | **PASS** | — |
| FAIL | >= 70% | **FAIL** | — |
| PASS | < 70% | **INCONCLUSIVE** | F4 |
| FAIL | < 70% | **INCONCLUSIVE** | F4 |
| (empty/timeout) | — | **FAIL** | F4 |
| (parse error) | — | **FAIL** | F4 |
| (CLI unavailable) | — | **FAIL** | F4 |

**INCONCLUSIVE** always triggers human escalation — it is never treated as a pass.

---

## Confidence Threshold

**Default: 70%**

Configurable per criterion via `confidence_threshold` field in the proof definition.

```yaml
type: semantic_match
target: src/auth/login.ts
rubric: |
  1. Error messages include the failed operation name
  2. Error messages suggest a recovery action
  3. No raw error codes are exposed to users
confidence_threshold: 70
```

### Threshold Semantics

- **>= 70%**: The judge is sufficiently certain. Use the `result` as-is (PASS or FAIL).
- **< 70%**: The judge is uncertain. Result becomes INCONCLUSIVE regardless of the judge's PASS/FAIL answer. Maps to failure code F4 (semantic verification inconclusive).

### Why 70%?

Lower thresholds produce too many false positives (the judge says PASS but isn't sure). Higher thresholds make semantic proofs impractical (too many INCONCLUSIVE results requiring human review). 70% balances automation with reliability.

---

## Rubric Format and Examples

Rubrics must have **maximum 3 clear, measurable criteria**. If you need more than 3, the acceptance criterion should be decomposed into multiple criteria, each with its own proof.

### Structure

```
1. [Specific, observable property]
2. [Specific, observable property]
3. [Specific, observable property]
```

Each criterion should be:
- **Observable**: Can be verified by reading the code (not running it)
- **Specific**: References concrete patterns, not abstract qualities
- **Binary**: Either present or absent — no "somewhat" or "mostly"

### Examples

#### Code Style Rubric

```yaml
rubric: |
  1. All exported functions have JSDoc comments with @param and @returns
  2. Variable names use camelCase (no underscores except constants)
  3. No single-letter variable names outside of loop iterators
```

#### Error Message Quality Rubric

```yaml
rubric: |
  1. Error messages include the name of the failed operation
  2. Error messages suggest at least one recovery action to the user
  3. No raw error codes, stack traces, or internal identifiers are exposed
```

#### Naming Convention Rubric

```yaml
rubric: |
  1. Function names use verb-noun format (e.g., createUser, validateInput)
  2. Boolean variables/functions use is/has/should prefix
  3. Constants use UPPER_SNAKE_CASE
```

### Anti-Patterns (Bad Rubrics)

| Bad Rubric | Problem | Fix |
|-----------|---------|-----|
| "Code should be clean" | Vague, not measurable | "No function exceeds 40 lines" |
| "Good error handling" | Subjective | "All async calls have try/catch with specific error types" |
| "Follows best practices" | Undefined scope | Pick 3 specific practices to check |
| 5+ criteria listed | Too many — judge loses focus | Decompose into multiple semantic_match proofs |

---

## Invocation

The judge is invoked via the Claude CLI in one-shot mode:

```bash
timeout 30 claude --model haiku -p "$prompt"
```

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Model | `haiku` | Smallest sufficient model — fast, cheap, adequate for rubric evaluation |
| Timeout | 30 seconds | Per-criterion budget. Prevents runaway judge calls from blocking the proof executor |
| Mode | `-p` (one-shot) | No conversation state — enforces separation principle |

### Prompt Structure

```
You are a code quality judge. Evaluate the code below against the rubric criteria.
You must respond with ONLY a JSON object — no markdown, no explanation outside the JSON.

RUBRIC:
[rubric text from proof definition]

CODE:
```
[code snippet — first 500 lines of target file]
```

Respond with EXACTLY this JSON format (no other text):
{"result": "PASS" or "FAIL", "confidence": 0-100, "reasoning": "brief explanation"}
```

The prompt is intentionally minimal:
- No system message or persona beyond "code quality judge"
- No examples (few-shot would bias toward specific patterns)
- No mention of the project, team, or implementation context
- JSON-only response format for reliable parsing

---

## Fallback Behavior

| Condition | Result | Failure Code | Evidence |
|-----------|--------|--------------|----------|
| `claude` CLI not in PATH | FAIL | F4 | "claude CLI not available" |
| Target file not found | FAIL | F4 | "target file not found: {path}" |
| Target file empty | FAIL | F4 | "target file is empty: {path}" |
| Judge timeout (>30s) | FAIL | F4 | "judge model returned empty response or timed out" |
| Judge returns empty | FAIL | F4 | "judge model returned empty response or timed out" |
| JSON parse failure | FAIL | F4 | "judge model output not parseable as JSON" |
| Invalid result value | FAIL | F4 | "judge returned invalid result: {value}" |
| Non-numeric confidence | FAIL | F4 | "judge returned non-numeric confidence: {value}" |
| Confidence < threshold | INCONCLUSIVE | F4 | "confidence {N}% below threshold {T}%" |

All fallback cases map to **F4** (semantic verification failure). F4 is non-blocking by default — it does not prevent task completion unless `discipline.block_on_fail: true` in talisman.

---

## Evidence Format

The evidence field in the output JSON includes the judge's full response:

```json
{
  "criterion_id": "AC-3",
  "result": "PASS",
  "evidence": "semantic_match: confidence=85%, reasoning=All error messages include operation name and recovery suggestion; judge_model_response={\"result\":\"PASS\",\"confidence\":85,\"reasoning\":\"...\"}",
  "timestamp": "2026-03-16T19:00:00Z"
}
```

The `judge_model_response` is always included in evidence for auditability — reviewers can inspect exactly what the judge saw and concluded.

---

## See Also

- [proof-schema.md](proof-schema.md) — All proof type definitions and selection decision tree
- [anti-rationalization.md](anti-rationalization.md) — Why separation matters
- [evidence-convention.md](evidence-convention.md) — Evidence storage paths and format
