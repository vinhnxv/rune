# FastAPI Doc Pack

## Etched — FastAPI: Dependency Injection Patterns (2026-03-11)

**Source**: `doc-pack:fastapi@1.0.0`
**Category**: pattern

### Core DI Pattern

- Use `Depends()` for dependency injection — FastAPI resolves the dependency tree automatically
- Dependencies can be functions, classes, or generators (for cleanup via `yield`)
- Sub-dependencies are resolved recursively — use for layered auth/db/config
- Dependencies with `yield` run cleanup after response is sent (like context managers)

### Common Dependencies

```python
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        yield session

async def get_current_user(token: str = Depends(oauth2_scheme)) -> User:
    return await verify_token(token)

@app.get("/items")
async def list_items(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    ...
```

### Gotchas

- `Depends()` in default parameter position — not as a type annotation
- Class-based dependencies: `__init__` params become query/path params
- Generator dependencies (`yield`) MUST have exactly one `yield`
- Use `Annotated[Type, Depends(dep)]` (Pydantic v2 style) for cleaner signatures

## Etched — FastAPI: Pydantic v2 Integration (2026-03-11)

**Source**: `doc-pack:fastapi@1.0.0`
**Category**: pattern

### Model Patterns

- Use `model_validator(mode="before")` instead of deprecated `@validator`
- Use `field_validator` instead of `@validator` for individual fields
- `model_config = ConfigDict(from_attributes=True)` replaces `class Config: orm_mode = True`
- Computed fields: `@computed_field` decorator instead of custom `@property` + schema

### Request/Response Models

- Separate input (`Create`), output (`Read`), and update (`Update`) models
- Use `model_dump(exclude_unset=True)` for PATCH operations — only update provided fields
- `Field(json_schema_extra={"example": ...})` replaces `schema_extra` in Field
- Use `Annotated[str, Field(min_length=1, max_length=100)]` for validated types

### Migration from Pydantic v1

- `from pydantic import BaseModel` — same import, new internals
- `.dict()` becomes `.model_dump()`, `.json()` becomes `.model_dump_json()`
- `parse_obj()` becomes `model_validate()`, `parse_raw()` becomes `model_validate_json()`
- `update_forward_refs()` becomes `model_rebuild()` (usually automatic now)

## Etched — FastAPI: Async Patterns and Background Tasks (2026-03-11)

**Source**: `doc-pack:fastapi@1.0.0`
**Category**: pattern

### Async Best Practices

- Use `async def` for I/O-bound endpoints (database, HTTP calls, file I/O)
- Use plain `def` for CPU-bound endpoints — FastAPI runs them in a thread pool
- Never mix sync I/O in `async def` — blocks the event loop
- Use `httpx.AsyncClient` (not `requests`) for outbound HTTP in async endpoints

### Background Tasks

- `BackgroundTasks` parameter: lightweight, in-process tasks after response
- For heavy work: use Celery, ARQ, or similar task queue — not BackgroundTasks
- Background tasks share the request's dependency context (db sessions, etc.)
- Multiple background tasks execute sequentially in order added

### Middleware and Security

- `@app.middleware("http")` for cross-cutting concerns (logging, timing, CORS)
- `OAuth2PasswordBearer(tokenUrl="token")` for JWT authentication
- Use `Security()` instead of `Depends()` when scopes are needed
- Rate limiting: use `slowapi` or custom middleware — not built into FastAPI
