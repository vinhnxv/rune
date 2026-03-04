# Figma URL Reader — Dual-Format Normalization

Shared reader function that normalizes both old (`figma_url: scalar`) and new (`figma_urls: array`) frontmatter formats into a single canonical array. All consumers use this reader instead of parsing frontmatter directly.

## Contract

```
readFigmaUrls(planContent: string) → FigmaUrlEntry[]

type FigmaUrlEntry = {
  url: string           // Full Figma URL
  role: 'primary' | 'variant' | 'auto'  // User-specified or analyst-determined
  screen: string | null // Screen group name (null = auto-detect)
}
```

### Role Semantics

| Role | Meaning |
|------|---------|
| `primary` | Main canonical file — the authoritative design source for this plan |
| `variant` | Alternate breakpoint or UI state (e.g., mobile layout, dark mode, error state) |
| `auto` | Deferred to analyst — role not specified by author; design-sync agent infers scope |

**Input**: Raw plan file content (string with YAML frontmatter).
**Output**: Ordered array of `FigmaUrlEntry` objects, deduplicated by URL.
**Side effects**: Logs warnings for malformed URLs (does not throw).

## Behavior Rules

| Input State | Output | Notes |
|-------------|--------|-------|
| `figma_urls:` array present (non-empty) | Parse entries from array | Takes precedence over scalar |
| `figma_urls:` array present (empty `[]`) | `[]` — do NOT fall through | Empty array is an explicit "no URLs" signal |
| `figma_url:` scalar present (non-empty) | `[{ url, role: 'primary', screen: null }]` | Legacy single-URL format |
| `figma_url:` empty string `""` | `[]` | Treat empty string as absent |
| Both `figma_urls:` and `figma_url:` present | `figma_urls:` takes precedence, ignore scalar | Log a warning that scalar is ignored |
| Neither present | `[]` | No-op |
| Malformed URL in array | Filter out, warn — do not crash | Log: `warn: skipping malformed Figma URL: {url}` |

### Canonical Naming

| Field | Status | Usage |
|-------|--------|-------|
| `figma_urls: []` | **Canonical** — always present in new plans | Array of `FigmaUrlEntry` objects (may be empty) |
| `figma_url:` | **Legacy** — optional backward-compat only | Scalar string; accepted but not emitted by new tooling |

New consumers MUST read `figma_urls` via `readFigmaUrls()`. Never read `figma_url:` directly — it is only supported as a fallback inside `readFigmaUrls()` itself.

## Array Entry Format (`figma_urls:`)

Each entry in the `figma_urls:` YAML array may be:

**Full object form** (recommended):
```yaml
figma_urls:
  - url: "https://www.figma.com/design/abc123/MyApp?node-id=1-3"
    role: primary
    screen: "Login Screen"
  - url: "https://www.figma.com/design/abc123/MyApp?node-id=4-5"
    role: variant
    screen: "Login Screen (Mobile)"
  - url: "https://www.figma.com/design/xyz789/OtherFile"
    role: auto
    screen: null
```

**String shorthand** (URL only, defaults applied):
```yaml
figma_urls:
  - "https://www.figma.com/design/abc123/MyApp?node-id=1-3"
  - "https://www.figma.com/design/xyz789/OtherFile"
```

String shorthand → `{ url: entry, role: 'auto', screen: null }`.

## Pseudocode Implementation

```
FIGMA_URL_VALIDATION_PATTERN = /^https?:\/\/[^\s]*figma\.com\/[^\s]+/

function readFigmaUrls(planContent: string) → FigmaUrlEntry[]:
  frontmatter = parseFrontmatter(planContent)
  // parseFrontmatter: extract YAML block between first --- markers

  // 1. Prefer figma_urls (new array format)
  if "figma_urls" in frontmatter:
    raw = frontmatter["figma_urls"]

    // Explicit empty array — do not fall through to scalar
    if Array.isArray(raw) AND raw.length === 0:
      return []

    if Array.isArray(raw):
      entries = []
      for each item in raw:
        entry = normalizeEntry(item)
        if entry === null:
          warn(`skipping malformed Figma URL: ${JSON.stringify(item)}`)
          continue
        entries.push(entry)
      return deduplicateByUrl(entries).urls

  // 2. Fall back to figma_url (legacy scalar)
  if "figma_url" in frontmatter:
    scalar = frontmatter["figma_url"]

    // Empty string — treat as absent
    if typeof scalar === "string" AND scalar.trim() === "":
      return []

    if typeof scalar === "string" AND FIGMA_URL_VALIDATION_PATTERN.test(scalar):
      return [{ url: scalar.trim(), role: 'primary', screen: null }]

    warn(`skipping malformed figma_url scalar: ${scalar}`)
    return []

  // 3. No URLs found
  return []

function normalizeEntry(item) → FigmaUrlEntry | null:
  if typeof item === "string":
    url = item.trim()
    if NOT FIGMA_URL_VALIDATION_PATTERN.test(url):
      return null
    return { url: url, role: 'auto', screen: null }

  if typeof item === "object" AND item !== null:
    url = (item.url ?? "").trim()
    if NOT FIGMA_URL_VALIDATION_PATTERN.test(url):
      return null

    role = item.role ?? 'auto'
    if role NOT IN ['primary', 'variant', 'auto']:
      warn(`unknown role '${role}', defaulting to 'auto'`)
      role = 'auto'

    screen = item.screen ?? null
    if screen !== null AND typeof screen !== "string":
      screen = null

    return { url, role, screen }

  return null  // Unsupported type

// Return type: { urls: FigmaUrlEntry[], deduped: boolean, removed_count: number }
function deduplicateByUrl(entries: FigmaUrlEntry[]) → { urls: FigmaUrlEntry[], deduped: boolean, removed_count: number }:
  seen = new Set()
  result = []
  removed = 0
  for each entry in entries:
    if NOT seen.has(entry.url):
      seen.add(entry.url)
      result.push(entry)
    else:
      warn(`duplicate Figma URL removed: ${entry.url}`)
      removed++
  return { urls: result, deduped: removed > 0, removed_count: removed }
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| `figma_urls:` with mix of strings and objects | Each normalized independently via `normalizeEntry()` |
| `figma_urls:` entry with unrecognized `role` | Warn + default to `'auto'` |
| `figma_urls:` entry with non-string `screen` | Coerce to `null` |
| Duplicate URLs in `figma_urls:` | First occurrence kept, duplicates logged + removed |
| Both `figma_urls:` and `figma_url:` present | `figma_urls:` used, `figma_url:` silently ignored + warning logged |
| URL without `node-id` (file-level) | Valid — `screen` will be `null`, analyst determines scope |
| Figma prototype URL (`/proto/`) | Passes regex — downstream `parseFigmaUrl()` reports unsupported type |
| `figma_url:` with leading/trailing whitespace | Trim before validation |
| Plan has no YAML frontmatter | `parseFrontmatter()` returns `{}` — result is `[]` |

## Consumer Migration List

The following 12 points in the codebase previously read `figma_url` directly from plan frontmatter. All must be updated to call `readFigmaUrls(planContent)` instead. **All consumers MUST call `readFigmaUrls()` instead of direct frontmatter access.**

| # | Consumer | Migration | Status |
|---|----------|-----------|--------|
| 1 | **devise/SKILL.md Phase 0** — Design Signal Detection | `figmaUrls[0]` → `readFigmaUrls(...)` | MIGRATED |
| 2 | **devise/SKILL.md Phase 0 --quick fallback** | `quickFigma[0]` → full `readFigmaUrls(...)` | MIGRATED |
| 3 | **brainstorm/SKILL.md Phase 3.5** — Design Asset Detection | `figmaUrls[0]` → `readFigmaUrls(...)` | MIGRATED |
| 4 | **design-sync/SKILL.md Phase 0** — Pre-flight URL argument parsing | add multi-URL loop | PENDING |
| 5 | **design-sync/SKILL.md Phase 0** — State file `figma_url` field | → `figma_urls` array | PENDING |
| 6 | **design-sync/SKILL.md Phase 1** — `figma_fetch_design` call | → iterate over `figmaUrls` | PENDING |
| 7 | **arc/references/arc-phase-design-extraction.md** — Single-URL extraction loop | → multi-URL | PENDING |
| 8 | **devise/references/synthesize.md** — Frontmatter emission | `figma_url:` → `figma_urls:` array | PENDING |
| 9 | **design-sync/references/vsm-spec.md** — VSM `figma_url` metadata field | → `figma_urls` | PENDING |
| 10 | **design-sync/references/phase1-design-extraction.md** — `fetchDesign(parsedUrl)` call site | update to loop | PENDING |
| 11 | **agents/design-sync-agent.md** — Agent prompt URL variable | → array iteration | PENDING |
| 12 | **inscription-schema.md** — `figma_url` inscription field | → `figma_urls: string[]` | PENDING |

### Migration Examples

**Example 1 — Scalar to array (consumers #1, #2, #3)**

```javascript
// BEFORE (scalar direct access)
const figmaUrl = frontmatter.figma_url ?? null
if (figmaUrl) {
  const parsed = parseFigmaUrl(figmaUrl)
  // single-URL logic
}

// AFTER (readFigmaUrls — scalar handled internally)
const figmaEntries = readFigmaUrls(planContent)
const primaryUrl = figmaEntries.find(e => e.role === 'primary')?.url ?? figmaEntries[0]?.url ?? null
if (primaryUrl) {
  const parsed = parseFigmaUrl(primaryUrl)
  // same single-URL logic — backward compatible
}
```

**Example 2 — Array iteration (consumers #4, #6, #10, #11)**

```javascript
// BEFORE (assumed single URL from array index)
const figmaUrls = frontmatter.figma_urls ?? []
const firstUrl = figmaUrls[0] ?? null
if (firstUrl) { await figma_fetch_design({ url: firstUrl }) }

// AFTER (iterate all entries)
const figmaEntries = readFigmaUrls(planContent)
for (const entry of figmaEntries) {
  await figma_fetch_design({ url: entry.url })
  // entry.role and entry.screen available for grouping
}
```

**Example 3 — Dedup check (VEIL-003 structured result)**

```javascript
// Consumers that need to detect whether deduplication occurred
const result = deduplicateByUrl(rawEntries)
// result: { urls: FigmaUrlEntry[], deduped: boolean, removed_count: number }
if (result.deduped) {
  warn(`Removed ${result.removed_count} duplicate Figma URL(s) from plan frontmatter`)
}
const cleanEntries = result.urls
```

## Integration Pattern

Consumers that previously did:
```javascript
const figmaUrl = frontmatter.figma_url ?? null
if (figmaUrl) { /* single-URL logic */ }
```

Should now do:
```javascript
const figmaEntries = readFigmaUrls(planContent)  // FigmaUrlEntry[]
const primaryEntry = figmaEntries.find(e => e.role === 'primary') ?? figmaEntries[0] ?? null

// For single-URL consumers (backward compatible):
const figmaUrl = primaryEntry?.url ?? null

// For multi-URL consumers (new behavior):
for (const entry of figmaEntries) {
  // Process each URL independently
  const parsedUrl = parseFigmaUrl(entry.url)
  // ...
}
```

## Cross-References

- [figma-url-parser.md](figma-url-parser.md) — URL structure parsing (file_key, node_id extraction) `[NOT IN SCOPE for this release]`
- [vsm-spec.md](vsm-spec.md) — VSM schema that records `figma_urls` in metadata
- [phase1-design-extraction.md](phase1-design-extraction.md) — Extraction loop that iterates `readFigmaUrls()`
- [devise/references/synthesize.md](../../devise/references/synthesize.md) — Emits `figma_urls:` frontmatter
