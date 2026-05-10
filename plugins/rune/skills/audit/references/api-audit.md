# API Audit — Tier 3 Endpoint Contract Review Protocol

> Protocol for auditing API endpoints with contract, validation, auth, and OWASP checks.

## Overview

When an API endpoint is selected for audit, the system traces the full request/response lifecycle and instructs Ashes to check contracts, validation, auth, and security concerns.

## Audit Execution

1. Load all files in the endpoint chain (handler, validator, serializer, middleware, docs, tests)
2. Pass them to the audit engine as `--focus-api <endpoint-id>`
3. Inject API analysis instructions into Ash system prompts
4. Generate API-specific findings in TOME alongside file-level findings
5. Update `apis.json` with results

## API Prompt Extension

Injected into Ash system prompts when `--focus-api` is active:

```
Analyze this API endpoint's full request/response lifecycle:

1. **Contract consistency**: Do request/response types match across handler,
   validator, serializer, and documentation?
2. **Validation completeness**: Are ALL input fields validated? Missing validation
   = injection risk.
3. **Error responses**: Are errors mapped to appropriate HTTP status codes?
   Are error shapes consistent? Do error responses leak stack traces or internal paths?
4. **Auth enforcement**: Does this mutable endpoint check authentication and
   authorization? Check for horizontal/vertical privilege escalation.
5. **Documentation accuracy**: Does API docs match the actual implementation?
6. **Rate limiting**: Are brute-force-sensitive endpoints rate-limited?
7. **CORS configuration**: Is Access-Control-Allow-Origin appropriately scoped?
8. **Content-Type validation**: Does the endpoint enforce expected Content-Type?
9. **Mass assignment protection**: Does the endpoint whitelist accepted fields?
10. **SSRF protection**: Do endpoints accepting URLs validate against internal ranges?
11. **Idempotency**: Do mutable endpoints support idempotency keys where applicable?

Report findings with prefix "API-" followed by finding type.
```

## Finding Prefixes

| Prefix | Description | OWASP Ref |
|--------|-------------|-----------|
| `API-CONTRACT` | Request/response type mismatch | — |
| `API-VALIDATE` | Missing or incomplete input validation | A08:2021 |
| `API-ERROR` | Error handling / information leakage | — |
| `API-AUTH` | Authentication/authorization gap | API1:2023 |
| `API-DOC` | Documentation inaccuracy or staleness | — |
| `API-RATE` | Missing rate limiting | API4:2023 |
| `API-CORS` | CORS misconfiguration | A05:2021 |
| `API-MASS-ASSIGN` | Mass assignment vulnerability | API3:2023 |
| `API-SSRF` | Server-side request forgery risk | A10:2021 |
| `API-HEADER` | Header injection / Host header attack | A03:2021 |
| `API-BFLA` | Broken Function Level Authorization | API5:2023 |
| `API-INVENTORY` | Undocumented endpoint (in code, not in spec) | API9:2023 |
| `API-DRIFT` | Contract changed since last audit | — |
| `API-IDEMPOTENCY` | Missing idempotency for mutable operations | — |
| `API-RESPONSE-HEADER` | Missing security headers (CSP, HSTS, etc.) | A05:2021 |

## Cross-Tier Security Feedback

API findings propagate back to Tier 1 file-level state:

| API Finding Severity | File Risk Boost | Scope |
|---------------------|-----------------|-------|
| P1 (Critical) | +3.0 to risk_score | All files in endpoint chain |
| P2 (High) | +1.5 to risk_score | Handler + directly implicated files |
| P3 (Medium) | +0.5 to risk_score | Handler file only |

If 3+ API endpoints sharing a common middleware file have P2+ findings, escalate that middleware file to `always_audit` status for the next 3 sessions.

## Result Write-Back

After API audit completes:

```
1. Parse TOME.md for API-prefixed findings
2. Update apis.json:
   - api.last_audited = now
   - api.findings = { contract: N, validation: M, security: K }
   - api.status = "audited"
3. Capture contract snapshot (first audit only)
4. Apply cross-tier risk boosts to state.json
5. Update stats (total_endpoints, audited_endpoints, coverage_pct)
```

## Batch Selection

API endpoints are selected independently from files and workflows:

```
max_per_batch = 5   // v3.x baked-in
scored = scoreAllEndpoints(apis)
selected = sorted(scored, descending).slice(0, max_per_batch)
```

## Integration with Other Tiers

- File-level audit (Tier 1) runs first — provides per-file quality baseline
- Workflow audit (Tier 2) runs second — provides cross-file interaction quality
- API audit (Tier 3) runs third — provides endpoint contract verification
- All three tiers share the same TOME for finding aggregation
- Each tier has independent coverage tracking and reporting
