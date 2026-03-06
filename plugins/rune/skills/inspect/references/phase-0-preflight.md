# Phase 0: Pre-flight + Phase 0.5: Classification

## Step 0.1 — Parse Input

```
input = $ARGUMENTS

if (input matches /\.(md|txt)$/):
  // SEC-003: Validate plan path BEFORE filesystem access
  // SEC-001 FIX: Regex guard must run before fileExists() to prevent information oracle
  if (!/^[a-zA-Z0-9._\/-]+$/.test(input) || input.includes('..')):
    error("Invalid plan path: contains unsafe characters or path traversal")
  if (!fileExists(input)):
    error("Plan file not found: " + input)
  planPath = input
  planContent = Read(planPath)
  mode = "file"
else:
  planContent = input
  planPath = null
  mode = "inline"

if (!planContent || planContent.trim().length < 10):
  error("Plan is empty or too short.")

// Parse inspect mode flag
const inspectMode = flag("--mode") ?? "implementation"
// SEC: validate against fixed allowlist
if (!["implementation", "plan"].includes(inspectMode)):
  error("Unknown --mode value. Valid: implementation, plan")
```

## Step 0.2 — Read Talisman Config

```javascript
// readTalismanSection: "inspect"
const inspectConfig = readTalismanSection("inspect")

// RUIN-001 FIX: Runtime clamping prevents misconfiguration-based DoS/bypass
maxInspectors = Math.max(1, Math.min(4, flag("--max-agents") ?? inspectConfig.max_inspectors ?? 4))
timeout = Math.max(60_000, Math.min(inspectConfig.timeout ?? 720_000, 3_600_000))
completionThreshold = Math.max(0, Math.min(100, flag("--threshold") ?? inspectConfig.completion_threshold ?? 80))
gapThreshold = Math.max(0, Math.min(100, inspectConfig.gap_threshold ?? 20))
```

## Step 0.3 — Generate Identifier

```javascript
identifier = Date.now().toString(36)  // e.g., "lz5k8m2"
if (!/^[a-zA-Z0-9_-]+$/.test(identifier)):
  error("Invalid identifier generated")
outputDir = `tmp/inspect/${identifier}`
```

## Phase 0.5: Classification

### Step 0.5.1 — Extract Requirements

Follow the algorithm in [plan-parser.md](../../roundtable-circle/references/plan-parser.md):

1. Parse YAML frontmatter (if present)
2. Extract requirements from explicit sections (Requirements, Deliverables, Tasks)
3. Extract requirements from implementation sections (Files to Create/Modify)
4. Fallback: extract action sentences from full text
5. Extract plan identifiers (file paths, code names, config keys)

```javascript
parsedPlan = parsePlan(planContent)
requirements = parsedPlan.requirements
identifiers = parsedPlan.identifiers

if (requirements.length === 0):
  error("No requirements could be extracted from the plan.")

// Plan mode: additionally extract code blocks as reviewable artifacts
if (inspectMode === "plan"):
  // Extract up to 20 code blocks, each capped at 1500 chars
```

### Steps 0.5.2–0.5.4 — Assign, Focus, Limit

1. **Assign** requirements to inspectors via keyword-based classification (plan-parser.md Step 5)
2. **Apply `--focus`**: redirect all requirements to a single inspector
3. **Apply `--max-agents`**: redistribute cut-inspector requirements to grace-warden

See [inspector-prompts.md](inspector-prompts.md) for step-by-step logic.
