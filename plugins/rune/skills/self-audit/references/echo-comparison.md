# Echo Comparison — Delta Analysis Algorithm

Reference document for `/rune:self-audit` echo comparison between consecutive runs.

## Overview

Echo comparison identifies what changed between self-audit runs by comparing current findings against persistent entries in `meta-qa/MEMORY.md`. This produces a delta report with three sections: **New**, **Resolved**, and **Persistent** findings.

> **CRITICAL**: Comparison uses persistent `meta-qa/MEMORY.md` entries — NOT ephemeral `metrics.json` from `tmp/`. The `tmp/` directory is cleaned by `/rune:rest`, so metrics stored there cannot survive between sessions.

## Finding ID Format

```
SA-{CATEGORY}-{NNN}
```

| Category | Prefix | Dimension |
|----------|--------|-----------|
| Agent prompt quality | AGT | prompt |
| Workflow definitions | WF | workflow |
| Hook scripts | HK | hook |
| Rule consistency | RC | rule |

Examples: `SA-AGT-001`, `SA-WF-014`, `SA-HK-003`, `SA-RC-005`

IDs are assigned sequentially within each category. Once assigned, an ID is stable across runs (deduplication prevents reassignment).

## Deduplication Algorithm

New findings are compared against existing `meta-qa/MEMORY.md` entries to prevent duplicates. Two findings are considered duplicates when their **Jaccard similarity >= 0.8**.

### Jaccard Similarity Computation

```javascript
function computeJaccard(finding1, finding2) {
  // Extract significant keywords (exclude stopwords, punctuation)
  const words1 = extractKeywords(finding1.description + " " + finding1.evidence)
  const words2 = extractKeywords(finding2.description + " " + finding2.evidence)

  // Compute Jaccard index
  const set1 = new Set(words1.map(w => w.toLowerCase()))
  const set2 = new Set(words2.map(w => w.toLowerCase()))

  const intersection = [...set1].filter(w => set2.has(w))
  const union = new Set([...set1, ...set2])

  return intersection.length / union.size
}

function extractKeywords(text) {
  const STOPWORDS = new Set([
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'in', 'on', 'at',
    'to', 'for', 'of', 'with', 'by', 'from', 'this', 'that', 'it',
    'and', 'or', 'but', 'not', 'no', 'has', 'have', 'had', 'be', 'been'
  ])
  return text
    .split(/[\s\-_.,;:!?()[\]{}'"]+/)
    .filter(w => w.length > 2 && !STOPWORDS.has(w.toLowerCase()))
}
```

**Threshold rationale**: 0.8 is the same threshold used by `review-recurrence-detector.sh` for review finding deduplication. It's strict enough to avoid false merges while catching reformulations of the same issue.

### Matching Priority

When a new finding matches multiple existing entries:
1. Exact ID match (same `SA-{CAT}-{NNN}`) → highest priority
2. Same category + Jaccard >= 0.8 → match
3. Cross-category Jaccard >= 0.9 → match (rare, for recategorized findings)

## Delta Analysis Algorithm

```javascript
function compareAuditRuns(currentFindings, memoryPath) {
  // 1. Parse existing entries from meta-qa/MEMORY.md
  const previousEntries = parseMemoryEntries(memoryPath)
  const previousIds = new Set(previousEntries.map(e => e.finding_id).filter(Boolean))

  // 2. Match current findings against previous entries
  const currentIds = new Set(currentFindings.map(f => f.id))

  const results = {
    new_findings: [],
    resolved_findings: [],
    persistent_findings: [],
    score_delta: {}
  }

  // 3. Classify each current finding
  for (const finding of currentFindings) {
    if (previousIds.has(finding.id)) {
      // Exact ID match → persistent
      results.persistent_findings.push(finding)
    } else {
      // Check Jaccard similarity against all previous entries
      const match = previousEntries.find(prev =>
        computeJaccard(finding, prev) >= 0.8
      )
      if (match) {
        // Fuzzy match → persistent (same issue, possibly reworded)
        finding.matched_previous_id = match.finding_id
        results.persistent_findings.push(finding)
      } else {
        // No match → new finding
        results.new_findings.push(finding)
      }
    }
  }

  // 4. Find resolved findings (in previous, not in current)
  for (const prev of previousEntries) {
    if (!prev.finding_id) continue
    const stillExists = currentFindings.some(f =>
      f.id === prev.finding_id || computeJaccard(f, prev) >= 0.8
    )
    if (!stillExists) {
      results.resolved_findings.push(prev)
    }
  }

  // 5. Compute score deltas per dimension
  const dimensions = ['prompt', 'workflow', 'hook', 'rule']
  for (const dim of dimensions) {
    const currentCount = currentFindings.filter(f => f.dimension === dim).length
    const previousCount = previousEntries.filter(e => e.dimension === dim).length
    results.score_delta[dim] = previousCount - currentCount  // fewer findings = improvement
  }
  results.score_delta.overall =
    Object.values(results.score_delta).reduce((a, b) => a + b, 0)

  return results
}
```

## Memory Entry Parsing

Entries in `meta-qa/MEMORY.md` follow this format:

```markdown
### [2026-03-19] Pattern: {description}
- **layer**: inscribed | etched
- **source**: rune:self-audit {mode}-{timestamp}
- **finding_id**: SA-{CAT}-{NNN}
- **recurrence_count**: {N}
- **last_seen**: {ISO date}
- **phase_tags**: [{phase1}, {phase2}]
- **confidence**: {0.0-1.0}
- {description and evidence text}
```

### Parser

```javascript
function parseMemoryEntries(memoryPath) {
  const content = Read(memoryPath)
  if (!content) return []

  const entries = []
  let current = null

  for (const line of content.split('\n')) {
    if (line.startsWith('### [')) {
      if (current) entries.push(current)
      current = {
        header: line,
        description: '',
        finding_id: null,
        recurrence_count: 0,
        last_seen: null,
        layer: null,
        dimension: null
      }
    } else if (current) {
      // Parse metadata fields
      const findingMatch = line.match(/\*\*finding_id\*\*:\s*(\S+)/)
      if (findingMatch) {
        current.finding_id = findingMatch[1]
        // Derive dimension from category prefix
        const cat = current.finding_id.split('-')[1]
        const dimMap = { AGT: 'prompt', WF: 'workflow', HK: 'hook', RC: 'rule' }
        current.dimension = dimMap[cat] || 'unknown'
      }

      const recurrenceMatch = line.match(/\*\*recurrence_count\*\*:\s*(\d+)/)
      if (recurrenceMatch) current.recurrence_count = parseInt(recurrenceMatch[1])

      const lastSeenMatch = line.match(/\*\*last_seen\*\*:\s*(\S+)/)
      if (lastSeenMatch) current.last_seen = lastSeenMatch[1]

      const layerMatch = line.match(/\*\*layer\*\*:\s*(\S+)/)
      if (layerMatch) current.layer = layerMatch[1]

      // Accumulate description text (non-metadata lines)
      if (!line.startsWith('- **')) {
        current.description += line + ' '
      }
    }
  }
  if (current) entries.push(current)

  return entries
}
```

## Output Format

### Delta Report Section

```markdown
## Changes Since Last Audit ({previous_date})

| Category | Count | Details |
|----------|-------|---------|
| New findings | {N} | {comma-separated IDs} |
| Resolved | {N} | {comma-separated IDs} (fixed or no longer applicable) |
| Persistent | {N} | Still open from previous audits |

### Score Delta
| Dimension | Previous | Current | Delta |
|-----------|----------|---------|-------|
| Prompt (AGT) | {N} findings | {N} findings | {+/-N} |
| Workflow (WF) | {N} findings | {N} findings | {+/-N} |
| Hook (HK) | {N} findings | {N} findings | {+/-N} |
| Rule (RC) | {N} findings | {N} findings | {+/-N} |
| **Overall** | **{N}** | **{N}** | **{+/-N}** |

> Note: Negative delta = fewer findings = improvement
```

### New Finding Detail

For each new finding, include:
```markdown
### NEW: SA-{CAT}-{NNN} — {title}
- **First seen**: {current_date}
- **Category**: {category}
- **Evidence**: {brief evidence summary}
```

### Resolved Finding Detail

For each resolved finding, include:
```markdown
### RESOLVED: SA-{CAT}-{NNN} — {title}
- **First seen**: {original_date}
- **Resolved after**: {recurrence_count} occurrences
- **Resolution**: Fix applied | No longer applicable | Superseded by SA-{CAT}-{NNN}
```

## Recurrence Counting and Promotion Logic

### Recurrence Increment

When a finding persists across runs:
1. Increment `recurrence_count` in the MEMORY.md entry
2. Update `last_seen` to current date
3. Check promotion threshold

### Tier Promotion Thresholds

| Current Tier | Condition | Promoted To |
|-------------|-----------|-------------|
| observations | recurrence_count >= 2 | traced |
| traced | recurrence_count >= 3 | inscribed |
| inscribed | recurrence_count >= 5 AND confidence >= 0.85 | etched |

Promotion is one-directional — findings never demote. Resolved findings retain their tier but are marked with `status: resolved`.

### Promotion Entry Update

When promoting, update the MEMORY.md entry:
```markdown
### [2026-03-20] Pattern: {description}
- **layer**: inscribed  ← promoted from traced
- **source**: rune:self-audit {mode}-{timestamp}
- **finding_id**: SA-AGT-001
- **recurrence_count**: 3  ← incremented
- **last_seen**: 2026-03-20  ← updated
- **promoted_from**: traced
- **promoted_date**: 2026-03-20
```

## Edge Cases

- **First run (no previous entries)**: All findings are "new", no resolved/persistent. Skip delta report, show "Initial audit — no previous data for comparison."
- **Empty MEMORY.md**: Treat as first run.
- **Finding ID collision**: If a new finding gets the same ID as a resolved one, check Jaccard. If >= 0.8, it's a recurrence (re-open). If < 0.8, assign next available ID in that category.
- **Category reclassification**: If a finding moves from AGT to RC (e.g., agent issue was actually a rule issue), treat as: resolve old ID, create new ID. Note in both entries.
