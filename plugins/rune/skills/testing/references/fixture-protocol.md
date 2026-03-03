# Test Data Fixture Execution Protocol

Defines fixture types, execution order, security restrictions, teardown, and
idempotency requirements for scenario-declared test data setup.

## Fixture Types

Scenarios declare fixtures in `preconditions.fixtures`. Each fixture type has specific
execution semantics and security constraints.

| Type | Purpose | Runs Before | Security Level |
|------|---------|-------------|----------------|
| `sql` | Seed database with test data | Scenario steps | Medium — content not validated |
| `api_call` | Hit API endpoint for setup | Scenario steps | High — SSRF restriction |
| `file_create` | Create temporary files | Scenario steps | High — path restriction |
| `env_set` | Set environment variables | Scenario steps | High — blocklist enforcement |

## Execution Order

```
executeFixtures(scenario):
  // 1. Resolve fixture order from depends_on
  orderedScenarios = topologicalSort(allScenarios, scenario.depends_on)

  // 2. Execute dependency scenario fixtures first
  for dep in orderedScenarios:
    if dep.name !== scenario.name:
      executeFixtures(dep)

  // 3. Execute this scenario's fixtures in declaration order
  for fixture in (scenario.preconditions?.fixtures ?? []):
    validateFixture(fixture)        // Security checks
    result = executeFixture(fixture)
    if result.failed:
      warn("Fixture ${fixture.type} failed: ${result.error}")
      // Fixture failure = scenario skipped (not failed)
      return { success: false, reason: "fixture_setup_failed" }

  // 4. Proceed to scenario steps
  return { success: true }
```

Fixtures execute **before** scenario steps, **within** the test runner agent.
Declaration order is preserved — fixtures are not reordered or parallelized.

## Fixture Type Details

### `sql` — Database Seed Scripts

```yaml
preconditions:
  fixtures:
    - type: sql
      source: "tests/fixtures/users.sql"
```

**Execution**:

```
executeSqlFixture(fixture):
  // Validate source path
  if !SAFE_PATH_PATTERN.test(fixture.source):
    reject("Unsafe SQL fixture path: ${fixture.source}")

  // Restrict to fixture directory
  fixtureDir = talismanConfig.testing?.fixtures?.directory ?? "tests/fixtures"
  if !fixture.source.startsWith(fixtureDir):
    reject("SQL source must be within ${fixtureDir}")

  // Read and execute
  sql = Read(fixture.source)
  // Execute via project's DB tool (psql, mysql, sqlite3)
  Bash(`${dbCommand} < "${fixture.source}"`)
```

**Security notes**:
- SQL seed script **content** is NOT validated (documented risk — the seed file is
  committed to the repo and trusted at the same level as test code)
- Path restricted to `testing.fixtures.directory` (default: `tests/fixtures/`)
- Connection string sourced from talisman or environment variable — never from
  the scenario file

### `api_call` — HTTP API Setup

```yaml
preconditions:
  fixtures:
    - type: api_call
      method: POST
      url: "/api/test/seed"
      body: { "scenario": "login-test" }
```

**Execution**:

```
executeApiFixture(fixture):
  // SSRF prevention: restrict to localhost only
  baseUrl = talismanConfig.testing?.tiers?.e2e?.base_url ?? "http://localhost:3000"
  parsedBase = parseURL(baseUrl)

  if parsedBase.hostname !== "localhost" && parsedBase.hostname !== "127.0.0.1":
    reject("API fixtures restricted to localhost (SSRF prevention)")

  fullUrl = baseUrl + fixture.url

  // Validate URL stays on localhost after resolution
  resolved = parseURL(fullUrl)
  if resolved.hostname !== parsedBase.hostname:
    reject("API fixture URL resolved to non-localhost host")

  // Validate HTTP method before shell interpolation (SEC-P2-003)
  ALLOWED_METHODS = ["GET", "POST", "PUT", "DELETE", "PATCH"]
  if !ALLOWED_METHODS.includes(fixture.method.toUpperCase()):
    reject("Invalid HTTP method: ${fixture.method}")
  method = fixture.method.toUpperCase()

  // Execute HTTP call — pipe body via stdin to prevent shell injection (SEC-P2-002)
  bodyJson = JSON.stringify(fixture.body ?? {})
  Bash(`printf '%s' ${shellQuote(bodyJson)} | curl -s -X ${method} "${fullUrl}" -H "Content-Type: application/json" --data-binary @-`)
```

**Security notes**:
- `url` field MUST be a relative path — absolute URLs rejected
- Resolved URL MUST remain on localhost (prevents DNS rebinding)
- Only `GET`, `POST`, `PUT`, `DELETE`, `PATCH` methods allowed
- Response is logged but not parsed — fixtures are fire-and-forget setup

### `env_set` — Environment Variables

```yaml
preconditions:
  fixtures:
    - type: env_set
      key: "TEST_USER_EMAIL"
      value: "test@example.com"
```

**Execution**:

```
executeEnvFixture(fixture):
  // ENFORCEMENT NOTE (VEIL-005): This blocklist MUST be validated at runtime
  // by the test runner agent. Implementers SHOULD add a PreToolUse hook
  // (e.g., validate-fixture-env.sh) to enforce blocklist checks before
  // any env_set fixture executes. Without runtime enforcement, security
  // depends on agent compliance with this pseudocode.

  // Blocklist sensitive variables
  BLOCKED_ENV_VARS = [
    "PATH", "HOME", "USER", "SHELL",
    "CLAUDE_*",                         # All Claude env vars
    "ANTHROPIC_*",                      # Anthropic API keys and credentials
    "AWS_*",                            # AWS credentials
    "GITHUB_TOKEN", "GH_TOKEN",         # GitHub tokens
    "OPENAI_*",                         # OpenAI API keys and credentials
    "COHERE_*",                         # Cohere API keys
    "GEMINI_*",                         # Google Gemini API keys
    "AZURE_OPENAI_*",                   # Azure OpenAI credentials
    "HUGGINGFACE_*",                    # HuggingFace tokens
    "REPLICATE_*",                      # Replicate API tokens
    "*_SECRET", "*_SECRET_KEY",         # Framework secret keys (Django, Flask, Rails) (SEC-P2-004)
    "*_PRIVATE_KEY",                    # Signing/encryption private keys (SEC-P2-004)
    "*_PASSWORD", "*_PASSWD",           # Database and service passwords (SEC-P2-004)
    "*_ENCRYPTION_KEY",                 # Encryption keys (SEC-P2-004)
    "JWT_SECRET", "*_JWT_SECRET",       # JWT signing secrets (SEC-P2-004)
    "SESSION_SECRET", "*_SESSION_SECRET", # Session secrets (SEC-P2-004)
    "DATABASE_URL", "*_DATABASE_URL",   # Connection strings
    "NODE_ENV",                         # Runtime mode
    "FIGMA_ACCESS_TOKEN"                # Service tokens
  ]

  for pattern in BLOCKED_ENV_VARS:
    if pattern.startsWith("*") && pattern.endsWith("*"):
      // Infix match: *SUBSTRING* (not currently used, but defensive)
      infix = pattern.slice(1, -1)
      if fixture.key.includes(infix):
        reject("Cannot set blocked env var: ${fixture.key}")
    else if pattern.startsWith("*"):
      // Suffix match: *_SECRET, *_PASSWORD, etc. (SEC-P2-004)
      suffix = pattern.slice(1)
      if fixture.key.endsWith(suffix):
        reject("Cannot set blocked env var: ${fixture.key}")
    else if pattern.endsWith("*"):
      // Prefix match: CLAUDE_*, AWS_*, etc.
      prefix = pattern.slice(0, -1)
      if fixture.key.startsWith(prefix):
        reject("Cannot set blocked env var: ${fixture.key}")
    else:
      // Exact match
      if fixture.key === pattern:
        reject("Cannot set blocked env var: ${fixture.key}")

  // Validate key format
  if !/^[A-Z_][A-Z0-9_]*$/.test(fixture.key):
    reject("Invalid env var name: ${fixture.key}")

  // Store original value for teardown restore
  originalValue = process.env[fixture.key]
  process.env[fixture.key] = fixture.value

  return { restore: { key: fixture.key, originalValue } }
```

**Security notes**:
- Blocklist prevents overwriting security-critical variables
- Wildcard patterns (`CLAUDE_*`, `ANTHROPIC_*`, `AWS_*`, `OPENAI_*`, etc.) block entire credential prefixes
- Key format enforced: uppercase letters, digits, underscores only
- Original values saved for teardown restoration

### `file_create` — Temporary Files

```yaml
preconditions:
  fixtures:
    - type: file_create
      path: "tmp/test-config.json"
      content: { "feature_flag": true }
```

**Execution**:

```
executeFileFixture(fixture):
  // Path validation
  if !SAFE_PATH_PATTERN.test(fixture.path):
    reject("Unsafe file path: ${fixture.path}")

  // Must be relative (no leading /)
  if fixture.path.startsWith("/"):
    reject("File fixture path must be relative")

  // No path traversal
  if fixture.path.includes(".."):
    reject("Path traversal (..) not allowed in file fixtures")

  // Restrict to safe directories
  allowedPrefixes = ["tmp/", "tests/"]
  if !allowedPrefixes.some(p => fixture.path.startsWith(p)):
    reject("File fixtures restricted to tmp/ or tests/ directories")

  // Write file
  content = typeof fixture.content === "object"
    ? JSON.stringify(fixture.content, null, 2)
    : String(fixture.content)

  Write(fixture.path, content)

  return { cleanup: fixture.path }
```

**Security notes**:
- Path restricted to `tmp/` or `tests/` only — prevents writing to production code
- No path traversal (`..`) components
- Relative paths only — no absolute paths
- Matches existing `SAFE_PATH_PATTERN` convention

## Teardown Protocol

Teardown runs after scenario completion, **regardless of pass/fail status**:

```
executeTeardown(scenario, fixtureState):
  // 1. Run scenario-declared teardown actions
  for action in (scenario.teardown ?? []):
    try:
      executeTeardownAction(action)
    catch error:
      warn("Teardown action failed: ${error}. Continuing cleanup.")

  // 2. Restore environment variables
  for restore in fixtureState.envRestores:
    if restore.originalValue !== undefined:
      process.env[restore.key] = restore.originalValue
    else:
      delete process.env[restore.key]

  // 3. Remove created files
  for filePath in fixtureState.createdFiles:
    Bash(`rm -f "${filePath}" 2>/dev/null`)
```

### Teardown Action Types

```yaml
teardown:
  - type: api_call
    method: DELETE
    url: "/api/test/cleanup"        # Same localhost restriction as fixture api_call

  - type: run_command
    command: "npm run db:reset-test" # Validated against SAFE_TEST_COMMAND_PATTERN + ALLOWED_TEARDOWN_PREFIXES

  - type: file_delete
    path: "tmp/test-config.json"    # Same path restrictions as file_create
```

Teardown actions use the same security validation as their fixture counterparts.

**`run_command` defense-in-depth** (SEC-P2-005): `SAFE_TEST_COMMAND_PATTERN` (`/^[a-zA-Z0-9._\-\/ ]+$/`)
blocks shell metacharacters but still allows destructive alphanumeric commands. Implementers
SHOULD additionally validate commands against an allowlist of known test-runner prefixes:

```
ALLOWED_TEARDOWN_PREFIXES = [
  "npm run ", "npx ", "yarn ", "pnpm ",   # Node.js package runners
  "pytest ", "python -m pytest ",          # Python test runners
  "cargo test", "cargo run ",             # Rust test runners
  "bundle exec ", "rails ",               # Ruby runners
  "make ", "go test"                      # Build system / Go runners
]

if !ALLOWED_TEARDOWN_PREFIXES.some(p => command.startsWith(p)):
  reject("Teardown command does not match allowed test-runner prefixes")
```

Since teardown commands come from committed scenario YAML files (same trust level as test
code), the allowlist is a defense-in-depth measure — not a primary security boundary.

## Idempotency Requirements

For checkpoint/resume compatibility, fixtures MUST be idempotent:

| Type | Idempotency Strategy |
|------|---------------------|
| `sql` | Use `INSERT ... ON CONFLICT DO NOTHING` or `CREATE TABLE IF NOT EXISTS` |
| `api_call` | Seed endpoints should handle duplicate calls gracefully |
| `file_create` | Overwrite existing file (Write() is naturally idempotent) |
| `env_set` | Set is naturally idempotent |

When resuming from a checkpoint, the runner:
1. Runs teardown for the last completed scenario (clean state)
2. Runs fixtures for the next scenario (idempotent re-setup)
3. Proceeds with scenario steps

This ensures fixtures produce consistent state even if the previous run was interrupted
mid-fixture-execution.

## Integration with Scenario Dependencies

When a scenario has `depends_on`, fixture execution follows dependency order:

```
scenario:
  name: "checkout-flow"
  depends_on: ["user-registration", "add-to-cart"]
  preconditions:
    fixtures:
      - type: api_call
        method: POST
        url: "/api/test/seed-payment"
```

Execution order:
1. `user-registration` fixtures (if not already run)
2. `add-to-cart` fixtures (if not already run)
3. `checkout-flow` fixtures
4. `checkout-flow` steps

Dependency fixtures are tracked to avoid redundant execution within the same test run.

## Security Summary

| Fixture Type | Risk | Mitigation |
|-------------|------|------------|
| `sql` | SQL injection via seed script | Content trusted (committed code), path restricted to fixture directory |
| `api_call` | SSRF via URL field, command injection via body/method | Localhost-only restriction, relative paths only, DNS rebinding check, method allowlist validation, body piped via stdin (not interpolated) |
| `env_set` | Environment injection | Agent-enforced blocklist (advisory — no runtime hook enforcement). Sensitive vars blocked: PATH, HOME, CLAUDE_*, ANTHROPIC_*, AWS_*, *_SECRET*, *_PRIVATE_KEY, *_PASSWORD, *_ENCRYPTION_KEY, *_JWT_SECRET, *_SESSION_SECRET, tokens. Implement `validate-fixture-env.sh` PreToolUse hook for hard enforcement |
| `file_create` | Path traversal, code overwrite | SAFE_PATH_PATTERN, relative only, no `..`, restricted to tmp/ or tests/ |
