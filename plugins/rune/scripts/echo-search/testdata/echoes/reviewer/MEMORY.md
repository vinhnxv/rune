# Reviewer Echoes

## Inscribed — Security Pattern Consistency Review (2026-01-15)

**Source**: `rune:appraise abc123`
**Confidence**: HIGH (3 Ashes, all completed)

### Review Metrics

- Branch: feat/auth-refactor
- Files reviewed: 12 (8 .py, 2 .ts, 2 .md)
- Ashes: Ward Sentinel, Pattern Weaver, Forge Warden
- Raw findings: 18 (2 P1, 8 P2, 8 P3)
- After dedup: 14 (2 P1, 6 P2, 6 P3)

### Key Learnings

1. **SQL injection in ORM layer**: Raw string interpolation found in `db/queries.py` despite using SQLAlchemy. Always use parameterized queries even with ORMs — `text()` accepts bind parameters.

2. **Cross-site scripting in template rendering**: Jinja2 `|safe` filter used on user-provided content without prior sanitization. Mark content as safe only AFTER explicit HTML escaping.

3. **Dedup hierarchy works well**: SEC > BACK > VEIL > DOC > QUAL hierarchy correctly promoted security findings over quality observations on the same code blocks.

## Inscribed — Performance Bottleneck Analysis (2026-01-20)

**Source**: `rune:appraise def456`
**Confidence**: HIGH (4 Ashes, all completed)

### Review Metrics

- Branch: feat/query-optimization
- Files reviewed: 8 (all .py)
- Ashes: Forge Warden, Ward Sentinel, Pattern Weaver

### Key Learnings

1. **N+1 query in user listing endpoint**: `get_users()` triggered individual role lookups per user. Replaced with `selectinload()` for eager loading — 47ms to 3ms improvement.

2. **Missing database index on frequently filtered column**: `orders.status` column lacked an index despite being used in 80% of dashboard queries. Adding B-tree index reduced p95 latency by 60%.

3. **Connection pool exhaustion under load**: Default pool size of 5 was insufficient for concurrent API requests. Increased to 20 with overflow=10, matching the uvicorn worker count.

## Etched — Recurring Anti-Patterns in Authentication Code (2026-02-01)

**Source**: `rune:appraise ghi789`
**Confidence**: MEDIUM (pattern observed across 3 reviews)

### Observations

- JWT token validation skips expiry check when `DEBUG=true` is set in environment
- Session tokens stored in localStorage instead of httpOnly cookies
- Password reset tokens don't expire — found in 2 separate review sessions
- CORS configuration uses wildcard `*` in development but leaks to staging

These patterns suggest a systemic gap in security review coverage for authentication flows. Consider adding a dedicated auth-review checklist.

## Traced — Experimental: Rust FFI Boundary Review (2026-02-10)

**Source**: rune:appraise jkl012
**Confidence**: LOW (single observation, needs verification)

Observed that Rust FFI functions exposed via `#[no_mangle]` lack null pointer checks on C-side arguments. The `unsafe` block in `bindings.rs` trusts caller-provided pointers without validation. This could cause undefined behavior if called from Python ctypes with None arguments.

Need to verify if the ctypes wrapper adds null guards before the FFI call.
