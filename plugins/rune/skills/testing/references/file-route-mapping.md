# File-to-Route Mapping Patterns

## Purpose

Maps changed frontend files to testable URLs for E2E browser testing.
The mapping is framework-specific and heuristic-based.

## Next.js (App Router)

```
src/app/page.tsx           → /
src/app/login/page.tsx     → /login
src/app/users/page.tsx     → /users
src/app/users/[id]/page.tsx → /users/1  (use test fixture ID)
src/app/api/users/route.ts → /api/users (API route — integration, not E2E)
```

**Detection**: `src/app/` or `app/` directory with `page.tsx`/`page.jsx` files.

## Next.js (Pages Router)

```
pages/index.tsx            → /
pages/login.tsx            → /login
pages/users/index.tsx      → /users
pages/users/[id].tsx       → /users/1
pages/api/users.ts         → /api/users (API — integration, not E2E)
```

**Detection**: `pages/` directory with `.tsx`/`.jsx` files (no `src/app/`).

## Rails

```
app/views/users/index.html.erb    → /users
app/views/users/show.html.erb     → /users/1
app/views/sessions/new.html.erb   → /login
app/controllers/users_controller.rb → /users (infer from controller)
```

**Detection**: `config/routes.rb` exists + `app/views/` directory.
Parse routes: `rails routes --expanded` or read `config/routes.rb`.

## Django

```
templates/users/list.html     → /users/
templates/users/detail.html   → /users/1/
templates/auth/login.html     → /accounts/login/
```

**Detection**: `urls.py` files with `urlpatterns`.
Parse: read `urls.py` for `path()` definitions.

## Generic SPA (React Router, Vue Router)

```
src/pages/Login.tsx         → /login (if router maps Login to /login)
src/pages/Dashboard.tsx     → /dashboard
src/components/UserForm.tsx  → (component — find parent page)
```

**Detection**: Look for router config in `src/App.tsx`, `src/router.ts`, etc.
Parse route definitions from JSX `<Route>` elements or route config objects.

## Backend File → Route (via Impact Tracing)

When changed files are backend-only, trace impact to frontend routes.
See [backend-impact-tracing.md](../../test-browser/references/backend-impact-tracing.md) for the full algorithm.

```
# Controllers/handlers → extract API endpoints → grep frontend for consumers
app/controllers/users_controller.rb  → /api/users → grep fetch("/api/users") → /users page
backend/views/user_views.py          → /api/users → grep api.get("/users") → /users page
src/controllers/auth.controller.ts   → /api/auth  → grep fetch("/api/auth") → /login page

# Models/migrations → find consuming controllers → extract endpoints → trace to frontend
db/migrate/20240101_add_role.rb       → User model → UsersController → /api/users → /users page
backend/models/order.py               → Order model → OrderViewSet → /api/orders → /orders page

# Services → find consuming controllers → extract endpoints → trace to frontend
backend/services/payment_service.py   → PaymentController → /api/payments → /checkout page
src/services/auth.service.ts          → AuthController → /api/auth → /login page
```

**Detection**: Files matching backend patterns (controllers, models, services, migrations,
serializers, handlers, resolvers) that don't match any frontend pattern.

## Mapping Algorithm

```
1. Classify changed files: frontend vs backend vs shared
2. For frontend files:
   a. Page/view file → direct route mapping
   b. Component file → find importing page → route mapping
   c. Layout/wrapper file → affects multiple routes → test top-level route
   d. Utility/helper file → no route (skip E2E for this file)
3. For backend files (when no frontend files, or mixed):
   a. Controller/handler → extract API endpoint → find frontend consumer → route
   b. Model/migration → find consuming controller → extract endpoint → trace to frontend
   c. Service/repository → find consuming controller → extract endpoint → trace to frontend
   d. Fallback: extract resource name from filename → grep frontend for resource
4. Combine and deduplicate routes
5. Cap at max_routes (talisman config, default: 3)
6. Priority: frontend-direct > backend HIGH confidence > backend MEDIUM > backend LOW
   Within each tier: login/auth routes > data mutation routes > read-only routes
```

## URL Construction

```
base_url = talisman.testing.tiers.e2e.base_url ?? "http://localhost:3000"
test_url = base_url + route_path
```

**Security**: All URLs MUST resolve to localhost or the configured base_url host.
External URLs are rejected.
