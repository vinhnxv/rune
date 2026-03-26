# Element Inventory Template

## Analysis Workflow

1. `figma_fetch_design()` (Rune) or `get_figma_data()` (Framelink) — structure overview (fast, cheap)
2. Screenshot + VSM creation (VISUAL-FIRST — before code analysis)
3. `figma_inspect_node()` (Rune) or `get_figma_data()` (Framelink) + `figma_to_react()` — code extraction (secondary)
4. Cross-Verification Gate — PASS/WARN/BLOCK
5. Document missing elements (Source: "Visual")
6. Search UI builder MCP for matches
7. Complete mapping with source tracking

## Inventory Sections

### 1. Page Structure

| Property | Value |
|----------|-------|
| Container | (width, max-width, padding) |
| Layout | (flex/grid direction, gap) |
| Sections | (count, names) |

### 2. Element Catalog (per section)

| Element | Type | Source | Library Match | Install Command |
|---------|------|--------|---------------|-----------------|

Source column values: Code / Visual / Both / Manual

### 3. Layout Summary

| Section | Direction | Justify | Align | Gap |
|---------|-----------|---------|-------|-----|

### 4. Token Maps

- Spacing: Figma px -> design system token
- Color: Figma variable -> semantic token
- Typography: size/weight/lh -> token

### 5. Component Mapping Summary

| Section | Library Component | Match Score | Install | Import Path |
|---------|-------------------|-------------|---------|-------------|

### 6. Visual-Only Sections (from Verification Gate)

| Section | Priority | Suggested Search Query | Notes |
|---------|----------|------------------------|-------|

These are regions identified from screenshot analysis (Source: "Visual") that were NOT
found in code extraction. They may need manual extraction or additional MCP searches.
