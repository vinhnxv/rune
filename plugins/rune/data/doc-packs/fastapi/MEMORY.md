# FastAPI Doc Pack

## Etched — FastAPI: Dependency Injection Patterns (2026-03-01)

**Source**: `doc-pack:fastapi@1.0.0`
**Category**: pattern

### Dependency Injection
- `Depends()` is FastAPI's DI system — use for DB sessions, auth, config
- Dependencies can depend on other dependencies — forms a DAG
- `yield` dependencies for cleanup (e.g., DB session commit/rollback)
- Class-based dependencies: `class Pagination: def __init__(self, skip: int = 0, limit: int = 100)`

### Common Dependency Patterns
```python
# DB session with cleanup
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        yield session

# Auth dependency chain
async def get_current_user(token: str = Depends(oauth2_scheme)) -> User: ...
async def get_admin_user(user: User = Depends(get_current_user)) -> User: ...
```

### Gotchas
- `Depends()` without parentheses (`Depends(get_db)`) — NOT `Depends(get_db())`
- Dependencies are called per-request by default — use `functools.lru_cache` for singletons
- Background tasks get their own dependency instances — do NOT share DB sessions
- `yield` dependencies MUST catch exceptions for proper cleanup

## Etched — FastAPI: Pydantic v2 Integration (2026-03-01)

**Source**: `doc-pack:fastapi@1.0.0`
**Category**: pattern

### Pydantic v2 Patterns
- `model_validator(mode="before")` replaces `@validator(pre=True)`
- `field_validator` replaces `@validator` — different decorator syntax
- `model_config = ConfigDict(from_attributes=True)` replaces `class Config: orm_mode = True`
- Use `Annotated[int, Field(gt=0)]` for reusable validated types

### Request/Response Models
- Separate `Create`, `Update`, `Response` schemas — never use ORM model directly
- `model_dump(exclude_unset=True)` for PATCH operations — distinguish None from missing
- `response_model_exclude_none=True` on route decorator for clean JSON output
- Use `TypeAdapter` for validating non-model types (lists, dicts)

## Etched — FastAPI: Async Patterns and Security (2026-03-01)

**Source**: `doc-pack:fastapi@1.0.0`
**Category**: pattern

### Async Best Practices
- Use `async def` for I/O-bound routes (DB, HTTP calls, file I/O)
- Use `def` (sync) for CPU-bound routes — FastAPI runs them in a thread pool
- Never mix `sync` DB calls in `async` routes — use async driver (asyncpg, aiosqlite)
- `BackgroundTasks` for fire-and-forget: `background_tasks.add_task(send_email, user.email)`

### Security Middleware
- `OAuth2PasswordBearer(tokenUrl="/token")` for JWT auth
- CORS: `CORSMiddleware` — always configure `allow_origins` explicitly, never `["*"]` in production
- Rate limiting: use `slowapi` or custom middleware — FastAPI has no built-in rate limiter
- Request validation is automatic via Pydantic — but validate business logic in dependencies

### Error Handling
- `HTTPException(status_code=404, detail="Not found")` for expected errors
- Custom exception handlers: `@app.exception_handler(MyError)` for domain errors
- Use `status.HTTP_201_CREATED` constants — not raw integers
- Validation errors return 422 automatically — customize with `@app.exception_handler(RequestValidationError)`
