# Domain Inference — inferProjectDomain()

Infers the project's business domain from codebase signals. Called as Phase 5.5 of
`discoverDesignSystem()`, between Variant System Resolution (Phase 5) and Component
Inventory (Phase 6).

## Algorithm

```
// Pseudocode — NOT implementation code
function inferProjectDomain(repoRoot: string): DomainResult

  // --- Check talisman override first ---
  talisman = readTalismanSection("devise")
  domainConfig = talisman?.design_system_discovery?.domain_inference ?? {}

  IF domainConfig.enabled === false:
    RETURN { domain: "general", confidence: 0.0, source: "disabled" }

  IF domainConfig.override is not null:
    RETURN { domain: domainConfig.override, confidence: 1.0, source: "talisman_override" }

  // --- Collect signals from 4 sources ---
  signals = {
    keywords:  scanKeywords(repoRoot),     // weight: 0.4
    routes:    scanRoutes(repoRoot),        // weight: 0.3
    deps:      scanDependencies(repoRoot),  // weight: 0.2
    readme:    scanReadme(repoRoot)         // weight: 0.1
  }

  // --- Score each domain ---
  scores = {}
  FOR EACH domain IN DOMAIN_REGISTRY:
    matched_weights = 0.0
    FOR EACH source IN [keywords, routes, deps, readme]:
      IF source.matches(domain):
        matched_weights += source.weight
    scores[domain] = matched_weights / ALL_WEIGHTS_SUM  // 0.4 + 0.3 + 0.2 + 0.1 = 1.0

  // --- Select winner ---
  winner = domain with max(scores[domain])
  confidence = scores[winner]

  IF confidence < 0.70:
    RETURN { domain: "general", confidence: confidence, source: "low_confidence", runner_up: winner }

  RETURN {
    domain: winner,
    confidence: confidence,
    source: "inferred",
    signal_breakdown: signals
  }
```

### Performance Constraint

All 4 signal sources use local file reads and grep — no external API calls.
Total execution target: < 2 seconds.

## Signal Sources

### Source 1: Keyword Scan (weight: 0.4)

Scans file names and directory names for domain-specific terms.

```
function scanKeywords(repoRoot: string): SignalResult
  files = Glob("{src,app,lib,pages,modules}/**/*.{ts,tsx,js,jsx,py,rb}")
  dirNames = unique directory names from files
  fileNames = unique file base names (without extension) from files

  allNames = lowercase(dirNames + fileNames)

  FOR EACH domain, keywords IN DOMAIN_KEYWORD_MAP:
    matchCount = count of keywords found in allNames
    IF matchCount >= 2:
      mark domain as matched for this source

  RETURN matched domains with match counts
```

### Source 2: Route Scan (weight: 0.3)

Scans route definitions for domain-specific URL patterns.

```
function scanRoutes(repoRoot: string): SignalResult
  // Next.js app router
  routeDirs = Glob("app/**/page.{ts,tsx,js,jsx}")
  // Next.js pages router
  routeDirs += Glob("pages/**/*.{ts,tsx,js,jsx}")
  // Express/Fastify/Flask routes
  routeContent = Grep("router\.(get|post|put|delete)\|@app\.(route|get|post)\|app\.(get|post|put|delete)")

  routeNames = extract route segments from paths and content

  FOR EACH domain, patterns IN DOMAIN_ROUTE_MAP:
    IF any pattern matches routeNames:
      mark domain as matched for this source

  RETURN matched domains
```

### Source 3: Dependency Scan (weight: 0.2)

Scans package.json (or requirements.txt, Gemfile) for domain-specific libraries.

```
function scanDependencies(repoRoot: string): SignalResult
  // Node.js
  IF package.json exists:
    deps = keys of (dependencies + devDependencies)
  // Python
  ELSE IF requirements.txt OR pyproject.toml exists:
    deps = parse dependency names
  // Ruby
  ELSE IF Gemfile exists:
    deps = parse gem names
  ELSE:
    RETURN no matches

  FOR EACH domain, depPatterns IN DOMAIN_DEP_MAP:
    IF any depPattern matches deps:
      mark domain as matched for this source

  RETURN matched domains
```

### Source 4: README Scan (weight: 0.1)

Scans README.md first 200 lines for domain-specific phrases.

```
function scanReadme(repoRoot: string): SignalResult
  readme = Read("{repoRoot}/README.md", limit=200)
  IF readme is empty:
    RETURN no matches

  readmeText = lowercase(readme)

  FOR EACH domain, phrases IN DOMAIN_KEYWORD_MAP:
    // Reuse keyword map but match against prose
    IF any phrase found in readmeText:
      mark domain as matched for this source

  RETURN matched domains
```

## Confidence Formula

**CRITICAL**: Domain inference uses a different formula than library detection.

```
// Domain inference formula — NOT the library detection formula
confidence = sum(matched_weights) / sum(all_weights)

WHERE:
  sum(all_weights) = 0.4 + 0.3 + 0.2 + 0.1 = 1.0
  sum(matched_weights) = sum of weights for sources that matched the winning domain
```

**Why different**: Library detection uses `maxWeight * (matchedCount / totalSignals) ^ 0.3` with
a conclusive single-signal shortcut. Domain inference has no conclusive single signal — all 4
sources contribute proportionally. The formula yields intuitive results:
- 4/4 sources match → confidence = 1.0
- 3/4 sources match → confidence = 0.7–0.9 (depends on which 3)
- 2/4 sources match → confidence = 0.3–0.7 (depends on which 2)
- 1/4 source matches → confidence = 0.1–0.4 (below threshold)

**Threshold**: confidence >= 0.70 → domain used for downstream recommendations.
confidence < 0.70 → domain set to "general" (safe fallback).

**Minimum agreement**: At least 3 signal sources must agree for confidence >= 0.70.
This is a structural property of the weights: the highest 2 weights sum to 0.7,
but that requires keywords (0.4) + routes (0.3) — the two strongest. In practice,
3/4 agreement is needed for a reliable inference.

## Worked Examples

### Example 1: E-commerce project (high confidence)

```
Signal sources:
  keywords (0.4):  files contain "cart", "checkout", "product" → MATCH e-commerce
  routes (0.3):    /products, /cart, /checkout routes found    → MATCH e-commerce
  deps (0.2):      "stripe" in package.json                    → MATCH e-commerce
  readme (0.1):    "online store" in README                    → MATCH e-commerce

confidence = (0.4 + 0.3 + 0.2 + 0.1) / 1.0 = 1.0
Result: { domain: "e-commerce", confidence: 1.0 }
```

### Example 2: SaaS project (medium-high confidence)

```
Signal sources:
  keywords (0.4):  files contain "dashboard", "tenant", "subscription" → MATCH saas
  routes (0.3):    /dashboard, /settings, /billing routes found        → MATCH saas
  deps (0.2):      no saas-specific deps found                         → NO MATCH
  readme (0.1):    "multi-tenant SaaS" in README                       → MATCH saas

confidence = (0.4 + 0.3 + 0.0 + 0.1) / 1.0 = 0.80
Result: { domain: "saas", confidence: 0.80 }
```

### Example 3: Ambiguous project (low confidence → fallback)

```
Signal sources:
  keywords (0.4):  generic files (utils, helpers, api)         → NO MATCH
  routes (0.3):    /api/users, /api/data (generic REST)        → NO MATCH
  deps (0.2):      "express" only (generic)                    → NO MATCH
  readme (0.1):    "A web application" (too generic)           → NO MATCH

confidence = 0.0 / 1.0 = 0.0
Result: { domain: "general", confidence: 0.0, source: "low_confidence" }
```

### Example 4: Fintech with partial signals

```
Signal sources:
  keywords (0.4):  files contain "transaction", "ledger"       → MATCH fintech
  routes (0.3):    /transactions, /accounts routes             → MATCH fintech
  deps (0.2):      "plaid" in package.json                     → MATCH fintech
  readme (0.1):    README is minimal, no domain phrases        → NO MATCH

confidence = (0.4 + 0.3 + 0.2 + 0.0) / 1.0 = 0.90
Result: { domain: "fintech", confidence: 0.90 }
```

## Domain Registry

8 supported domains with descriptions:

| Domain | Key | Description | Design Implications |
|--------|-----|-------------|---------------------|
| E-commerce | `e-commerce` | Online stores, marketplaces, product catalogs | Product cards, cart UX, checkout flows, payment forms |
| SaaS | `saas` | Multi-tenant platforms, dashboards, subscriptions | Dashboard layouts, settings panels, onboarding flows |
| Fintech | `fintech` | Banking, payments, trading, ledgers | Data tables, transaction lists, security-heavy forms |
| Healthcare | `healthcare` | Patient portals, EHR, telehealth | Accessibility-first, HIPAA-aware forms, appointment scheduling |
| Creative | `creative` | Design tools, media platforms, portfolios | Rich media displays, canvas/editor UIs, gallery layouts |
| Education | `education` | LMS, course platforms, e-learning | Progress tracking, quiz interfaces, content hierarchies |
| Content | `content` | CMS, blogs, news, publishing | Article layouts, rich text editors, media management |
| General | `general` | Default fallback — no specific domain detected | Standard web patterns, no domain-specific recommendations |

## Signal Maps

### DOMAIN_KEYWORD_MAP

File/directory name keywords that indicate a domain. Minimum 2 keyword matches required.

```yaml
e-commerce:
  - cart
  - checkout
  - product
  - catalog
  - inventory
  - order
  - shipping
  - storefront
  - wishlist
  - sku

saas:
  - dashboard
  - tenant
  - subscription
  - billing
  - onboarding
  - workspace
  - organization
  - settings
  - plan
  - invite

fintech:
  - transaction
  - ledger
  - payment
  - account
  - wallet
  - transfer
  - balance
  - portfolio
  - trade
  - kyc

healthcare:
  - patient
  - appointment
  - diagnosis
  - prescription
  - medical
  - clinic
  - ehr
  - vitals
  - telehealth
  - hipaa

creative:
  - canvas
  - editor
  - gallery
  - media
  - asset
  - design
  - template
  - layer
  - artboard
  - palette

education:
  - course
  - lesson
  - quiz
  - student
  - enrollment
  - grade
  - curriculum
  - assignment
  - module
  - lms

content:
  - article
  - post
  - blog
  - author
  - publish
  - draft
  - editorial
  - cms
  - category
  - tag
```

### DOMAIN_ROUTE_MAP

URL route patterns that indicate a domain.

```yaml
e-commerce:
  - /products
  - /cart
  - /checkout
  - /orders
  - /shop
  - /catalog

saas:
  - /dashboard
  - /settings
  - /billing
  - /team
  - /workspace
  - /onboarding

fintech:
  - /transactions
  - /accounts
  - /transfers
  - /wallet
  - /portfolio
  - /payments

healthcare:
  - /patients
  - /appointments
  - /records
  - /prescriptions
  - /vitals

creative:
  - /editor
  - /canvas
  - /gallery
  - /assets
  - /projects

education:
  - /courses
  - /lessons
  - /quizzes
  - /students
  - /grades
  - /assignments

content:
  - /articles
  - /posts
  - /drafts
  - /editorial
  - /categories
  - /authors
```

### DOMAIN_DEP_MAP

Package dependencies that indicate a domain.

```yaml
e-commerce:
  - stripe
  - shopify
  - snipcart
  - medusa
  - saleor
  - commercejs

saas:
  - "@clerk/nextjs"
  - "@auth0/auth0-react"
  - supertokens
  - paddle
  - chargebee
  - lemon-squeezy

fintech:
  - plaid
  - dwolla
  - "@solana/web3.js"
  - ethers
  - web3
  - alpaca

healthcare:
  - fhir
  - hl7
  - medplum
  - "@medplum/core"
  - "@smile-cdr/fhir"

creative:
  - fabric
  - konva
  - three
  - "@react-three/fiber"
  - pixi.js
  - tldraw

education:
  - "@edx/frontend-platform"
  - canvas-lms
  - moodle
  - scorm

content:
  - contentful
  - sanity
  - strapi
  - "@contentful/rich-text-react-renderer"
  - ghost
  - keystonejs
```

## Edge Cases

### EC-D1: Monorepo with multiple domains

When `repoRoot` contains multiple `package.json` files in subdirectories, scan only the
root `package.json` and the first-level `apps/*/package.json`. If different apps match
different domains, return `"general"` with a note in `signal_breakdown`.

### EC-D2: Python projects

Python projects use `requirements.txt`, `pyproject.toml`, or `setup.py` instead of
`package.json`. The dependency scan adapts: parse `requirements.txt` lines or
`[project.dependencies]` from `pyproject.toml`. Route detection uses Flask/FastAPI patterns
(`@app.route`, `@router.get`) instead of file-based routing.

### EC-D3: Multi-domain signals

When two domains score equally (e.g., both at 0.70), prefer the domain with more keyword
matches (source 1) as the tiebreaker. If still tied, return `"general"`.

### EC-D4: Mobile projects (React Native, Flutter)

Route detection uses navigation patterns instead of URL routes:
- React Native: `Stack.Screen name=` patterns in navigation config
- Flutter: `MaterialPageRoute` patterns in `routes.dart`

Keyword and dependency scans work identically for mobile projects.

## Output Schema

```yaml
# Added to design-system-profile.yaml by Phase 5.5
domain:
  inferred: "e-commerce"          # Domain key from registry
  confidence: 0.90                # 0.0–1.0
  source: "inferred"              # "inferred" | "talisman_override" | "disabled" | "low_confidence"
  signal_breakdown:
    keywords: { matched: true, domain: "e-commerce", count: 4 }
    routes: { matched: true, domain: "e-commerce", count: 3 }
    deps: { matched: true, domain: "e-commerce", count: 1 }
    readme: { matched: false }
  runner_up: null                 # Second-highest domain (if any), null if clear winner
```

## Cross-References

- [signal-aggregation.md](signal-aggregation.md) — Library/token/variant signal aggregation (Phases 2–5)
- [design-context.md](design-context.md) — DesignContext schema where `domain` is consumed
- [SKILL.md](../SKILL.md) — Phase 5.5 integration point in `discoverDesignSystem()`
