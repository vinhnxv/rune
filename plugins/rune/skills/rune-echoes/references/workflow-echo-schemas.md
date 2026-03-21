# Workflow Echo Content Schemas

Per-workflow echo schemas defining title format, content template, tag vocabulary, layer, and confidence for each workflow that auto-writes echoes. These schemas ensure consistency and dedup-friendliness (Jaccard 80% title similarity threshold).

**Inputs**: Workflow completion context (findings, decisions, patterns)
**Outputs**: Echo entries written to `.rune/echoes/{role}/MEMORY.md`
**Preconditions**: `.rune/echoes/` directory initialized, echo-writer.sh available

## Title Dedup Rule

Titles use the format `[YYYY-MM-DD] {Type}: {description}` where `{Type}` is one of: Architecture, Decision, Convention, Pattern, Review patterns, Pipeline, Fix patterns, Audit findings. The Jaccard similarity threshold (80%) prevents near-duplicate entries — titles differing only in date or minor wording are merged rather than appended.

## Devise Echoes

Written after `/rune:devise` Phase 5 (cleanup).

| Field | Value |
|-------|-------|
| **Role** | `planner` |
| **Title** | `Architecture: {feature}` or `Decision: {feature} approach` |
| **Content** | Tech stack + conventions discovered + approach rationale + key trade-offs |
| **Tags** | `architecture`, `devise`, `{feature-keyword}` |
| **Layer** | `inscribed` |
| **Confidence** | `HIGH` (0.85-0.95) |
| **Source** | `rune:devise {feature}` |

**Example title**: `[2026-03-21] Architecture: OAuth2 integration with Prisma sessions`

## Appraise Echoes

Written after `/rune:appraise` Phase 7 (cleanup).

| Field | Value |
|-------|-------|
| **Role** | `reviewer` |
| **Title** | `Review patterns: {scope}` |
| **Content** | Top 5 P1/P2 findings as bullet list with prefix codes (e.g., `SEC-001`, `QUAL-003`) |
| **Tags** | `review`, `patterns`, `{scope-keyword}` |
| **Layer** | `inscribed` |
| **Confidence** | `MEDIUM` (0.70-0.85) |
| **Source** | `rune:appraise {scope}` |

**Example title**: `[2026-03-21] Review patterns: auth middleware refactor`

## Arc Echoes

Written after `/rune:arc` post-arc cleanup phase.

| Field | Value |
|-------|-------|
| **Role** | `team` |
| **Title** | `Pipeline: {plan-name} outcomes` |
| **Content** | Phase completion summary + blocking issues encountered + resolution strategies |
| **Tags** | `arc`, `pipeline`, `{plan-keyword}` |
| **Layer** | `inscribed` |
| **Confidence** | `HIGH` (0.85-0.95) |
| **Source** | `rune:arc {plan-file}` |

**Example title**: `[2026-03-21] Pipeline: echo-write-automation outcomes`

## Strive Echoes

Written after `/rune:strive` Phase 5 (cleanup).

| Field | Value |
|-------|-------|
| **Role** | `workers` |
| **Title** | `Convention: {feature} implementation patterns` |
| **Content** | Implementation patterns discovered + file organization + testing approach used |
| **Tags** | `strive`, `implementation`, `{feature-keyword}` |
| **Layer** | `inscribed` |
| **Confidence** | `MEDIUM` (0.70-0.85) |
| **Source** | `rune:strive {plan-file}` |

**Example title**: `[2026-03-21] Convention: echo persistence hook patterns`

## Mend Echoes

Written after `/rune:mend` cleanup.

| Field | Value |
|-------|-------|
| **Role** | `reviewer` |
| **Title** | `Fix patterns: {scope} remediation` |
| **Content** | Common fix strategies applied + false positives identified + recurring issue categories |
| **Tags** | `mend`, `fixes`, `{scope-keyword}` |
| **Layer** | `inscribed` |
| **Confidence** | `MEDIUM` (0.70-0.85) |
| **Source** | `rune:mend {scope}` |

**Example title**: `[2026-03-21] Fix patterns: auth middleware remediation`

## Audit Echoes

Written after `/rune:audit` cleanup.

| Field | Value |
|-------|-------|
| **Role** | `auditor` |
| **Title** | `Audit findings: {scope} health` |
| **Content** | Codebase health summary + top systemic issues + architectural observations |
| **Tags** | `audit`, `health`, `{scope-keyword}` |
| **Layer** | `inscribed` |
| **Confidence** | `HIGH` (0.85-0.95) |
| **Source** | `rune:audit {scope}` |

**Example title**: `[2026-03-21] Audit findings: full codebase health`

## Tag Vocabulary

Controlled vocabulary for echo tags to enable consistent search:

| Category | Tags |
|----------|------|
| **Workflow** | `devise`, `appraise`, `arc`, `strive`, `mend`, `audit` |
| **Domain** | `architecture`, `patterns`, `conventions`, `security`, `performance`, `testing` |
| **Scope** | `{feature-keyword}` — extracted from plan/PR description |
| **Meta** | `pipeline`, `review`, `fixes`, `health`, `implementation` |

## Content Guidelines

1. **Brevity**: Max 5 bullet points per entry. Each bullet under 120 chars.
2. **Evidence**: Include at least one file path reference per entry.
3. **Actionability**: Each entry should inform future decisions, not just record history.
4. **No secrets**: Never include API keys, tokens, or credentials in echo content.
5. **Dedup-aware**: Check existing echoes before writing — update if Jaccard > 80%.
