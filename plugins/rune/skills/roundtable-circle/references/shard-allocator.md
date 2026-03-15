# Shard Allocator — Domain-Affinity File Partitioning

> Partitions `classifiedFiles` into non-overlapping shards for parallel review.
> Called from SKILL.md Phase 1 when `totalFiles > SHARD_THRESHOLD` and `scope === "diff"`.
> Returns `null` below threshold (standard review path unchanged).

## Algorithm

```
Input:  classifiedFiles[]  — output of Rune Gaze Phase 1 (sorted by risk tier when Lore Layer active)
        config              — { SHARD_SIZE, MAX_SHARDS, MODEL_POLICY }
Output: shards[]            — array of { shard_id, files[], domains, primary_domain, model }
        OR null             — when below threshold (standard review)
```

### Constants (from talisman or defaults)

```javascript
const SHARD_THRESHOLD = talisman?.review?.shard_threshold ?? 15
const SHARD_SIZE      = talisman?.review?.shard_size      ?? 12
const MAX_SHARDS      = talisman?.review?.max_shards      ?? 5
const MODEL_POLICY    = talisman?.review?.shard_model_policy ?? "auto"

// Threshold gate — standard review for small diffs
if (classifiedFiles.length <= SHARD_THRESHOLD) return null
```

### Step 1: Domain Group Assignment

```javascript
const groups = {
  security_critical: [],   // .claude/**, auth-related paths, *secret*, *credential*
  backend: [],             // *.py, *.go, *.rs, *.rb, *.java, *.kt, *.scala, *.cs, *.erl, *.hs, *.ml
  frontend: [],            // *.ts, *.tsx, *.js, *.jsx, *.vue, *.svelte, *.astro, *.css, *.scss
  infra: [],               // Dockerfile, *.sh, *.sql, *.tf, CI/CD configs, extensionless infra files
  config: [],              // *.yml, *.yaml, *.json, *.toml
  docs: [],                // *.md, *.rst, *.txt
  tests: []                // *test*, *spec*, __tests__/, /tests/ paths
}

for (const file of classifiedFiles) {
  // Security escalation (checked first — overrides domain)
  if (file.path.startsWith('.claude/') || isAuthRelated(file.path)) {
    groups.security_critical.push(file)
  // Test extraction (before domain routing — test files have own shard)
  } else if (isTestFile(file.path)) {
    groups.tests.push(file)
  } else {
    const domain = deriveDomain(file.path)
    groups[domain].push(file)
  }
}
```

### Step 2: Risk-Sort Within Groups

```javascript
// Sort by risk_score descending (high-risk files reviewed first within each shard)
for (const group of Object.values(groups)) {
  group.sort((a, b) => (b.risk_score ?? 0) - (a.risk_score ?? 0))
}
```

### Step 3: Priority Bin-Pack Into Shards

```javascript
const PRIORITY_ORDER = [
  'security_critical', 'backend', 'frontend', 'infra', 'config', 'tests', 'docs'
]

const LARGE_FILE_THRESHOLD = 400  // lines changed
const LARGE_FILE_WEIGHT = 2       // large files count as 2 slots for context budget

const shards = []
let current = { files: [], domains: new Set(), effectiveSize: 0 }

for (const groupName of PRIORITY_ORDER) {
  for (const file of groups[groupName]) {
    if (current.effectiveSize >= SHARD_SIZE) {
      current.primary_domain = dominantDomain(current.domains)
      shards.push(current)
      current = { files: [], domains: new Set(), effectiveSize: 0 }
    }
    const weight = (file.lines_changed ?? 0) > LARGE_FILE_THRESHOLD ? LARGE_FILE_WEIGHT : 1
    current.files.push(file)
    current.domains.add(groupName)
    current.effectiveSize += weight
  }
}
if (current.files.length > 0) {
  current.primary_domain = dominantDomain(current.domains)
  shards.push(current)
}
```

### Step 4: Merge to Respect MAX_SHARDS

```javascript
// Merge smallest shards first until count <= MAX_SHARDS
while (shards.length > MAX_SHARDS) {
  shards.sort((a, b) => a.files.length - b.files.length)
  const merged = {
    files: [...shards[0].files, ...shards[1].files],
    domains: new Set([...shards[0].domains, ...shards[1].domains])
  }
  merged.primary_domain = dominantDomain(merged.domains)
  shards.splice(0, 2, merged)
}

// Step 4b: Rebalance after merge (prevents mega-shards > SHARD_SIZE * 1.5)
for (const shard of shards) {
  while (shard.files.length > SHARD_SIZE * 1.5) {
    const smallest = shards.reduce((a, b) => a.files.length < b.files.length ? a : b)
    // Don't rebalance into self
    if (smallest === shard) break
    smallest.files.push(shard.files.pop())
  }
}
```

### Step 5: Assign Model Per Shard

```javascript
for (const shard of shards) {
  if (MODEL_POLICY === "all-sonnet") {
    shard.model = "sonnet"
  } else if (MODEL_POLICY === "all-haiku") {
    shard.model = "haiku"
  } else {  // "auto"
    shard.model = shard.domains.has('security_critical') ? 'sonnet'
                : (shard.files.length <= 5 && onlyDocs(shard)) ? 'haiku'
                : 'sonnet'
  }
}

return shards
```

## Helper Functions

```javascript
// Maps file path → domain group. Aligns with Rune Gaze canonical extension sets.
// NOTE: Rune Gaze classifies into code_files/doc_files/infra_files/skip_files arrays.
// deriveDomain() provides the finer-grained domain needed for shard affinity.
function deriveDomain(path) {
  const ext = (path.split('.').pop() ?? '').toLowerCase()

  // Extensionless infra files (checked before extension matching)
  const INFRA_FILENAMES = new Set([
    'Makefile', 'Procfile', 'Vagrantfile', 'Rakefile', 'Justfile',
    'Dockerfile', 'Brewfile'
  ])
  const basename = path.split('/').pop() ?? ''
  if (INFRA_FILENAMES.has(basename)) return 'infra'

  // Extension sets — aligned with Rune Gaze (smart-selection.md SOURCE_CODE_EXTENSIONS)
  // Missing from naive lists: scala, cs, erl, hs, ml (backend); astro (frontend)
  const BACKEND_EXT  = new Set(['py','go','rs','rb','java','kt','scala','cs','erl','hs','ml','php','ex','exs'])
  const FRONTEND_EXT = new Set(['ts','tsx','js','jsx','vue','svelte','astro','css','scss','sass','less'])
  const CONFIG_EXT   = new Set(['yml','yaml','json','toml','ini'])  // .env excluded (→ security_critical)
  const DOC_EXT      = new Set(['md','rst','txt'])
  const INFRA_EXT    = new Set(['sh','bash','zsh','sql','tf','hcl'])

  if (DOC_EXT.has(ext))     return 'docs'
  if (INFRA_EXT.has(ext))   return 'infra'
  if (CONFIG_EXT.has(ext))  return 'config'
  if (FRONTEND_EXT.has(ext)) return 'frontend'
  if (BACKEND_EXT.has(ext)) return 'backend'

  // Infra path patterns for files without clear extension
  const INFRA_PATH_PATTERNS = ['.github/', 'ci/', '.tf', 'docker-compose']
  if (INFRA_PATH_PATTERNS.some(p => path.includes(p))) return 'infra'

  return 'backend'  // default: treat unknown as backend (conservative)
}

// Auth-related file detection — escalates to security_critical group
function isAuthRelated(path) {
  const AUTH_PATTERNS = [
    'auth', 'login', 'session', 'token', 'credential', 'secret',
    'permission', 'rbac', 'oauth', 'jwt', 'password', 'encrypt'
  ]
  const lower = path.toLowerCase()
  // .env files contain secrets — escalate regardless of explicit auth patterns
  if (lower.endsWith('.env') || lower.includes('.env.')) return true
  return AUTH_PATTERNS.some(p => lower.includes(p))
}

// Test file detection
function isTestFile(path) {
  return /\.(test|spec)\.[a-z]+$/.test(path)
      || path.includes('__tests__')
      || path.includes('/tests/')
      || path.includes('/test/')
      || path.includes('_test.')
}

// Returns the highest-priority domain from a domain Set
function dominantDomain(domains) {
  const DOMAIN_PRIORITY = [
    'security_critical', 'backend', 'frontend', 'infra', 'config', 'tests', 'docs'
  ]
  for (const d of DOMAIN_PRIORITY) {
    if (domains.has(d)) return d
  }
  return 'mixed'
}

// True when shard contains only docs-domain files
function onlyDocs(shard) {
  return shard.domains.size === 1 && shard.domains.has('docs')
}
```

## Edge Cases

| Condition | Behavior |
|-----------|----------|
| `classifiedFiles.length <= SHARD_THRESHOLD` | Returns `null` — standard review unchanged |
| All files in same domain AND count > SHARD_THRESHOLD | Sharded into multiple same-domain shards |
| Security files > SHARD_SIZE | Security shard gets priority; overflow promoted to second shard |
| Only doc files in diff (above threshold) | Single haiku shard (or 2 small haiku shards) |
| Mixed-domain shard after merge | Uses sonnet (conservative model selection) |
| 0 files after skip filter | Abort review — existing behavior, no change |
| `.env` in diff | Routed to `security_critical` (NOT `config`) |

> **Correction note**: "All files in one domain" does NOT trigger standard review when
> `count > SHARD_THRESHOLD`. Files are still sharded — it just results in same-domain shards.
> Standard review only applies when `count <= SHARD_THRESHOLD`.

## Convergence Re-Review Behavior

When the convergence loop (arc Phase 7.5 VERIFY MEND) retries the review phase,
`allocateShards()` runs again on the progressive-focus file set:

```javascript
// In convergence retry (round > 0):
const focusFiles = buildProgressiveFocus(resolutionReport, originalChangedFiles)
const reShards = allocateShards(focusFiles, config)

if (reShards === null) {
  // Below threshold → standard review (expected path — mend touches < 15 files)
} else {
  // Still above reshard_threshold → force standard review to preserve finding continuity
  // See: reshard_threshold talisman key
  if (focusFiles.length <= (talisman?.review?.reshard_threshold ?? 30)) {
    // Use re-sharded review
  } else {
    // Force standard review — re-sharding at this scale breaks prefix continuity
    return null
  }
}
```

**Key constraint**: Re-sharding produces NEW shard IDs (SHA-, SHB-...) that have no
continuity with prior round IDs, impairing oscillation detection. Default: standard
review on re-review (mend typically touches 5-15 files, below SHARD_THRESHOLD).

## Context Budget Estimate

| Files per shard | Estimate | Tokens |
|----------------|----------|--------|
| 12 files | prompt 3K + files ~86K + findings 5K + summary 2K + self-review 6K | ~102K (~51% of teammate context window) |
| Haiku docs shard | Similar token count, lower cost | ~100K |

For files > 400 lines, `LARGE_FILE_WEIGHT = 2` applies — count them as 2 slots in
`SHARD_SIZE` to prevent context overflow (see Phase 3 shard reviewer prompt for details).

## Performance Estimate

| Metric | Sharded | Chunked (prior) | Improvement |
|--------|---------|----------------|-------------|
| 30-file diff | 3 shards × 12 files, parallel | 5 chunks × 30 files, sequential | ~2-3× faster |
| Total file reads | 36 (3 shards × 12) | 210 (7 specialists × 30) | ~75-85% fewer |
| Cross-file analysis | Cross-Shard Sentinel (metadata only) | Full file reads per specialist | Metadata-only reconciliation |
