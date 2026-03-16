# Phase 1: Prerequisites & Detection

> Checks codex availability, selects agents by focus area, and writes inscription.
> Called from SKILL.md Phase 1.

## Setup

```javascript
const identifier = generateIdentifier()  // YYYYMMDD-HHMMSS-{shortSession} (first 4 chars of session nonce)
const REVIEW_DIR = `tmp/codex-review/${identifier}/`
Bash(`mkdir -p ${REVIEW_DIR}/claude ${REVIEW_DIR}/codex`)
```

## Talisman Config

```javascript
// readTalismanSection: "codex", "misc"
const codex = readTalismanSection("codex")
const misc = readTalismanSection("misc")

// Check both disable flags:
const globalDisabled = codex?.disabled === true
const skillDisabled = misc?.codex_review?.disabled === true
if (globalDisabled || skillDisabled) {
  // If --codex-only: ERROR "Codex is disabled in talisman.yml"
  // Else: fall back to Claude-only mode, warn user
}

const codexReviewConfig = misc?.codex_review || {}
```

## Codex Detection

Follow the 9-step algorithm from [codex-detection.md](../../roundtable-circle/references/codex-detection.md).

Key steps for this skill:
1. Check `talisman.codex.disabled` (global) AND `talisman.codex_review.disabled` (skill-specific)
2. `command -v codex` — CLI installed?
3. `codex --version` — CLI executable?
4. Check `.codexignore` exists (required for `--full-auto`)
5. Set `codex_available = true/false`

```javascript
// Resolution:
// --codex-only && !codex_available → ERROR: "Codex not available. Install from https://github.com/openai/codex"
// --claude-only → skip Codex detection entirely
// !codex_available && !--codex-only → warn, set claudeOnly = true
```

## Agent Selection

### MCP-First Reviewer Discovery (v1.171.0+)

Before selecting reviewers by focus area, query agent-search MCP for review agents.
Enables user-defined reviewers (e.g., "compliance-reviewer" for regulated codebases)
to participate in cross-model review alongside built-in agents.

```javascript
// MCP-first reviewer discovery for codex-review
let additionalClaudeReviewers = []
try {
  const candidates = agent_search({
    query: "code review security bugs quality performance dead code analysis",
    phase: "appraise",
    category: "review",
    limit: 10
  })
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")

  if (candidates?.results?.length > 0) {
    const builtinNames = new Set([
      "security-reviewer", "bug-hunter", "quality-analyzer",
      "dead-code-finder", "performance-analyzer"
    ])
    for (const c of candidates.results) {
      if (!builtinNames.has(c.name) && (c.source === "user" || c.source === "project")) {
        additionalClaudeReviewers.push({ name: c.name, focus: "all" })
      }
    }
  }
} catch (e) {
  // MCP unavailable — proceed with hardcoded defaults
}
// additionalClaudeReviewers are appended to the Claude wing agent list below
```

**Claude agents by focus:**

| Focus | Claude Agents Selected |
|-------|----------------------|
| `all` | security-reviewer, bug-hunter, quality-analyzer, dead-code-finder, performance-analyzer (+ MCP-discovered) |
| `security` | security-reviewer |
| `bugs` | bug-hunter |
| `performance` | performance-analyzer |
| `quality` | quality-analyzer |
| `dead-code` | dead-code-finder |

**Codex agents by focus:**

| Focus | Codex Agents Selected |
|-------|----------------------|
| `all` | codex-security, codex-bugs, codex-quality, codex-performance |
| `security` | codex-security |
| `bugs` | codex-bugs |
| `performance` | codex-performance |
| `quality` | codex-quality |

**Multi-focus**: comma-separated `--focus security,bugs` → union of agent sets.

**Max-agents cap (--max-agents N):**

```javascript
// Split proportionally: 60% Claude, 40% Codex (minimum 1 per wing)
const claudeCount = Math.ceil(N * 0.6)
const codexCount = N - claudeCount
// claudeCount ≥ 1, codexCount ≥ 1 (unless --claude-only or --codex-only)
// Truncate agent lists to fit within counts (priority order per focus)
```

## Write Inscription

```javascript
Write(`${REVIEW_DIR}/inscription.json`, JSON.stringify({
  workflow: "codex-review",
  status: "active",
  config_dir: RUNE_CURRENT_CFG,  // from resolve-session-identity.sh
  owner_pid: PPID,               // $PPID
  session_id: CLAUDE_SESSION_ID || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  identifier,
  team_name: `rune-codex-review-${identifier}`,
  output_dir: REVIEW_DIR,
  started_at: new Date().toISOString(),
  scope_type,
  file_count: fileList.length,
  agents: {
    claude: claudeAgents.map(a => a.name),
    codex: codexAgents.map(a => a.name)
  },
  phase: "spawning",
  codex_available: codexAvailable
}, null, 2))

// Write state file for hook infrastructure:
Write(`tmp/.rune-codex-review-${identifier}.json`, JSON.stringify({
  workflow: "codex-review",
  status: "active",
  config_dir: RUNE_CURRENT_CFG,
  owner_pid: PPID,
  session_id: CLAUDE_SESSION_ID || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  identifier,
  team_name: `rune-codex-review-${identifier}`,
  phase: "spawning"
}, null, 2))
```
