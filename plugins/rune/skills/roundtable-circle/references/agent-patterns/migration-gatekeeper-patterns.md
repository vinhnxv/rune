# Migration Gatekeeper Patterns Reference

Detailed patterns for each GATE finding in the Forge Keeper agent. Covers dual-write implementation, production verification queries, multi-database sequencing, and rollback failure recovery.

---

## Dual-Write Implementation Checklist

### Pattern: Column Rename (old_name -> new_name)

Step 1: Add new column (nullable)
Step 2: Backfill new column from old column (batched)
Step 3: Deploy dual-write code (writes to both old + new)
Step 4: Verify new column data matches old column
Step 5: Switch reads to new column
Step 6: Remove old column writes
Step 7: Drop old column (separate migration, separate deploy)

### Detection: Incomplete Dual-Write

Search for patterns indicating only partial implementation:
- New column added but no backfill migration in same PR
- Column aliased but original not kept
- One write path updated but not the other (background jobs often missed)

### Blue-Green Migration Pattern

For large-scale schema changes requiring zero-downtime:

```
-- SCAFFOLD: Verify against production schema before executing
-- Phase A (Blue): Current schema serving traffic
-- Phase B (Green): New schema deployed alongside
-- Phase C: Traffic cutover from Blue to Green
-- Phase D: Blue schema decommissioned (separate deploy cycle)
```

1. Deploy new schema as parallel tables/columns (Green)
2. Dual-write to both schemas from application layer
3. Backfill Green from Blue (batched, idempotent)
4. Verify data parity between Blue and Green
5. Cut reads to Green (feature flag or load balancer)
6. Stop writes to Blue (after verification window)
7. Drop Blue schema (after retention period)

### Canary Migration Pattern

For data transformations on high-traffic tables:

1. Apply migration to canary slice (e.g., 1% of rows by hash/modulo)
2. Monitor error rates, query performance, data integrity on canary slice
3. If canary is healthy after observation window: expand to 10%, 50%, 100%
4. If canary shows issues: rollback canary slice only (minimal blast radius)

---

## Production Verification Queries

### Template: Pre-Deploy Baseline

For every data migration, these queries MUST be documented and executed before deployment:

```sql
-- SCAFFOLD: Verify against production schema before executing
-- Pre-deploy baseline: capture current state
SELECT COUNT(*) AS row_count,
       COUNT(DISTINCT {key_column}) AS unique_keys,
       MIN({key_column}) AS min_key,
       MAX({key_column}) AS max_key
FROM {table};

-- Null ratio for affected columns
SELECT COUNT(*) AS total_rows,
       COUNT({column}) AS non_null_count,
       ROUND(COUNT({column})::numeric / NULLIF(COUNT(*), 0) * 100, 2) AS fill_pct
FROM {table};
```

### Template: Post-Deploy Verification

Run within 5 minutes of deployment:

```sql
-- SCAFFOLD: Verify against production schema before executing
-- Verify all data migrated (no orphaned NULLs)
SELECT COUNT(*) FROM {table}
WHERE {new_column} IS NULL AND {old_column} IS NOT NULL;
-- Expected: 0

-- Verify transformation correctness
SELECT COUNT(*) FROM {table}
WHERE {new_column} != {expected_transform}({old_column});
-- Expected: 0

-- Verify referential integrity preserved
SELECT COUNT(*) FROM {child_table} c
LEFT JOIN {parent_table} p ON c.{fk_column} = p.id
WHERE p.id IS NULL;
-- Expected: 0
```

### Template: Data Volume Estimation

```sql
-- SCAFFOLD: Verify against production schema before executing
-- Estimate migration runtime based on table size
SELECT relname AS table_name,
       n_live_tup AS estimated_row_count,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname = '{table}'
ORDER BY n_live_tup DESC;
```

---

## GATE Finding Detailed Patterns

### GATE-001: Missing Rollback Plan for Destructive Migration

**Trigger:** Migration contains DROP TABLE, DROP COLUMN, TRUNCATE, or irreversible data transformation without documented rollback strategy.

**Required safeguards:**
- Database snapshot/backup taken before migration
- Point-of-no-return explicitly documented
- Rollback time estimate provided
- Team notification plan documented

### GATE-002: Column Rename Without Dual-Write Period

**Trigger:** Direct `ALTER TABLE RENAME COLUMN` or equivalent without dual-write code.

**Required safeguards:**
- Dual-write code deployed before migration
- Both old and new column names functional during transition
- All consumers audited (models, serializers, jobs, APIs, views, caches)
- Migration split into at minimum 3 deploy cycles

### GATE-003: NOT NULL Without Default on Populated Table

**Trigger:** `ALTER TABLE ADD COLUMN ... NOT NULL` without `DEFAULT` on table with existing rows.

**Required safeguards:**
- Multi-step approach: add nullable, backfill, then set NOT NULL
- Or: add with DEFAULT and backfill in separate migration
- Lock duration estimated for table size

### GATE-004: Foreign Key on High-Traffic Table Without Index

**Trigger:** FK constraint added to table with >10K rows without index on FK column.

**Required safeguards:**
- Index created CONCURRENTLY before FK constraint
- FK added with NOT VALID, then validated separately

### GATE-005: Data Transformation Without Validation Query

**Trigger:** UPDATE/INSERT based on data transformation without pre/post verification queries.

**Required safeguards:**
- Pre-deploy baseline query documented
- Post-deploy verification query documented
- Expected results documented for both

### GATE-006: Large Table Migration Without Batching

**Trigger:** UPDATE/DELETE on table with >100K rows without LIMIT/batch strategy.

**Required safeguards:**
- Batched execution (1K-10K rows per batch)
- Progress logging between batches
- Ability to pause/resume mid-migration

### GATE-007: Enum/Type Change Without Consumer Audit

**Trigger:** Enum values added/removed or column type changed without auditing all code that reads/compares the column.

**Required safeguards:**
- All switch/match/case statements on the enum identified
- All serializers/deserializers for the type identified
- All API contracts that expose the value identified

### GATE-008: Multi-Service Schema Change Without Deployment Sequencing

**Trigger:** Schema change affects tables read/written by multiple services without documented deployment order.

**Required safeguards:**
- Deployment order documented (which service deploys first)
- Backward compatibility verified for each deployment step
- Rollback order documented (reverse of deployment)

### GATE-009: Index on High-Traffic Table Without CONCURRENTLY

**Trigger:** CREATE INDEX without CONCURRENTLY on table with >10K rows (PostgreSQL) or equivalent non-blocking strategy.

**Required safeguards:**
- Use CREATE INDEX CONCURRENTLY
- Disable transaction wrapping for the migration (CONCURRENTLY cannot run in transaction)
- Verify index creation completed successfully (CONCURRENTLY can fail silently)

### GATE-010: Non-Idempotent Data Backfill

**Trigger:** Data migration that produces different results when run multiple times.

**Required safeguards:**
- WHERE clause excludes already-migrated rows
- Or: migration checks for existing data before inserting
- Documented: "safe to re-run" or "one-shot only"

---

## Multi-Database Migration Sequencing

When a change spans multiple databases/services:

1. Deploy schema changes to all databases FIRST (additive only)
2. Deploy application code that writes to new schema
3. Run backfill migrations
4. Deploy code that reads from new schema
5. Remove old schema (separate deploy cycle)

**Sequencing rules:**
- Additive changes (ADD COLUMN, CREATE TABLE) can be deployed in parallel
- Destructive changes (DROP COLUMN, DROP TABLE) MUST be deployed last, after all consumers updated
- Data migrations run AFTER all schema changes are deployed
- Each step must be independently rollback-able

---

## Rollback Failure Recovery

When a down migration fails mid-execution:

1. **Assess:** Is the database in a consistent state? (partial column drop = inconsistent)
2. **If inconsistent:** Restore from most recent snapshot/backup
3. **If consistent but wrong:** Write a new forward migration to fix
4. **NEVER:** Re-run a failed down migration without understanding why it failed

### Recovery Decision Matrix

| State After Failure | Recovery Strategy | Time Estimate |
|-------------------|-------------------|---------------|
| Schema inconsistent (partial DDL) | Restore from backup | Minutes to hours |
| Data partially migrated | New forward migration to fix | Minutes |
| Locks held (migration killed) | Wait for lock timeout or manual lock release | Seconds to minutes |
| Transaction rolled back cleanly | Re-run after fixing cause | Minutes |

### Post-Recovery Verification

After any rollback or recovery:

```sql
-- SCAFFOLD: Verify against production schema before executing
-- Verify schema state matches expected
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = '{table}'
ORDER BY ordinal_position;

-- Verify constraint state
SELECT constraint_name, constraint_type
FROM information_schema.table_constraints
WHERE table_name = '{table}';

-- Verify index state
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = '{table}';
```
