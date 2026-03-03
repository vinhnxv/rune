# Data Integrity & Migration Safety Patterns Reference

Multi-framework code examples for Forge Keeper analysis. Covers migration reversibility, table lock analysis, data transformation safety, transaction boundaries, schema change patterns, and privacy compliance.

---

## 1. Migration Reversibility

Every migration must have a working downgrade/rollback path.

**Python (Alembic)**
```python
# BAD: Empty downgrade — cannot rollback
def upgrade():
    op.add_column('users', sa.Column('status', sa.String(50), nullable=False, server_default='active'))

def downgrade():
    pass  # P1: No rollback!

# GOOD: Complete downgrade
def upgrade():
    op.add_column('users', sa.Column('status', sa.String(50), nullable=False, server_default='active'))

def downgrade():
    op.drop_column('users', 'status')
```

**Python (Django)**
```python
# BAD: RunPython without reverse_code
migrations.RunPython(populate_status)

# GOOD: Reversible RunPython
migrations.RunPython(populate_status, reverse_code=clear_status)
```

**TypeScript (Knex)**
```typescript
// BAD: Missing down()
export async function up(knex: Knex): Promise<void> {
  await knex.schema.alterTable('users', t => t.string('status'));
}
export async function down(knex: Knex): Promise<void> {
  // empty — P1!
}

// GOOD: Complete down()
export async function down(knex: Knex): Promise<void> {
  await knex.schema.alterTable('users', t => t.dropColumn('status'));
}
```

**TypeScript (Prisma)**
```prisma
// Prisma migrations are auto-generated — verify the down.sql exists
// and correctly reverses the up.sql operations
// Check: prisma/migrations/{timestamp}/migration.sql
```

**Rust (Diesel)**
```rust
// BAD: down.sql missing or empty
// diesel/migrations/{timestamp}/down.sql → empty file

// GOOD: Proper down.sql
// down.sql
// DROP TABLE IF EXISTS user_profiles;
```

**Rust (sqlx)**
```sql
-- sqlx reversible migrations use {timestamp}_name.up.sql / .down.sql
-- Verify both files exist and are consistent
```

**Detection patterns:**
```
# Find empty downgrade functions (Python/Alembic)
rg "def downgrade\(\)" -A 3 | rg "pass$|return$"

# Find RunPython without reverse_code (Django)
rg "RunPython\([^,]+\)" --type py | rg -v "reverse_code"

# Find empty down() functions (TypeScript/Knex)
rg "async function down" -A 3 --type ts | rg "\{\s*\}"

# Find empty down.sql files (Rust/Diesel)
find . -name "down.sql" -empty
```

---

## 2. Table Lock Analysis

Certain DDL operations acquire exclusive locks that block all reads and writes.

| Operation | PostgreSQL Lock | MySQL Lock | Risk |
|-----------|----------------|------------|------|
| `ADD COLUMN` (nullable) | ACCESS EXCLUSIVE (brief) | Metadata lock (brief) | Low |
| `ADD COLUMN` (NOT NULL, no default) | ACCESS EXCLUSIVE | Table copy | **P1** |
| `ADD COLUMN` (NOT NULL, with default) | ACCESS EXCLUSIVE (brief, PG 11+) | Table copy | Medium |
| `DROP COLUMN` | ACCESS EXCLUSIVE | Table copy | **Review** |
| `CREATE INDEX` | SHARE | Shared lock | **Use CONCURRENTLY** |
| `CREATE INDEX CONCURRENTLY` | ShareUpdateExclusive | Online DDL | Safe |
| `ALTER COLUMN TYPE` | ACCESS EXCLUSIVE | Table copy | **P1** |
| `ADD CONSTRAINT` | ACCESS EXCLUSIVE | Metadata lock | **Use NOT VALID** |
| `RENAME TABLE/COLUMN` | ACCESS EXCLUSIVE | Metadata lock | **Review** |

**Safe deployment patterns:**

```python
# PostgreSQL: Concurrent index creation (Alembic)
# BAD: Blocks writes during index creation
op.create_index('ix_users_email', 'users', ['email'])

# GOOD: Non-blocking concurrent index
op.execute('CREATE INDEX CONCURRENTLY ix_users_email ON users (email)')
# NOTE: CONCURRENTLY cannot run inside a transaction — requires:
# from alembic import context
# context.configure(..., transaction_per_migration=False)
```

```python
# PostgreSQL: Two-phase constraint addition
# BAD: Locks table for full constraint scan
op.create_check_constraint('ck_positive_amount', 'orders', 'amount > 0')

# GOOD: NOT VALID + separate VALIDATE (two migrations)
# Migration 1: Brief lock
op.execute("ALTER TABLE orders ADD CONSTRAINT ck_positive_amount CHECK (amount > 0) NOT VALID")
# Migration 2: Non-blocking validation
op.execute("ALTER TABLE orders VALIDATE CONSTRAINT ck_positive_amount")
```

---

## 3. Data Transformation Safety

Data migrations (backfills, transformations) must handle edge cases.

```python
# BAD: NULL concatenation produces NULL in PostgreSQL
op.execute("UPDATE users SET name = first_name || ' ' || last_name")

# GOOD: Explicit NULL handling
op.execute("""
    UPDATE users
    SET name = COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')
    WHERE name IS NULL
""")
```

```python
# BAD: Unbounded UPDATE on large table — locks entire table, fills WAL
op.execute("UPDATE orders SET status = 'active' WHERE status IS NULL")

# GOOD: Batched update with progress
op.execute("""
    UPDATE orders SET status = 'active'
    WHERE id IN (
        SELECT id FROM orders WHERE status IS NULL LIMIT 10000
    )
""")
# Repeat until 0 rows affected
```

```typescript
// BAD: Type cast without validation
await knex.raw("ALTER TABLE prices ALTER COLUMN amount TYPE numeric USING amount::numeric");

// GOOD: Verify data is castable first
const invalid = await knex.raw(
  "SELECT count(*) FROM prices WHERE amount !~ '^[0-9]+(\\.[0-9]+)?$'"
);
if (invalid.rows[0].count > 0) throw new Error("Non-numeric amounts exist!");
```

---

## 4. Transaction Boundaries

Operations that modify multiple tables or combine reads and writes must be atomic.

```python
# BAD: Split transaction — partial failure leaves inconsistent state
async def create_order(session, user_id, items):
    order = Order(user_id=user_id)
    session.add(order)
    await session.commit()  # Commits order

    for item in items:
        line = OrderLine(order_id=order.id, item=item)
        session.add(line)
    await session.commit()  # If this fails, order exists without lines!

# GOOD: Single transaction
async def create_order(session, user_id, items):
    async with session.begin():
        order = Order(user_id=user_id)
        session.add(order)
        await session.flush()  # Get order.id without committing
        for item in items:
            session.add(OrderLine(order_id=order.id, item=item))
    # Both committed atomically
```

```typescript
// BAD: No transaction — partial failure
async function transferFunds(from: string, to: string, amount: number) {
  await db('accounts').where({ id: from }).decrement('balance', amount);
  await db('accounts').where({ id: to }).increment('balance', amount);
  // If second query fails, money disappears!
}

// GOOD: Transaction wrapping
async function transferFunds(from: string, to: string, amount: number) {
  await db.transaction(async (trx) => {
    await trx('accounts').where({ id: from }).decrement('balance', amount);
    await trx('accounts').where({ id: to }).increment('balance', amount);
  });
}
```

```rust
// BAD: Manual commit with no error handling
sqlx::query("INSERT INTO orders ...").execute(&pool).await?;
sqlx::query("INSERT INTO order_lines ...").execute(&pool).await?;
// No atomicity guarantee!

// GOOD: Transaction
let mut tx = pool.begin().await?;
sqlx::query("INSERT INTO orders ...").execute(&mut *tx).await?;
sqlx::query("INSERT INTO order_lines ...").execute(&mut *tx).await?;
tx.commit().await?;
```

---

## 5. Referential Integrity Examples

```python
# BAD: Soft delete breaks FK queries — orphaned references
class User(Base):
    is_deleted = Column(Boolean, default=False)

# Queries that join on user_id may return deleted users!
# Solution: Filtered unique index or application-level check

# BAD: Missing cascade consideration
op.drop_table('users')  # What about orders.user_id FK?

# GOOD: Check for dependent tables first
# SELECT table_name, constraint_name FROM information_schema.table_constraints
# WHERE constraint_type = 'FOREIGN KEY' AND ...
```

---

## 6. Schema Change Patterns (Safe Deployment)

Multi-step schema changes for zero-downtime deployments:

**Adding a NOT NULL column to an existing table:**
```
Step 1: ADD COLUMN ... NULL (no lock, no data change)
Step 2: Backfill data (batched UPDATE)
Step 3: ALTER COLUMN SET NOT NULL (separate migration, after verification)
```

**Renaming a column:**
```
Step 1: ADD new column (nullable)
Step 2: Backfill new column from old column
Step 3: Deploy code reading BOTH columns (COALESCE(new, old))
Step 4: Deploy code writing to BOTH columns
Step 5: Deploy code reading only new column
Step 6: DROP old column (separate migration)
```

**Changing column type:**
```
Step 1: ADD new column with target type
Step 2: Backfill with CAST/conversion
Step 3: Swap application code to use new column
Step 4: DROP old column
```

---

## 7. Privacy & Data Compliance

```python
# BAD: PII in plain text
class User(Base):
    ssn = Column(String(11))  # P1: Unencrypted SSN!
    email = Column(String)     # Review: PII without encryption consideration

# BAD: No audit trail on PII changes
def update_email(user, new_email):
    user.email = new_email
    session.commit()  # No record of what changed!

# GOOD: Audit trail
def update_email(user, new_email):
    old_email = user.email
    user.email = new_email
    audit_log.record(
        entity="user", entity_id=user.id,
        field="email", old_value=mask(old_email), new_value=mask(new_email)
    )
    session.commit()
```

**PII field detection patterns:**
```
# Find potential PII columns
rg "(ssn|social_security|tax_id|passport|credit_card|card_number)" --type py --type ts --type rs
rg "(phone_number|date_of_birth|address|salary|bank_account)" --type py --type ts --type rs
```

---

## 8. Dual-Write Migration Pattern

When renaming or moving a column in a live system, dual-write ensures zero-downtime data consistency.

**Python (Alembic) — Dual-Write Column Rename**
```python
# Migration 1: Add new column
def upgrade():
    op.add_column('users', sa.Column('display_name', sa.String(255), nullable=True))

def downgrade():
    op.drop_column('users', 'display_name')
```

```python
# Application code: Dual-write phase
class User(Base):
    name = Column(String(255))           # Old column (still primary)
    display_name = Column(String(255))   # New column (being populated)

    def set_name(self, value):
        self.name = value
        self.display_name = value  # Dual-write to both columns
```

```python
# Migration 2: Backfill (batched, idempotent)
def upgrade():
    # -- SCAFFOLD: Verify against production schema before executing
    conn = op.get_bind()
    while True:
        result = conn.execute(text("""
            UPDATE users SET display_name = name
            WHERE display_name IS NULL
            LIMIT 10000
        """))
        if result.rowcount == 0:
            break
```

**TypeScript (Knex) — Dual-Write Column Rename**
```typescript
// Application code: Dual-write phase
async function updateUserName(id: string, name: string) {
  await db('users')
    .where({ id })
    .update({
      name,           // Old column
      display_name: name,  // New column — dual-write
    });
}
```

**Detection: Incomplete Dual-Write**
```
# Find column additions without corresponding dual-write code
# Step 1: Identify new columns in migration
rg "add_column|addColumn|ADD COLUMN" --type py --type ts --type rb

# Step 2: Check if application writes to both old and new
rg "(old_column_name|new_column_name)" --type py --type ts --type rb

# Step 3: Check background jobs and serializers (often missed)
rg "(old_column_name)" --glob "*job*" --glob "*worker*" --glob "*serializer*" --glob "*task*"
```

**WebSocket/SSE dual-write consideration:**
When migrating real-time event schemas, both old and new event shapes must be emitted during the transition period. Subscribers may be running old or new client code simultaneously.
