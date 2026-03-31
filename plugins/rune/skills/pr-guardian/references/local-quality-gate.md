# Local Quality Gate — Lint & Typecheck Commands

Framework-specific lint, typecheck, and format commands for Phase 1.5.

## Stack Detection

```bash
CHANGED_FILES=$(gh pr diff <PR_NUMBER> --name-only)

# --- Frontend detection ---
HAS_FRONTEND=false
if echo "$CHANGED_FILES" | grep -qE '\.(tsx?|jsx?|vue|svelte|css|scss)$'; then
  HAS_FRONTEND=true
fi

# --- Backend detection ---
HAS_BACKEND=false
if echo "$CHANGED_FILES" | grep -qE '\.(py|rb|go|php|rs|java|kt)$'; then
  HAS_BACKEND=true
fi
```

## Frontend Quality Gates

```bash
if [ "$HAS_FRONTEND" = "true" ]; then

  # Detect package manager
  if [ -f "pnpm-lock.yaml" ]; then PKG="pnpm"
  elif [ -f "yarn.lock" ]; then PKG="yarn"
  elif [ -f "bun.lockb" ]; then PKG="bun"
  else PKG="npm"; fi

  # Lint (try common script names in order)
  if grep -q '"lint"' package.json 2>/dev/null; then
    $PKG run lint
  elif grep -q '"eslint"' package.json 2>/dev/null; then
    npx eslint . --ext .ts,.tsx,.js,.jsx --fix
  fi

  # Typecheck
  if [ -f "tsconfig.json" ]; then
    npx tsc --noEmit
  fi

  # Format check (non-blocking — auto-fix and stage)
  if grep -q '"prettier"' package.json 2>/dev/null; then
    npx prettier --write $(echo "$CHANGED_FILES" | grep -E '\.(tsx?|jsx?|css|scss|json)$') 2>/dev/null
    git add -u  # stage auto-fixed formatting
  fi
fi
```

## Backend Quality Gates

### Python
```bash
if echo "$CHANGED_FILES" | grep -qE '\.py$'; then
  if [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
    # Ruff (fast, preferred)
    if command -v ruff >/dev/null 2>&1; then
      ruff check --fix .
      ruff format .
    # Flake8 fallback
    elif command -v flake8 >/dev/null 2>&1; then
      flake8 $(echo "$CHANGED_FILES" | grep '\.py$')
    fi
    # Mypy typecheck
    if command -v mypy >/dev/null 2>&1 && [ -f "mypy.ini" -o -f "pyproject.toml" ]; then
      mypy $(echo "$CHANGED_FILES" | grep '\.py$') --ignore-missing-imports || true
    fi
    # Pyright typecheck
    if command -v pyright >/dev/null 2>&1; then
      pyright $(echo "$CHANGED_FILES" | grep '\.py$') || true
    fi
  fi
fi
```

### Ruby
```bash
if echo "$CHANGED_FILES" | grep -qE '\.rb$'; then
  if command -v rubocop >/dev/null 2>&1; then
    rubocop --autocorrect $(echo "$CHANGED_FILES" | grep '\.rb$')
  fi
fi
```

### Go
```bash
if echo "$CHANGED_FILES" | grep -qE '\.go$'; then
  if command -v golangci-lint >/dev/null 2>&1; then
    golangci-lint run --fix
  elif command -v go >/dev/null 2>&1; then
    go vet ./...
  fi
fi
```

### Rust
```bash
if echo "$CHANGED_FILES" | grep -qE '\.rs$'; then
  if command -v cargo >/dev/null 2>&1; then
    cargo clippy --fix --allow-dirty
    cargo fmt
  fi
fi
```

### PHP
```bash
if echo "$CHANGED_FILES" | grep -qE '\.php$'; then
  if [ -f "vendor/bin/phpstan" ]; then
    vendor/bin/phpstan analyse $(echo "$CHANGED_FILES" | grep '\.php$') || true
  fi
  if [ -f "vendor/bin/pint" ]; then
    vendor/bin/pint $(echo "$CHANGED_FILES" | grep '\.php$')
  elif [ -f "vendor/bin/php-cs-fixer" ]; then
    vendor/bin/php-cs-fixer fix $(echo "$CHANGED_FILES" | grep '\.php$')
  fi
fi
```

## Makefile / Taskfile Fallback

```bash
if [ -f "Makefile" ]; then
  if grep -q '^check-all:' Makefile 2>/dev/null; then
    make check-all
  elif grep -q '^lint:' Makefile 2>/dev/null; then
    make lint
  fi
elif [ -f "Taskfile.yml" ]; then
  if command -v task >/dev/null 2>&1; then
    task lint 2>/dev/null || true
  fi
fi
```

## Auto-Fix Commit

```bash
if [ -n "$(git diff --name-only)" ]; then
  git add -u
  git commit -m "style: auto-fix lint and formatting"
fi
```

## Supported Stacks Summary

| Stack | Lint | Typecheck | Format |
|-------|------|-----------|--------|
| JS/TS | eslint / `$PKG run lint` | `tsc --noEmit` | prettier `--write` |
| Python | ruff → flake8 | mypy / pyright | ruff format |
| Ruby | rubocop `--autocorrect` | — | rubocop |
| Go | golangci-lint `--fix` → go vet | — | gofmt (via golangci) |
| Rust | `cargo clippy --fix` | built-in | `cargo fmt` |
| PHP | phpstan → pint / php-cs-fixer | phpstan | pint |
