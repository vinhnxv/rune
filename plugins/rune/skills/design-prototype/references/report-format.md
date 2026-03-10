# Report Format Templates

Each pipeline phase produces a structured Markdown report in `{outputDir}/reports/`.

## 01 — Figma Inventory

```markdown
# 01 — Figma Inventory

**URL**: {figmaUrl}
**Extracted**: {timestamp}
**Components found**: {total}
**Components selected**: {selected} (cap: {maxReferenceComponents})

| # | Component | Node ID | Type | Variants | Status |
|---|-----------|---------|------|----------|--------|
| 1 | UserProfile | 123:456 | Frame | 3 | extracted |
| 2 | NavigationBar | 123:789 | Component | 5 | extracted |
| 3 | SettingsPanel | 124:100 | Frame | 2 | skipped (timeout) |
```

## 02 — Reference Extraction

```markdown
# 02 — Reference Extraction

**Successful**: {count}/{total}
**Tokens extracted**: {tokenCount}
**Avg confidence**: {avgConfidence}%

| Component | Lines | Tokens Extracted | Confidence | Issues |
|-----------|-------|-----------------|------------|--------|
| UserProfile | 85 | 12 (colors: 5, spacing: 4, typography: 3) | 92% | — |
| NavigationBar | 120 | 18 (colors: 7, spacing: 6, typography: 5) | 88% | Missing icon refs |
| SettingsPanel | — | — | — | Timeout (15s) |

## Token Snapshot
| Token | Type | Value | Source Component |
|-------|------|-------|-----------------|
| --color-primary | color | #2563EB | UserProfile |
| --spacing-md | spacing | 16px | NavigationBar |
```

## 03 — Library Matching

```markdown
# 03 — Library Matching

**Builder MCP**: {builderName} ({serverName})
**Matched**: {matchedCount}/{total}
**Threshold**: {libraryMatchThreshold}
**Circuit breaker triggered**: {yes/no}

| Component | Search Query | Best Match | Confidence | Packages |
|-----------|-------------|-----------|------------|----------|
| UserProfile | "user profile card avatar" | @untitledui/card | 0.85 | @untitledui/card, @untitledui/avatar |
| NavigationBar | "navigation bar tabs" | @untitledui/navigation | 0.72 | @untitledui/navigation |
| SettingsPanel | "settings form toggle" | — | 0.35 (below threshold) | — |

## Library Manifest
| Package | Version | Components Used |
|---------|---------|----------------|
| @untitledui/card | ^1.2.0 | Card, CardHeader, CardContent |
| @untitledui/avatar | ^1.0.0 | Avatar |
```

## 03b — UX Flow Mapping

```markdown
# 03b — UX Flow Mapping

**Components analyzed**: {count}
**Flows detected**: {flowCount}
**Pages composed**: {pageCount}

## Screen Flow

\```mermaid
graph LR
  A[Dashboard] --> B[UserProfile]
  A --> C[SettingsPanel]
  B --> C
  C --> A
\```

## Action Map

| Source | Action | Target | Type |
|--------|--------|--------|------|
| Dashboard | Click avatar | UserProfile | navigation |
| UserProfile | Click settings | SettingsPanel | navigation |
| SettingsPanel | Save | Dashboard | navigation + toast |

## Notification Patterns

| Pattern | Type | Components | Trigger |
|---------|------|-----------|---------|
| Save confirmation | toast | SettingsPanel | Form submit success |
| Validation error | inline | SettingsPanel | Form submit failure |
| Profile updated | toast | UserProfile | Edit save |

## UX Patterns Summary
- Navigation: tab-based with breadcrumb fallback
- Loading: skeleton placeholders (not spinners)
- Error: inline messages with retry actions
- Empty states: illustration + CTA
```

## 04 — Prototype Synthesis

```markdown
# 04 — Prototype Synthesis

**Prototypes generated**: {count}
**Stories generated**: {storyCount}
**Avg confidence**: {avgConfidence}%

| Component | Source Refs | Output Lines | Confidence | Trust Level |
|-----------|-----------|-------------|------------|-------------|
| UserProfile | figma-ref + library-match | 85 | 92% | high (both refs) |
| NavigationBar | figma-ref + library-match | 120 | 78% | medium (partial match) |
| SettingsPanel | figma-ref only | 95 | 55% | low (no library match) |

## Dependency Summary
| Package | Install Command |
|---------|----------------|
| @untitledui/card | npm install @untitledui/card |
| @untitledui/avatar | npm install @untitledui/avatar |
```

## 04b — Self-Review

```markdown
# 04b — Self-Review

## Completeness
**Inventory → Prototypes**: {prototypeCount}/{inventoryCount} ({percentage}%)

| Component | Extracted | Matched | Synthesized | Gap |
|-----------|-----------|---------|-------------|-----|
| UserProfile | yes | yes | yes | — |
| NavigationBar | yes | yes | yes | — |
| SettingsPanel | yes | no | partial | No library match |

## Element Coverage
**Figma elements → Prototype elements**: {covered}/{total} ({percentage}%)

| Component | Figma Elements | Prototype Elements | Missing |
|-----------|---------------|-------------------|---------|
| UserProfile | avatar, name, email, edit-btn | avatar, name, email, edit-btn | — |
| NavigationBar | logo, tabs(5), search, avatar | logo, tabs(5), search, avatar | — |

## State Coverage
**Figma variants → Story variants**: {covered}/{total} ({percentage}%)

| Component | Figma Variants | Stories | Missing States |
|-----------|---------------|---------|----------------|
| UserProfile | default, hover, loading | Default, Loading, Error, Empty, Disabled | — |
| NavigationBar | default, active-tab, collapsed | Default, ActiveTab | Collapsed |

## API Coverage
**Library props → Used props**: {used}/{available} ({percentage}%)

| Component | Library Props | Used Props | Unused Props |
|-----------|-------------|-----------|-------------|
| Card | variant, size, className, asChild | variant, className | size, asChild |
| Avatar | src, alt, fallback, size | src, alt | fallback, size |
```

## 05 — Verification Summary

```markdown
# 05 — Verification Summary

## Structural Findings (Phase 4.0)
| Dimension | Score | Issues |
|-----------|-------|--------|
| Completeness | 90% | 1 component skipped (timeout) |
| Element coverage | 95% | Missing collapsed nav state |
| State coverage | 85% | 2 missing story variants |
| API coverage | 70% | 4 unused library props |

## Visual Findings (Phase 4.2)
| Component | Visual Match | Issues |
|-----------|------------|--------|
| UserProfile | 88% | Avatar border-radius differs |
| NavigationBar | 72% | Tab spacing inconsistent |

## Gap Synthesis
| # | Gap | Source | Severity | Suggested Fix |
|---|-----|--------|----------|--------------|
| 1 | Missing collapsed nav | structural | medium | Add Collapsed story + responsive logic |
| 2 | Avatar border mismatch | visual | low | Update rounded-full to rounded-xl |
| 3 | Tab spacing off | visual | low | Adjust gap-2 to gap-3 |

## Overall Score
| Dimension | Weight | Score |
|-----------|--------|-------|
| Completeness | 30% | 90% |
| Element coverage | 25% | 95% |
| State coverage | 25% | 85% |
| API coverage | 20% | 70% |
| **Weighted total** | | **86%** |
```
