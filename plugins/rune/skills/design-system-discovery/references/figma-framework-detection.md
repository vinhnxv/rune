# discoverFigmaFramework(figmaApiResponse, nodeId)

**Input**: `figmaApiResponse` — full Figma API response object; `nodeId` — target node ID to analyze (extracted from Figma URL)
**Output**: detection result object with framework, score, match details, and alternatives — or null-safe fallback on error

Analyzes Figma API component metadata to identify which UI library a design references.
Uses the signature registry from [figma-framework-signatures.md](figma-framework-signatures.md)
for pattern matching. Called during `design-prototype` Phase 0 after Figma API data is fetched.

Layer 2 of the 3-layer detection pipeline (Layer 1: `discoverFrontendStack`, Layer 3: `discoverUIBuilder`).

## Output Schema

```yaml
figma_framework:
  framework: "untitled_ui"      # untitled_ui | shadcn_ui | material_ui | ant_design | null
  score: 0.82                   # 0.0-1.0 weighted match score
  match_details:
    components: ["Buttons/Button", "Page header"]   # max 10 per category (BACK-004)
    variants: ["Size=md, Hierarchy=Primary"]
    icons: ["arrow-left", "home-line"]
    typography: ["Text sm/Semibold"]
    styles: ["Shadows/shadow-xs-skeuomorphic"]
  alternatives:                 # Other frameworks with score >= 0.20
    - framework: "shadcn_ui"
      score: 0.12
  fallback: "react-tailwind-v4" # Used when score < 0.40
```

**Confidence interpretation** (numeric only — no string labels per PAT-004):

| Score Range | Interpretation |
|-------------|---------------|
| >= 0.70 | Strong match — proceed with detected framework |
| 0.40-0.69 | Likely match — usable but may need confirmation |
| < 0.40 | No clear match — use fallback (`react-tailwind-v4`) |

## Algorithm

```
// Import module-level constant (compiled once — BACK-001)
IMPORT FRAMEWORK_SIGNATURES from figma-framework-signatures.md
IMPORT isIconLike from figma-framework-signatures.md

function discoverFigmaFramework(figmaApiResponse, nodeId):
  // FLAW-001: Null guard on missing node
  IF figmaApiResponse is null OR figmaApiResponse.nodes is null:
    RETURN { framework: null, score: 0.0, match_details: {}, alternatives: [], fallback: "react-tailwind-v4", error: "invalid_response" }

  node = figmaApiResponse.nodes[nodeId]
  IF node is null:
    RETURN { framework: null, score: 0.0, match_details: {}, alternatives: [], fallback: "react-tailwind-v4", error: "node_not_found" }

  components = node.components ?? {}        // { id: { name, key, remote } }
  componentSets = node.componentSets ?? {}  // { id: { name, key, remote } }
  styles = node.styles ?? {}                // { id: { name, styleType, remote } }

  // BACK-002: Pre-compute signal arrays ONCE before framework loop
  componentNames = values(componentSets).map(c => c.name)
  allComponentValues = values(components)
  variantNames = allComponentValues.filter(c => c.name.contains("=")).map(c => c.name)
  iconNames = allComponentValues.filter(c => isIconLike(c.name)).map(c => c.name)
  textStyles = values(styles).filter(s => s.styleType === "TEXT").map(s => s.name)
  effectStyles = values(styles).filter(s => s.styleType in ["EFFECT", "FILL"]).map(s => s.name)
  remoteCount = allComponentValues.filter(c => c.remote === true).length
  totalComponents = max(allComponentValues.length, 1)

  scores = {}

  FOR frameworkId, signature IN FRAMEWORK_SIGNATURES:
    score = 0.0
    matchDetails = { components: [], variants: [], icons: [], typography: [], styles: [] }

    // Signal 1: Component name matching (weight: 0.35)
    IF componentNames.length > 0:
      componentMatches = componentNames.filter(n => signature.component_patterns.any(p => p.test(n)))
      score += 0.35 * (componentMatches.length / componentNames.length)
      matchDetails.components = componentMatches.slice(0, 10)  // BACK-004: cap at 10

    // Signal 2: Variant prop matching (weight: 0.25)
    IF variantNames.length > 0:
      variantMatches = variantNames.filter(n => signature.variant_patterns.any(p => p.test(n)))
      score += 0.25 * (variantMatches.length / variantNames.length)
      matchDetails.variants = variantMatches.slice(0, 10)

    // Signal 3: Icon matching (weight: 0.15)
    IF iconNames.length > 0:
      iconMatches = iconNames.filter(n => signature.icon_patterns.any(p => p.test(n)))
      score += 0.15 * (iconMatches.length / iconNames.length)
      matchDetails.icons = iconMatches.slice(0, 10)

    // Signal 4: Typography matching (weight: 0.10)
    IF textStyles.length > 0 AND signature.typography_patterns.length > 0:
      textMatches = textStyles.filter(n => signature.typography_patterns.any(p => p.test(n)))
      score += 0.10 * (textMatches.length / textStyles.length)
      matchDetails.typography = textMatches.slice(0, 10)

    // Signal 5: Effect/fill style matching (weight: 0.05)
    IF effectStyles.length > 0 AND signature.style_patterns.length > 0:
      effectMatches = effectStyles.filter(n => signature.style_patterns.any(p => p.test(n)))
      score += 0.05 * (effectMatches.length / effectStyles.length)
      matchDetails.styles = effectMatches.slice(0, 10)

    // Signal 6: Remote flag bonus (weight: 0.10)
    remoteRatio = remoteCount / totalComponents
    IF remoteRatio > 0.8:
      score += 0.10

    scores[frameworkId] = { score: round(score, 3), matchDetails: matchDetails }

    // BACK-003: Early termination — skip remaining frameworks if near-perfect match
    IF score >= 0.95:
      BREAK

  // Sort by score descending
  ranked = sortByScoreDesc(entries(scores))

  IF ranked.length === 0:
    RETURN { framework: null, score: 0.0, match_details: {}, alternatives: [], fallback: "react-tailwind-v4" }

  winner = ranked[0]
  runnerUp = ranked.length > 1 ? ranked[1] : { score: 0.0 }

  // FLAW-005: Margin check — force low confidence when gap is too small
  marginTooSmall = (winner.score - runnerUp.score) < 0.15 AND winner.score < 0.70

  // FLAW-007: Return threshold 0.40 (not 0.30) — aligns with confidence semantics
  IF winner.score < 0.40 OR marginTooSmall:
    RETURN {
      framework: null,
      score: winner.score,
      match_details: winner.matchDetails,
      alternatives: ranked.filter(r => r.score >= 0.20).map(r => { framework: r.id, score: r.score }),
      fallback: "react-tailwind-v4"
    }

  RETURN {
    framework: winner.id,
    score: winner.score,
    match_details: winner.matchDetails,
    alternatives: ranked.slice(1).filter(r => r.score >= 0.20).map(r => { framework: r.id, score: r.score }),
    fallback: "react-tailwind-v4"
  }
```

## Error Handling

| Error Condition | Behavior |
|-----------------|----------|
| `figmaApiResponse` is null | Return null-safe fallback with `error: "invalid_response"` |
| `nodes[nodeId]` missing | Return null-safe fallback with `error: "node_not_found"` |
| Empty `components` + `componentSets` + `styles` | Return `{ framework: null, score: 0.0 }` — no signals to match |
| All frameworks score 0.0 | Return fallback — pipeline uses `react-tailwind-v4` |

## Design Decisions

### Return threshold 0.40 (FLAW-007)

The plan originally used 0.30, which would return a non-null `framework` for scores the caller
should treat as "no match." By raising to 0.40, callers can trust that a non-null `framework`
field means "usable detection" without also checking the score.

### Margin check (FLAW-005)

When the winner and runner-up are within 0.15 of each other AND the winner is below 0.70,
the result is ambiguous. Force `framework: null` to avoid acting on an uncertain detection.
Above 0.70, the winner is strong enough to trust even with a close runner-up.

### Numeric scores only (PAT-004)

The existing codebase uses numeric 0.0-1.0 confidence with thresholds at 0.90/0.70/0.50.
No string labels (`"high"`, `"medium"`, `"low"`) — callers compare against numeric thresholds.

### Pre-computed signal arrays (BACK-002)

Component names, variant names, icon names, text styles, and effect styles are extracted once
before the framework loop. This reduces array traversals from 12 (3 per framework × 4 frameworks)
to 3 (one extraction pass + one filter per signal category).

### Variant pre-filtering (FLAW-008)

Only component names containing `=` are treated as variant entries. This prevents non-variant
component names from diluting the variant match ratio.

## Mode Guard: Text-Only Path (ARCH-005)

When `design-prototype` runs in text-only mode (`--describe`), no Figma API response exists.
Callers MUST NOT invoke `discoverFigmaFramework()` in text-only mode. The caller (Phase 0)
should branch on input mode:

```
IF mode === "url":
  figmaResponse = figma_list_components(url)
  figmaFramework = discoverFigmaFramework(figmaResponse, nodeId)
ELIF mode === "describe":
  figmaFramework = null  // Layer 2 skipped in text-only mode
```

## Caller Integration

Called from `design-prototype` Phase 0 after Figma API data is fetched:

```
// Phase 0b (sequential — depends on Figma response from Phase 0a)
figmaFramework = discoverFigmaFramework(figmaApiResponse, nodeId)
```

The result feeds into `DesignContext.figma` for the synthesis strategy decision.
See the enriched plan §Integration for the full `DesignContext` composition.
