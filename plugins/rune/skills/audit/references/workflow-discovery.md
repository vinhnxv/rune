# Workflow Discovery — Tier 2 Cross-File Flow Detection

> Discovers cross-file business logic flows for workflow-level audit coverage.

## Overview

A "workflow" is a cross-file business logic flow (e.g., "user authentication", "order processing"). Workflows are discovered by tracing import chains, route handlers, and convention-based patterns.

## Discovery Methods (in precedence order)

### 1. Import Graph Tracing (PRIMARY)

Follow `import`/`require`/`from` chains from entry points:

```
src/routes/auth.ts
  → src/controllers/auth.controller.ts
  → src/services/auth.service.ts
  → src/middleware/auth.middleware.ts
  → src/validators/auth.validator.ts
```

**Detection patterns**:
- `import { X } from './path'`
- `const X = require('./path')`
- `from path import X`
- `use crate::path`

**Depth limit**: Configurable `max_trace_depth` (default: 10 hops from entry point). Most meaningful workflows are within 5-7 hops.

**Cycle detection**: Visited-set per trace chain with stack-based cycle detector. When a cycle is detected, include ALL cycle files in the workflow (tightly coupled) and emit `WF-CYCLE` informational finding.

### 2. Route-Handler Chains (PRIMARY)

For web apps, trace route definitions to handlers:

```
POST /api/auth/login
  → authController.login()
  → authService.authenticate()
  → tokenService.generate()
  → userRepository.findByEmail()
```

**Framework patterns**:

| Framework | Route Pattern | Handler Resolution |
|-----------|--------------|-------------------|
| Express/Koa | `router.post('/path', handler)` | Follow handler reference |
| FastAPI | `@router.post("/path")` | Function below decorator |
| Spring | `@PostMapping("/path")` | Method below annotation |
| Go net/http | `http.HandleFunc("/path", handler)` | Follow handler reference |
| Rails | `resources :name` | Convention: `controllers/name_controller.rb` |

Also scan middleware: `app.use()` / `router.use()` and error handlers `(err, req, res, next)`.

### 3. Convention-Based Discovery (FALLBACK)

Match directory patterns when import/route tracing finds nothing:

```
src/features/auth/     → "auth" workflow
src/features/payments/  → "payments" workflow
src/modules/orders/     → "orders" workflow
```

**Plugin-specific patterns** (for Claude Code plugin repos):
```
commands/*.md → skills/*/SKILL.md → agents/*/*.md → scripts/*.sh
```

Patterns are baked-in v3.x literals.

### 4. Manual Definitions (OVERRIDE)

Users can define workflows in talisman.yml:

```yaml
audit:
  incremental:
    tiers:
      workflows:
        manual:
          - name: "payment-checkout"
            entry_point: "src/routes/payments.ts"
            files:
              - "src/routes/payments.ts"
              - "src/services/payment.service.ts"
              - "src/validators/payment.validator.ts"
```

Manual definitions serve as ground truth — if auto-discovery misses a manually defined workflow, it indicates a tracing gap.

## Workflow Boundary Rules

- Tracing depth stops at repository/database layer
- If two workflows share >70% of files, merge into single workflow
- Shared files belong to their PRIMARY workflow (highest import count from workflow-specific files)
- Other workflows list shared files in `shared_files`
- Maximum discovered workflows: 100 (cap prevents unbounded growth)

## Shared File Strategy

```json
{
  "auth-login": {
    "files": ["src/routes/auth.ts", "src/controllers/auth.controller.ts"],
    "shared_files": ["src/services/user.service.ts", "src/models/user.model.ts"],
    "shared_with": ["auth-register", "profile-update"]
  }
}
```

## workflows.json Schema

```json
{
  "schema_version": 1,
  "workflows": {
    "auth-login": {
      "name": "User Authentication — Login Flow",
      "entry_point": "src/routes/auth.ts:POST /api/auth/login",
      "files": ["src/routes/auth.ts", "src/controllers/auth.controller.ts"],
      "shared_files": ["src/services/user.service.ts"],
      "shared_with": ["auth-register"],
      "discovery_method": "route-handler-chain",
      "confidence": "high",
      "last_audited": "ISO8601 or null",
      "last_audit_id": "20260222-100000 or null",
      "audit_count": 1,
      "findings": { "cross_file": 2, "per_file": 8 },
      "risk_tier": "CRITICAL",
      "status": "audited"
    }
  },
  "stats": {
    "total_workflows": 12,
    "audited_workflows": 5,
    "coverage_pct": 41.7
  }
}
```

## Workflow Priority Scoring

```
workflow_priority = (
    0.30 * staleness_score(workflow)       +
    0.25 * file_change_score(workflow)     +
    0.20 * risk_aggregate_score(workflow)  +
    0.15 * file_coverage_score(workflow)   +
    0.10 * criticality_score(workflow)
)
```

**file_change_score**: If ANY file in the workflow changed since last workflow audit → boost to 8-10.

**criticality_score** (by workflow name/path patterns):
- Auth/security/payment/billing → 10
- User management/order processing → 8
- Notification/reporting/analytics → 5
- Admin/settings/config → 3

## Progressive Refinement

Workflow discovery runs incrementally across sessions:
1. First session: convention-based (cheap) + import graph for entry points
2. Subsequent sessions: refine with route-handler tracing
3. Cache in `workflows.json`, only re-run when entry point files change

## Known Limitations

| Limitation | Affected Method | Mitigation |
|-----------|----------------|------------|
| Dynamic imports (`import()`) | Import graph | Grep heuristic for `import(` |
| Circular imports | Import graph | Visited-set cycle detection |
| Barrel files / re-exports | Import graph | Transitive resolution |
| Import aliases (tsconfig) | Import graph | Read tsconfig.json |
| Cross-process events | Event chain | Scan broker config files |
| Non-conventional dirs | Convention | Fallback to import-graph |

## Zero-Workflow Repos

Libraries, CLI tools, and data pipelines may have no traditional workflows. When all discovery methods return empty, Tier 2 is silently skipped and coverage report shows "N/A — no workflows detected" instead of 0%.
