# Insecure Defaults Pattern Library

Reference document for ward-sentinel's Insecure Defaults (Fail-Open Detection) dimension.

**CWE-1188**: Insecure Default Initialization of Resource

**Key principle**: Code that CRASHES without configuration is SAFE (fail-secure).
Code that RUNS with insecure defaults is VULNERABLE (fail-open).

## JavaScript / TypeScript

### P1: Secret Fallback

```javascript
// INSECURE — fail-open: runs with hardcoded secret in production
const JWT_SECRET = process.env.JWT_SECRET || "development-secret"
const SESSION_KEY = process.env.SESSION_KEY ?? "my-session-key"
const API_KEY = config.apiKey || "default-api-key"

// SECURE — fail-secure: crashes if env var missing
const JWT_SECRET = process.env.JWT_SECRET  // undefined → crash on use
const JWT_SECRET = requireEnv("JWT_SECRET") // explicit crash helper
```

### P1: Permissive CORS

```javascript
// INSECURE — fail-open: allows all origins by default
app.use(cors({ origin: config.origin || "*" }))
app.use(cors({ origin: process.env.CORS_ORIGIN ?? "*" }))

// SECURE — fail-secure: no default, explicit origin required
app.use(cors({ origin: config.origin }))
app.use(cors({ origin: getAllowedOrigins() }))  // throws if unconfigured
```

### P1: Default Credentials

```javascript
// INSECURE — fail-open: connects with default password
const dbPassword = process.env.DB_PASS || "postgres"
const redisUrl = process.env.REDIS_URL || "redis://default:password@localhost"

// SECURE — fail-secure: crashes without credentials
const dbPassword = process.env.DB_PASS  // undefined → connection fails
```

### P2: Debug Mode Default

```javascript
// INSECURE — fail-open: debug enabled by default
const DEBUG = process.env.DEBUG !== "false"  // true unless explicitly disabled
const VERBOSE_ERRORS = config.verboseErrors ?? true

// SECURE — fail-secure: debug off by default
const DEBUG = process.env.DEBUG === "true"  // false unless explicitly enabled
```

### P2: Weak Crypto Default

```javascript
// INSECURE — weak algorithm as fallback
const algorithm = config.hashAlgo || "md5"
const cipher = config.encryption ?? "des-ecb"

// SECURE — strong algorithm or crash
const algorithm = config.hashAlgo || "sha256"
const algorithm = config.hashAlgo  // undefined → error
```

## Python

### P1: Secret Fallback

```python
# INSECURE — fail-open: runs with insecure default
SECRET_KEY = os.getenv("SECRET_KEY", "insecure-default")
JWT_SECRET = os.environ.get("JWT_SECRET", "dev-secret-key")

# SECURE — fail-secure: crashes if missing
SECRET_KEY = os.environ["SECRET_KEY"]  # KeyError if missing

# SECURE — explicit validation
SECRET_KEY = os.getenv("SECRET_KEY")
if not SECRET_KEY:
    raise ValueError("SECRET_KEY must be set")
```

### P1: Default Credentials

```python
# INSECURE — fail-open: default database credentials
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://admin:password@localhost/db")
REDIS_PASSWORD = config.get("redis_password", "default")

# SECURE — fail-secure: no defaults for credentials
DATABASE_URL = os.environ["DATABASE_URL"]
```

### P2: Weak Crypto Default

```python
# INSECURE — weak algorithm as default
algorithm = config.get("hash_algo", "md5")
hash_func = getattr(hashlib, os.getenv("HASH_ALGO", "sha1"))

# SECURE — strong default
algorithm = config.get("hash_algo", "sha256")
```

### P2: Debug Mode Default

```python
# INSECURE — fail-open: debug on by default
DEBUG = os.environ.get("DEBUG", "True").lower() == "true"
DEBUG = not os.getenv("PRODUCTION")  # True unless PRODUCTION is set

# SECURE — fail-secure: debug off by default
DEBUG = os.environ.get("DEBUG", "False").lower() == "true"
```

### P1: Permissive CORS (Django)

```python
# INSECURE — fail-open: allows all origins
CORS_ALLOWED_ORIGINS = os.getenv("CORS_ORIGINS", "*").split(",")
CORS_ALLOW_ALL_ORIGINS = os.getenv("CORS_ALLOW_ALL", "True").lower() == "true"

# SECURE — fail-secure: explicit allowlist
CORS_ALLOWED_ORIGINS = os.environ["CORS_ORIGINS"].split(",")
CORS_ALLOW_ALL_ORIGINS = False  # explicit deny
```

## Go

### P1: Secret Fallback

```go
// INSECURE — fail-open: uses default if env var empty
jwtSecret := os.Getenv("JWT_SECRET")
if jwtSecret == "" {
    jwtSecret = "development-secret"
}

apiKey := getEnvOrDefault("API_KEY", "default-key")

// SECURE — fail-secure: panics or returns error
jwtSecret := os.Getenv("JWT_SECRET")
if jwtSecret == "" {
    log.Fatal("JWT_SECRET environment variable is required")
}

// SECURE — using required env helper
jwtSecret := mustGetenv("JWT_SECRET")
```

### P1: Default Credentials

```go
// INSECURE — fail-open: default database password
dbPassword := os.Getenv("DB_PASS")
if dbPassword == "" {
    dbPassword = "postgres"
}

// SECURE — fail-secure: error without credentials
dbPassword := os.Getenv("DB_PASS")
if dbPassword == "" {
    return fmt.Errorf("DB_PASS environment variable is required")
}
```

### P2: Permissive CORS

```go
// INSECURE — fail-open: wildcard CORS default
corsOrigin := os.Getenv("CORS_ORIGIN")
if corsOrigin == "" {
    corsOrigin = "*"
}

// SECURE — fail-secure: explicit origin required
corsOrigin := os.Getenv("CORS_ORIGIN")
if corsOrigin == "" {
    log.Fatal("CORS_ORIGIN must be configured")
}
```

## Ruby

### P1: Secret Fallback

```ruby
# INSECURE — fail-open
SECRET_KEY_BASE = ENV.fetch("SECRET_KEY_BASE", "insecure-fallback")
JWT_SECRET = ENV["JWT_SECRET"] || "dev-secret"

# SECURE — fail-secure: raises KeyError
SECRET_KEY_BASE = ENV.fetch("SECRET_KEY_BASE")
```

## Rust

### P1: Secret Fallback

```rust
// INSECURE — fail-open: unwrap_or provides insecure default
let jwt_secret = std::env::var("JWT_SECRET").unwrap_or("dev-secret".to_string());

// SECURE — fail-secure: panics if missing
let jwt_secret = std::env::var("JWT_SECRET").expect("JWT_SECRET must be set");
```

## Severity Guide

| Category | Default Severity | Rationale |
|----------|-----------------|-----------|
| Secret/credential fallback | **P1** | Direct authentication bypass in production |
| Default credentials | **P1** | Trivially exploitable |
| Permissive CORS default | **P1** | Enables cross-origin attacks |
| Debug mode default on | **P2** | Information disclosure, expanded attack surface |
| Weak crypto default | **P2** | Cryptographic weakness, not immediately exploitable |
| Missing security headers | **P3** | Defense-in-depth gap |
| Dev tools enabled by default | **P2** | Information disclosure (GraphQL introspection, Swagger) |

## False Positive Guidance

**NOT insecure defaults** (do not flag):
- Test/fixture files with hardcoded values (check file path for `test`, `spec`, `fixture`, `mock`)
- Constants that are not secrets (e.g., `const PORT = process.env.PORT || 3000`)
- Non-sensitive configuration with safe defaults (e.g., `const LOG_LEVEL = env.LOG_LEVEL || "info"`)
- Environment detection helpers (e.g., `const IS_DEV = process.env.NODE_ENV !== "production"`)
- Default values for non-security settings (pagination limits, timeouts, retry counts)

**Context matters**: A `|| "default"` pattern is only insecure when the value is security-sensitive (secrets, credentials, crypto algorithms, access control settings).
