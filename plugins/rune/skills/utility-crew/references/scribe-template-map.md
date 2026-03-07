# Scribe Template Map — Per-Workflow Template Sources

Reference for context-scribe: maps each workflow to its template source files,
variable catalogs, sanitization rules, and content loading order.

## Template Source Paths

| Workflow | Template Sources | Path | Lines |
|----------|-----------------|------|-------|
| appraise / audit | Ash prompt templates | `skills/roundtable-circle/references/ash-prompts/{role}.md` | 32 files |
| appraise / audit | Task creation templates | `skills/roundtable-circle/references/task-templates.md` | 162 |
| appraise / audit | Prompt weaving structure | `skills/rune-orchestration/references/prompt-weaving.md` | 7-section template |
| strive | Worker prompt templates | `skills/strive/references/worker-prompts.md` | 808 |
| devise | Research agent prompts | `skills/devise/references/research-phase.md` | 854 |
| mend | Fixer spawning prompts | `skills/mend/references/fixer-spawning.md` | 309 |
| inspect | Inspector prompt templates | `skills/inspect/references/inspector-prompts.md` | 258 |
| forge | Enrichment protocol | `skills/forge/references/forge-enrichment-protocol.md` | 383 |
| brainstorm | Advisor persona prompts | `skills/brainstorm/references/advisor-prompts.md` | 222 |

All paths are relative to the plugin root (`plugins/rune/`).

## Variable Catalogs

### appraise / audit

Variables substituted by the scribe when composing review context packs:

| Variable | Source | Description |
|----------|--------|-------------|
| `{output_path}` | Crew Request `output_dir` + agent name | Output file path for the Ash |
| `{fileList}` | Crew Request `changed_files_path` (Read) | Changed files to review |
| `{scope}` | inscription.json `file_groups` | Per-Ash file scope assignment |
| `{sessionNonce}` | Crew Request (from inscription) | Anti-injection nonce (UUID v4) |
| `{dirScope}` | Crew Request or inscription | Directory scope filter |
| `{customPromptBlock}` | Crew Request `extra_context` | Custom per-session Ash instructions |
| `{backend_files}` | inscription.json file categorization | Backend file subset |
| `{frontend_files}` | inscription.json file categorization | Frontend file subset |
| `{doc_files}` | inscription.json file categorization | Documentation file subset |
| `{id}` | Crew Request `identifier` | Session identifier |

### strive

Variables substituted when composing worker context packs:

| Variable | Source | Description |
|----------|--------|-------------|
| `${nonGoalsBlock}` | Plan YAML frontmatter `non-goals` | Non-goals section from plan |
| `${file_ownership}` | inscription.json `task_ownership` | Per-worker file assignments |
| `${risk_tier}` | Goldmask risk analysis | Risk tier for the assigned files |
| `${designContextBlock}` | Design system discovery output | Design system profile and tokens |
| `${mcpContextBlock}` | `resolveMCPIntegrations()` output | Active MCP tool integrations |

### devise

Variables substituted when composing research agent context packs:

| Variable | Source | Description |
|----------|--------|-------------|
| `{feature}` | Crew Request (plan feature description) | Feature being planned |
| `{timestamp}` | Session timestamp | Brainstorm/plan session identifier |
| `${safeFeature}` | Sanitized `{feature}` (HTML stripped) | Safe feature description for prompts |

### mend

Variables substituted when composing fixer context packs:

| Variable | Source | Description |
|----------|--------|-------------|
| `${fixer.file_group}` | inscription.json `file_groups` | Files assigned to this fixer |
| `${fixer.findings}` | TOME.md findings for the file group | Findings to fix (UNTRUSTED content) |
| `{tome_path}` | Crew Request | Path to TOME.md |
| `{session_nonce}` | inscription.json | Anti-injection nonce |

### inspect

Variables substituted when composing inspector context packs:

| Variable | Source | Description |
|----------|--------|-------------|
| `{plan_path}` | Crew Request `plan_path` | Path to plan being inspected |
| `{requirements}` | Plan requirements extraction | Parsed requirement identifiers |
| `{code_blocks}` | Plan code block extraction | Code samples from plan |
| `{scope_files}` | Crew Request `changed_files_path` | Files in inspection scope |

### forge

Variables substituted when composing enrichment agent context packs:

| Variable | Source | Description |
|----------|--------|-------------|
| `${section_title}` | Plan section heading | Section being enriched |
| `${section_content}` | Plan section body (sanitized) | Content to enrich |
| `${agent.perspective}` | Forge agent assignment | Enrichment perspective |

### brainstorm

Variables substituted when composing advisor context packs:

| Variable | Source | Description |
|----------|--------|-------------|
| `{feature_description}` | Crew Request (sanitized, max 2000 chars) | Feature being brainstormed |
| `{timestamp}` | Session timestamp | Brainstorm session identifier |

## Sanitization Rules

Apply these rules per variable type before injection into context packs:

| Variable Type | Rule | Rationale |
|---------------|------|-----------|
| `{output_path}` | Validate with `SAFE_PATH_PATTERN`: `/^[a-zA-Z0-9._\-\/]+$/`. Reject if contains `..` | Prevents path traversal |
| `{fileList}` | Strip HTML comments (`<!-- ... -->`), zero-width chars (U+200B ZWSP, U+200C ZWNJ, U+200D ZWJ, U+FEFF BOM) | Prevents hidden injection content |
| `{customPromptBlock}` | Already sanitized by `resolveCustomPromptBlock()` in parent workflow. Do NOT re-sanitize | Double-sanitization breaks legitimate content |
| `{sessionNonce}` | Pass through verbatim. Opaque UUID v4 value | Nonce integrity required for downstream validation |
| `${fixer.findings}` | Contains untrusted TOME content. Inject ONLY between ANCHOR/RE-ANCHOR boundaries | Limits injection blast radius |
| `{feature_description}` | Strip HTML tags, cap at 2000 chars | Prevents XSS-style injection in prompts |
| `${section_content}` | Sanitized via `sanitizeForCodex()` (existing utility) | Standard forge sanitization |

### What NOT to Strip

- **Code fences** (triple backticks): Legitimate in templates. Ash-prompt files contain markdown code blocks for output format examples. Stripping them breaks template rendering.
- **Markdown headings** (`#`): Required for 9-section structure.
- **YAML frontmatter**: Required for context pack metadata.

## Content Loading Order

Per prompt-weaving Principle #2 (Read Ordering), the scribe composes packs with:

1. **Source files FIRST** — the code/data the agent will work on (file lists, scope)
2. **Task instructions SECOND** — what the agent needs to do
3. **Reference docs LAST** — review criteria, checklists, output format

This keeps review criteria and quality gates fresh near the RE-ANCHOR at the bottom
of each pack, mitigating the Lost-in-Middle attention degradation effect.

### Per-Workflow Loading Sequence

**appraise / audit:**
```
1. Read inscription.json → extract file_groups for this agent
2. Read ash-prompts/{role}.md → extract perspectives
3. Read task-templates.md → extract task structure
4. Read prompt-weaving.md → extract ANCHOR, OUTPUT FORMAT, QUALITY GATES
5. Compose 9-section pack (ANCHOR at top, RE-ANCHOR at bottom)
```

**strive:**
```
1. Read inscription.json → extract task_ownership for this worker
2. Read worker-prompts.md → extract rune-smith or trial-forger template
3. Read plan file → extract non-goals, task descriptions
4. Read design context (if applicable) → design system profile
5. Compose 9-section pack
```

**devise:**
```
1. Read research-phase.md → extract agent-specific prompt template
2. Read plan feature description
3. Compose 9-section pack (research agents have simpler packs)
```

**mend:**
```
1. Read inscription.json → extract file_groups for this fixer
2. Read TOME.md → extract findings for assigned files (UNTRUSTED)
3. Read fixer-spawning.md → extract fixer protocol template
4. Compose 9-section pack (findings injected between ANCHOR/RE-ANCHOR)
```

**inspect:**
```
1. Read plan file → extract requirements and code blocks
2. Read inspector-prompts.md → extract inspector-specific template
3. Read ash-prompts/{inspector}-inspect.md → extract perspectives
4. Compose 9-section pack
```

**forge:**
```
1. Read plan section content (sanitized)
2. Read forge-enrichment-protocol.md → extract enrichment template
3. Compose 9-section pack (one per section-agent pair)
```

**brainstorm:**
```
1. Read advisor-prompts.md → extract persona template (user-advocate, tech-realist, devils-advocate)
2. Read feature description from Crew Request
3. Compose 9-section pack
```

## 9-Section to 7-Section Mapping

The existing prompt-weaving.md defines a 7-section template. The context pack extends
this to 9 sections by adding DO and DO NOT between PERSPECTIVES and OUTPUT FORMAT.

| 7-Section (prompt-weaving) | 9-Section (context pack) |
|---------------------------|-------------------------|
| 1. ANCHOR | 1. ANCHOR |
| 2. YOUR TASK | 2. YOUR TASK |
| 3. PERSPECTIVES | 3. PERSPECTIVES |
| — | 4. SCOPE (new) |
| — | 5. DO (new) |
| — | 6. DO NOT (new) |
| 4. OUTPUT FORMAT | 7. OUTPUT FORMAT |
| 5. QUALITY GATES | 8. QUALITY GATES |
| 6-7. COMPLETION + RE-ANCHOR | 9. RE-ANCHOR — SEAL |

The scribe maps sections 1-3 from prompt-weaving to sections 1-3, inserts new
sections 4-6 from workflow-specific rules, then maps sections 4-5 from
prompt-weaving to sections 7-8, and section 6-7 to section 9.
