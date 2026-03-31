# Backend Impact Tracing — API → Frontend → Route

## Purpose

When a PR contains only backend/API/database changes, trace the impact forward
to discover which frontend routes consume those changes and should be E2E tested.

The pipeline: `backend file → API endpoint → frontend consumer → page/view → route`

## File Classification

```
classifyChangedFiles(files) → { frontend: string[], backend: string[], shared: string[] }

BACKEND_PATTERNS = [
  // Python
  /^(backend|server|api|app)\//,
  /\/(views|viewsets|serializers|models|schemas|services|repositories|handlers)\.py$/,
  /\/(views|viewsets|serializers|models|schemas|services|repositories|handlers)\//,
  /\/migrations\//,
  /\/urls\.py$/, /\/routes\.py$/,

  // Node/Express/NestJS
  /\/(controllers|routes|middleware|services|models|entities|resolvers|schemas)\//,
  /\.(controller|service|entity|resolver|dto|model)\.(ts|js)$/,

  // Rails
  /^app\/(controllers|models|serializers|services|jobs|mailers)\//,
  /^db\/(migrate|schema|seeds)/,
  /^config\/routes\.rb$/,

  // Go
  /\/(handlers|services|repositories|models|middleware)\//,
  /\.(handler|service|repository)\.go$/,

  // PHP/Laravel
  /^app\/(Http|Models|Services|Repositories)\//,
  /^(routes|database)\//,

  // Generic
  /\.(sql|graphql|gql|proto)$/,
  /openapi|swagger/i,
]

FRONTEND_PATTERNS = [
  /\/(components|pages|views|screens|layouts|hooks|stores|slices)\//,
  /\.(tsx|jsx|vue|svelte)$/,
  /\/(src|app|dashboard|admin|frontend|client)\/.+\.(ts|js|css|scss)$/,
]

for each file in files:
  if file matches any FRONTEND_PATTERN → frontend
  else if file matches any BACKEND_PATTERN → backend
  else → shared (config, CI, docs, etc.)
```

## API Endpoint Extraction

From changed backend files, extract the API endpoints they serve.

```
extractAPIEndpoints(backendFiles) → string[]

Strategy per framework:

--- Python (Django/DRF/FastAPI/Flask) ---
For each .py file in backendFiles:
  1. Read the file
  2. Look for route decorators:
     - @app.route("/api/users")
     - @router.get("/users/{id}")
     - @api_view(["GET", "POST"])  (DRF — check urls.py for path)
     - path("api/users/", UserViewSet)  (in urls.py)
  3. For ViewSet/View classes, check urls.py for the registered path

--- Node/Express ---
  - router.get("/api/users", handler)
  - @Get("/users/:id")   (NestJS)
  - app.post("/api/auth/login", ...)

--- Rails ---
  - routes.rb: resources :users → /users, /users/:id, etc.
  - Controller name → REST routes (UsersController → /users/*)

--- Go ---
  - r.HandleFunc("/api/users", handler)
  - e.GET("/users/:id", handler)  (Echo)

--- GraphQL ---
  - Changed resolvers/mutations → extract operation names
  - Map to: /graphql (single endpoint) + operation context

--- REST fallback ---
  If framework detection fails:
  - Grep for URL patterns: "/api/", "/v1/", "/v2/"
  - Extract path strings from route registrations

Return: ["/api/users", "/api/users/:id", "/api/auth/login", ...]
```

## Frontend Consumer Discovery

Given API endpoints, find which frontend files consume them.

```
discoverFrontendConsumers(endpoints) → { file: string, route: string }[]

For each endpoint in endpoints:
  1. Normalize: strip path params → "/api/users/:id" → "/api/users"
  2. Build search patterns:
     patterns = [
       endpoint,                          // exact: "/api/users"
       endpoint.replace(/^\/api/, ""),     // relative: "/users"
       endpoint.split("/").pop(),          // resource: "users"
     ]

  3. Grep frontend directories for API call sites:
     searchDirs = detect frontend root dirs:
       - src/, app/, dashboard/, admin/, frontend/, client/, pages/

     For each pattern:
       Grep(pattern, searchDirs, glob="*.{ts,tsx,js,jsx,vue,svelte}")

     Look for patterns like:
       - fetch("/api/users")
       - axios.get("/api/users")
       - api.get("/users")
       - useSWR("/api/users")
       - useQuery(["users"], () => fetch("/api/users"))
       - $fetch("/api/users")  (Nuxt)
       - trpc.users.useQuery()  (tRPC — match resource name)
       - gql`query GetUsers`  (GraphQL — match operation name)
       - API_ENDPOINTS.users  (constant reference)
       - apiClient.users.list()  (typed client)

  4. For each consuming file:
     - If it's a page/view file → direct route
     - If it's a component/hook → trace upward to importing page:
       Grep for: import.*from.*{component_path}
       Repeat until a page file is found (max 3 levels)

  5. Map page files to routes using existing file-route-mapping algorithm

Return: [{ file: "src/pages/Users.tsx", route: "/users" }, ...]
```

## Database/Model Impact Tracing

When only models/migrations change (no direct API endpoint change):

```
traceModelToEndpoints(modelFiles) → string[]

1. Extract model/table names from changed files:
   - Python: class User(Model) → "User", "user"
   - Rails: class User < ApplicationRecord → "User", "users"
   - TypeScript: @Entity() class User → "User", "user"
   - SQL migration: CREATE TABLE users / ALTER TABLE users → "users"

2. Find API endpoints that use these models:
   - Grep backend dirs for model imports/references
   - Map those backend files → API endpoints (via extractAPIEndpoints)

3. Feed discovered endpoints into discoverFrontendConsumers()
```

## Service Layer Impact Tracing

When service/business logic changes (no direct route/endpoint file):

```
traceServiceToEndpoints(serviceFiles) → string[]

1. Find which controllers/handlers import/use the changed service:
   - Grep: "import.*{ServiceName}" or "from.*{service_path}"
   - Check dependency injection registrations

2. Map those controllers → API endpoints

3. Feed into discoverFrontendConsumers()
```

## Full Pipeline

```
traceBackendImpact(backendFiles, allProjectFiles) → string[]

  // Layer 1: Direct API endpoints from changed files
  directEndpoints = extractAPIEndpoints(backendFiles)

  // Layer 2: Model/migration → endpoint tracing
  modelFiles = backendFiles.filter(f => isModelOrMigration(f))
  modelEndpoints = traceModelToEndpoints(modelFiles)

  // Layer 3: Service → endpoint tracing
  serviceFiles = backendFiles.filter(f => isServiceFile(f))
  serviceEndpoints = traceServiceToEndpoints(serviceFiles)

  // Combine and deduplicate
  allEndpoints = unique([...directEndpoints, ...modelEndpoints, ...serviceEndpoints])

  if allEndpoints.length == 0:
    // Fallback: use resource names from file paths
    // e.g., backend/services/user_service.py → "user" → grep frontend for "user"
    resourceNames = backendFiles.map(f => extractResourceName(f)).filter(Boolean)
    // Search frontend for these resource names in API calls
    for each name in resourceNames:
      Grep(name, frontendDirs, glob="*.{ts,tsx,js,jsx,vue,svelte}")
    // Map hits to routes

  // Discover frontend consumers for all endpoints
  consumers = discoverFrontendConsumers(allEndpoints)

  // Extract unique routes
  routes = unique(consumers.map(c => c.route))

  return routes
```

## Helper: extractResourceName

```
extractResourceName(filePath) → string | null

  // Extract semantic resource name from backend file path
  basename = path.basename(filePath, path.extname(filePath))

  // Strip common suffixes
  SUFFIXES = [
    "_controller", "Controller", "_handler", "Handler",
    "_service", "Service", "_model", "Model",
    "_serializer", "Serializer", "_viewset", "ViewSet",
    "_view", "View", "_repository", "Repository",
    "_resolver", "Resolver", "_entity", "Entity",
  ]
  name = basename
  for suffix in SUFFIXES:
    name = name.replace(suffix, "")

  // Normalize: snake_case → lowercase
  name = name.toLowerCase().replace(/_/g, "")

  if name.length < 2: return null  // too short to be meaningful
  return name
```

## Confidence Levels

Not all backend → frontend traces are equally reliable:

| Trace Type | Confidence | Example |
|-----------|-----------|---------|
| Direct endpoint match in fetch/axios | HIGH | `fetch("/api/users")` matches `/api/users` endpoint |
| Resource name match in API client | MEDIUM | `api.users.list()` matches users controller |
| Model name in frontend store/hook | MEDIUM | `useUsers()` hook likely consumes users API |
| Indirect via service → controller | LOW | Service change → controller → endpoint → frontend |
| Fallback resource name grep | LOW | File named `user_service.py` → grep "user" in frontend |

**Priority**: Test HIGH confidence routes first, then MEDIUM. LOW confidence routes
only included if total routes < maxRoutes.

## Output

The tracing pipeline returns routes in the same format as the frontend file-route-mapping,
so they feed directly into the existing test loop (Step 5).
