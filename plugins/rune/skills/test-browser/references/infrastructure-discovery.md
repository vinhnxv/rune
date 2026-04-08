# Step 0.5: Infrastructure Discovery

Detects project infrastructure (Docker Compose, tunnels, proxies) and discovers test
credentials before route discovery begins. Runs once per test session and writes results
to the workspace for downstream steps.

**Contract**:
```
Input:  Project directory with docker-compose.yml, .env, CLAUDE.local.md
Output: {
  base_url: "http://localhost:8080",
  credentials: { email: "test@example.com", password: "pass123" },
  credential_source: ".env.local",
  infrastructure: {
    docker_compose: { found: true, file: "docker-compose.yml", services: [...] },
    tunnel: { found: false },
    proxy: { found: false }
  }
}
```

## Infrastructure Discovery Algorithm

```
discoverInfrastructure() → InfraResult

  result = { base_url: null, credentials: null, credential_source: null, infrastructure: {} }

  // ═══════════════════════════════════════════
  // 1. Docker Compose Detection
  // ═══════════════════════════════════════════
  // Detect Compose v1 and v2 short names, plus override files
  composeFiles = Glob("docker-compose.yml")
    + Glob("compose.yml")
    + Glob("docker-compose.*.yml")
    + Glob("compose.*.yml")
    + Glob("compose.override.yml")

  if composeFiles.length > 0:
    composeContent = Read(composeFiles[0])
    services = parseComposeServices(composeContent)

    // Find the primary web-facing service
    webService = services.find(s =>
      s.name.match(/web|app|frontend|nginx|next|nuxt|vite|react/) ||
      s.ports?.some(p => p.host <= 9000)
    )
    if webService and webService.ports:
      result.base_url = `http://localhost:${webService.ports[0].host}`

    // Extract environment variables that look like test credentials
    for each service in services:
      envVars = service.environment ?? {}
      for each [key, value] in envVars:
        if key.match(/EMAIL|USERNAME|USER|LOGIN/i):
          result.credentials = result.credentials ?? {}
          result.credentials.email = result.credentials.email ?? value
        if key.match(/PASSWORD|PASS|SECRET/i) and not key.match(/DB_|DATABASE_|REDIS_|AWS_|API_|SMTP_|MAIL_|S3_|GCS_|FIREBASE_|STRIPE_|JWT_|TOKEN_|HASH_|SALT_|ENCRYPTION_/i):
          result.credentials = result.credentials ?? {}
          result.credentials.password = result.credentials.password ?? value

    result.infrastructure.docker_compose = {
      found: true,
      file: composeFiles[0],
      services: services.map(s => s.name)
    }
  else:
    result.infrastructure.docker_compose = { found: false }

  // ═══════════════════════════════════════════
  // 2. Tunnel Detection (Cloudflare, ngrok)
  // ═══════════════════════════════════════════

  // --- Cloudflare Tunnel ---
  cfConfigs = Glob(".cloudflare/**/*") + Glob("cloudflared.yml") + Glob(".cloudflared/*")
  if cfConfigs.length > 0:
    cfContent = Read(cfConfigs[0])
    // Parse tunnel URL from ingress rules or hostname field
    tunnelUrl = parseCloudflareTunnelUrl(cfContent)
    if tunnelUrl:
      result.base_url = result.base_url ?? tunnelUrl
    result.infrastructure.tunnel = { found: true, type: "cloudflare", config: cfConfigs[0] }

  // --- ngrok (config file) ---
  ngrokConfigs = Glob("ngrok.yml") + Glob(".ngrok*") + Glob("ngrok.yaml")
  if ngrokConfigs.length > 0:
    ngrokContent = Read(ngrokConfigs[0])
    // Parse addr field for local port
    ngrokUrl = parseNgrokConfig(ngrokContent)
    if ngrokUrl:
      result.base_url = result.base_url ?? ngrokUrl
    result.infrastructure.tunnel = { found: true, type: "ngrok", config: ngrokConfigs[0] }

  // --- ngrok (running process) ---
  ngrokRunning = Bash("pgrep -x ngrok 2>/dev/null || true").trim()
  if ngrokRunning:
    ngrokApi = Bash("curl -s http://localhost:4040/api/tunnels 2>/dev/null || true").trim()
    if ngrokApi:
      publicUrl = parseNgrokApiUrl(ngrokApi)
      if publicUrl:
        result.base_url = result.base_url ?? publicUrl
        result.infrastructure.tunnel = { found: true, type: "ngrok", source: "running_process" }

  if not result.infrastructure.tunnel:
    result.infrastructure.tunnel = { found: false }

  // ═══════════════════════════════════════════
  // 3. Proxy Detection (nginx, caddy, traefik)
  // ═══════════════════════════════════════════
  proxyConfigs = Glob("nginx.conf") + Glob("Caddyfile") + Glob("traefik.yml")
    + Glob("**/nginx/*.conf") + Glob("**/caddy/*")

  if proxyConfigs.length > 0:
    proxyContent = Read(proxyConfigs[0])
    // Extract upstream/proxy_pass URLs — informational only
    proxyUrl = parseProxyUpstream(proxyContent)
    result.infrastructure.proxy = {
      found: true,
      type: detectProxyType(proxyConfigs[0]),
      config: proxyConfigs[0]
    }
    // NOTE: Don't override base_url — proxy config shows the origin, not the test target
  else:
    result.infrastructure.proxy = { found: false }

  // ═══════════════════════════════════════════
  // 4. Credential Discovery
  // ═══════════════════════════════════════════
  // Priority order: project-local overrides first, then env files
  credentialSources = [
    ".claude/CLAUDE.local.md",
    "CLAUDE.md",
    ".claude/CLAUDE.md",
    ".env.test",
    ".env.local",
    ".env"
  ]

  for each source in credentialSources:
    if not fileExists(source): continue
    content = Read(source)

    // --- Markdown files: free-form credential patterns ---
    if source.endsWith(".md"):
      // Common patterns:
      //   "Test credentials: email@test.com / password123"
      //   "Login: admin@example.com, Password: secret"
      //   "## Test Account\n- email: test@test.com\n- password: test123"
      emailMatch = content.match(/(?:email|login|username|user)[:\s]+([^\s,]+@[^\s,]+)/i)
      passMatch = content.match(/(?:password|pass)[:\s]+([^\s,\n]+)/i)
      if emailMatch:
        result.credentials = result.credentials ?? {}
        result.credentials.email = result.credentials.email ?? emailMatch[1]
      if passMatch:
        result.credentials = result.credentials ?? {}
        result.credentials.password = result.credentials.password ?? passMatch[1]

    // --- .env files: KEY=VALUE format ---
    if source.startsWith(".env"):
      for each line in content.split("\n"):
        if line.match(/^(TEST_|DEMO_|SEED_)?(EMAIL|USERNAME|USER)=/i):
          result.credentials = result.credentials ?? {}
          result.credentials.email = result.credentials.email ?? line.split("=")[1].trim().replace(/['"]/g, "")
        if line.match(/^(TEST_|DEMO_|SEED_)?(PASSWORD|PASS)=/i):
          result.credentials = result.credentials ?? {}
          result.credentials.password = result.credentials.password ?? line.split("=")[1].trim().replace(/['"]/g, "")

    // Stop early once we have complete credentials
    if result.credentials?.email and result.credentials?.password:
      result.credential_source = source
      break

  // ═══════════════════════════════════════════
  // 4.1 Credential Sanitization
  // ═══════════════════════════════════════════
  // SEC: NEVER include raw credential values in test-plan.md or logs
  // Mask credentials in any output: result.credentials.password = "****" for display
  // Only pass raw values to agent-browser fill commands (never to Write/log)

  // ═══════════════════════════════════════════
  // 5. Base URL Fallback
  // ═══════════════════════════════════════════
  if not result.base_url:
    // Check talisman config, then fall back to conventional default
    result.base_url = testingConfig?.testing?.tiers?.e2e?.base_url ?? "http://localhost:3000"

  // ═══════════════════════════════════════════
  // 6. Base URL Normalization
  // ═══════════════════════════════════════════
  // agent-browser may not resolve 0.0.0.0 — normalize to localhost
  result.base_url = result.base_url.replace("0.0.0.0", "localhost")
  // Strip trailing slashes to prevent double-slash in route concatenation
  result.base_url = result.base_url.replace(/\/+$/, "")
  // Ensure scheme prefix
  if not result.base_url.match(/^https?:\/\//):
    result.base_url = "http://" + result.base_url

  // ═══════════════════════════════════════════
  // 7. Credential Security Rules
  // ═══════════════════════════════════════════
  // SEC: NEVER log credential values in reports or console output.
  // Only log the SOURCE (e.g., "Credentials found in .env.local").
  // In infrastructure.md output, write: "Credentials: found (source: .env.local)" — never actual values.
  // Credentials are passed ONLY to agent-browser fill commands via sessionState.
  // sensitive-patterns.sh (plugins/rune/scripts/lib/) defines the SEC boundary.

  return result
```

## Docker Compose Port Parsing

```
parseComposeServices(content) → Service[]

  // Detect v1 (services at root) vs v2/v3 (under services: key)
  // If top-level keys include "version:" or "services:", treat as v2/v3
  servicesBlock = content.services ?? content  // v1 fallback

  services = []
  for each [name, config] in servicesBlock:
    service = { name: name, ports: [], environment: {} }

    // --- Port parsing: handle ALL Docker Compose formats ---
    for each portEntry in (config.ports ?? []):

      // Long syntax (v3.2+): mapping with target/published keys
      if typeof portEntry == "object":
        service.ports.push({
          host: portEntry.published,
          container: portEntry.target
        })
        continue

      // Short syntax: string format
      port = String(portEntry)

      // Strip protocol suffix: "8080:80/tcp" → "8080:80"
      port = port.split("/")[0]

      parts = port.split(":")
      if parts.length == 3:
        // "127.0.0.1:8080:80" → bind address format, take second element
        service.ports.push({ host: parseInt(parts[1]), container: parseInt(parts[2]) })
      else if parts.length == 2:
        // "8080:80" → host:container
        host = parts[0]
        container = parts[1]
        // Handle ranges: "8080-8090:80-90" → take first number
        if host.includes("-"):
          log WARN: "Port range detected (${port}) — using first port in range"
          host = host.split("-")[0]
          container = container.split("-")[0]
        service.ports.push({ host: parseInt(host), container: parseInt(container) })
      else if parts.length == 1:
        // "8080" → same host and container
        p = parseInt(parts[0])
        service.ports.push({ host: p, container: p })

    // --- Environment parsing ---
    env = config.environment
    if Array.isArray(env):
      // List format: ["KEY=VALUE", ...]
      for each entry in env:
        [k, ...rest] = entry.split("=")
        service.environment[k] = rest.join("=")
    else if typeof env == "object":
      // Map format: { KEY: VALUE }
      service.environment = env

    services.push(service)

  return services
```

## Tunnel URL Parsers

```
parseCloudflareTunnelUrl(content) → string | null

  // Cloudflare config typically has:
  //   ingress:
  //     - hostname: app.example.com
  //       service: http://localhost:8080
  //     - service: http_status:404
  // OR:
  //   tunnel: <uuid>
  //   credentials-file: ...

  if content.ingress:
    for each rule in content.ingress:
      if rule.hostname and rule.service and rule.service != "http_status:404":
        return `https://${rule.hostname}`

  return null


parseNgrokConfig(content) → string | null

  // ngrok.yml format:
  //   tunnels:
  //     app:
  //       proto: http
  //       addr: 8080
  //   OR (v3):
  //   endpoints:
  //     - name: app
  //       upstream:
  //         url: 8080

  if content.tunnels:
    for each [name, tunnel] in content.tunnels:
      if tunnel.addr:
        port = String(tunnel.addr).replace(/^https?:\/\//, "").split(":").pop()
        return `http://localhost:${port}`

  if content.endpoints:
    for each endpoint in content.endpoints:
      if endpoint.upstream?.url:
        return `http://localhost:${endpoint.upstream.url}`

  return null


parseNgrokApiUrl(apiResponse) → string | null

  // ngrok local API response:
  //   { "tunnels": [{ "public_url": "https://abc123.ngrok.io", "proto": "https", ... }] }

  parsed = JSON.parse(apiResponse)
  if parsed?.tunnels?.length > 0:
    // Prefer https tunnel
    httpsTunnel = parsed.tunnels.find(t => t.proto == "https")
    return httpsTunnel?.public_url ?? parsed.tunnels[0].public_url

  return null
```

## Proxy Detection

```
detectProxyType(configPath) → "nginx" | "caddy" | "traefik" | "unknown"

  lower = configPath.toLowerCase()
  if lower.includes("nginx"):   return "nginx"
  if lower.includes("caddy"):   return "caddy"
  if lower.includes("traefik"): return "traefik"
  return "unknown"


parseProxyUpstream(content) → string | null

  // nginx: proxy_pass http://localhost:3000;
  // caddy: reverse_proxy localhost:3000
  // traefik: url: "http://localhost:3000"

  // nginx
  match = content.match(/proxy_pass\s+(https?:\/\/[^;\s]+)/i)
  if match: return match[1]

  // caddy
  match = content.match(/reverse_proxy\s+([\w.:\/]+)/i)
  if match:
    target = match[1]
    if not target.match(/^https?:\/\//): target = "http://" + target
    return target

  // traefik
  match = content.match(/url:\s*["']?(https?:\/\/[^"'\s]+)/i)
  if match: return match[1]

  return null
```

## Workspace Output

After discovery completes, write results to the session workspace for downstream steps.

```
writeInfrastructureReport(result, workspacePath)

  // Determine base_url source for reporting
  urlSource = "default"
  if result.infrastructure.docker_compose?.found: urlSource = "docker-compose"
  else if result.infrastructure.tunnel?.found: urlSource = "tunnel"
  else if result.base_url != "http://localhost:3000": urlSource = "talisman"

  report = `# Infrastructure Discovery

## Base URL
${result.base_url} (source: ${urlSource})

## Credentials
${result.credentials ? `found (source: ${result.credential_source})` : "not found"}

## Docker Compose
${result.infrastructure.docker_compose?.found
  ? `yes — file: ${result.infrastructure.docker_compose.file}, services: [${result.infrastructure.docker_compose.services.join(", ")}]`
  : "not detected"}

## Tunnel
${result.infrastructure.tunnel?.found
  ? `${result.infrastructure.tunnel.type} (config: ${result.infrastructure.tunnel.config ?? result.infrastructure.tunnel.source ?? "N/A"})`
  : "not detected"}

## Proxy
${result.infrastructure.proxy?.found
  ? `${result.infrastructure.proxy.type} (config: ${result.infrastructure.proxy.config})`
  : "not detected"}
`

  Write(`${workspacePath}/infrastructure.md`, report)
```
