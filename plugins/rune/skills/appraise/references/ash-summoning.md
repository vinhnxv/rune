# Ash Summoning — Phase 3 Reference

This reference covers Phase 3 of `/rune:appraise`: Ash selection, prompt generation, inscription contract, talisman custom Ashes, and CLI-backed Ashes.

## Phase 3: Summon Ash

Summon ALL selected Ash in a **single message** (parallel execution):

<!-- NOTE: Ashes are summoned as general-purpose (not namespaced agent types) because
     Ash prompts are composite — each Ash embeds multiple review perspectives from
     agents/review/*.md. The agent file allowed-tools are NOT enforced at runtime.
     Tool restriction is enforced via prompt instructions (defense-in-depth).

     SEC-001 MITIGATION (P1): Review and Audit Ashes inherit ALL general-purpose tools
     (including Write/Edit/Bash). Prompt instructions restrict them to Read/Glob/Grep only,
     but prompt-only restrictions are bypassable — a sufficiently adversarial input could
     convince an Ash to write files.

     REQUIRED: Deploy the following PreToolUse hook in .claude/settings.json (or the plugin
     hooks/hooks.json) to enforce tool restrictions at the PLATFORM level for review AND
     audit teammates. Without this hook, the read-only constraint is advisory only.

     Hook config block (copy into .claude/settings.json "hooks" section):

       {
         "PreToolUse": [
           {
             "matcher": "Write|Edit|Bash|NotebookEdit",
             "hooks": [
               {
                 "type": "command",
                 "command": "if echo \"$CLAUDE_TOOL_USE_CONTEXT\" | grep -qE 'rune-review|rune-audit'; then echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"SEC-001: review/audit Ashes are read-only\"}}'; exit 2; fi"
               }
             ]
           }
         ]
       }

     SEC-008 NOTE: This hook MUST also cover rune-audit team patterns (grep -qE covers
     both 'rune-review' and 'rune-audit'). Audit Ashes have the same tool inheritance
     issue as review Ashes (see audit.md Phase 3).

     TODO: Create composite Ash agent files with restricted allowed-tools frontmatter
     to enforce read-only at the agent definition level (eliminates need for hook). -->

```javascript
// Built-in Ash: load prompt from ash-prompts/{role}.md
Agent({
  team_name: "rune-review-{identifier}",
  name: "{ash-name}",
  subagent_type: "general-purpose",
  prompt: /* Load from roundtable-circle/references/ash-prompts/{role}.md
             Substitute: {changed_files}, {output_path}, {task_id}, {branch}, {timestamp}
             // SEC-006 (P2): Sanitize file paths before interpolation — validate against SAFE_PATH_PATTERN
             // (/^[a-zA-Z0-9._\-\/]+$/) and reject paths with special characters.
             // NOTE: Phase 0 pre-flight already filters non-existent files and symlinks (lines 76-78)
             // but does NOT sanitize filenames — paths with shell metacharacters, backticks, or
             // $() constructs could be injected into Ash prompts.
             // MITIGATION: Write the file list to tmp/reviews/{identifier}/changed-files.txt and
             // reference it in the prompt rather than embedding raw paths inline.
             // Codex Oracle additionally requires: {context_budget}, {codex_model}, {codex_reasoning},
             // {file_batch}, {review_mode}, {default_branch}, {identifier}, {diff_context}, {max_diff_size}
             // review_mode is always "review" for /rune:appraise (Codex Oracle uses diff-focused strategy)
             // These are resolved from talisman.codex.* config. See codex-oracle.md header for full contract.
             // SEC-007: Validate review_mode before substitution:
             // review_mode = ["review", "audit"].includes(mode) ? mode : "audit"
             */,
  run_in_background: true
})

// Custom Ash: use wrapper prompt template from custom-ashes.md
// The wrapper injects Truthbinding Protocol + Glyph Budget + Seal format
Agent({
  team_name: "rune-review-{identifier}",
  name: "{custom.name}",
  subagent_type: "{custom.agent}",  // local name or plugin namespace
  prompt: /* Generate from wrapper template in roundtable-circle/references/custom-ashes.md
             Substitute: {name}, {file_list}, {output_dir}, {finding_prefix}, {context_budget} */,
  run_in_background: true
})
```

## Elicitation Sage — Security Context (v1.31)

When security-relevant files are reviewed (3+ files matching `.py`, `.ts`, `.rb`, `.go` in `auth/`, `api/`, `security/` paths), summon 1-2 elicitation-sage teammates for structured security reasoning alongside the review Ashes.

Skipped if talisman `elicitation.enabled` is `false`.

```javascript
// ATE-1: subagent_type: "general-purpose", identity via prompt
// NOTE: Review uses path-based activation (security file patterns), not keyword-based.
// See elicitation-sage.md for keyword-based activation used by forge.md and plan.md.
// readTalismanSection: "gates"
const gates = readTalismanSection("gates")
const elicitEnabled = gates?.elicitation?.enabled !== false
const securityFiles = changedFiles.filter(f =>
  /\/(auth|api|security|middleware)\//.test(f) ||
  /\b(auth|login|token|session|password|secret)\b/i.test(f)
)

if (elicitEnabled && securityFiles.length >= 3) {
  // REVIEW-002: Sanitize file paths before prompt interpolation — reject paths with
  // shell metacharacters, backticks, $() constructs, or path traversal sequences.
  const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
  const safeSecurityFiles = securityFiles
    .filter(f => SAFE_PATH_PATTERN.test(f) && !f.includes('..'))
    .slice(0, 10)

  // review:6 methods: Red Team vs Blue Team (T1), Challenge from Critical Perspective (T1)
  const securitySageCount = safeSecurityFiles.length >= 6 ? 2 : 1
  // NOTE: Elicitation sages are supplementary and NOT counted in ashCount.
  // Phase 7 dynamic member discovery handles sage shutdown via team config.members.
  // Sage output is advisory-only (see REVIEW-010 below).
  // NOTE: Sage teammates are NOT counted toward the max_ashes cap from talisman.yml.
  // They are auto-summoned based on security file heuristics, independent of Ash selection.

  for (let i = 0; i < securitySageCount; i++) {
    // REVIEW-006: Create task for sage before spawning — enables monitor tracking
    TaskCreate({
      subject: `Elicitation sage security analysis ${i + 1}`,
      description: `Security reasoning for: ${safeSecurityFiles.join(", ")}. Output: tmp/reviews/{identifier}/elicitation-security-${i + 1}.md`,
      activeForm: `Sage security analysis ${i + 1}...`
    })

    Agent({
      team_name: "rune-review-{identifier}",
      name: `elicitation-sage-security-${i + 1}`,
      subagent_type: "general-purpose",
      prompt: `You are elicitation-sage — structured reasoning specialist.

        ## Bootstrap
        Read skills/elicitation/SKILL.md and skills/elicitation/methods.csv first.

        ## Assignment
        Phase: review:6 (code review)
        Auto-select the #${i + 1} top-scored security method (filter: review:6 phase + security topics).
        Changed files: Read tmp/reviews/{identifier}/changed-files.txt
        Focus on security analysis of: ${safeSecurityFiles.join(", ")}

        Write output to: tmp/reviews/{identifier}/elicitation-security-${i + 1}.md
        // REVIEW-010: Advisory output: sage results written to tmp/reviews/{identifier}/elicitation-security-*.md
        // are NOT aggregated into TOME by Runebinder. They serve as supplementary analysis for the
        // Tarnished during Phase 7 cleanup.

        Do not write implementation code. Security reasoning only.
        When done, SendMessage to team-lead: "Seal: elicitation security review done."`,
      run_in_background: true
    })
  }
}
```

The Tarnished does not review code directly. Focus solely on coordination.

## Inscription Contract

The inscription.json written in Phase 2 controls the review Ash spawning:

```javascript
// inscription.json — output contract (written in Phase 2)
Write("tmp/reviews/{identifier}/inscription.json", {
  workflow: "rune-review",
  timestamp: timestamp,
  output_dir: `tmp/reviews/${identifier}/`,
  diff_scope: diffScope,          // From Phase 0 diff range generation
  context_intelligence: contextIntel,  // From Phase 0.3 (PR metadata)
  linter_context: linterContext,       // From Phase 0.4 (detected linters)
  teammates: selectedAsh.map(name => ({
    name: name,
    output_file: `${name}.md`
  }))
})
```

## Talisman Custom Ashes

Agent-backed custom Ashes are **discovered in Phase 1 (Rune Gaze)** — NOT here in Phase 3.
The discovery step in `rune-gaze.md` validates, trigger-matches, and stores results in
`inscription.custom_agent_ashes`. Phase 3 reads that list and spawns them.

**Phase 3 spawning (reads from Phase 1 discovery):**

```
1. Read inscription.custom_agent_ashes (populated by Phase 1 Rune Gaze)
2. For each custom Ash in the list:
   a. Load wrapper prompt template from roundtable-circle/references/custom-ashes.md
   b. Substitute: {name}, {file_list}, {output_dir}, {finding_prefix}, {context_budget}
   c. Spawn via Agent({ team_name, name: entry.name, subagent_type: entry.agent, prompt: wrapper })
3. If inscription.custom_agent_ashes is empty or absent → no custom Ashes to spawn (skip silently)
```

**Important:** If `inscription.custom_agent_ashes` is not populated (e.g., legacy inscription without
Phase 1 discovery), fall back to the original discovery flow:

```
1. Read .claude/talisman.yml (project) or ~/.claude/talisman.yml (global)
2. If ashes.custom[] exists:
   a. Validate: unique prefixes, unique names, resolvable agents, count <= max
   b. Filter by workflows: keep only entries with "review" in workflows[]
   c. Match triggers against changed_files (extension + path match)
   d. Skip entries with fewer matching files than trigger.min_files
3. Merge validated custom Ash with built-in selections
4. Apply defaults.disable_ashes to remove any disabled built-ins
```

See `roundtable-circle/references/custom-ashes.md` for full schema and validation rules.

## CLI-Backed Ashes

After custom Ash loading, check whether the Codex Oracle should be summoned. Codex Oracle is a built-in Ash that wraps the OpenAI `codex` CLI, providing cross-model verification (GPT-5.3-codex alongside Claude). It is auto-detected and gracefully skipped when unavailable.

See `roundtable-circle/references/codex-detection.md` for the canonical detection algorithm.

**Note:** CLI detection is fast (no network call, <100ms). When Codex Oracle is selected, it counts toward the `max_ashes` cap. Codex Oracle findings use the `CDX` prefix and participate in standard dedup, TOME aggregation, and Truthsight verification.

### Other CLI-Backed Ashes

External models can participate as CLI-backed Ashes (v1.57.0+). Unlike agent-backed custom Ashes, CLI-backed Ashes invoke an external CLI binary (e.g., `gemini`, `llama`):

- Define in `talisman.yml` → `ashes.custom[]` with `cli:` field
- When `cli:` is present, `agent` and `source` become optional
- Subject to `max_cli_ashes` sub-cap (default: 2) within `max_ashes`
- Codex Oracle is NOT counted toward `max_cli_ashes`
- Prompt generated from `external-model-template.md` with Truthbinding

See `roundtable-circle/references/custom-ashes.md` and `roundtable-circle/references/codex-detection.md` for full specs.
