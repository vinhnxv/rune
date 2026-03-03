# State Detection Algorithm

Reference specification for the 5-signal weighted composite algorithm used by the
`design-analyst` agent to classify relationships between Figma frames extracted from
multiple URLs.

## Overview

Given N frames extracted across M Figma URLs, the algorithm computes a pairwise
composite score for each frame pair and groups frames by relationship type:

| Classification | Meaning | Composite |
|---------------|---------|-----------|
| `SAME-SCREEN` | Same screen, different state/breakpoint | >= 0.75 |
| `RELATED` | Likely related — ask user to confirm | 0.50–0.74 |
| `DIFFERENT-SCREEN` | Distinct screens | < 0.50 |
| `VARIANT` | Figma Component Set variant | fast-path |

## Fast Paths

Fast paths resolve classification without signal computation. Evaluated in order:

### Fast Path 1: Different file_key → DIFFERENT-SCREEN

```
if frame_a.file_key != frame_b.file_key:
  → classification: DIFFERENT-SCREEN, confidence: 1.0
  skip all signal computation
```

Rationale: Frames from different Figma files cannot be variants of each other.

### Fast Path 2: Component Set → VARIANT

```
if frame_a.component_set_id != null AND frame_a.component_set_id == frame_b.component_set_id:
  → classification: VARIANT, confidence: 1.0
  skip all signal computation
```

Rationale: Direct Component Set membership is a definitive Figma structural signal.

### Fast Path 3: User Screen Labels → Trust Labels

```
if frame_a.name.startsWith("screen:") OR frame_b.name.startsWith("screen:"):
  label = extractLabel(frame.name)  // "screen:home" → "home"
  → use label as classification hint, skip analyst
```

User-applied `screen:` prefixes express explicit intent and override inference.

## 5-Signal Weighted Composite

When no fast path applies, compute 5 signals and combine via weighted sum.

### Signal Weights

| Signal | Weight | Rationale |
|--------|--------|-----------|
| Name-based | 0.35 | Strongest designer intent signal |
| Component Set | 0.25 | Structural Figma relationship |
| Structural similarity | 0.20 | Child node type sequence |
| Dimension match | 0.10 | Same viewport/canvas size |
| Shared instances | 0.10 | Reused component IDs |

**Total: 1.00**

### Signal 1: Name-Based (w=0.35)

Parses frame names to extract a canonical screen identifier, then computes
string similarity between canonicalized names.

#### Multi-Strategy Name Parser

```
function parseFrameName(name):
  // Strategy 1: slash separator (most common)
  if "/" in name:
    parts = name.split(" / ")
    screen = parts[0]           // "Home"
    variant = parts[1] ?? null  // "Desktop"
    state = parts[2] ?? null    // "Hover"
    return { screen, variant, state }

  // Strategy 2: em-dash separator
  if "—" in name:
    parts = name.split(" — ")
    return { screen: parts[0], variant: parts[1] ?? null, state: null }

  // Strategy 3: underscore decomposition
  if "_" in name:
    parts = name.split("_")
    return { screen: parts[0], variant: parts.slice(1).join("_"), state: null }

  // Strategy 4: no separator — treat full name as screen
  return { screen: name, variant: null, state: null }
```

#### Auto-Generated Name Detection

Skip name signal (score = 0.0) when frame name matches auto-generated pattern:

```
AUTO_GENERATED_PATTERN = /^(Frame|Group|Rectangle|Vector|Ellipse|Line|Polygon|Star|Instance|Component|Section)\s+\d+$/i
```

These names carry no designer intent and would produce spurious similarity scores.

#### Canonical Name Scoring

```
function nameScore(nameA, nameB):
  parsedA = parseFrameName(nameA)
  parsedB = parseFrameName(nameB)

  if AUTO_GENERATED_PATTERN.test(parsedA.screen) OR AUTO_GENERATED_PATTERN.test(parsedB.screen):
    return 0.0

  canonA = parsedA.screen.toLowerCase().trim()
  canonB = parsedB.screen.toLowerCase().trim()

  // Exact match on canonical screen name
  if canonA == canonB: return 1.0

  // Levenshtein ratio similarity
  return levenshteinSimilarity(canonA, canonB)

function levenshteinSimilarity(a, b):
  dist = levenshteinDistance(a, b)
  return 1.0 - (dist / max(a.length, b.length))
```

### Signal 2: Component Set (w=0.25)

```
function componentSetScore(frameA, frameB):
  // Direct Component Set membership (same parent component set)
  if frameA.component_set_id != null AND frameA.component_set_id == frameB.component_set_id:
    return 1.0  // (also triggers fast-path VARIANT)

  // Shared component_id reference in subtrees
  idsA = collectComponentIds(frameA)
  idsB = collectComponentIds(frameB)
  sharedDirectInstances = intersection(idsA, idsB)
  if sharedDirectInstances.length > 0: return 0.5

  return 0.0
```

### Signal 3: Structural Similarity (w=0.20)

Measures how similar the child node type compositions are between two frames,
with dynamic content handling and layout mode bonus.

```
function structuralSimilarityScore(frameA, frameB):
  seqA = collapseConsecutive(collectChildTypes(frameA))
  seqB = collapseConsecutive(collectChildTypes(frameB))

  base = jaccardSimilarity(new Set(seqA), new Set(seqB))

  // Layout mode bonus
  bonus = (frameA.layoutMode == frameB.layoutMode) ? 0.1 : 0.0

  return min(1.0, base + bonus)
```

#### Collapse Consecutive Identical Types

```
function collapseConsecutive(types):
  result = []
  for each type in types:
    if result.length == 0 OR result[result.length - 1] != type:
      result.push(type)
  return result

// ["FRAME","TEXT","TEXT","FRAME"] → ["FRAME","TEXT","FRAME"]
```

This prevents TEXT-heavy frames with different copy counts from being scored as dissimilar.

#### Dynamic Content Handling

All TEXT nodes are treated as the same type regardless of their string content.
Only the structural role (TEXT) matters for similarity — not the copy value.

### Signal 4: Dimension Match (w=0.10)

```
function dimensionScore(frameA, frameB):
  widthRatio = abs(frameA.width - frameB.width) / max(frameA.width, frameB.width)
  heightRatio = abs(frameA.height - frameB.height) / max(frameA.height, frameB.height)

  widthMatch = widthRatio <= 0.05   // within 5% tolerance
  heightMatch = heightRatio <= 0.05

  if widthMatch AND heightMatch: return 1.0
  if widthMatch OR heightMatch: return 0.5
  return 0.0
```

5% tolerance handles pixel-snapping differences and minor layout adjustments between
responsive breakpoints or state variants.

### Signal 5: Shared Instances (w=0.10)

```
function sharedInstancesScore(frameA, frameB):
  idsA = collectAllComponentIds(frameA)  // recursive traversal
  idsB = collectAllComponentIds(frameB)
  return jaccardSimilarity(idsA, idsB)

function jaccardSimilarity(setA, setB):
  intersection = setA ∩ setB
  union = setA ∪ setB
  if union.size == 0: return 0.0
  return intersection.size / union.size
```

## Signal Correlation Discount

Signals 2 (Component Set) and 3 (Structural Similarity) are positively correlated:
Component Set membership implies structural similarity. To avoid double-counting,
apply a 0.9 discount factor when both signals are elevated:

```
function applyCorrelationDiscount(signals):
  cs = signals.component_set
  ss = signals.structural_similarity

  if cs > 0.5 AND ss > 0.5:
    if cs >= ss:
      signals.component_set = cs * 0.9
    else:
      signals.structural_similarity = ss * 0.9

  return signals
```

## Weighted Sum

```
function compositeScore(signals):
  signals = applyCorrelationDiscount(signals)

  return (
    signals.name_based           * 0.35 +
    signals.component_set        * 0.25 +
    signals.structural_similarity * 0.20 +
    signals.dimension_match      * 0.10 +
    signals.shared_instances     * 0.10
  )
```

## Classification Thresholds

```
composite >= 0.75 → SAME-SCREEN
0.50 <= composite < 0.75 → RELATED (user confirmation required)
composite < 0.50 → DIFFERENT-SCREEN
```

## Single-Linkage Clustering

Groups frames by transitive SAME-SCREEN relationships.

```
function cluster(frames, pairwiseScores):
  unassigned = Set(frames)
  groups = []

  while unassigned is not empty:
    seed = unassigned.first()
    group = [seed]
    unassigned.delete(seed)

    // BFS: expand group through SAME-SCREEN edges
    queue = [seed]
    while queue is not empty:
      current = queue.shift()
      for each other in unassigned:
        score = pairwiseScores[pair(current, other)]
        if score.classification == "SAME-SCREEN":
          group.push(other)
          unassigned.delete(other)
          queue.push(other)

    // Select representative: highest average pairwise score within group
    representative = argmax(f in group, avg(pairwiseScores[pair(f, g)] for g in group if g != f))
    groups.push({ frames: group, representative })

  return groups
```

RELATED pairs form their own 2-frame groups and are added to `user_confirmation_required`.
DIFFERENT-SCREEN pairs remain in their separate single-frame groups.

## Per-Signal Breakdown for User Confirmation

When a pair is in the RELATED band and added to `user_confirmation_required`, include
the per-signal breakdown in the output so the user can understand what drove the score:

```json
{
  "group_id": "grp-003",
  "classification": "RELATED",
  "confidence": 0.63,
  "reason": "Composite score 0.63 — in RELATED band (0.50–0.75)",
  "signals": {
    "name_based": { "score": 0.72, "weight": 0.35, "contribution": 0.252 },
    "component_set": { "score": 0.50, "weight": 0.25, "contribution": 0.125 },
    "structural_similarity": { "score": 0.58, "weight": 0.20, "contribution": 0.116 },
    "dimension_match": { "score": 1.00, "weight": 0.10, "contribution": 0.100 },
    "shared_instances": { "score": 0.37, "weight": 0.10, "contribution": 0.037 }
  },
  "interpretation": "Frame names suggest same screen (0.72) but structural composition differs moderately (0.58). Confirm whether these are the same screen at different breakpoints."
}
```

## Example Walkthrough

**Frame A**: `Home / Desktop` (file_key=abc, dimensions=1440×900, 12 TEXT nodes, 3 FRAME nodes)
**Frame B**: `Home / Mobile` (file_key=abc, dimensions=390×844, 11 TEXT nodes, 3 FRAME nodes)

Fast paths:
- Same file_key (abc) → continue
- No Component Set membership → continue
- No `screen:` label → continue

Signals:
- Name-based: parseFrameName gives `screen="Home"` for both → score = 1.0
- Component Set: no shared component_set_id, some shared instances → score = 0.5
- Structural Similarity: both FRAME+TEXT patterns, same layoutMode (VERTICAL) → Jaccard({"FRAME","TEXT"}, {"FRAME","TEXT"}) = 1.0, +0.1 bonus → 1.0 (capped)
- Dimension Match: 1440 vs 390 width (73% diff > 5%) → widthMatch=false; 900 vs 844 (6.2% diff > 5%) → heightMatch=false → score = 0.0
- Shared Instances: moderate overlap → score = 0.45

Correlation discount: component_set=0.5 (not > 0.5) → no discount

Composite = 1.0×0.35 + 0.5×0.25 + 1.0×0.20 + 0.0×0.10 + 0.45×0.10
         = 0.350 + 0.125 + 0.200 + 0.000 + 0.045
         = 0.720

Classification: RELATED (0.50–0.74) → add to user_confirmation_required

**Interpretation**: "Frames share the same screen name (Home) and structural composition but have significantly different widths (1440 vs 390). Likely Desktop vs Mobile breakpoints of the same screen. Confirm to merge into one group."

## Cross-References

- [design-analyst.md](../../../agents/utility/design-analyst.md) — Agent that implements this algorithm
- [phase1-design-extraction.md](phase1-design-extraction.md) — Extraction pipeline that feeds frames to analyst
- [vsm-spec.md](vsm-spec.md) — VSM schema consumed after classification
