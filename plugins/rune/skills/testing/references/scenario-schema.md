# YAML Test Scenario Schema

Defines the structured format for pre-defined test scenarios in `.rune/test-scenarios/`.
Scenarios are discovered by STEP 0.5 and merged with auto-discovered tests during strategy generation.

## Schema Definition

```yaml
scenario:
  # === Required fields ===
  name: string            # Human-readable, unique across all scenario files
  tier: enum              # unit | integration | e2e | contract | visual

  # === Optional metadata ===
  tags: string[]          # Filtering/grouping labels (e.g., [auth, login, critical-path])
  risk: enum              # high | medium | low — affects prioritization (default: medium)
  priority: integer       # Execution order within tier — lower = first (default: 99)
  ac_ref: string          # Traceability to plan acceptance criteria (e.g., "AC-001")
  timeout_ms: integer     # Per-scenario timeout override (default: tier timeout)
  mode: enum              # execute | generate | exploratory (default: execute)

  # === Scope binding (diff-scoped activation) ===
  triggers: string[]      # Glob patterns — scenario activates when matching files change
  always_run: boolean     # true = run regardless of diff scope (default: false)
  exclude_triggers: string[]  # Glob patterns — exclude even if triggers match

  # === Preconditions ===
  preconditions:
    service_healthy: boolean    # Require service running (default: false)
    fixtures: Fixture[]         # Data setup before test (see fixture-protocol.md)
    depends_on: string[]        # Other scenario names that must pass first

  # === Steps (tier-specific) ===
  steps: Step[]

  # === Expectations ===
  expect: Expectation[]

  # === Cleanup ===
  teardown: TeardownAction[]

  # === Mode-specific fields ===
  # mode: generate
  target_files: string[]        # Files to generate tests for (required when mode=generate)
  methodology: enum             # london | detroit | property-based (optional, default: detroit)
  output_dir: string            # Output directory (default: tests/generated/)

  # mode: exploratory
  route: string                 # Starting route for exploration (required when mode=exploratory)
  exploration_budget_ms: integer  # Time budget for free exploration (required when mode=exploratory)
  focus_areas: string[]         # Hints for the agent (e.g., ["empty states", "error handling"])
```

## Field Details

### Tiers

| Tier | Routes to | Description |
|------|-----------|-------------|
| `unit` | STEP 5 | Unit tests — mocked dependencies, fast execution |
| `integration` | STEP 6 | Integration tests — real services, API contracts |
| `e2e` | STEP 7 | End-to-end browser tests — agent-browser actions |
| `contract` | STEP 5.5 | Schema validation against OpenAPI/JSON Schema specs |
| `visual` | STEP 7 | Visual regression — routes to E2E with `visual_regression.enabled` force-set |

### Trigger Patterns

Triggers use glob patterns to activate scenarios based on changed files:

```yaml
triggers:
  - "src/auth/**"                    # All files under auth
  - "src/components/LoginForm.*"     # Specific component
  - "api/routes/*.ts"                # API route files
```

- When `always_run: true`, scenario runs regardless of diff scope
- When `triggers` is empty and `always_run` is false, scenario never activates via diff
- `exclude_triggers` removes files that matched `triggers`

### Steps by Tier

**E2E steps** (agent-browser actions):

```yaml
steps:
  - action: navigate
    url: "/login"
  - action: wait
    condition: networkidle        # networkidle | load | domcontentloaded
  - action: fill
    selector: "#email"
    value: "test@example.com"
  - action: click
    selector: "button[type=submit]"
  - action: wait
    condition: url_contains
    value: "/dashboard"
  - action: screenshot
    name: "after-login"           # Screenshot capture
```

**Unit/Integration steps** (command-based):

```yaml
steps:
  - action: run_command
    command: "pytest tests/test_auth.py::test_login_valid -v"
  - action: run_command
    command: "npm test -- --testPathPattern=auth"
```

**Contract steps** (schema validation):

```yaml
steps:
  - action: validate_schema
    endpoint: "POST /api/auth/login"
    spec: "openapi.yaml"
  - action: validate_response
    endpoint: "GET /api/users/{id}"
    expected_status: 200
```

### Expectations

| Type | Fields | Description |
|------|--------|-------------|
| `url_contains` | `value` | Current URL contains substring |
| `element_visible` | `selector` | Element exists and is visible |
| `element_text` | `selector`, `contains` | Element text includes substring |
| `element_count` | `selector`, `count` | Number of matching elements |
| `console_errors` | `count` | Expected console error count (usually 0) |
| `response_status` | `endpoint`, `status` | HTTP response status code |
| `screenshot_match` | `baseline`, `threshold` | Visual comparison (visual tier) |
| `schema_valid` | `spec`, `endpoint` | Response matches OpenAPI/JSON Schema |
| `no_crash` | (none) | Page did not crash during interaction |

### Scenario Modes

**`execute`** (default): Run steps sequentially and validate expectations.

**`generate`**: Agent writes tests for target files instead of running pre-defined steps.

```yaml
scenario:
  name: "Generate auth tests"
  tier: unit
  mode: generate
  target_files:
    - "src/auth/login.ts"
    - "src/auth/session.ts"
  methodology: london           # london | detroit | property-based
  output_dir: "tests/generated/"
```

- `target_files` required — files to generate tests for
- `methodology` optional — defaults to `detroit` (classical TDD)
- `output_dir` validated against SAFE_PATH_PATTERN, restricted to `tmp/` or `tests/`

**`exploratory`**: Agent navigates freely within route, finds issues ad-hoc.

```yaml
scenario:
  name: "Exploratory: Dashboard edge cases"
  tier: e2e
  mode: exploratory
  route: "/dashboard"
  exploration_budget_ms: 120000   # 2 min exploration budget
  focus_areas:
    - "empty states"
    - "error handling"
    - "edge cases with special characters"
  expect:
    - type: console_errors
      count: 0
    - type: no_crash
```

- `route` required — starting URL path for exploration
- `exploration_budget_ms` required — time budget for free exploration
- Agent must stay on same origin and path prefix (URL scope restriction)
- No predefined steps — agent uses judgment based on `focus_areas`
- Results captured as discovered findings

## Teardown Actions

```yaml
teardown:
  - type: api_call
    method: DELETE
    url: "/api/test/cleanup"
  - type: run_command
    command: "npm run db:reset-test"
  - type: file_delete
    path: "tmp/test-config.json"
```

Teardown runs after scenario completion regardless of pass/fail status.

## Validation Rules

### Required Field Validation

- `name` must be unique across all scenario files in the project
- `tier` must be one of: `unit`, `integration`, `e2e`, `contract`, `visual`
- `tier: visual` routes to STEP 7 (E2E) with `visual_regression.enabled` force-set

### Pattern Validation

| Field | Pattern | Description |
|-------|---------|-------------|
| `triggers` | `SAFE_GLOB_PATTERN` | `/^[a-zA-Z0-9._\-\/\*\?]+$/` — extends SAFE_PATH_PATTERN for `*` and `?` |
| `exclude_triggers` | `SAFE_GLOB_PATTERN` | Same as triggers |
| `steps[].selector` | Selector allowlist | `/^[a-zA-Z0-9#._\-\[\]=:>"' @]+$/` (SEC-007) |
| `expect[].value` | Max length 1000 | Prevents payload injection via expectation values |
| `fixture paths` | `SAFE_PATH_PATTERN` | Relative only, no `..` — see fixture-protocol.md |
| `output_dir` | `SAFE_PATH_PATTERN` | Restricted to `tmp/` or `tests/` directories |

### Size Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max file size | 50KB per scenario file | Prevents DoS via large YAML |
| Max scenario files per run | 50 | Execution budget constraint |
| Max nesting depth | 10 levels | Prevents billion-laughs-style expansion |
| Max `expect[].value` length | 1000 chars | Injection prevention |

### YAML Parser Safety (SEC-001)

```
parseScenarioFile(filePath):
  // 1. Size check BEFORE parsing
  fileSize = stat(filePath).size
  if fileSize > 50 * 1024:  // 50KB
    reject("Scenario file exceeds 50KB limit")

  // 2. Safe load — reject all YAML tags
  raw = readFile(filePath)
  if raw.contains("!!"):
    reject("YAML tags (!! syntax) are not allowed in scenario files")

  // 3. Parse with safe loader
  parsed = yaml.safe_load(raw)  // Python: yaml.safe_load()
                                 // JS: yaml.parse() with strict mode

  // 4. Validate nesting depth
  if maxDepth(parsed) > 10:
    reject("YAML nesting exceeds 10 levels")

  // 5. Schema validation
  errors = validateSchema(parsed, TEST_SCENARIO_SCHEMA)
  if errors.length > 0:
    reject("Schema validation failed: ${errors}")

  return parsed.scenario
```

### Fixture Path Restrictions (SEC-003)

- All fixture paths MUST be relative (no leading `/`)
- No `..` path components allowed
- `file_create.path` restricted to `tmp/` or `tests/` directories
- SQL `source` restricted to `testing.fixtures.directory` config value
- `api_call.url` restricted to localhost only (SSRF prevention)
- `env_set.key` validated against sensitive variable blocklist

See [fixture-protocol.md](fixture-protocol.md) for full fixture security details.

### Dependency Validation

```
validateDependencies(scenarios):
  // Build dependency graph
  graph = {}
  for scenario in scenarios:
    graph[scenario.name] = scenario.depends_on ?? []

  // Detect cycles via topological sort
  if hasCycle(graph):
    reject("Circular dependency detected in scenario depends_on")

  // Validate all references exist
  allNames = scenarios.map(s => s.name)
  for scenario in scenarios:
    for dep in (scenario.depends_on ?? []):
      if dep not in allNames:
        reject("Scenario '${scenario.name}' depends on unknown scenario '${dep}'")
```

## Discovery Algorithm

STEP 0.5 discovers and validates scenarios before test execution:

```
discoverScenarios(diffFiles, talismanConfig):
  scenarioDir = talismanConfig.testing?.scenarios?.directory ?? ".rune/test-scenarios"
  if !exists(scenarioDir): return { scenarios: [], source: "none" }

  // 1. Glob all YAML files
  allFiles = glob(scenarioDir + "/**/*.yml") + glob(scenarioDir + "/**/*.yaml")
  if allFiles.length > MAX_SCENARIOS_PER_RUN (50):
    warn("Scenario cap reached, using first 50 by priority")

  // 2. Parse and validate each file
  scenarios = []
  for file in allFiles:
    parsed = parseScenarioFile(file)   // SEC-001 safe parsing
    if parsed is error:
      warn("Invalid scenario ${file}: ${parsed.error}. Skipping.")
      continue
    scenarios.push({ ...parsed, source_file: file })

  // 3. Validate cross-file constraints
  validateUniqueNames(scenarios)
  validateDependencies(scenarios)

  // 4. Diff-scoped filtering
  activeScenarios = scenarios.filter(s =>
    s.always_run === true ||
    s.triggers?.some(pattern => diffFiles.some(f => minimatch(f, pattern)))
  )

  // 5. Exclude-trigger filtering
  activeScenarios = activeScenarios.filter(s =>
    !s.exclude_triggers?.some(pattern =>
      diffFiles.every(f => minimatch(f, pattern))
    )
  )

  // 6. Risk-weighted sort
  RISK_WEIGHT = { high: 3, medium: 2, low: 1 }
  activeScenarios.sort((a, b) =>
    RISK_WEIGHT[b.risk ?? "medium"] - RISK_WEIGHT[a.risk ?? "medium"]
    || (a.priority ?? 99) - (b.priority ?? 99)
  )

  return { scenarios: activeScenarios, source: "yaml", total: allFiles.length }
```

## Example Scenarios

### E2E Login Flow

```yaml
scenario:
  name: "Login flow with valid credentials"
  tier: e2e
  tags: [auth, login, critical-path]
  risk: high
  priority: 1
  ac_ref: "AC-001"
  triggers:
    - "src/auth/**"
    - "src/components/LoginForm.*"
  preconditions:
    service_healthy: true
    fixtures:
      - type: sql
        source: "tests/fixtures/users.sql"
  steps:
    - action: navigate
      url: "/login"
    - action: wait
      condition: networkidle
    - action: fill
      selector: "#email"
      value: "test@example.com"
    - action: fill
      selector: "#password"
      value: "TestPassword123!"
    - action: click
      selector: "button[type=submit]"
    - action: wait
      condition: url_contains
      value: "/dashboard"
  expect:
    - type: url_contains
      value: "/dashboard"
    - type: element_visible
      selector: ".user-avatar"
    - type: console_errors
      count: 0
  teardown:
    - type: api_call
      method: DELETE
      url: "/api/test/cleanup"
```

### Unit Test Scenario

```yaml
scenario:
  name: "Auth module unit tests"
  tier: unit
  tags: [auth, unit]
  risk: medium
  triggers:
    - "src/auth/**"
  steps:
    - action: run_command
      command: "pytest tests/test_auth.py -v --tb=short"
  expect:
    - type: response_status
      endpoint: "test_runner"
      status: 0
```

### Contract Validation Scenario

```yaml
scenario:
  name: "Login API contract"
  tier: contract
  tags: [auth, api-contract]
  risk: high
  triggers:
    - "api/routes/auth.*"
    - "openapi.yaml"
  steps:
    - action: validate_schema
      endpoint: "POST /api/auth/login"
      spec: "openapi.yaml"
    - action: validate_schema
      endpoint: "POST /api/auth/register"
      spec: "openapi.yaml"
  expect:
    - type: schema_valid
      spec: "openapi.yaml"
      endpoint: "POST /api/auth/login"
```

### Exploratory Scenario

```yaml
scenario:
  name: "Exploratory: Dashboard edge cases"
  tier: e2e
  mode: exploratory
  route: "/dashboard"
  exploration_budget_ms: 120000
  focus_areas:
    - "empty states"
    - "error handling"
    - "edge cases with special characters"
  expect:
    - type: console_errors
      count: 0
    - type: no_crash
```
