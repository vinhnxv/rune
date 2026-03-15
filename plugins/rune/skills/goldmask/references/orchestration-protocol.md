# Orchestration Protocol — Phases 0-3

## 0. Parse Input

```
$ARGUMENTS = diff-spec (e.g., HEAD~3..HEAD) or file list (e.g., src/auth/ src/payment/)

If --quick flag: skip to Quick Check mode (no agents).
If --lore flag: skip to Intelligence mode (Lore only).
Otherwise: Full investigation.
```

Validate input:
```
// Strip own operational flags before validation
const ownFlags = ['--quick', '--lore']
let cleanArgs = $ARGUMENTS
for (const flag of ownFlags) {
  cleanArgs = cleanArgs.replace(new RegExp(flag + '\\b', 'g'), '').trim()
}

if (!/^[a-zA-Z0-9._\/ ~^:-]+$/.test(cleanArgs))
  → reject with "Invalid input characters"
// SEC-10: Reject git flag injection — no unknown token may start with '-'
const tokens = cleanArgs.split(/\s+/).filter(t => t.length > 0)
if (tokens.some(token => token.startsWith('-')))
  → reject with "Git flag injection detected — arguments must not start with '-'"
// SEC-10: Reject path traversal (per-token check — allows git range operator '..')
if (tokens.some(t => t === '..' || t.includes('/../') || t.startsWith('../') || t.endsWith('/..')))
  → reject with "Path traversal detected — '..' tokens are not allowed"
```

## 1. Resolve Changed Files

```bash
# For diff-spec (MUST quote $ARGUMENTS in all Bash interpolation):
git diff --name-only -- "${diff_spec}"

# For file list:
# Use provided paths directly
```

If no changed files found, report "No changes detected" and exit.

## 2. Generate Session ID + Output Directory

```
session_id = "goldmask-" + Date.now()
// SEC-5: Validate session_id immediately after generation (defense-in-depth)
if (!/^[a-zA-Z0-9_-]+$/.test(session_id)) { error("Invalid session_id"); return }
output_dir = "tmp/goldmask/{session_id}/"

# If invoked from arc:
# SEC-5: Validate arc_id before path construction (same guard as session_id)
if (!/^[a-zA-Z0-9_-]+$/.test(arc_id)) { error("Invalid arc_id"); return }
output_dir = "tmp/arc/{arc_id}/goldmask/"
```

Create output directory and write `inscription.json`:
```json
{
  "session_id": "{session_id}",
  "config_dir": "{resolved_config_dir}",
  "owner_pid": "{ppid}",
  "output_dir": "{output_dir}",
  "changed_files": ["..."],
  "mode": "full|quick|intelligence",
  "layers": {
    "impact": { "expected_files": ["data-layer.md", "api-contract.md", "business-logic.md", "event-message.md", "config-dependency.md"] },
    "wisdom": { "expected_files": ["wisdom-report.md"] },
    "lore":   { "expected_files": ["risk-map.json"] }
  }
}
```

## 2.5. Workflow Lock (reader)

```bash
CWD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
source "${CWD}/plugins/rune/scripts/lib/workflow-lock.sh"
conflicts=$(rune_check_conflicts "reader")
if echo "$conflicts" | grep -q "CONFLICT"; then
  AskUserQuestion({ question: "Active workflow conflict:\n${conflicts}\nProceed anyway?" })
fi
rune_acquire_lock "goldmask" "reader"
```

## 3. Pre-Create Guard + Team Lifecycle

Follow the 3-step pre-create guard from [engines.md](../../team-sdk/references/engines.md) § createTeam:

```
Step 0: Try TeamDelete() — may succeed if leftover (no arguments — clears current leadership)
Step A: rm -rf target team/task dirs (use CHOME pattern)
Step B: Cross-workflow find scan for stale goldmask-* dirs
Step C: Retry TeamDelete() if Step A found dirs
```

Then:
```
TeamCreate({ team_name: session_id })
```

Create state file for session hook discovery (STOP-001, TLC-003):
```javascript
// EC-12, ward-sentinel #3: resolve CLAUDE_SESSION_ID via Bash, not literal string
const sessionId = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash("echo $PPID").trim()
if (!/^[0-9]+$/.test(ownerPid)) { warn("goldmask: invalid PPID — using fallback"); }
Write(`tmp/.rune-goldmask-${session_id}.json`, JSON.stringify({
  status: "active",
  team_name: session_id,  // session_id = "goldmask-{timestamp}" (workflow ID)
  started: new Date().toISOString(),
  config_dir: configDir,
  owner_pid: /^[0-9]+$/.test(ownerPid) ? ownerPid : "0",
  session_id: sessionId
}))
```
