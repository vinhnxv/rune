# Prompt Warden — 12-Point Review Checklist

Reference document for the prompt-warden agent. Defines validation rules, regex patterns, severity rationale, and decision examples for context pack review.

## Checklist Overview

| # | Check Name | Severity | Quick Description |
|---|-----------|----------|-------------------|
| 1 | `anchor_present` | CRITICAL | ANCHOR heading at top of pack |
| 2 | `output_path_valid` | CRITICAL | Safe output path in frontmatter |
| 3 | `seal_format_correct` | HIGH | Properly formatted seal tags |
| 4 | `file_list_nonempty` | CRITICAL | At least 1 file in SCOPE |
| 5 | `no_implementation_code` | HIGH | No bare code outside fences |
| 6 | `glyph_budget_injected` | HIGH | Glyph budget instruction present |
| 7 | `do_donot_sections` | MEDIUM | Both DO and DO NOT headings |
| 8 | `model_matches_tier` | LOW | Model consistent with manifest |
| 9 | `token_estimate_reasonable` | MEDIUM | token_budget < 5000 |
| 10 | `no_duplicate_packs` | HIGH | Unique agent names in manifest |
| 11 | `shared_context_linked` | LOW | _shared-context.md referenced |
| 12 | `quality_gates_present` | HIGH | QUALITY GATES section exists |

## Severity Classification Rationale

| Severity | Meaning | Impact on Verdict |
|----------|---------|-------------------|
| **CRITICAL** | Missing element makes pack unusable or unsafe. Teammate will malfunction or ignore security boundary. | Each CRITICAL failure increments `critical_blocks`. Any `critical_blocks > 0` produces `BLOCK`. |
| **HIGH** | Missing element degrades quality or weakens security, but pack is technically functional. | Each HIGH failure increments `high_issues`. When `high_issues > 2` produces `WARN`. |
| **MEDIUM** | Missing element reduces clarity or completeness but does not affect correctness. | Counted in issues but does not affect recommendation. |
| **LOW** | Missing element is cosmetic or informational. | Counted in issues but does not affect recommendation. |

## Detailed Check Definitions

### Check 1: `anchor_present` (CRITICAL)

**Purpose**: The ANCHOR heading establishes the Truthbinding protocol boundary. Without it, the teammate has no anti-injection defense.

**Validation**:
```
Pattern: /^#\s+ANCHOR/m
Scope: First 20 lines of the .context.md file
Pass: Pattern matches within first 20 lines
Fail: Pattern not found in first 20 lines
```

**Rationale for CRITICAL**: A pack without ANCHOR exposes the teammate to prompt injection from reviewed code. This is a security-critical omission that must block spawning.

### Check 2: `output_path_valid` (CRITICAL)

**Purpose**: The output path in frontmatter tells the teammate where to write results. An invalid path could cause path traversal or write to protected locations.

**Validation**:
```
Pattern: /^output:\s*(.+)$/m  (extract path from YAML frontmatter)
Safe path: /^[a-zA-Z0-9._\-\/]+$/  (alphanumeric, dots, hyphens, underscores, slashes)
Blocked: /\.\./  (path traversal sequences)
Blocked: Paths starting with /  (absolute paths)
Pass: Path matches safe pattern AND does not contain blocked patterns
Fail: Path fails safe pattern OR contains blocked patterns OR output field is missing
```

**Rationale for CRITICAL**: A malformed output path could allow a teammate to write outside `tmp/`, potentially overwriting plugin files or user code.

### Check 3: `seal_format_correct` (HIGH)

**Purpose**: The seal enables deterministic completion detection. Monitor hooks grep for `<seal>` tags to confirm teammate finished.

**Validation**:
```
Pattern (open): /<seal>/
Pattern (close): /<\/seal>/
Content pattern: /[A-Z][A-Z0-9\-]+-SEAL/  (between tags)
Pass: Both open and close tags found, content matches NAME-SEAL pattern
Fail: Either tag missing, or content does not match pattern
```

**Rationale for HIGH**: Missing seal causes completion detection to fall back to timeout-based detection, which is slower but still functional. Not CRITICAL because the teammate can still produce valid output.

### Check 4: `file_list_nonempty` (CRITICAL)

**Purpose**: The SCOPE section lists files the teammate should review/work on. An empty scope means the teammate has nothing to operate on.

**Validation**:
```
Section: Find content between /^#\s+SCOPE/m and the next /^#\s+/m heading
File pattern: /[a-zA-Z0-9._\-\/]+\.[a-zA-Z]+/  (anything that looks like a file path with extension)
Pass: At least 1 file path found in SCOPE section
Fail: SCOPE section missing OR contains no file paths
```

**Rationale for CRITICAL**: A teammate with empty scope will either review nothing (wasted resources) or review everything (unbounded scope, context explosion).

### Check 5: `no_implementation_code` (HIGH)

**Purpose**: Context packs should contain instructions, not code. Bare code in the pack suggests template rendering errors or prompt injection.

**Validation**:
```
First: Identify fenced code blocks (lines between ``` markers)
Then scan lines OUTSIDE fences for bare code indicators:

Bare code patterns (at line start, optional whitespace):
  /^\s*def\s+\w+\s*\(/           # Python function def
  /^\s*function\s+\w+\s*\(/      # JS/TS function
  /^\s*class\s+\w+[\s({:]/       # Class declaration
  /^\s*import\s+/                 # Import statement
  /^\s*from\s+\w+\s+import\s+/   # Python from-import
  /^\s*(const|let|var)\s+\w+\s*=/ # JS/TS variable declaration

Pass: No bare code patterns found outside fenced blocks
Fail: Any bare code pattern found outside fenced blocks
```

**Rationale for HIGH**: Bare code outside fences is a strong signal of template rendering failure. The teammate might try to execute or modify the injected code rather than following review instructions. Not CRITICAL because the teammate's ANCHOR still protects against following injected instructions.

**False positive guard**: Code inside fenced blocks (triple backticks) is legitimate — templates include code examples for output format. Only flag bare code.

### Check 6: `glyph_budget_injected` (HIGH)

**Purpose**: The glyph budget constrains teammate output length, preventing context overflow in the aggregation phase.

**Validation**:
```
Pattern (case-insensitive): /write\s+all/i  OR  /glyph\s+budget/i
Scope: Entire pack content
Pass: Either pattern found
Fail: Neither pattern found
```

**Rationale for HIGH**: Missing glyph budget allows unbounded output, which can cause context overflow in the Runebinder aggregation phase. Not CRITICAL because the Runebinder can still truncate, but quality degrades.

### Check 7: `do_donot_sections` (MEDIUM)

**Purpose**: DO and DO NOT sections provide explicit behavioral boundaries for the teammate.

**Validation**:
```
DO pattern: /^#\s+DO\b/m  (must be exact heading, not "DOC" or "DOCUMENTATION")
DO NOT pattern: /^#\s+DO\s+NOT\b/m
Pass: Both headings found
Fail: Either heading missing
```

**Rationale for MEDIUM**: These sections enhance clarity but are not strictly required — the TASK section already contains the primary instructions. Their absence reduces prompt quality but does not cause malfunction.

### Check 8: `model_matches_tier` (LOW)

**Purpose**: Ensures the model specified in the pack frontmatter matches the model in manifest.json, indicating consistent tier resolution.

**Validation**:
```
Pack frontmatter: /^model:\s*(\w+)$/m → pack_model
Manifest entry: packs[agent].model → manifest_model
Pass: pack_model === manifest_model  OR  either is absent (inherits)
Fail: Both present and different
```

**Rationale for LOW**: A model mismatch is informational — the actual model used at spawn time is determined by `resolveModelForAgent()`, not the pack frontmatter. The frontmatter model is advisory.

### Check 9: `token_estimate_reasonable` (MEDIUM)

**Purpose**: Catches runaway pack composition that produced oversized prompts.

**Validation**:
```
Frontmatter: /^token_budget:\s*(\d+)$/m → budget
Pass: budget is numeric AND budget < 5000
Fail: budget >= 5000 OR budget is non-numeric OR field is missing
```

**Rationale for MEDIUM**: Oversized packs waste tokens but are still functional. The 5000-token cap is a soft limit based on typical pack sizes (1500-3000 tokens).

### Check 10: `no_duplicate_packs` (HIGH)

**Purpose**: Each agent should have exactly one context pack. Duplicates indicate a scribe composition bug.

**Validation**:
```
Source: manifest.json → packs[].agent
Collect all agent names into a list
Pass: All agent names are unique (no duplicates)
Fail: Any agent name appears more than once
```

**Rationale for HIGH**: Duplicate packs cause ambiguity — which pack does the teammate read? The spawner picks the first match, but the second pack is wasted computation and may contain conflicting instructions.

### Check 11: `shared_context_linked` (LOW)

**Purpose**: When shared context exists, packs should reference it for DRY compliance.

**Validation**:
```
Condition: manifest.json → shared_context field is set (not null/empty)
If set:
  Pattern in each pack: /_shared-context\.md/
  Pass: Pattern found in pack content
  Fail: Pattern not found
If not set:
  Pass: Always (shared context not applicable)
```

**Rationale for LOW**: Missing shared context reference is cosmetic — the shared context file still exists and can be discovered. The teammate may or may not read it independently.

### Check 12: `quality_gates_present` (HIGH)

**Purpose**: Quality gates section contains the Inner Flame self-review checklist. Without it, the teammate skips self-review.

**Validation**:
```
Heading pattern: /^#\s+QUALITY\s+GATES/m
Content check: At least 1 non-empty line after the heading before the next heading
Pass: Heading found AND section has content
Fail: Heading missing OR section is empty
```

**Rationale for HIGH**: Missing quality gates means no Inner Flame self-review, which increases the rate of shallow or incomplete findings. Not CRITICAL because the teammate can still produce valid output.

## Decision Examples

### Example 1: BLOCK — Missing ANCHOR and Empty Scope

```json
{
  "packs_reviewed": 3,
  "checks_passed": 30,
  "checks_total": 36,
  "issues": [
    { "pack": "forge-warden", "check_id": 1, "check_name": "anchor_present", "severity": "CRITICAL", "note": "# ANCHOR heading not found in first 20 lines" },
    { "pack": "ward-sentinel", "check_id": 4, "check_name": "file_list_nonempty", "severity": "CRITICAL", "note": "SCOPE section contains no file paths" }
  ],
  "critical_blocks": 2,
  "high_issues": 0,
  "recommendation": "BLOCK"
}
```

**Why BLOCK**: 2 CRITICAL failures. forge-warden would spawn without Truthbinding protection. ward-sentinel would have no files to review. Tarnished must fall back to inline composition.

### Example 2: WARN — Multiple HIGH Issues

```json
{
  "packs_reviewed": 5,
  "checks_passed": 54,
  "checks_total": 60,
  "issues": [
    { "pack": "forge-warden", "check_id": 3, "check_name": "seal_format_correct", "severity": "HIGH", "note": "Seal tags missing" },
    { "pack": "pattern-weaver", "check_id": 6, "check_name": "glyph_budget_injected", "severity": "HIGH", "note": "No glyph budget instruction found" },
    { "pack": "void-analyzer", "check_id": 12, "check_name": "quality_gates_present", "severity": "HIGH", "note": "QUALITY GATES heading missing" }
  ],
  "critical_blocks": 0,
  "high_issues": 3,
  "recommendation": "WARN"
}
```

**Why WARN**: 0 CRITICAL but 3 HIGH issues (threshold is > 2). Packs are functional but degraded. Tarnished may proceed with advisory or fall back.

### Example 3: PROCEED — Clean Pass

```json
{
  "packs_reviewed": 7,
  "checks_passed": 84,
  "checks_total": 84,
  "issues": [],
  "critical_blocks": 0,
  "high_issues": 0,
  "recommendation": "PROCEED"
}
```

**Why PROCEED**: All checks pass. Spawn teammates with context packs.

### Example 4: PROCEED with LOW Issues

```json
{
  "packs_reviewed": 4,
  "checks_passed": 46,
  "checks_total": 48,
  "issues": [
    { "pack": "ember-oracle", "check_id": 8, "check_name": "model_matches_tier", "severity": "LOW", "note": "Pack says opus, manifest says sonnet" },
    { "pack": "flaw-hunter", "check_id": 11, "check_name": "shared_context_linked", "severity": "LOW", "note": "_shared-context.md not referenced" }
  ],
  "critical_blocks": 0,
  "high_issues": 0,
  "recommendation": "PROCEED"
}
```

**Why PROCEED**: Only LOW issues — informational, no impact on pack functionality. Model mismatch is advisory (runtime resolution takes precedence). Shared context reference is optional.

## Shared Context Structural Validation

When `_shared-context.md` exists in the context-packs directory, validate its structural integrity as an additional check (not numbered in the 12-point checklist but reported as a separate issue if failing):

```
Expected structure: Exactly 3 top-level headings (#):
  1. Truthbinding (or ANCHOR variant)
  2. Glyph Budget
  3. Inner Flame

Validation: Count lines matching /^#\s+/m (top-level headings only)
Pass: Count === 3
Fail: Count !== 3

Issue ID: WARDEN-SHARED-001
Severity: HIGH
Note: "_shared-context.md structural integrity — expected 3 top-level headings, found {N}"
```

## Cross-Pack Consistency

Check #10 is the only cross-pack validation in the current checklist. Future checks may include:

- **Token budget sum**: Total of all pack `token_budget` values should be < workflow limit
- **Scope overlap**: Files assigned to multiple packs (intentional for multi-perspective review)
- **Model diversity**: Verify tier-appropriate model distribution across packs

These are not currently implemented but listed here for future reference.
