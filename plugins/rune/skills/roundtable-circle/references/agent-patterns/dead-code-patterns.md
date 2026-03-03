# Dead Code & Unwired Code Detection Patterns Reference

Framework-specific code examples and grep templates for Wraith Finder analysis. Covers classical dead code, DI wiring verification, router registration, and event handler subscription patterns across Python, Rust, and TypeScript.

---

## 1. Classical Dead Code Detection

### 1A. Unused Functions/Classes

```python
# Check: Is this function called anywhere?
def legacy_format_date(date):  # grep shows 0 callers
    return date.strftime("%Y-%m-%d")
# Note: Check for dynamic references before flagging!
```

```rust
// Rust: Check for #[allow(dead_code)] as a smell — it may mask real issues
#[allow(dead_code)]
fn calculate_score(input: &Data) -> f64 { ... }  // Is this actually used?
```

```typescript
// TypeScript: Exported but never imported anywhere
export function formatCurrency(amount: number): string { ... }  // 0 importers
```

### 1B. Unreachable Code

```python
# BAD: Code after unconditional return
def process(data):
    if not data:
        return None
    return transform(data)
    cleanup(data)  # Never reached!
```

```rust
// BAD: Match arm that can never be reached
match status {
    Status::Active => handle_active(),
    Status::Inactive => handle_inactive(),
    _ => unreachable!(),  // Fine IF enum is exhaustive
}
```

```typescript
// BAD: Dead branch after type narrowing
function handle(value: string | number) {
    if (typeof value === "string") return value.toUpperCase();
    if (typeof value === "number") return value.toFixed(2);
    return value;  // Never reached — TS knows this is `never`
}
```

### 1C. Commented-Out Code

```python
# BAD: Large blocks of commented code — use git history instead
# def old_implementation():
#     for item in items:
#         if item.status == "active":
#             process(item)
#     return result
```

### 1D. Unused Imports

```python
from datetime import datetime, timedelta  # timedelta unused
import json  # json never used in file
```

```typescript
import { useState, useEffect, useCallback } from "react";  // useCallback unused
```

```rust
use std::collections::{HashMap, BTreeMap};  // BTreeMap unused (rustc warns)
```

---

## 2. DI Wiring Verification (Framework-Agnostic)

The most critical gap in AI-generated code: services that exist but are never injected.

### Python DI Patterns

| Framework | Registration | Injection | Verify |
|-----------|-------------|-----------|--------|
| **Dishka** | `@provide(scope=Scope.REQUEST)` | `FromDishka[ServiceType]` | Container.py vs usage |
| **FastAPI Depends** | `def get_service(): ...` | `Depends(get_service)` | Depends() vs definition |
| **Django** | `INSTALLED_APPS`, signals | `from app.services import ...` | apps.py + urls.py |
| **inject** | `@inject.autoparams()` | Constructor injection | `inject.configure()` |

```python
# DETECTION: Find all service/repository classes
# Grep: class \w+(Service|Repository|Handler|Provider|Factory|Gateway)
# Then verify EACH has:
#   1. Registration in DI container
#   2. At least one injection point (consumer)
```

### Rust DI Patterns

| Framework | Registration | Injection | Verify |
|-----------|-------------|-----------|--------|
| **Manual (common)** | `impl` blocks + `pub fn new()` | Constructor params | `::new()` callers |
| **shaku** | `#[derive(Component)]` | `#[inject]` | Module::build() |
| **Actix DI** | `.app_data(Data::new(...))` | `data: web::Data<T>` | configure() chain |

```rust
// DETECTION: Find all structs with impl blocks
// Grep: pub struct \w+(Service|Repository|Handler|Client)
// Then verify EACH has:
//   1. At least one `::new()` or `::default()` call
//   2. The instance is passed to a consumer (route, other service)

// Common Rust unwired pattern:
pub struct AnalyticsService { /* fields */ }
impl AnalyticsService {
    pub fn new(db: Pool) -> Self { Self { db } }
    pub async fn calculate(&self) -> Result<Metrics> { ... }
}
// Service exists, compiles, but is NEVER instantiated anywhere!
```

### TypeScript DI Patterns

| Framework | Registration | Injection | Verify |
|-----------|-------------|-----------|--------|
| **NestJS** | `@Injectable()` + `@Module({ providers })` | Constructor injection | module.ts providers array |
| **tsyringe** | `@injectable()` | `@inject()` or `container.resolve()` | container.register() |
| **inversify** | `@injectable()` | `@inject(TYPES.X)` | container.bind() |
| **Angular** | `@Injectable({ providedIn })` | Constructor injection | NgModule providers |

```typescript
// DETECTION: Find all @Injectable() or service classes
// Grep: @Injectable|class \w+(Service|Repository|Handler|Gateway)
// Then verify EACH has:
//   1. Listed in a module's providers array (NestJS)
//   2. At least one constructor injection consumer

// Common NestJS unwired pattern:
@Injectable()
export class AnalyticsService {
    async getMetrics(id: string): Promise<Metrics> { ... }
}
// Created but NOT added to any module's providers[] array!
```

---

## 3. Router/Endpoint Registration

### Python

```python
# FastAPI: Every router file must be include_router'd
# Grep: router\s*=\s*APIRouter → find definitions
# Grep: include_router → find registrations
# DIFF: Any router NOT included = orphaned endpoints (all return 404)

# Flask: Every Blueprint must be registered
# Grep: Blueprint( → find definitions
# Grep: register_blueprint → find registrations

# Django: Every view must be in urlpatterns
# Grep: def \w+_view|class \w+View → find views
# Grep: path\(|re_path\( → find URL patterns
```

### Rust

```rust
// Actix-web: Every handler must be .service()'d or .configure()'d
// Grep: #\[get\|#\[post\|#\[put\|#\[delete\|#\[patch → find handlers
// Grep: \.service\(|\.configure\(|\.route\( → find registrations

// Axum: Every handler must be in Router::new().route()
// Grep: async fn \w+\(.*extract → find handlers
// Grep: \.route\(|\.merge\( → find route registrations

// Rocket: Every handler must be routes![] or mount()'d
// Grep: #\[get\|#\[post → find handlers
// Grep: routes!\[|\.mount\( → find registrations
```

### TypeScript

```typescript
// Express: Every router must be app.use()'d
// Grep: Router\(\)|express\.Router → find definitions
// Grep: app\.use\(|router\.use\( → find registrations

// NestJS: Every @Controller must be in a @Module's controllers[]
// Grep: @Controller → find controllers
// Grep: controllers:\s*\[ → find module registrations

// Fastify: Every plugin must be .register()'d
// Grep: fastify\.register|app\.register → find registrations
```

---

## 4. Event Handler/Subscription Verification

### Python

```python
# Django signals: @receiver must match signal
# Grep: @receiver\( → find handlers
# Grep: \.connect\( → find manual connections

# Event bus: Handlers must be subscribe()'d
# Grep: class \w+Handler.*handle → find handlers
# Grep: \.subscribe\(|\.register_handler\( → find subscriptions

# Celery: @app.task or @shared_task must be called somewhere
# Grep: @app\.task|@shared_task → find task definitions
# Grep: \.delay\(|\.apply_async\( → find task invocations
```

### Rust

```rust
// tokio channels: Receivers must be .recv()'d
// Grep: mpsc::channel|broadcast::channel → find channel creation
// Grep: \.recv\(\)|\.recv_async\( → find consumers

// Trait-based handlers: impl Handler must be registered
// Grep: impl.*Handler.*for → find implementations
// Grep: register_handler|add_handler|subscribe → find registrations
```

### TypeScript

```typescript
// EventEmitter: .on() handlers must match .emit() events
// Grep: \.on\(|\.addEventListener\( → find listeners
// Grep: \.emit\(|\.dispatchEvent\( → find emitters

// NestJS: @EventPattern/@MessagePattern must match gateway
// Grep: @EventPattern|@MessagePattern → find handlers
// Grep: @WebSocketGateway|@Controller → find registrations

// RxJS: .subscribe() must have matching .next()/.emit()
// Grep: \.subscribe\( → find subscribers
// Grep: \.next\(|\.emit\( → find emitters
```
