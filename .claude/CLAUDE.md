# Claude Code Plugin Development Rules

Rules and conventions for writing Claude Code plugins, based on official documentation.

## Plugin Structure

### Directory Layout

```
my-plugin/
├── .claude-plugin/           # Metadata ONLY — nothing else goes here
│   └── plugin.json           # Plugin manifest (name is the only required field)
├── commands/                 # Slash commands as .md files (legacy — prefer skills/)
├── skills/                   # Agent Skills: <name>/SKILL.md
├── agents/                   # Subagent definitions as .md files
├── hooks/                    # hooks.json event handlers
├── .mcp.json                 # MCP server configurations
├── .lsp.json                 # LSP server configurations
├── scripts/                  # Hook and utility scripts
├── CLAUDE.md                 # Plugin-level instructions (loaded when plugin is active)
└── README.md                 # Documentation
```

**CRITICAL**: `commands/`, `agents/`, `skills/`, `hooks/` go at the plugin root — NEVER inside `.claude-plugin/`. Only `plugin.json` belongs in `.claude-plugin/`.

### Plugin Manifest (`.claude-plugin/plugin.json`)

```json
{
  "name": "my-plugin",          // Required. Kebab-case, no spaces. Becomes skill namespace.
  "version": "1.0.0",           // Semver. MAJOR.MINOR.PATCH
  "description": "Brief purpose",
  "author": { "name": "Name", "email": "email@example.com" },
  "homepage": "https://docs.example.com",
  "repository": "https://github.com/user/plugin",
  "license": "MIT",
  "keywords": ["keyword1"]
}
```

**Name** = unique identifier AND skill namespace. Skills get prefixed: `/my-plugin:hello`.

### Component Path Overrides (optional in plugin.json)

```json
{
  "commands": ["./custom/cmd.md"],       // Supplements commands/, doesn't replace
  "agents": "./custom/agents/",
  "skills": "./custom/skills/",
  "hooks": "./config/hooks.json",
  "mcpServers": "./mcp-config.json",
  "lspServers": "./.lsp.json",
  "outputStyles": "./styles/"
}
```

All paths must be relative, starting with `./`. Custom paths ADD to defaults — they don't replace them.

### Environment Variables

- `${CLAUDE_PLUGIN_ROOT}` — absolute path to plugin directory. Use in hooks, MCP, scripts.
- `$CLAUDE_PROJECT_DIR` — project root. Use in project-level hook scripts.

## Skills

### SKILL.md Format

Every skill lives in `skills/<name>/SKILL.md`:

```yaml
---
name: my-skill                      # Lowercase + hyphens, max 64 chars. Defaults to dir name.
description: |                      # RECOMMENDED. Claude uses this to decide when to load.
  What this skill does and when to use it.
  Include trigger keywords so Claude matches correctly.
user-invocable: true                # true = appears in / menu. false = hidden (background knowledge).
disable-model-invocation: false     # true = only user can trigger. false = Claude can auto-load.
allowed-tools: Read, Grep, Glob    # Restrict tools when skill is active. Omit = inherit all.
model: sonnet                       # Override model. Options: sonnet, opus, haiku.
context: fork                       # Run in isolated subagent context.
agent: Explore                      # Subagent type when context: fork. Default: general-purpose.
argument-hint: "[issue-number]"     # Autocomplete hint for arguments.
hooks:                              # Lifecycle hooks scoped to this skill
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate.sh"
---

Skill instructions in Markdown...
```

### Invocation Control

| Setting | You invoke | Claude invokes | Context cost |
|---------|-----------|---------------|-------------|
| Default | Yes | Yes | Description always loaded |
| `disable-model-invocation: true` | Yes | No | Zero until you invoke |
| `user-invocable: false` | No | Yes | Description always loaded |

### String Substitutions

| Variable | Description |
|----------|-------------|
| `$ARGUMENTS` | All args after skill name |
| `$ARGUMENTS[N]` or `$N` | Specific arg by 0-based index |
| `${CLAUDE_SESSION_ID}` | Current session ID |
| `` !`command` `` | Preprocessor — runs shell command, inserts output |

### Supporting Files

```
my-skill/
├── SKILL.md           # Main instructions (required, keep under 500 lines)
├── reference.md       # Detailed docs (loaded on demand)
├── examples/
│   └── sample.md
└── scripts/
    └── helper.py
```

Reference from SKILL.md: `For details, see [reference.md](reference.md)`

### Skills in Plugins vs Standalone

| Approach | Skill names | Best for |
|----------|------------|---------|
| Standalone (`.claude/skills/`) | `/hello` | Personal, project-specific, experiments |
| Plugin (`plugin/skills/`) | `/plugin-name:hello` | Sharing, distribution, versioned releases |

### Skill Discovery Order (highest priority wins)

enterprise > personal (`~/.claude/skills/`) > project (`.claude/skills/`) > plugin

## Subagents

### Agent File Format

Agents live in `agents/` as `.md` files with YAML frontmatter:

```yaml
---
name: code-reviewer               # Required. Lowercase + hyphens.
description: |                     # Required. When Claude should delegate to this agent.
  Expert code review specialist.
  Use proactively after code changes.
tools: Read, Grep, Glob, Bash     # Allowlist. Omit = inherit all.
disallowedTools: Write, Edit       # Denylist. Removed from inherited/specified list.
model: sonnet                      # sonnet | opus | haiku | inherit (default)
permissionMode: default            # default | acceptEdits | dontAsk | delegate | bypassPermissions | plan
maxTurns: 50                       # Max agentic turns before stopping.
skills:                            # Skills preloaded at startup (full content injected)
  - api-conventions
  - error-handling-patterns
mcpServers:                        # MCP servers available to this subagent
  - slack                          # Reference existing server by name
memory: user                       # Persistent memory: user | project | local
hooks:                             # Lifecycle hooks scoped to this agent
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate.sh"
---

System prompt for the agent in Markdown...
```

### Agent Scope (highest priority wins)

1. `--agents` CLI flag (session only)
2. `.claude/agents/` (project)
3. `~/.claude/agents/` (user)
4. Plugin `agents/` (where enabled)

### Key Subagent Rules

- Subagents receive ONLY their system prompt + environment details — NOT the full Claude Code system prompt.
- Subagents CANNOT spawn other subagents. No nesting.
- Background subagents auto-deny permissions not pre-approved.
- `tools: Agent(worker, researcher)` restricts which subagent types can be spawned (main thread only).
- Skills passed to subagents are FULLY injected at startup — not loaded on demand.

### Persistent Memory

When `memory` is set, the agent gets a persistent directory:
- `user` → `~/.claude/agent-memory/<name>/`
- `project` → `.claude/agent-memory/<name>/`
- `local` → `.claude/agent-memory-local/<name>/`

System prompt auto-includes first 200 lines of `MEMORY.md`. Read/Write/Edit auto-enabled.

### Built-in Subagents

| Agent | Model | Tools | Purpose |
|-------|-------|-------|---------|
| Explore | Haiku | Read-only | Fast codebase search |
| Plan | Inherit | Read-only | Research for plan mode |
| general-purpose | Inherit | All | Complex multi-step tasks |

## Agent Teams

### Enable

```json
// .claude/settings.local.json or settings.json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

### Architecture

| Component | Role |
|-----------|------|
| Team lead | Main session that creates team, spawns teammates, coordinates |
| Teammates | Separate Claude Code instances with own context windows |
| Task list | Shared work items at `~/.claude/tasks/{team-name}/` |
| Mailbox | Messaging system for inter-agent communication |

### Team Lifecycle

1. **TeamCreate** — creates team + task list
2. **TaskCreate** — populate tasks with dependencies
3. **Agent tool** — spawn teammates with `team_name` and `name` (renamed from `Task` in Claude Code 2.1.63)
4. **TaskUpdate** — assign tasks (`owner`), mark `in_progress`/`completed`
5. **SendMessage** — `message` (DM), `broadcast` (all), `shutdown_request`
6. **TeamDelete** — cleanup (fails if members active — shutdown first)

### Config Locations

- Team config: `~/.claude/teams/{team-name}/config.json`
- Task list: `~/.claude/tasks/{team-name}/`

### Communication

| Type | Use | Cost |
|------|-----|------|
| `message` | DM to one teammate | 1 delivery |
| `broadcast` | All teammates | N deliveries (use sparingly) |
| `shutdown_request` | Ask teammate to exit | 1 delivery |

### Best Practices

- Give teammates enough context in spawn prompts (they don't inherit conversation history)
- Size tasks appropriately — 5-6 tasks per teammate
- Avoid file conflicts — each teammate should own different files
- Use `delegate` mode to prevent lead from implementing
- Require plan approval for risky tasks: `plan_mode_required`
- Start with research/review tasks before parallel implementation

### Agent Team Cleanup (MANDATORY)

Every workflow that creates an agent team via `TeamCreate` **MUST** clean up with the full 5-component standard pattern before completing. Orphaned teams leak processes, block future `TeamCreate` calls, and waste resources.

**Standard cleanup pattern** (all 5 components required):

```javascript
// 1. Dynamic member discovery — read team config for ALL teammates
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: hardcoded list of all known teammates for this workflow
  allMembers = ["agent-1", "agent-2", "agent-3"]
}

// 2. shutdown_request to all members
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Workflow complete" })
}

// 3. Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) { Bash("sleep 15") }

// 4. TeamDelete with retry-with-backoff (3 attempts: 0s, 5s, 10s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}
```

**Rules:**
- **Use `Agent` tool** (not `Task`) for spawning teammates — renamed in Claude Code 2.1.63 (see PR #172)
- **Never skip cleanup** — even on error paths, wrap the main workflow in try/finally
- **Fallback arrays must be complete** — list ALL teammates that could be spawned by the workflow, including conditional ones (safe to send `shutdown_request` to absent members)
- **SEC-4 validation** — always filter member names with `/^[a-zA-Z0-9_-]+$/` before use in `SendMessage`
- **QUAL-012** — gate filesystem fallback behind `!cleanupTeamDeleteSucceeded` to avoid unnecessary `rm -rf` when TeamDelete already succeeded
- **CHOME pattern** — never hardcode `~/.claude/` in `Bash()` cleanup commands; use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`
- **Shared vs separate teams** — if a workflow uses ONE team across multiple phases (e.g., devise), cleanup belongs at the FINAL phase only — not at intermediate phases
- **Arc team prefix registration** — when adding a new `TeamCreate` in any arc phase (including ephemeral/conditional teams), register the team name prefix in ALL 3 crash recovery layers. Without all 3, orphaned teams become invisible on crash:
  1. `ARC_TEAM_PREFIXES` in `arc-preflight.md` — preflight stale scan (cross-session)
  2. `PHASE_PREFIX_MAP` in `arc-phase-cleanup.md` — postPhaseCleanup (inter-phase)
  3. Crash recovery table in the phase's reference file — documentation for manual recovery

### Display Modes

```json
{ "teammateMode": "auto" }  // auto | in-process | tmux
```

### Quality Gates via Hooks

```json
{
  "hooks": {
    "TeammateIdle": [{ "hooks": [{ "type": "command", "command": "./check-quality.sh" }] }],
    "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "./verify-task.sh" }] }]
  }
}
```

Exit code 2 = block (teammate keeps working / task stays open). stderr = feedback message.

### Limitations

- No session resumption for in-process teammates
- One team per session
- No nested teams (teammates can't create teams)
- Lead is fixed for team lifetime
- All teammates start with lead's permission mode

## Hooks

### Configuration Locations

| Location | Scope |
|----------|-------|
| `~/.claude/settings.json` | All projects |
| `.claude/settings.json` | Project (committable) |
| `.claude/settings.local.json` | Project (gitignored) |
| Plugin `hooks/hooks.json` | When plugin enabled |
| Skill/Agent frontmatter | While component active |

### Hook Events

| Event | When | Can Block? | Matcher |
|-------|------|-----------|---------|
| `SessionStart` | Session begins/resumes | No | startup, resume, clear, compact |
| `UserPromptSubmit` | User submits prompt | Yes | (none) |
| `PreToolUse` | Before tool executes | Yes | Tool name |
| `PermissionRequest` | Permission dialog shown | Yes | Tool name |
| `PostToolUse` | After tool succeeds | No | Tool name |
| `PostToolUseFailure` | After tool fails | No | Tool name |
| `Notification` | Notification sent | No | permission_prompt, idle_prompt, etc. |
| `SubagentStart` | Subagent spawned | No | Agent type |
| `SubagentStop` | Subagent finishes | Yes | Agent type |
| `Stop` | Claude finishes responding | Yes | (none) |
| `TeammateIdle` | Teammate about to go idle | Yes | (none) |
| `TaskCompleted` | Task being marked complete | Yes | (none) |
| `PreCompact` | Before compaction | No | manual, auto |
| `SessionEnd` | Session ends | No | clear, logout, etc. |

### Hook Types

```json
{ "type": "command", "command": "./script.sh", "timeout": 600, "async": false }
{ "type": "prompt", "prompt": "Evaluate: $ARGUMENTS", "model": "haiku", "timeout": 30 }
{ "type": "agent", "prompt": "Verify tests pass: $ARGUMENTS", "timeout": 60 }
```

### Exit Codes

- **0** = success. Stdout parsed as JSON (if valid).
- **2** = blocking error. stderr fed to Claude. Tool call blocked (PreToolUse), prompt rejected (UserPromptSubmit), etc.
- **Other** = non-blocking error. stderr in verbose mode.

### Matcher Patterns

Regex-based. `"Edit|Write"` matches either. `"mcp__memory__.*"` matches all memory MCP tools. Omit or `"*"` = match all.

### Hook JSON Output — Required `hookEventName`

When a hook script outputs JSON with `hookSpecificOutput`, it **MUST** include `hookEventName` matching the event type. Without it, Claude Code logs "hook error" even if the script exits 0.

```json
// CORRECT — includes hookEventName
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}

// WRONG — missing hookEventName, causes "SessionStart:startup hook error"
{"hookSpecificOutput":{"additionalContext":"..."}}
```

This applies to ALL hook events (SessionStart, PreToolUse, PostToolUse, etc.).

### PreToolUse Decision Control

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",    // allow | deny | ask
    "permissionDecisionReason": "Safe operation",
    "updatedInput": { "command": "modified-command" },
    "additionalContext": "Extra context for Claude"
  }
}
```

## Feature Selection Guide

| Need | Use |
|------|-----|
| "Always do X" rules | CLAUDE.md |
| Reference docs loaded on demand | Skill |
| Repeatable workflow with `/name` | Skill with `disable-model-invocation: true` |
| Context isolation for verbose tasks | Subagent |
| Parallel work with peer communication | Agent Team |
| External service connection | MCP server |
| Deterministic automation on events | Hook |
| Package and distribute all of the above | Plugin |

### Context Cost

| Feature | Loads | Cost |
|---------|-------|------|
| CLAUDE.md | Every session | Every request |
| Skills | Description at start, full on invoke | Low until used |
| MCP servers | All tool schemas at start | Every request |
| Subagents | On spawn | Isolated |
| Hooks | On trigger | Zero (external) |

## Plugin Development Checklist

- [ ] `.claude-plugin/plugin.json` has valid `name` (kebab-case)
- [ ] Components at plugin root, NOT inside `.claude-plugin/`
- [ ] Skills have `description` in frontmatter
- [ ] Subagents have `name` and `description` in frontmatter
- [ ] Hook scripts are executable (`chmod +x`)
- [ ] Hook scripts use `${CLAUDE_PLUGIN_ROOT}` for paths
- [ ] All paths relative, starting with `./`
- [ ] Skills under 500 lines (move details to supporting files)
- [ ] CLAUDE.md under 500 lines
- [ ] Version follows semver (MAJOR.MINOR.PATCH)
- [ ] Test with `claude --plugin-dir ./my-plugin`
- [ ] Validate with `claude --debug`

## Naming Conventions

- Plugin name: `kebab-case`, no spaces
- Skill names: `lowercase-with-hyphens`, max 64 chars
- Agent names: `lowercase-with-hyphens`
- Hook scripts: descriptive names (`validate-command.sh`, `format-code.sh`)
- Commands: `kebab-case.md`

## Version Management

```
1.0.0  — First stable release
1.1.0  — New feature (backward-compatible)
1.1.1  — Bug fix
2.0.0  — Breaking change
2.0.0-beta.1 — Pre-release for testing
```

Update `plugin.json` version before distributing. Document changes in CHANGELOG.md.

## Security Rules

- Always quote shell variables: `"$VAR"` not `$VAR`
- Validate and sanitize hook inputs
- Block path traversal: check for `..` in file paths
- Use absolute paths with env vars for scripts
- Skip sensitive files (`.env`, `.git/`, keys)
- Review all hook commands before adding
- Hooks run with FULL user permissions
- `bypassPermissions` skips ALL checks — use with extreme caution
- `allowed-tools` = security boundary — apply least-privilege


## Project-Level Skills

These skills live in `.claude/skills/` and take priority over plugin-level skills with the same name.

| Skill | Invoke | Purpose |
|-------|--------|---------|
| `create-agent-skills` | `/create-agent-skills` | Expert guidance for creating and auditing SKILL.md files, slash commands, and skill structure. Includes references, templates, and workflows. |
| `skill-creator` | `/skill-creator` | Guide for creating skills that extend Claude's capabilities with specialized knowledge, workflows, and tool integrations. Includes init/validate/package scripts. |

**When to use which:**
- `/create-agent-skills` — comprehensive reference with 13 reference docs, 2 templates, 10 workflows. Use for auditing existing skills, understanding best practices, or building complex router-style skills.
- `/skill-creator` — lightweight guide with init/validate/package scripts. Use for quick skill scaffolding and packaging.

## CLAUDE_CONFIG_DIR — Multi-Account Support

Users may set `CLAUDE_CONFIG_DIR` to a custom path (e.g., `~/.claude-work`, `~/.claude-personal`). **Never hardcode `~/.claude/`** in `Bash()` commands that reference teams/tasks directories.

**Pattern for all shell commands:**
```bash
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
rm -rf "$CHOME/teams/..." "$CHOME/tasks/..." 2>/dev/null
find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" \) -exec rm -rf {} + 2>/dev/null
```

- `TeamCreate`/`TeamDelete`/`Read` of config.json — the SDK resolves the config dir automatically
- `Bash()` with `rm -rf` or `find` — must resolve via `CHOME` (shell commands run literally)
- See `team-lifecycle-guard.md` for the canonical pre-create guard pattern

## Project Rules

- Don't commit plan files (`./plans/*.md`)
- Always ensure plugin version is in sync between `.claude-plugin/marketplace.json` and `plugins/rune/.claude-plugin/plugin.json`
- **Planning disambiguation**: ALWAYS use `/rune:devise` for feature planning — NEVER use `EnterPlanMode`. Plan output MUST follow Rune templates (YAML frontmatter + Minimal/Standard/Comprehensive sections from `devise/references/synthesize.md`)
- **Plugin reload after sync**: After merging a PR, or checking out `main` and pulling new code (`git checkout main && git pull`), always run `/reload-plugins` to reload the Rune plugin with the latest changes

## Rune Session Isolation Rule

Session-level isolation is a CRITICAL requirement for the Rune plugin. Different Claude Code sessions working on the same repo MUST NOT interfere with each other, even if they share the same CLAUDE_CONFIG_DIR.

**All Rune state files MUST include:**
- `config_dir` — resolved CLAUDE_CONFIG_DIR path (installation isolation)
- `owner_pid` — Claude Code process PID via $PPID (session isolation)
- `session_id` — CLAUDE_SESSION_ID (diagnostic, not verifiable in bash)

**All Rune hook scripts that read state files MUST:**
- Check `config_dir` matches current session before acting
- Check `owner_pid` matches $PPID (with kill -0 liveness check) before acting
- Skip silently if state belongs to another live session
- Clean up if state belongs to a dead session (orphan recovery)
