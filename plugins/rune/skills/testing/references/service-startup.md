# Service Startup Protocol

## Auto-Detection Strategy (v1)

```
Detection order (first match wins):

1. docker-compose.yml / compose.yml exists
   → T3 path traversal guard: canonicalize path before use
     composePath = Bash(`realpath --relative-base="$(pwd)" docker-compose.yml 2>/dev/null || realpath --relative-base="$(pwd)" compose.yml 2>/dev/null`)
     if composePath starts with "/" or contains ".." → reject with error ("Docker Compose path traversal detected")
   → docker compose up -d --wait
   → Hard timeout: 3 minutes

2. talisman.testing.service.startup_command is set
   → Validate: must match SAFE_TEST_COMMAND_PATTERN (/^[a-zA-Z0-9._\-\/ ]+$/)
   → Reject with error if validation fails (command injection prevention)
   → Run the validated command with quoted variable: Bash(`"${startup_command}"`)
   → Example: "bin/dev", "npm run dev"

3. package.json scripts contains "dev" or "start"
   → npm run dev (background) OR npm start (background)

4. Makefile contains "serve" or "dev" target
   → make dev (background)

5. Nothing found
   → WARN: "No service startup detected. Services may already be running."
   → Skip STEP 3 entirely — proceed to tests
```

## Health Check Protocol

```
After service startup, verify readiness:

1. Determine health endpoint:
   - /health, /healthz, /api/health (try in order)
   - Or: talisman.testing.tiers.e2e.base_url + /health

2. Poll loop:
   - HTTP GET to health endpoint
   - Interval: 2 seconds
   - Max attempts: 30 (= 60s total)
   - Success: any HTTP 2xx response
   - Timeout: skip integration/E2E tiers, unit still runs

3. On timeout:
   - Capture diagnostic: docker compose logs (last 50 lines)
   - Write to test report as WARN
   - Unit tests still execute (they don't need services)
```

## Snapshot Verification

After health check passes, perform a lightweight browser-level verification to confirm
the server returns a real, non-error page. This catches misconfigured apps that respond
HTTP 200 on `/health` but serve blank/error pages to real users.

```
verifyServerWithSnapshot(baseUrl, sessionName) → "ok" | "blank" | "error" | "loading"

  // Open a throwaway browser session and take a text snapshot
  session = sessionName || "startup-verify-" + Date.now()
  Bash(`agent-browser --session "${session}" open "${baseUrl}" --timeout 15s 2>/dev/null`)
  Bash(`agent-browser wait --load networkidle --timeout 5s 2>/dev/null || true`)
  snapshotText = Bash(`agent-browser snapshot --text 2>/dev/null || echo ""`)

  // Clean up throwaway session immediately
  Bash(`agent-browser close --session "${session}" 2>/dev/null || true`)

  // Classify snapshot content
  if snapshotText is empty or blank:
    return "blank"

  blanks  = [/^\s*$/, /no content/i, /empty page/i]
  errors  = [/internal server error/i, /500/i, /application error/i, /something went wrong/i,
             /unhandled exception/i, /stack trace:/i, /syntax error/i]
  loading = [/loading\.{3}/i, /please wait/i, /initializing/i]

  if any errors pattern matches snapshotText:
    return "error"
  if any loading pattern matches snapshotText:
    return "loading"
  if any blanks pattern matches snapshotText:
    return "blank"

  return "ok"
```

### Integration into Service Startup

```
startServices(testingConfig) → { healthy, dockerStarted }

  // ... existing startup steps ...

  if health check passes:
    // Snapshot verification (requires agent-browser)
    agentBrowserAvailable = Bash("agent-browser --version 2>/dev/null && echo yes || echo no").trim() == "yes"
    if agentBrowserAvailable:
      baseUrl = testingConfig.tiers?.e2e?.base_url ?? "http://localhost:3000"
      verifyResult = verifyServerWithSnapshot(baseUrl, "arc-startup-verify-{id}")

      // Framework-specific failure instructions
      FRAMEWORK_HINTS = {
        "next.js":    "Check: `npm run dev` output, or run `npx next dev` to see build errors",
        "rails":      "Check: `bin/rails server` output. Missing migrations? `bin/rails db:migrate`",
        "django":     "Check: `python manage.py runserver` output. Missing migrations? `python manage.py migrate`"
      }
      detectedFramework = detectFrameworkName()  // from test-discovery.md detect_test_framework()

      if verifyResult != "ok":
        hint = FRAMEWORK_HINTS[detectedFramework] ?? "Check your server logs for startup errors."
        message = "Server returned ${verifyResult} page at ${baseUrl}. ${hint}"

        // Mode-dependent behavior
        if standalone:
          // Abort with instructions — user can fix and retry
          throw new Error(`Startup verification failed: ${message}`)
        else:
          // Arc mode: advisory only — do not block the pipeline
          warn(`WARN: Startup verification: ${message}. Proceeding with tests — E2E results may be unreliable.`)

  return { healthy, dockerStarted }
```

**Key behavioral difference**:
- **Arc mode** (`standalone=false`): verification failure logs a WARN and proceeds — the pipeline must not stall
- **Standalone mode** (`standalone=true`): verification failure aborts with user instructions for self-service recovery

## Docker-Specific Patterns

### Startup
```bash
# Preferred (Docker Compose v2 with --wait)
docker compose up -d --wait

# Fallback (older Docker)
docker compose up -d
# Then poll health checks manually
```

### Health Checks in docker-compose.yml
```yaml
services:
  postgres:
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres}"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s

  redis:
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 3s
      timeout: 2s
      retries: 5

  app:
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
```

### Container ID Recording
```bash
# Record for crash recovery
docker compose ps --format json > tmp/arc/{id}/docker-containers.json
```

### Cleanup
```bash
# Normal cleanup
docker compose down --timeout 10 --remove-orphans

# Fallback: kill by container IDs
docker kill $(jq -r '.[].ID' "tmp/arc/${id}/docker-containers.json") 2>/dev/null

# Nuclear: remove volumes too
docker compose down -v --timeout 10 --remove-orphans
```

## Startup Timeout Budgets

| Service | Typical cold start | Recommended timeout |
|---------|--------------------|---------------------|
| PostgreSQL | 3-8s | 30s |
| Redis | 1-3s | 15s |
| Node.js app | 5-15s | 60s |
| Full stack (compose up) | 15-40s | 120s |

## Port Detection

```bash
# From docker-compose.yml
docker compose config --format json | jq '.services[].ports[]'

# From talisman
# talisman.testing.tiers.e2e.base_url → extract port

# From package.json (heuristic)
grep -o 'PORT=[0-9]*' package.json || echo "3000"
```

## Graceful Degradation

If service startup fails at any point:
1. Log the failure diagnostic to test report
2. Skip integration and E2E tiers
3. Unit tests still run (they use mocks, no service dependency)
4. Phase 7.7 still produces a useful report (partial coverage)
