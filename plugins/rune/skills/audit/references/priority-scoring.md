# Priority Scoring — 6-Factor Composite Algorithm

> Assigns a priority score (0.0-10.0) to each file for incremental batch selection.

## Composite Formula

```
priority_score = (
    W_staleness  * staleness_score(file)   +
    W_recency    * recency_score(file)     +
    W_risk       * risk_score(file)        +
    W_complexity * complexity_score(file)  +
    W_novelty    * novelty_score(file)     +
    W_role       * role_score(file)
)
```

## Default Weights (configurable via talisman)

| Factor | Weight | Score Range | Description |
|--------|--------|-------------|-------------|
| Staleness | 0.30 | 0-10 | Days since last audit. Never-audited = 10. |
| Recency | 0.25 | 0-10 | Inverse days since last git modification. |
| Risk | 0.20 | 0-10 | From Lore Layer risk-map.json. |
| Complexity | 0.10 | 0-10 | Line count normalized. |
| Novelty | 0.10 | 0-10 | File creation recency. |
| Role | 0.05 | 0-10 | File role heuristic (entry point, core, etc.). |

**Weight normalization**: If talisman weights do not sum to 1.0 (tolerance 0.001), normalize by dividing each by the sum. Log a warning. Normalization happens as pre-processing in readTalisman() resolution.

## Score Functions

All score functions follow the contract: `(file, state) => number [0.0, 10.0]`

### computeStalenessScore(file)

```
if never_audited: return 10.0
days = days_since(file.last_audited)
if days <= 7: return 0.0          # Floor clamp: recently audited
return min(9.5, 10 * sigmoid((days - 45) / 15))
# Never-audited cap: sigmoid capped at 9.5 to distinguish from never-audited (hard 10.0)
```

**Sigmoid lookup table** (for shell script approximation):

| Days | Score |
|------|-------|
| 0 | 0.0 (floor clamp) |
| 7 | 0.0 (floor clamp) |
| 15 | 1.2 |
| 30 | 2.7 |
| 45 | 5.0 |
| 60 | 7.3 |
| 90 | 9.5 (ceiling) |

### computeRecencyScore(file)

```
days = days_since(file.git.modified_at)
days = max(0, days)   # Clamp for clock skew / future timestamps
return max(0, min(10, 10 * exp(-days / 20)))
# Exponential decay: 10 today, ~6 at 7d, ~2 at 30d, ~0 at 90d
```

### computeRiskScore(file)

```
tier_map = { CRITICAL: 10, HIGH: 7.5, MEDIUM: 5, LOW: 2.5, STALE: 0 }
return tier_map[file.lore_tier] ?? 5   # Default MEDIUM if no Lore data
```

### computeComplexityScore(file)

```
loc = file.line_count
return min(10, loc / 50)   # 500 LOC = 10, linear scaling
```

### computeNoveltyScore(file)

```
days = days_since(file.git.created_at)
if days <= 7: return 10
if days <= 30: return 5
if days <= 90: return 2
return 0
```

### computeRoleScore(file)

```
# Heuristic based on path patterns
if matches("**/index.*", "**/main.*", "**/app.*"): return 10     # entry points
if matches("**/core/**", "**/domain/**"): return 9                # core logic
if matches("**/service*", "**/controller*"): return 8             # services
if matches("**/handler*", "**/route*"): return 7                  # handlers
if matches("**/model*", "**/schema*"): return 6                   # models
if matches("**/util*", "**/helper*", "**/lib/**"): return 4       # utilities
if matches("**/test*", "**/__test__/**", "**/*.test.*"): return 2 # tests
if matches("**/*.config.*", "**/.*rc"): return 1                  # config
return 5   # default
```

## Batch Selection

After scoring, select the top-N files for the current audit session:

```
selectBatch(scored_files, config):
  1. Filter: exclude files with status "excluded" or "deleted"
  2. Exclude error_permanent files (consecutive_error_count >= 3)
  3. Apply error penalty: files with error_count 1-2 get score -= count * 3.0
  4. Sort descending by priority_score
  5. Apply tie-breaker: coverage_gap_streak desc, then file path asc (locale-independent)

  batch_size = config.batch_size || 30
  min_batch = config.min_batch_size || 10

  # Dynamic adjustment: if avg LOC of top-N > 500, reduce N by 30%
  avg_loc = mean(top_N.map(f => f.line_count))
  if avg_loc > 500:
    batch_size = max(min_batch, floor(batch_size * 0.7))

  # Composition rules (in priority order):
  # 1. always_audit patterns (uncapped, hard requirement)
  always = matchGlobs(scored_files, config.always_audit)
  if always.length >= batch_size * 0.8:
    log_warning("always_audit fills >= 80% of batch — skipping composition rules")
    remaining = fillByScore(scored_files - always, batch_size - always.length)
    return always + remaining

  # 2. Fill 20% never-audited (minimum 5 files absolute floor)
  never_audited_slots = max(5, floor((batch_size - always.length) * 0.2))
  never_audited = filter(scored_files, status == "never_audited").slice(0, never_audited_slots)

  # 3. Fill 10% gap carry-forward
  gap_slots = floor((batch_size - always.length - never_audited.length) * 0.1)
  gaps = filter(scored_files, has_coverage_gap).slice(0, gap_slots)

  # 4. Fill rest by score
  remaining_slots = batch_size - always.length - never_audited.length - gaps.length
  rest = fillByScore(scored_files - always - never_audited - gaps, remaining_slots)

  # 5. Token budget guard
  batch = always + never_audited + gaps + rest
  estimated_tokens = sum(batch.map(f => f.line_count * 3))  # ~3 tokens/line estimate
  if estimated_tokens > 30000:
    batch = truncateToTokenBudget(batch, 30000)
    batch_size = max(min_batch, batch.length)

  return batch
```

## Talisman Configuration

```yaml
audit:
  incremental:
    batch_size: 30           # Files per batch (10-100, default: 30)
    min_batch_size: 10       # Minimum batch size
    weights:
      staleness: 0.30
      recency: 0.25
      risk: 0.20
      complexity: 0.10
      novelty: 0.10
      role: 0.05
    always_audit:
      - "CLAUDE.md"
      - ".rune/**/*.md"
      - ".claude/**/*.md"
      - "**/auth/**"
    extra_skip_patterns:
      - "**/generated/**"
      - "**/*.snapshot.*"
```

## Scoring Example

For a never-audited, recently-modified core service:

```
staleness_score = 10.0 (never audited)
recency_score   =  8.5 (modified 3 days ago)
risk_score      =  7.5 (HIGH tier in Lore)
complexity_score=  6.0 (300 LOC)
novelty_score   =  0.0 (created 6 months ago)
role_score      =  8.0 (service file)

priority = 0.30 * 10.0 + 0.25 * 8.5 + 0.20 * 7.5 + 0.10 * 6.0 + 0.10 * 0.0 + 0.05 * 8.0
         = 3.0 + 2.125 + 1.5 + 0.6 + 0.0 + 0.4
         = 7.625 / 10.0
```

## Edge Cases

- **Clock skew**: `max(0, days)` clamping in recency function for future git timestamps
- **Missing git data**: Fall back to `risk = 5.0`, `recency = 5.0`, `novelty = 0`
- **Empty Lore Layer**: All files get `risk = 5.0` (MEDIUM default)
- **Single file in batch**: Still valid — no minimum except configured `min_batch_size`
- **All files never-audited**: First run — all files score 10.0 staleness, selection by secondary factors
