# SQLAlchemy Doc Pack

## Etched — SQLAlchemy: 2.0 Query Style (2026-03-11)

**Source**: `doc-pack:sqlalchemy@1.0.0`
**Category**: pattern

### Select Statement Pattern

- Use `select()` function instead of `session.query()` (legacy 1.x style)
- Execute via `session.execute(stmt)` — returns `Result` object
- Use `.scalars()` for single-column results: `session.execute(stmt).scalars().all()`
- Use `.one()`, `.one_or_none()`, `.first()` for single-row results

### Common Query Patterns

```python
from sqlalchemy import select, func

# Basic select
stmt = select(User).where(User.email == email)
user = session.execute(stmt).scalar_one_or_none()

# Join
stmt = select(User, Address).join(User.addresses).where(Address.city == "NYC")

# Aggregation
stmt = select(func.count()).select_from(User).where(User.active == True)
count = session.execute(stmt).scalar()

# Subquery
subq = select(func.max(Order.total)).correlate(User).scalar_subquery()
stmt = select(User).where(User.balance > subq)
```

### Migration from 1.x Query API

- `session.query(User).filter_by(name="x")` becomes `select(User).where(User.name == "x")`
- `session.query(User).get(1)` becomes `session.get(User, 1)`
- `query.count()` becomes `select(func.count()).select_from(User)`
- `query.join(Address)` becomes `select(User).join(User.addresses)`

## Etched — SQLAlchemy: Async Session Patterns (2026-03-11)

**Source**: `doc-pack:sqlalchemy@1.0.0`
**Category**: pattern

### Async Engine Setup

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession

engine = create_async_engine("postgresql+asyncpg://...", echo=False)
async_session = async_sessionmaker(engine, expire_on_commit=False)
```

### Session Usage

- Always use `async with async_session() as session:` — ensures cleanup
- `expire_on_commit=False` is critical for async — prevents lazy loads after commit
- Use `await session.flush()` to get generated IDs before commit
- Wrap mutations in `async with session.begin():` for auto-commit/rollback

### Relationship Loading in Async

- Lazy loading DOES NOT WORK in async — always use eager loading
- `selectinload(User.posts)` — separate SELECT per relationship (good for collections)
- `joinedload(User.profile)` — JOIN in same query (good for one-to-one)
- `subqueryload(User.orders)` — subquery strategy (good for large collections)
- Use `awaitable_attrs`: `posts = await user.awaitable_attrs.posts` (2.0.20+)

## Etched — SQLAlchemy: Alembic Migration Patterns (2026-03-11)

**Source**: `doc-pack:sqlalchemy@1.0.0`
**Category**: pattern

### Migration Best Practices

- Always review auto-generated migrations — Alembic misses: renamed columns (shows as drop+add), data migrations, index changes on existing columns
- Use `--autogenerate` for schema changes, manual for data migrations
- One migration per logical change — avoid combining unrelated schema changes
- Test migrations: `alembic upgrade head` AND `alembic downgrade -1` in CI

### Common Migration Operations

- Rename column: `op.alter_column('table', 'old', new_column_name='new')`
- Add nullable column then backfill: two migrations (add nullable, backfill, alter to non-null)
- Enum changes: use `op.execute()` with raw SQL for PostgreSQL enum modifications
- Batch operations for SQLite: `with op.batch_alter_table('table') as batch_op:`

### Async Alembic Setup

- `env.py` needs `run_async()` wrapper for async engines
- Use `connectable = async_engine` in `env.py` with `run_sync` callback
- Migrations themselves are always synchronous — only the connection setup is async
