# Lore Protocol — Risk Scoring for Lore Analyst

Single-pass git history extraction to produce `risk-map.json` with per-file risk scores.

## Step 1: Guard Checks

Run before any analysis. If a guard trips, degrade gracefully.

| Guard | Check | Failure Mode |
|-------|-------|-------------|
| G1: Non-git | `git rev-parse --is-inside-work-tree 2>/dev/null` | Skip entirely — return empty risk-map |
| G2: Shallow clone | `git rev-parse --is-shallow-repository` | Degraded mode — echoes only, no history metrics |
| G3: Window check | Date calculation (see macOS fallback below) | Use fallback date command |
| G4: Large repo | Count files in window > 5000 | Sparse mode — analyze top 500 by revision count |
| G5: Min commits | `git rev-list --count --after="{date}" HEAD` | < 5 commits — skip analysis |

### macOS Date Compatibility

macOS `date` does not support `-d`. Use dual fallback:

```bash
# Default: 180 days (configurable via talisman goldmask.layers.lore.lookback_days)
LOOKBACK_DAYS="${LOOKBACK_DAYS:-180}"
[[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || { echo "Invalid lookback_days: $LOOKBACK_DAYS"; exit 1; }
WINDOW_START=$(date -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%d 2>/dev/null || date -v-${LOOKBACK_DAYS}d +%Y-%m-%d)
```

## Step 2: Single-Pass Extraction

One git command extracts all needed data:

```bash
# Use NUL-byte separators for reliable parsing — avoids guessable sentinel strings
# File-scoped: only analyze files in the changed set (not --all branches)
git log --numstat --no-merges --no-renames \
  --diff-filter=ACMR \
  --pretty=format:'%x00%H%x00%aN%x00%aE%x00%ct%x00%s' \
  --after="$WINDOW_START" \
  -- "${file_list[@]}"
```

**Sanitization**: Author names (`%aN`) and emails (`%aE`) can contain arbitrary strings.
When parsing, strip non-printable characters and escape JSON metacharacters before writing to `risk-map.json`.

**Format fields** (NUL-separated to handle special chars in author names):
- `%H` — full commit hash
- `%aN` — author name
- `%aE` — author email
- `%ct` — committer timestamp (unix)
- `%s` — subject line

**Numstat output** (per file, after each NUL-delimited commit record):
```
{lines_added}\t{lines_deleted}\t{file_path}
```

**Edge cases**:
- Binary files: numstat shows `-\t-\t{file}` — skip these lines
- Deleted files: excluded by `--diff-filter=ACMR` (no D)
- Renames: `--no-renames` avoids O(n^2) detection cost

## Step 3: Compute 5 Metrics

Parse the extraction output and compute per-file:

### 3.1 Frequency (weight: 0.35)

```
frequency[file] = count of commits touching this file in window
```

### 3.2 Churn (weight: 0.25)

```
churn[file] = sum(lines_added + lines_deleted) across all commits
```

### 3.3 Recency (weight: 0.15)

```
last_modified[file] = max(commit_timestamp) for commits touching this file
recency[file] = 1 - (days_since_last_modified / window_days)
```

`last_modified` must be derived during this step from the parsed commit data — do not assume it exists.

### 3.4 Ownership (weight: 0.15)

```
top_contributor_pct[file] = commits_by_top_author / total_commits
ownership_risk[file] = top_contributor_pct  # Higher concentration = higher risk
```

Single-commit files: `ownership_risk` defaults to 0.5 (insufficient data).

### 3.5 Echo Correlation (weight: 0.10)

```
If .rune/echoes/ exists:
  Scan for P1/P2 findings referencing this file
  echo_correlation[file] = normalized count of past findings
Else:
  echo_correlation[file] = 0.0
```

## Step 4: Percentile Normalization

Use **percentile rank** (not min-max) — robust to outliers:

```
percentile[file] = rank(file) / total_files
```

Example: 100 files, file ranked 95th by frequency -> percentile = 0.95

This prevents one outlier file (e.g., 500 commits) from compressing all others to near-zero.

## Step 5: Risk Score

```
risk_score = 0.35 * frequency_pctl + 0.25 * churn_pctl + 0.15 * recency_pctl
           + 0.15 * ownership_pctl + 0.10 * echo_pctl
```

## Step 6: Tier Classification

| Tier | Condition | Meaning |
|------|-----------|---------|
| **CRITICAL** | risk_score >= 90th percentile | Highest churn + risk + past bugs |
| **HIGH** | risk_score >= 70th percentile | Above-average activity/risk |
| **MEDIUM** | risk_score >= 30th percentile | Average activity |
| **LOW** | risk_score < 30th percentile | Stable, low activity |
| **STALE** | No commits in window | Use `git ls-files` left-join to detect |

For STALE detection: compare `git ls-files` against files seen in the git log window. Files present in the repo but absent from the window are STALE.

## Step 7: Co-Change Graph

Files appearing in the same commit are co-change candidates.

```
For each commit with <= max_changeset_size (default: 30) files:
  For each pair (file_A, file_B) in commit:
    shared_revisions[A][B] += 1

coupling_pct[A][B] = shared_revisions[A][B] / max(total_revisions[A], total_revisions[B]) * 100
```

**Filters**:
- Skip commits touching > `max_changeset_size` files (likely bulk refactoring)
- Only report edges with >= `min_shared_revisions` (default: 3) AND >= `min_coupling_pct` (default: 25%)

## Step 8: Output

Write `{output_dir}/risk-map.json` following the schema in `output-format.md`.

Sort files by `risk_score` descending. Include `co_changes` array per file.
