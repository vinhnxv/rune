# Phase 2: Spawn Agent Teams

**Goal**: Create team, spawn all Claude and Codex agents in parallel.

## Pre-Create Guard

Follow the teamTransition pattern from [engines.md](../../team-sdk/references/engines.md) § createTeam:

```javascript
const teamName = `rune-codex-review-${identifier}`
// 1. Validate identifier (alphanumeric + hyphens only)
// 2. TeamDelete retry-with-backoff (3 attempts, 2s between)
//    → catch if team doesn't exist (expected)
// 3. TeamCreate
TeamCreate({ team_name: teamName, description: "Cross-model code review" })
```

## Generate AGENTS.md

Generate fresh context file for Codex agents (MUST NOT include cross-verification details):

```javascript
const projectStructure = Bash(`find . -maxdepth 2 -type d | head -30 2>/dev/null`)
const recentCommits = Bash(`git log --oneline -5 2>/dev/null`)
const branch = Bash(`git branch --show-current 2>/dev/null`)

// Filter file list through .codexignore at PROMPT LAYER (SEC-CODEX-001):
// Even though sandbox blocks reads, file names in prompts leak structure.
const codexIgnoreContent = safeRead('.codexignore') || ''
const codexFileList = fileList.filter(f => !matchesGitignorePattern(f, codexIgnoreContent))

Write(`${REVIEW_DIR}/AGENTS.md`, buildAgentsMd({
  projectStructure, recentCommits, branch,
  fileList: codexFileList, scopeType, focusAreas
}))
// AGENTS.md MUST NOT contain: cross-verification algorithm, confidence formulas,
// prefix conventions beyond CDX-, or information about how Claude agents work.
```

## Create Tasks

```javascript
const allTaskIds = []

// Claude wing tasks
for (const agent of claudeAgents) {
  const task = TaskCreate({
    subject: `Claude ${agent.name} review`,
    description: `Review files as ${agent.perspective}. Write findings to ${REVIEW_DIR}/claude/${agent.outputFile}`,
    activeForm: `${agent.name} analyzing...`
  })
  allTaskIds.push(task.id)
}

// Codex wing tasks
for (const agent of codexAgents) {
  const task = TaskCreate({
    subject: `Codex ${agent.name} review`,
    description: `Review files via codex exec as ${agent.perspective}. Write findings to ${REVIEW_DIR}/codex/${agent.outputFile}`,
    activeForm: `${agent.name} analyzing...`
  })
  allTaskIds.push(task.id)
}
```

## Readonly Enforcement

```javascript
// SEC-001: Write tools blocked for review Ashes via enforce-readonly.sh hook when .readonly-active marker exists
Bash(`mkdir -p tmp/.rune-signals/${teamName}`)
Write(`tmp/.rune-signals/${teamName}/.readonly-active`, "active")
```

## Spawn Claude Wing (ALL in ONE call — parallel)

```javascript
// ATE-1: ALL Claude agents MUST use team_name (never bare Agent calls)
for (const agent of claudeAgents) {
  Agent({
    team_name: teamName,
    name: `claude-${agent.name}`,
    subagent_type: "general-purpose",
    model: resolveModelForAgent(agent.name, talisman),
    run_in_background: true,
    prompt: buildClaudeReviewPrompt(agent, {
      files: fileList,
      diff: diffContent,
      scope: scopeType,
      outputPath: `${REVIEW_DIR}/claude/${agent.outputFile}`,
      customPrompt: flags['--prompt'],
      nonce: identifier  // Nonce boundary for injected content (SEC-NONCE-001)
    })
  })
}
```

Each Claude agent prompt includes ANCHOR/RE-ANCHOR Truthbinding, nonce-bounded content, perspective checklist, finding format (P1/P2/P3 with `<!-- RUNE:FINDING -->` markers), and Seal. See [claude-wing-prompts.md](claude-wing-prompts.md) for full template.

## Spawn Codex Wing (staggered starts — rate limit guard)

```javascript
// ATE-1: ALL Codex agents MUST use team_name
for (let i = 0; i < codexAgents.length; i++) {
  if (i > 0) Bash(`sleep 2`)  // Stagger to avoid Codex API rate limits (SEC-RATE-001)
  const agent = codexAgents[i]
  Agent({
    team_name: teamName,
    name: `codex-${agent.name}`,
    subagent_type: "general-purpose",
    model: resolveModelForAgent('codex-wrapper', talisman),  // sonnet for reasoning, haiku if mechanical
    run_in_background: true,
    prompt: buildCodexReviewPrompt(agent, {
      files: codexFileList,  // .codexignore-filtered list
      diff: diffContent,
      scope: scopeType,
      outputPath: `${REVIEW_DIR}/codex/${agent.outputFile}`,
      promptFilePath: `${REVIEW_DIR}/codex/${agent.name}-prompt.txt`,
      model: talisman?.codex?.model || 'gpt-5.3-codex',
      reasoning: flags['--reasoning'],
      customPrompt: flags['--prompt'],
      agentsMdPath: `${REVIEW_DIR}/AGENTS.md`
    })
  })
}
```

Codex agents use temp prompt files (SEC-003), `.codexignore` filtering (SEC-CODEX-001), timeout cascade, ANCHOR stripping (SEC-ANCHOR-001), prefix enforcement (SEC-PREFIX-001), and HTML sanitization. See [codex-wing-prompts.md](codex-wing-prompts.md) for full prompt template.
