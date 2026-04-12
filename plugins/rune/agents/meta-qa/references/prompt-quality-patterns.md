# Prompt Quality Anti-Pattern Taxonomy

> **Attribution**: Patterns adapted from [Prompt Master](https://github.com/nidhinjs/prompt-master) v1.5.0 by Nidhin JS, licensed under MIT.
> Rune adopts 8 of 35 patterns as lint rules AGT-017 through AGT-024. The remaining 27 patterns are tool-specific (Midjourney, DALL-E, Cursor, GPT, Stable Diffusion) or duplicate existing Rune checks.

## Adopted Patterns — Rune Lint Rule Mapping

| Rule | Source Pattern # | Rune Description | Severity | Detection | Exemptions |
|------|-----------------|------------------|----------|-----------|------------|
| AGT-017 | PM-003 (Context Setup) | **Starting State Defined** — Agent prompt defines input context or initial state via headings like `## Input`, `## Context`, `## Starting State`, `## Scan Protocol` | P3 (Info) | Regex: `(?i)^#{1,3}\s*(input|context|starting.state|scan.protocol|prerequisite|setup)` in body | Agents in `agents/shared/` (template files). Review agents (implicit context = diff/files). |
| AGT-018 | PM-007 (Output Specification) | **Completion Criteria Defined** — Agent prompt specifies what "done" looks like via headings like `## Output`, `## Seal Format`, `## Completion`, `## Exit Conditions` | P2 (work/investigation) / P3 (others) | Regex: `(?i)^#{1,3}\s*(output|seal.format|completion|exit.condition|deliverable|done.criteria)` in body | Agents in `agents/shared/` (template files). |
| AGT-019 | PM-001 (Task Clarity) | **Precise Task Verbs** — Agent `description:` field uses precise action verbs, not vague ones like "handle", "manage", "process", "deal with", "work on" | P3 (Info) | Regex: `(?i)\b(handle|manage|process|deal.with|work.on|take.care)\b` in `description:` frontmatter field | None — all agents should have precise descriptions. |
| AGT-020 | PM-012 (Success Metrics) | **Success Criteria Present** — Agent prompt includes measurable success criteria via headings like `## Scoring`, `## Quality Gates`, `## Success Criteria`, `## Acceptance` | P2 (work/investigation) / P3 (review) | Regex: `(?i)^#{1,3}\s*(scoring|quality.gate|success.criteria|acceptance|metric|dimension.score)` in body | Agents in `agents/shared/` (template files). |
| AGT-021 | PM-009 (Scope Boundaries) | **Scope Boundary for Write Agents** — Agents with Write or Edit in tools list define scope boundaries via patterns like "MUST NOT", "do not modify", "only touch", "scope:" | P2 (Warning) | Check: `tools:` contains `Write` or `Edit` AND body lacks `(?i)(MUST NOT|do not modify|only touch|scope:|boundary|restrict|limit.to)` | Agents without Write/Edit in tools. Agents in `agents/shared/`. |
| AGT-022 | PM-015 (Cognitive Load) | **No Responsibility Overload** — Agent prompt does not have excessive subsections (>8 H2/H3 headings in the instruction body suggests responsibility overload) | P3 (Info) | Count: `^#{2,3}\s+` headings in body. Flag if count > 8 | Agents in `agents/shared/` (templates have many sections by design). Aggregation agents (runebinder, verdict-binder) that legitimately need many sections. |
| AGT-023 | PM-011 (Grounding) | **Grounding Anchor for Review Agents** — Review and investigation agents include a grounding reference (TRUTHBINDING, checklist, rubric, or reference file link) beyond just the ANCHOR section | P2 (Warning) | Check: agent in `agents/review/` or `agents/investigation/` AND body lacks `(?i)(checklist|rubric|reference|heuristic|rule.set|criteria.matrix|\[.*\.md\])` (excluding ANCHOR/RE-ANCHOR sections) | Non-review/non-investigation agents. Agents in `agents/shared/`. |
| AGT-024 | PM-014 (Context Budget) | **Context Budget Defined** — Agent prompt includes budget or prioritization guidance via patterns like "budget", "prioritize", "batch", "limit", "cap", "max" | P3 (Info) | Regex: `(?i)(context.budget|prioriti[zs]e|batch.size|processing.limit|cap.at|max.findings|finding.caps|token.budget)` in body | Agents in `agents/shared/` (template files). Simple utility agents with single-pass execution. |

## Pass/Fail Examples

| Rule | Pass Example | Fail Pattern |
|------|-------------|--------------|
| AGT-017 | `breach-hunter.md` — has `## Scan Protocol` heading with structured input context | Agent body with no `## Input`, `## Context`, or `## Scan Protocol` heading |
| AGT-018 | `rune-smith.md` — has `## Output` and `## Seal Format` sections defining completion | Work agent body with no `## Output`, `## Seal Format`, or `## Exit Conditions` heading |
| AGT-019 | `breach-hunter.md` — description uses "Hunts for security breaches" (precise verb) | Description using "Handles security stuff" or "Manages code review" (vague verbs) |
| AGT-020 | `micro-evaluator.md` — has `## Scoring` section with dimension scores | Work agent body with no `## Scoring`, `## Quality Gates`, or `## Success Criteria` heading |
| AGT-021 | `mend-fixer.md` — has "MUST NOT modify files outside assigned group" scope boundary | Agent with Write/Edit tools but no "MUST NOT", "only touch", or "scope:" instruction |
| AGT-022 | `ward-sentinel.md` — 6 subsections (within limit) | Agent with >8 H2/H3 headings suggesting too many responsibilities |
| AGT-023 | `doubt-seer.md` — references `[rubric]` and criteria matrix for grounding | Review agent with only TRUTHBINDING ANCHOR but no checklist, rubric, or reference link |
| AGT-024 | `prompt-linter.md` — has "process in batches of 15-20" budget guidance | Agent with no "max", "batch", "prioritize", or "budget" instructions |

## Detection Notes

### Severity Assignment Logic

- **P2 (Warning)**: Rules where violation directly impacts agent effectiveness in production workflows
  - AGT-018: Work/investigation agents without completion criteria → orchestrator cannot verify done state
  - AGT-020: Work/investigation agents without success criteria → no quality measurement possible
  - AGT-021: Write agents without scope → risk of unintended file modifications
  - AGT-023: Review agents without grounding → findings lack evidence basis
- **P3 (Info)**: Rules where violation is a quality signal but does not block functionality
  - AGT-017: Missing input context → agent may still function via implicit context
  - AGT-019: Vague description verbs → discoverability issue, not functional
  - AGT-022: Many subsections → possible overload but may be intentional
  - AGT-024: Missing budget guidance → agent may still complete within limits

### Exemption: `agents/shared/` Path

Files in `agents/shared/` are template/protocol files (e.g., `truthbinding-protocol.md`, `communication-protocol.md`). They define shared patterns, not executable agents. Exempt from all quality rules AGT-017 through AGT-024.

### Category-Conditional Severity

AGT-018 and AGT-020 use **category-conditional severity**:
- Infer category from directory path (same as AGT-002)
- `agents/work/` or `agents/investigation/` → P2 (these agents need clear completion/success criteria)
- All other categories → P3 (completion criteria are nice-to-have)

## Patterns NOT Adopted (27 of 35)

### Tool-Specific Patterns (20)

These Prompt Master patterns target specific AI tools and are not applicable to Claude Code agent definitions:

| Pattern # | Name | Target Tool | Reason Not Adopted |
|-----------|------|-------------|-------------------|
| PM-002 | Persona Assignment | ChatGPT | Claude agents use `## Expertise` sections instead |
| PM-004 | Few-Shot Examples | GPT | Claude agents use `<example>` blocks — already checked informally |
| PM-005 | Chain-of-Thought | GPT | Claude's extended thinking handles this natively |
| PM-006 | Temperature Guidance | GPT/API | Not applicable to agent definitions |
| PM-008 | Format Enforcement | GPT | Claude agents use structured output sections |
| PM-010 | Negative Constraints | Midjourney | Image generation specific |
| PM-013 | Iteration Hooks | ChatGPT | Conversational refinement — agents are single-pass |
| PM-016 | Style Transfer | DALL-E | Image generation specific |
| PM-017 | Aspect Ratio | Midjourney | Image generation specific |
| PM-018 | Seed Control | Stable Diffusion | Image generation specific |
| PM-019 | LoRA References | Stable Diffusion | Model fine-tuning specific |
| PM-020 | Prompt Weighting | Midjourney | Image generation specific |
| PM-021 | Cursor Rules | Cursor IDE | IDE-specific prompt engineering |
| PM-022 | .cursorrules Format | Cursor IDE | IDE-specific configuration |
| PM-023 | Cursor Context | Cursor IDE | IDE-specific context management |
| PM-024 | GPT System Prompts | OpenAI GPT | Platform-specific |
| PM-025 | GPT Function Calling | OpenAI GPT | Platform-specific |
| PM-026 | Claude Artifacts | Claude.ai | Web UI specific, not CLI agents |
| PM-027 | Gemini Grounding | Google Gemini | Platform-specific |
| PM-028 | Copilot Instructions | GitHub Copilot | IDE-specific |

### Duplicate/Covered Patterns (7)

These patterns overlap with existing Rune lint rules or conventions:

| Pattern # | Name | Covered By |
|-----------|------|-----------|
| PM-029 | Tool Declaration | AGT-004/AGT-005/AGT-006 (tool list validation) |
| PM-030 | Safety Guardrails | AGT-009/AGT-010 (TRUTHBINDING ANCHOR/RE-ANCHOR) |
| PM-031 | Error Handling | Covered by team workflow protocol sections |
| PM-032 | Memory Management | Covered by `memory:` frontmatter field |
| PM-033 | Multi-Turn State | Not applicable — agents are stateless within a turn |
| PM-034 | Retrieval Augmentation | Covered by `skills:` and `mcpServers:` frontmatter |
| PM-035 | Evaluation Criteria | AGT-012 (description quality) |
