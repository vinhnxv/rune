# Cross-Verification Algorithm

Full specification for Phase 3 of `/rune:codex-review`. Runs on the orchestrator
(lead agent) after all Claude and Codex wings complete. Never delegated to a
teammate — this prevents compromised output from influencing verification.

**Input**: `REVIEW_DIR/claude/*.md` and `REVIEW_DIR/codex/*.md`
**Output**: `REVIEW_DIR/cross-verification.json`

---

## Step 0: Hallucination Guard (SECURITY GATE)

This step MUST run before any cross-verification matching. It is a security
gate, not a quality filter. All Codex findings pass through it; Claude findings
are trusted (produced in-process).

```
for each finding in codex_raw_findings:

  // Check 1: File existence
  if not file_exists(finding.file):
    finding.status = "CDX-HALLUCINATED"
    finding.fail_reason = "file_not_found"
    continue

  // Check 2: Line reference
  actual_line_count = count_lines(finding.file)
  if finding.line > actual_line_count or finding.line < 1:
    finding.status = "CDX-HALLUCINATED"
    finding.fail_reason = "line_out_of_range"
    continue

  // Check 3: Semantic check
  file_content = read_lines(finding.file, max(1, finding.line - 3), finding.line + 3)
  key_terms = extract_key_terms(finding.description)  // nouns, identifiers
  if not any(term in file_content for term in key_terms):
    finding.status = "CDX-HALLUCINATED"
    finding.fail_reason = "semantic_mismatch"
    continue

  finding.status = "valid"

codex_findings = codex_raw_findings.filter(f => f.status === "valid")
hallucinated_count = codex_raw_findings.length - codex_findings.length
```

Stats: `stats.hallucinated_count`, `stats.hallucination_rate`.

---

## Step 1: Parse Findings

Extract structured findings from all agent output files.

### Claude Output Parsing

```
claude_findings = []

for each file in glob(REVIEW_DIR + "/claude/*.md"):
  lines = read_lines(file)
  for each line matching:
    /^\s*-\s*\[\s*\]\s*\*\*\[(\w+-\d+)\]\*\*\s+(.+?)\s+in\s+`([^:]+):(\d+)`/
  extract:
    id          = match[1]   // e.g., XSEC-001
    description = match[2]
    file_path   = match[3]
    line        = int(match[4])
  also extract confidence from next line:
    /Confidence:\s*(\d+)%/  → confidence = int(match[1])
  derive:
    prefix      = id.split('-')[0]   // XSEC, XBUG, etc.
    category    = mapPrefixToCategory(prefix)  // SEC, BUG, PERF, QUAL, DEAD
    severity    = detectSeverity(preceding_heading)  // P1/P2/P3
    source_model = "claude"

claude_findings.push({ id, description, file_path, line, confidence,
                        prefix, category, severity, source_model })
```

### Codex Output Parsing

Same regex patterns applied to `REVIEW_DIR/codex/*.md`. Additional step:

```
// SANITIZATION PIPELINE (SEC-014): Execute in this exact order:
// Step 1: Strip ANCHOR/RE-ANCHOR markers
// Step 2: Strip HTML/script tags (XSS prevention)
// Step 3: Apply sanitizeUntrustedText() (length + encoding normalization)
// Step 4: Parse findings via regex

// Step 1: Strip ANCHOR/RE-ANCHOR echoes from Codex output
content = content.replace(/<!-- ANCHOR.*?-->/gs, '')
content = content.replace(/<!-- RE-ANCHOR.*?-->/gs, '')
// Step 2: Strip HTML/script tags
content = content.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '')
content = content.replace(/<[^>]+>/g, '')
// Step 3: Apply sanitizeUntrustedText() before regex parsing

// Prefix enforcement: reject non-CDX- prefixes
for each parsed finding:
  if not finding.id.startsWith("CDX-"):
    log.warn("SUSPICIOUS_PREFIX in Codex output:", finding.id)
    finding.status = "SUSPICIOUS_PREFIX"  // excluded from cross-verification

// SEC-009: Enforce per-model finding cap to prevent resource exhaustion
MAX_FINDINGS_PER_MODEL = 50
claudeFindings = claudeFindings.slice(0, MAX_FINDINGS_PER_MODEL)
codexFindings = codexFindings.slice(0, MAX_FINDINGS_PER_MODEL)
```

### Finding Schema

```typescript
interface Finding {
  id: string              // e.g., XSEC-001 or CDX-SEC-001
  prefix: string          // XSEC | XBUG | XQAL | XDEAD | XPERF | CDX-*
  category: Category      // SEC | BUG | PERF | QUAL | DEAD
  severity: Severity      // P1 | P2 | P3
  file_path: string       // normalized relative path
  line: number | null     // null if not specified
  description: string
  confidence: number      // 0–100
  source_model: "claude" | "codex"
  status?: "valid" | "CDX-HALLUCINATED" | "SUSPICIOUS_PREFIX"
}
```

---

## Step 2: Normalize

Standardize paths and lines before matching.

### File Path Normalization

```
normalize_path(p):
  p = p.replace(/^\//, '')       // strip leading slash
  p = resolve_relative(p)        // resolve ./ and ../
  p = p.toLowerCase() on case-insensitive FS  // optional
  return p
```

### Line Bucketing

Group lines into buckets to handle small differences in line references.
Bucket width varies by file type (scope-adaptive):

```
function getBucketWidth(file_path):
  ext = path.extname(file_path).toLowerCase()
  match ext:
    case ".py", ".rb":       return 8   // decorator/docstring offsets
    case ".min.js", ".bundle.js": return 2  // dense — avoid false matches
    default:                 return 5   // standard (JS, TS, Go, Java, etc.)

function lineBucket(line, file_path):
  if line is null: return null
  w = getBucketWidth(file_path)
  return floor(line / w) * w   // e.g., line 42 with w=5 → bucket 40
```

### Category Normalization

```
PREFIX_TO_CATEGORY = {
  "XSEC": "SEC",   "CDX-SEC": "SEC",  "CDXS": "SEC",
  "XBUG": "BUG",   "CDX-BUG": "BUG",  "CDXB": "BUG",
  "XPERF": "PERF", "CDX-PERF": "PERF","CDXP": "PERF",
  "XQAL": "QUAL",  "CDX-QUAL": "QUAL", "CDXQ": "QUAL",
  "XDEAD": "DEAD", "CDX-DEAD": "DEAD"
}
```

### Category Adjacency Map

For near-miss category matching (penalized, not rejected):

```
ADJACENT_CATEGORIES = {
  "SEC":  ["BUG"],   // security bugs
  "BUG":  ["SEC", "PERF"],  // bugs that cause perf issues
  "PERF": ["BUG"],
  "QUAL": ["DEAD"],  // quality issues indicating dead code
  "DEAD": ["QUAL"]
}
```

---

## Step 3: Match

For each Claude finding, search for a matching Codex finding.

### Match Key

```
match_key(finding) = (normalize_path(finding.file_path),
                      lineBucket(finding.line, finding.file_path),
                      finding.category)
```

### Match Scoring

```
function computeMatchScore(claude_f, codex_f):
  same_file = (normalize_path(claude_f.file_path) ==
               normalize_path(codex_f.file_path))

  if not same_file:
    return 0.0   // different files → no match

  // Line proximity
  if claude_f.line is null or codex_f.line is null:
    line_match = "no_line"  // match on file+category only
  elif lineBucket(claude_f.line) == lineBucket(codex_f.line):
    line_match = "exact_bucket"
  elif abs(claude_f.line - codex_f.line) <= 10:
    line_match = "nearby"
  else:
    line_match = "distant"

  // Category match
  if claude_f.category == codex_f.category:
    cat_match = "exact"
  elif codex_f.category in ADJACENT_CATEGORIES[claude_f.category]:
    cat_match = "adjacent"
  else:
    cat_match = "none"

  // Score matrix
  match (line_match, cat_match):
    ("exact_bucket", "exact")    → 1.0   // STRONG: same bucket, same category
    ("nearby",       "exact")    → 0.7   // PARTIAL: nearby line, same category
    ("exact_bucket", "adjacent") → 0.64  // adjacent category penalty (0.8×0.8)
    ("no_line",      "exact")    → 0.6   // file+category only, no line
    ("nearby",       "adjacent") → 0.56  // nearby + adjacent
    _                            → 0.0   // no match
```

### Description-Text Fallback

When score is 0.0 but same file, apply Jaccard fallback:

```
function jaccardSimilarity(a, b):
  words_a = Set(tokenize(a))
  words_b = Set(tokenize(b))
  intersection = words_a.intersect(words_b).size
  union = words_a.union(words_b).size
  return intersection / union

// Fallback matching
if score == 0.0 and same_file:
  j = jaccardSimilarity(claude_f.description, codex_f.description)
  if j >= 0.45:
    score = 0.4  // WEAK match — below CROSS-VERIFIED threshold
```

### Multi-line Finding Expansion

For findings spanning a line range (detected by `lines 42–58` pattern in description):

```
if finding.description matches /lines? (\d+)[–\-](\d+)/:
  finding.line_range = { start: int(match[1]), end: int(match[2]) }
  // Expand: match if ANY line in range overlaps other finding's bucket
```

---

## Step 4: Classify

```
CROSS_VERIFIED_THRESHOLD = 0.7

for each (claude_f, codex_f) pair with best_score:

  if best_score >= CROSS_VERIFIED_THRESHOLD:

    // Check for severity disagreement → DISPUTED
    if severity_delta(claude_f.severity, codex_f.severity) >= 2:
      // e.g., claude=P1, codex=P3 → disagreement of 2 levels
      classify as DISPUTED

    else:
      classify as CROSS_VERIFIED
      merged_severity = higher_severity(claude_f.severity, codex_f.severity)
      merged_confidence = confidenceFormula.crossVerified(claude_f, codex_f)

  else:
    // No match found from the other model
    classify as STANDARD (claude_only or codex_only)
```

### Confidence Scoring Formulas

```
cross_model_bonus = talisman.codex_review?.cross_model_bonus ?? 15

CROSS_VERIFIED confidence:
  merged_conf = min(100, max(claude_f.confidence, codex_f.confidence) + cross_model_bonus)

STANDARD confidence:
  original_confidence (unchanged)

DISPUTED confidence:
  penalized_conf = min(claude_f.confidence, codex_f.confidence) - 10
  // Minimum floor: 0
  penalized_conf = max(0, penalized_conf)
```

### Severity Delta Function

```
SEVERITY_ORDER = { "P1": 1, "P2": 2, "P3": 3 }

severity_delta(a, b) = abs(SEVERITY_ORDER[a] - SEVERITY_ORDER[b])
```

---

## Step 5: Dedup

Within each classification group:

```
CROSS-VERIFIED:
  Each (claude_finding, codex_finding) pair → ONE merged finding
  ID = "XVER-{category}-{sequence}"
  Use higher severity, merged confidence (from formula above)
  Include both model descriptions in output

STANDARD (claude_only):
  No dedup — already unique per model
  ID = "CLD-{category}-{sequence}"

STANDARD (codex_only):
  No dedup
  ID = "CDX-{category}-{sequence}"

DISPUTED:
  Keep both findings side-by-side
  ID = "DISP-{sequence}"
```

### Edge Cases

| Scenario | Handling |
|----------|----------|
| One wing returns 0 findings | All findings from other wing → STANDARD, not DISPUTED |
| Finding at exactly `cross_model_bonus` threshold | Use `>=` (inclusive) for CROSS_VERIFIED |
| Multi-file finding | Match on PRIMARY file only (first file mentioned) |
| Finding with `line: null` | Match on `(file, category)` only (no line bucket) |
| Confidence boundary at 80% | Use `>=` inclusive for inclusion threshold |

---

## Step 6: Write cross-verification.json

```typescript
interface CrossVerificationResult {
  // N-way model-agnostic structure (supports future Gemini/Llama addition)
  cross_verified: MergedFinding[]
  disputed: DisputedFinding[]
  model_exclusive: {
    claude: Finding[]     // claude_only
    codex: Finding[]      // codex_only
    // future: gemini: Finding[]
  }
  stats: {
    total_claude: number
    total_codex: number
    hallucinated_count: number
    hallucination_rate: string     // "N%"
    cross_verified_count: number
    disputed_count: number
    claude_only_count: number
    codex_only_count: number
    agreement_rate: string         // "N%"
    suspicious_prefix_count: number
  }
  metadata: {
    generated_at: string           // ISO timestamp
    claude_agents: string[]
    codex_agents: string[]
    cross_model_bonus: number
    confidence_threshold: number
  }
}

interface MergedFinding {
  finding_id: string               // XVER-SEC-001
  models_agree: string[]           // ["claude", "codex"]
  models_disagree: string[]        // []
  agreement_count: number          // 2
  total_models: number             // 2
  severity: Severity               // P1/P2/P3 (higher of two)
  category: Category
  file_path: string
  line: number | null
  merged_confidence: number
  claude_description: string
  codex_description: string
  claude_finding_id: string
  codex_finding_id: string
  match_score: number
}

interface DisputedFinding {
  finding_id: string               // DISP-001
  file_path: string
  line: number | null
  claude_severity: Severity
  codex_severity: Severity
  claude_description: string
  codex_description: string
  disagreement_reason: string      // "severity_mismatch P1 vs P3"
  confidence: number               // penalized formula
}
```

---

## Existing Pattern Reuse

- Line bucket logic from `roundtable-circle/references/dedup-runes.md`
- `<!-- RUNE:FINDING -->` markers for TOME compatibility (enables `/rune:mend`)
- `sanitizeUntrustedText()` from `rune-orchestration` skill
- Config fallback: `talisman.codex_review.cross_model_bonus ?? 15`
- `talisman.codex_review.confidence_threshold ?? 80` for inclusion filtering
