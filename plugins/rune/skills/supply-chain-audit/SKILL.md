---
name: supply-chain-audit
description: |
  Analyze project dependencies for supply chain risks. Checks maintainer count,
  commit frequency, CVE history, abandonment signals, bus factor, and security
  policy presence for each direct dependency. Supports npm, pip, cargo, go mod,
  and composer.
  Use when: "supply chain audit", "dependency risk", "check dependencies",
  "maintainer risk", "abandoned packages", "dependency health",
  "package security", "supply chain risk".
user-invocable: true
---

# Supply Chain Audit

Standalone skill for analyzing the supply chain threat landscape of a project's direct dependencies.

**Load skills**: `zsh-compat`

## Usage

```bash
/rune:supply-chain-audit                    # Auto-detect package manager, analyze all
/rune:supply-chain-audit --max 20           # Limit to 20 dependencies
/rune:supply-chain-audit --manager npm      # Force specific package manager
```

## Flags

| Flag | Effect |
|------|--------|
| `--max N` | Maximum dependencies to analyze (default: 50, from talisman) |
| `--manager TYPE` | Force package manager: npm, pip, cargo, go, composer |

## Workflow

```javascript
const args = "$ARGUMENTS".trim()
const maxFlag = args.match(/--max\s+(\d+)/)
const managerFlag = args.match(/--manager\s+(\w+)/)

// Read talisman config
// readTalismanSection: "misc"
const talismanMisc = readTalismanSection("misc") ?? {}
const supplyChainConfig = talismanMisc.supply_chain ?? {}

if (supplyChainConfig.enabled === false) {
  log("Supply chain audit is disabled in talisman. Set supply_chain.enabled: true to enable.")
  return
}

const maxDeps = maxFlag ? parseInt(maxFlag[1]) : (supplyChainConfig.max_dependencies ?? 50)
const riskThreshold = supplyChainConfig.risk_threshold ?? "medium"

// Step 1: Auto-detect package manager
const manifests = {
  npm: "package.json",
  pip: ["requirements.txt", "pyproject.toml"],
  cargo: "Cargo.toml",
  go: "go.mod",
  composer: "composer.json"
}

let detectedManagers = []
if (managerFlag) {
  detectedManagers = [managerFlag[1]]
} else {
  // Scan for manifest files
  for (const [manager, files] of Object.entries(manifests)) {
    const fileList = Array.isArray(files) ? files : [files]
    for (const f of fileList) {
      if (Glob(f).length > 0) {
        detectedManagers.push(manager)
        break
      }
    }
  }
}

if (detectedManagers.length === 0) {
  log("No package manifest files found. Supply chain audit requires package.json, requirements.txt, Cargo.toml, go.mod, or composer.json.")
  return
}

log(`Detected package managers: ${detectedManagers.join(", ")}`)

// Step 2: Extract dependencies per manager
let allDeps = []

for (const manager of detectedManagers) {
  let deps = []
  switch (manager) {
    case "npm":
      // Read package.json, extract .dependencies keys
      const pkg = JSON.parse(Read("package.json"))
      deps = Object.keys(pkg.dependencies || {}).map(name => ({
        name, version: pkg.dependencies[name], manager: "npm"
      }))
      break
    case "pip":
      // Read requirements.txt, strip version specifiers
      const reqFile = Glob("requirements.txt").length > 0 ? "requirements.txt" : null
      if (reqFile) {
        const lines = Read(reqFile).split("\n")
          .filter(l => l.trim() && !l.startsWith("#") && !l.startsWith("-"))
          .map(l => ({ name: l.replace(/[>=<!\[].*$/, "").trim(), version: "*", manager: "pip" }))
        deps = lines
      }
      break
    case "cargo":
      // Parse Cargo.toml [dependencies]
      const cargoContent = Read("Cargo.toml")
      const depSection = cargoContent.match(/\[dependencies\]([\s\S]*?)(?:\[|$)/)?.[1] || ""
      deps = depSection.split("\n")
        .filter(l => l.includes("="))
        .map(l => ({ name: l.split("=")[0].trim().replace(/"/g, ""), version: l.split("=")[1]?.trim(), manager: "cargo" }))
      break
    case "go":
      // Parse go.mod require block
      const goContent = Read("go.mod")
      const requireBlock = goContent.match(/require \(([\s\S]*?)\)/)?.[1] || ""
      deps = requireBlock.split("\n")
        .filter(l => l.trim())
        .map(l => {
          const parts = l.trim().split(/\s+/)
          return { name: parts[0], version: parts[1], manager: "go" }
        })
      break
    case "composer":
      const composer = JSON.parse(Read("composer.json"))
      deps = Object.keys(composer.require || {})
        .filter(n => n !== "php" && !n.startsWith("ext-"))
        .map(name => ({ name, version: composer.require[name], manager: "composer" }))
      break
  }
  allDeps = allDeps.concat(deps)
}

// Cap at maxDeps
if (allDeps.length > maxDeps) {
  log(`Found ${allDeps.length} dependencies, capping at ${maxDeps}`)
  allDeps = allDeps.slice(0, maxDeps)
}

log(`Analyzing ${allDeps.length} dependencies...`)

// Step 3: For each dependency, query registry + GitHub for risk signals
// Uses gh api for GitHub data, npm view / curl for registry data
// Scores across 6 risk dimensions per the supply-chain-sentinel agent protocol

// Step 4: Generate structured risk report
// Output format matches supply-chain-sentinel output with risk summary table

// Step 5: For P1/P2 findings, suggest alternatives via WebSearch (if available)

// Present final report to user
```

## Risk Dimensions

| Dimension | Weight | P1 Threshold | P2 Threshold | P3 Threshold |
|-----------|--------|-------------|-------------|-------------|
| Maintainer count | 25% | 0-1 maintainers | 2-3 maintainers | — |
| Last commit date | 25% | >24 months | 12-24 months | 6-12 months |
| CVE history | 20% | Unpatched CVEs | 3+ CVEs/2yr | 1-2 CVEs/2yr |
| Download trajectory | 10% | — | >50% decline | >25% decline |
| Bus factor | 10% | >90% single | >70% single | >50% single |
| Security policy | 10% | — | — | Missing SECURITY.md |

## Severity Mapping

- **P1 (Critical)**: Abandoned package with known CVEs, or composite score >= 0.7
- **P2 (High)**: Single maintainer, or abandoned (>12mo), or composite score >= 0.4
- **P3 (Medium)**: Weak signals only, composite score >= 0.2

## Output

The skill produces a formatted risk report directly in the conversation with:
- Risk summary table (all dependencies)
- Detailed findings for P1/P2/P3 dependencies
- Alternative package suggestions for high-risk dependencies
- Packages that could not be analyzed (API failures)

## Talisman Configuration

```yaml
# .rune/talisman.yml
supply_chain:
  enabled: true              # Enable supply chain analysis
  max_dependencies: 50       # Cap on dependencies to analyze
  risk_threshold: "medium"   # Minimum risk level to report: low|medium|high
  registries:                # Override registry API endpoints (optional)
    npm: "https://registry.npmjs.org"
    pypi: "https://pypi.org/pypi"
```

## Error Handling

| Error | Recovery |
|-------|----------|
| `gh` CLI not available | Fall back to unauthenticated API calls (60 req/hr limit) |
| Registry API failure | Mark dependency as UNCERTAIN, continue with others |
| GitHub API rate limit | Stop GitHub queries, report partial results |
| No manifest files found | Report and exit gracefully |
| Private/scoped packages | Skip with note (cannot query public registries) |
