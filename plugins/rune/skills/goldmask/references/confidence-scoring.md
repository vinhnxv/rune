# Confidence Scoring — Noisy-OR + Caution

## Noisy-OR Formula

Combines independent confidence signals into a single score bounded [0, 1]:

```
combined = 1 - PRODUCT(1 - c_i)
```

Example: two signals at 0.70 each:
```
combined = 1 - (1 - 0.70) * (1 - 0.70) = 1 - 0.09 = 0.91
```

## Three Confidence Methods

| Method | Description | Base Confidence |
|--------|-------------|-----------------|
| **A (Import/Direct)** | File directly imports or calls the changed symbol | 0.80 |
| **B (Type System)** | File uses a type/interface defined in the changed file | 0.60 |
| **C (Empirical/Co-change)** | Files historically change together (from Lore Layer) | 0.40 (0.60 with Lore boost) |

### Lore Boost for Method C

When `risk-map.json` has a co-change edge between files A and B with `avg_coupling_pct >= 50`, Method C base confidence rises from 0.40 to 0.60.

### Combination Example

File B has:
- Method A signal (imports from changed file): c_A = 0.80
- Method C signal (co-changes in history, Lore-boosted): c_C = 0.60

```
combined = 1 - (1-0.80) * (1-0.60) = 1 - 0.08 = 0.92
```

## Classification Thresholds

| Classification | Confidence | Action |
|---------------|------------|--------|
| **MUST-CHANGE** | >= 0.80 | File almost certainly needs modification |
| **SHOULD-CHECK** | >= 0.50 | File likely needs review, may need changes |
| **MAY-AFFECT** | >= 0.20 | File could be indirectly affected |
| (below threshold) | < 0.20 | Not reported |

## Caution Score (from Wisdom Layer)

Separate from confidence. Measures how carefully a code area should be modified:

```
caution = base + age_modifier + contributor_modifier + comment_modifier
caution = min(1.0, caution)  # Cap at 1.0
```

### Base Values by Intent Category

| Intent | Base | Rationale |
|--------|------|-----------|
| CONSTRAINT | 0.90 | External compliance requirement |
| WORKAROUND | 0.80 | May re-expose original bug |
| DEFENSIVE | 0.75 | Removing guard creates runtime errors |
| COMPATIBILITY | 0.75 | Premature removal breaks clients |
| OPTIMIZATION | 0.60 | Naive change may regress performance |
| CONVENTION | 0.55 | Requires team buy-in to change |
| UNKNOWN | 0.40 | No signals — standard review applies |
| EXPLORATORY | 0.20 | Intended to be changed |

### Modifiers

| Modifier | Condition | Value |
|----------|-----------|-------|
| Age | > 365 days | +0.10 |
| Age | > 1095 days (3 years) | +0.15 |
| Contributor | Single author | +0.10 |
| Contributor | Single author, no longer active | +0.20 |
| Comments | Warning comments present | +0.10 |
| Comments | TODO with reason | +0.05 |

### Caution Levels

| Level | Score | Meaning |
|-------|-------|---------|
| CRITICAL | >= 0.85 | Modify with extreme care |
| HIGH | >= 0.70 | Review git history before touching |
| MEDIUM | >= 0.40 | Standard careful review |
| LOW | < 0.40 | Safe to change freely |

