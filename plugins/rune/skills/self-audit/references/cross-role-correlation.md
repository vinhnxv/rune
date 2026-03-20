# Cross-Role Echo Correlation

Correlates patterns across echo roles to detect pipeline-spanning issues
that are invisible when examining each role in isolation.

## Overview

Individual dimension analysis catches issues within a single role (e.g.,
"reviewer found 4 error handling issues"). Cross-role correlation catches
systemic patterns across the pipeline (e.g., "planner didn't specify error
handling -> workers missed it -> reviewer caught it 4 times").

## Echo Roles

| Role | Directory | Source workflows |
|------|-----------|-----------------|
| `planner` | `.rune/echoes/planner/` | `/rune:devise`, arc Phase 1 |
| `orchestrator` | `.rune/echoes/orchestrator/` | `/rune:arc`, `/rune:strive` |
| `workers` | `.rune/echoes/workers/` | `/rune:strive` workers, arc Phase 3 |
| `reviewer` | `.rune/echoes/reviewer/` | `/rune:appraise`, arc Phase 6 |
| `meta-qa` | `.rune/echoes/meta-qa/` | `/rune:self-audit` |
| `team` | `.rune/echoes/team/` | Cross-role correlation output |

## Correlation Algorithm

### Step 1: Collect Echo Entries

Read all echo entries across roles using the echo-search MCP server:

```javascript
// Use echo_search MCP for cross-role discovery
const roles = ['planner', 'orchestrator', 'reviewer', 'workers', 'meta-qa']
const allEntries = {}

for (const role of roles) {
  // echo_search supports role filtering
  const results = mcp__plugin_rune_echo_search__echo_search({
    query: '*',
    role: role,
    limit: 50
  })

  allEntries[role] = results.entries.map(e => ({
    id: e.id,
    title: e.title,
    content: e.content_preview,
    layer: e.layer,
    date: e.date,
    keywords: extractKeywords(e.title + ' ' + e.content_preview)
  }))
}
```

### Step 2: Topic Overlap via Jaccard Similarity

Reuse the echo-search server's `compute_entry_similarity()` for topic matching.
When MCP is unavailable, fall back to local Jaccard computation:

```javascript
function topicOverlap(entry1, entry2) {
  // Prefer echo-search MCP similarity (BM25 + semantic grouping)
  // Fallback: local Jaccard on extracted keywords
  const words1 = new Set(entry1.keywords)
  const words2 = new Set(entry2.keywords)

  const intersection = [...words1].filter(w => words2.has(w))
  const union = new Set([...words1, ...words2])

  return intersection.length / union.size
}

function extractKeywords(text) {
  // Remove stopwords and extract significant terms
  const stopwords = new Set([
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been',
    'being', 'have', 'has', 'had', 'do', 'does', 'did', 'will',
    'would', 'could', 'should', 'may', 'might', 'must', 'shall',
    'can', 'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by',
    'from', 'as', 'into', 'through', 'during', 'before', 'after',
    'and', 'but', 'or', 'not', 'no', 'this', 'that', 'these',
    'those', 'it', 'its', 'they', 'them', 'their', 'we', 'our'
  ])

  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, ' ')
    .split(/\s+/)
    .filter(w => w.length > 2 && !stopwords.has(w))
}
```

### Step 3: Pipeline Pattern Detection

Three correlation patterns are detected:

#### Pattern A: Planner Gap -> Worker Miss -> Reviewer Catch

The most common pipeline-spanning pattern. A specification omission flows
through the entire pipeline before being caught at review.

```javascript
function detectPipelineGaps(allEntries) {
  const correlations = []

  for (const reviewerEntry of allEntries.reviewer) {
    for (const plannerEntry of allEntries.planner) {
      const plannerOverlap = topicOverlap(reviewerEntry, plannerEntry)
      if (plannerOverlap > 0.6) {
        // Check if workers had related issues
        const workerMatch = allEntries.workers.find(w =>
          topicOverlap(w, reviewerEntry) > 0.4
        )

        if (workerMatch) {
          correlations.push({
            type: 'pipeline_gap',
            confidence: Math.min(plannerOverlap, topicOverlap(workerMatch, reviewerEntry)),
            planner: plannerEntry,
            worker: workerMatch,
            reviewer: reviewerEntry,
            description: `Planner didn't specify "${plannerEntry.title}", ` +
              `workers missed it, reviewer caught it as "${reviewerEntry.title}"`
          })
        }
      }
    }
  }

  return correlations
}
```

#### Pattern B: Recurring Reviewer Findings

Same issue found by reviewer across multiple arcs, suggesting a systemic
planner or worker gap rather than a one-time miss.

```javascript
function detectRecurringReviewFindings(allEntries) {
  // Group reviewer entries by topic similarity
  const groups = []
  const used = new Set()

  for (let i = 0; i < allEntries.reviewer.length; i++) {
    if (used.has(i)) continue
    const group = [allEntries.reviewer[i]]
    used.add(i)

    for (let j = i + 1; j < allEntries.reviewer.length; j++) {
      if (used.has(j)) continue
      if (topicOverlap(allEntries.reviewer[i], allEntries.reviewer[j]) > 0.7) {
        group.push(allEntries.reviewer[j])
        used.add(j)
      }
    }

    if (group.length >= 2) {
      groups.push({
        type: 'recurring_review',
        count: group.length,
        entries: group,
        topic: group[0].title,
        description: `"${group[0].title}" found ${group.length} times across reviews`
      })
    }
  }

  return groups
}
```

#### Pattern C: Fix Regression

An applied fix that causes new findings in a different dimension.

```javascript
function detectFixRegressions(allEntries) {
  const regressions = []

  for (const metaEntry of allEntries['meta-qa']) {
    // Look for entries with fix_applied: true and verdict: REGRESSION
    if (metaEntry.content.includes('verdict: REGRESSION') ||
        metaEntry.content.includes('**verdict**: REGRESSION')) {
      regressions.push({
        type: 'fix_regression',
        entry: metaEntry,
        description: `Fix caused regression: ${metaEntry.title}`
      })
    }
  }

  return regressions
}
```

### Step 4: Write to Team Echoes

Correlations are written to `.rune/echoes/team/MEMORY.md`:

```javascript
function writeTeamCorrelations(correlations) {
  // Create directory on demand
  Bash('mkdir -p .rune/echoes/team')

  const today = new Date().toISOString().split('T')[0]

  for (const corr of correlations) {
    const entry = formatCorrelationEntry(corr, today)
    // Append to team MEMORY.md
    appendToFile('.rune/echoes/team/MEMORY.md', entry)
  }

  // Signal echo-search for reindex
  Bash('mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.echo-dirty')
}

function formatCorrelationEntry(corr, date) {
  switch (corr.type) {
    case 'pipeline_gap':
      return `
### [${date}] Pipeline Gap: ${corr.planner.title}
- **layer**: inscribed
- **source**: rune:self-audit correlation
- **confidence**: ${corr.confidence.toFixed(2)}
- **correlation_type**: pipeline_gap
- **roles_involved**: planner, workers, reviewer
- Planner: ${corr.planner.title} (gap)
- Worker: ${corr.worker.title} (miss)
- Reviewer: ${corr.reviewer.title} (catch)
- Recommendation: Add this topic as a required plan section template
`

    case 'recurring_review':
      return `
### [${date}] Recurring Review: ${corr.topic}
- **layer**: inscribed
- **source**: rune:self-audit correlation
- **confidence**: 0.90
- **correlation_type**: recurring_review
- **occurrence_count**: ${corr.count}
- Found ${corr.count} times across separate reviews.
- Suggests systemic gap in planning or worker guidance.
`

    case 'fix_regression':
      return `
### [${date}] Fix Regression: ${corr.entry.title}
- **layer**: etched
- **source**: rune:self-audit correlation
- **confidence**: 1.0
- **correlation_type**: fix_regression
- An applied fix caused regression. Review and potentially revert.
`
  }
}
```

## Report Format

The correlation results appear in the audit report as:

```markdown
## Cross-Role Patterns

### Pipeline Gap: Error handling specification
- **Planner**: Did not specify error handling patterns for API module
- **Workers**: Implemented without try/catch (no guidance)
- **Reviewer**: Caught 4 P1 findings for unhandled errors
- **Recommendation**: Add "Error Handling" as a required plan section template

### Pipeline Gap: Test coverage requirements
- **Planner**: No test coverage targets specified
- **Workers**: Wrote implementation without tests
- **Reviewer**: Flagged 6 files with zero test coverage
- **Recommendation**: Add test coverage criteria to acceptance criteria template

### Recurring Review: Missing input validation
- **Occurrences**: 3 across separate reviews
- **Pattern**: Workers consistently skip input validation at API boundaries
- **Recommendation**: Add validation checklist to worker injection prompt

### Fix Regression: SA-WF-004 phase count update
- **Applied**: 2026-03-15
- **Regression**: New SA-PQ-008 finding (stale count in a different file)
- **Action**: Review related files for similar stale counts
```

## MCP Integration

The correlation engine leverages the echo-search MCP server:

| MCP Tool | Usage |
|----------|-------|
| `echo_search` | Cross-role entry discovery with `role` filter |
| `echo_details` | Full content retrieval for matched entries |
| `echo_upsert_group` | Semantic grouping of correlated entries |
| `echo_record_access` | Track access frequency for auto-promotion |

When the echo-search MCP server is unavailable, the correlation falls back to
direct `MEMORY.md` file parsing with local Jaccard similarity computation.

## Thresholds

| Parameter | Value | Purpose |
|-----------|-------|---------|
| Pipeline gap: planner-reviewer overlap | > 0.6 | Topic must be sufficiently similar |
| Pipeline gap: worker-reviewer overlap | > 0.4 | Lower threshold for worker matches |
| Recurring review: group similarity | > 0.7 | Entries must be about the same topic |
| Recurring review: min group size | >= 2 | At least 2 occurrences to flag |
| Max entries per role | 50 | Bound computation time |
