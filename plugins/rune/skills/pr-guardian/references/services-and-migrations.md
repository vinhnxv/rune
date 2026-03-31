# Local Services & Migration Health — Phase 3.5 Commands

Framework-specific service startup, migration conflict resolution, migration apply,
and database verification for Phase 3.5.

## 3.5A: Service Readiness

### Docker Compose

```bash
CHANGED_FILES=$(gh pr diff <PR_NUMBER> --name-only)

if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "compose.yml" ]; then
  COMPOSE_FILE=$(ls docker-compose.yml docker-compose.yaml compose.yml 2>/dev/null | head -1)

  # Check if services are already running
  RUNNING=$(docker compose ps --format json 2>/dev/null | grep -c '"running"' || echo "0")

  if [ "$RUNNING" = "0" ]; then
    echo "Starting Docker Compose services..."
    docker compose up -d --wait

    # Wait for health checks to pass (max 60s)
    TIMEOUT=60
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
      HEALTHY=$(docker compose ps --format json 2>/dev/null | grep -c '"healthy"' || echo "0")
      TOTAL=$(docker compose ps --format json 2>/dev/null | wc -l | tr -d ' ')
      if [ "$HEALTHY" = "$TOTAL" ] && [ "$TOTAL" -gt "0" ]; then
        echo "All $TOTAL services healthy."
        break
      fi
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done

    if [ $ELAPSED -ge $TIMEOUT ]; then
      echo "WARNING: Some services not healthy after ${TIMEOUT}s"
      docker compose ps
    fi
  else
    echo "Docker Compose: $RUNNING service(s) already running."
  fi

  # Rebuild if Dockerfile or requirements changed
  if echo "$CHANGED_FILES" | grep -qE '(Dockerfile|requirements\.txt|package\.json|Gemfile|go\.(mod|sum)|Cargo\.(toml|lock)|composer\.(json|lock))'; then
    echo "Dependency files changed — rebuilding affected services..."
    docker compose build
    docker compose up -d --wait
  fi
fi
```

### Standalone Port Check

```bash
check_port() {
  local port=$1
  local name=$2
  if command -v nc >/dev/null 2>&1; then
    nc -z localhost "$port" 2>/dev/null && echo "$name running on :$port" && return 0
  elif command -v curl >/dev/null 2>&1; then
    curl -sf "http://localhost:$port" -o /dev/null 2>/dev/null && echo "$name running on :$port" && return 0
  fi
  return 1
}

for PORT_INFO in "8000:backend" "8080:backend" "3000:app" "5000:flask" "4000:phoenix" "5432:postgres" "3306:mysql" "6379:redis"; do
  PORT="${PORT_INFO%%:*}"
  NAME="${PORT_INFO##*:}"
  check_port "$PORT" "$NAME" || true
done

if ! check_port 8000 "backend" && ! check_port 8080 "backend" && ! check_port 3000 "app"; then
  if [ ! -f "docker-compose.yml" ] && [ ! -f "compose.yml" ]; then
    echo "WARNING: No running dev server detected and no Docker Compose found."
    echo "Browser tests may fail. Start your dev server manually if needed."
  fi
fi
```

## 3.5B: Migration Conflict Detection & Resolution

### Detection Gate

```bash
HAS_MIGRATION_CHANGES=false
if echo "$CHANGED_FILES" | grep -qE '(migrations/|migrate/|alembic/|prisma/migrations)'; then
  HAS_MIGRATION_CHANGES=true
fi
```

### Alembic (Python / SQLAlchemy / FastAPI)

```bash
if [ -f "alembic.ini" ] || [ -d "alembic" ] || [ -d "*/alembic" ]; then
  echo "Detected: Alembic migration framework"

  # Find alembic command (may need venv or uv)
  if command -v uv >/dev/null 2>&1 && [ -f "pyproject.toml" ]; then
    ALEMBIC="uv run alembic"
  elif [ -f ".venv/bin/alembic" ]; then
    ALEMBIC=".venv/bin/alembic"
  elif command -v alembic >/dev/null 2>&1; then
    ALEMBIC="alembic"
  else
    echo "WARNING: alembic not found in PATH or .venv — skipping migration check"
    ALEMBIC=""
  fi

  if [ -n "$ALEMBIC" ]; then
    # Check for multiple heads (= migration conflict)
    HEADS=$($ALEMBIC heads 2>/dev/null)
    HEAD_COUNT=$(echo "$HEADS" | grep -c "head" || echo "0")

    if [ "$HEAD_COUNT" -gt 1 ]; then
      echo "CONFLICT: $HEAD_COUNT Alembic heads detected — merging..."
      $ALEMBIC merge heads -m "merge_migration_heads_$(date +%Y%m%d)"

      NEW_HEAD_COUNT=$($ALEMBIC heads 2>/dev/null | grep -c "head" || echo "0")
      if [ "$NEW_HEAD_COUNT" -gt 1 ]; then
        echo "ERROR: Alembic merge failed — still $NEW_HEAD_COUNT heads"
        echo "Manual intervention required."
      else
        echo "Alembic heads merged successfully."
        git add -A alembic/ migrations/ */alembic/ */migrations/ 2>/dev/null
        git commit -m "fix: merge alembic migration heads" 2>/dev/null || true
      fi
    else
      echo "Alembic: single head — no conflict."
    fi

    CURRENT=$($ALEMBIC current 2>/dev/null | tail -1)
    echo "Alembic current revision: $CURRENT"
  fi
fi
```

### Django

```bash
if [ -f "manage.py" ] && grep -q "django" requirements*.txt pyproject.toml setup.cfg 2>/dev/null; then
  echo "Detected: Django migration framework"

  if command -v uv >/dev/null 2>&1 && [ -f "pyproject.toml" ]; then
    MANAGE="uv run python manage.py"
  elif [ -f ".venv/bin/python" ]; then
    MANAGE=".venv/bin/python manage.py"
  else
    MANAGE="python manage.py"
  fi

  CONFLICT_APPS=$($MANAGE showmigrations --plan 2>/dev/null | grep "CONFLICT" || echo "")
  if [ -n "$CONFLICT_APPS" ]; then
    echo "CONFLICT: Django migration conflicts detected"
    echo "$CONFLICT_APPS"

    for APP in $(echo "$CONFLICT_APPS" | awk '{print $2}' | sort -u); do
      echo "Merging migrations for app: $APP"
      $MANAGE makemigrations --merge "$APP" --noinput 2>/dev/null
    done

    git add -A */migrations/ 2>/dev/null
    git commit -m "fix: merge django migration conflicts" 2>/dev/null || true
  fi

  UNAPPLIED=$($MANAGE showmigrations --plan 2>/dev/null | grep "\[ \]" | wc -l | tr -d ' ')
  echo "Django: $UNAPPLIED unapplied migration(s)"
fi
```

### Rails (ActiveRecord)

```bash
if [ -f "config/routes.rb" ] && [ -d "db/migrate" ]; then
  echo "Detected: Rails migration framework"

  TIMESTAMPS=$(ls db/migrate/*.rb 2>/dev/null | sed 's/.*\///' | cut -d'_' -f1 | sort)
  DUPES=$(echo "$TIMESTAMPS" | uniq -d)
  if [ -n "$DUPES" ]; then
    echo "WARNING: Duplicate migration timestamps detected:"
    echo "$DUPES"
  fi

  if command -v bundle >/dev/null 2>&1; then
    PENDING=$(bundle exec rails db:migrate:status 2>/dev/null | grep -c "down" || echo "0")
    echo "Rails: $PENDING pending migration(s)"
  fi
fi
```

### Prisma

```bash
if [ -f "prisma/schema.prisma" ]; then
  echo "Detected: Prisma migration framework"
  npx prisma migrate status 2>/dev/null

  DRIFT=$(npx prisma migrate diff --from-schema-datamodel prisma/schema.prisma --to-migrations prisma/migrations 2>/dev/null)
  if [ -n "$DRIFT" ]; then
    echo "WARNING: Prisma schema drift detected"
    echo "$DRIFT"
  fi
fi
```

### Sequelize / Knex / TypeORM

```bash
# Sequelize
if [ -f ".sequelizerc" ] || [ -d "migrations" ] && grep -q "sequelize" package.json 2>/dev/null; then
  echo "Detected: Sequelize migration framework"
  npx sequelize-cli db:migrate:status 2>/dev/null || true
fi

# Knex
if grep -q '"knex"' package.json 2>/dev/null; then
  echo "Detected: Knex migration framework"
  npx knex migrate:status 2>/dev/null || true
fi

# TypeORM
if grep -q '"typeorm"' package.json 2>/dev/null; then
  echo "Detected: TypeORM migration framework"
  npx typeorm migration:show 2>/dev/null || true
fi
```

## 3.5C: Apply Migrations & Verify Database

### Alembic — Apply + Round-Trip

```bash
if [ -n "$ALEMBIC" ]; then
  echo "Applying Alembic migrations..."
  $ALEMBIC upgrade head

  # Round-trip verification
  echo "Verifying migration round-trip..."
  $ALEMBIC downgrade -1
  $ALEMBIC upgrade head

  if [ $? -eq 0 ]; then
    echo "Alembic: migration round-trip verified."
  else
    echo "ERROR: Alembic round-trip verification failed!"
  fi
fi
```

### Django — Apply

```bash
if [ -n "$MANAGE" ] && [ "$UNAPPLIED" -gt 0 ]; then
  echo "Applying Django migrations..."
  $MANAGE migrate --noinput

  if [ $? -eq 0 ]; then
    echo "Django: all migrations applied."
  else
    echo "ERROR: Django migration failed!"
    $MANAGE showmigrations --plan | grep "\[ \]"
  fi
fi
```

### Rails — Apply + Schema Update

```bash
if [ -f "config/routes.rb" ] && [ "${PENDING:-0}" -gt 0 ]; then
  echo "Applying Rails migrations..."
  bundle exec rails db:migrate

  if [ $? -eq 0 ]; then
    echo "Rails: all migrations applied."
    if [ -n "$(git diff db/schema.rb 2>/dev/null)" ]; then
      git add db/schema.rb
      git commit -m "chore: update schema.rb after migration" 2>/dev/null || true
    fi
  else
    echo "ERROR: Rails migration failed!"
    bundle exec rails db:migrate:status
  fi
fi
```

### Prisma — Deploy + Generate

```bash
if [ -f "prisma/schema.prisma" ]; then
  echo "Applying Prisma migrations..."
  npx prisma migrate deploy
  npx prisma generate
fi
```

### Sequelize / Knex / TypeORM — Apply

```bash
if [ -f ".sequelizerc" ] || ([ -d "migrations" ] && grep -q "sequelize" package.json 2>/dev/null); then
  npx sequelize-cli db:migrate
elif grep -q '"knex"' package.json 2>/dev/null; then
  npx knex migrate:latest
elif grep -q '"typeorm"' package.json 2>/dev/null; then
  npx typeorm migration:run
fi
```

### Database Health Check

```bash
if command -v docker >/dev/null 2>&1 && docker compose ps 2>/dev/null | grep -q "postgres"; then
  docker compose exec -T postgres pg_isready 2>/dev/null && echo "PostgreSQL: ready" || echo "WARNING: PostgreSQL not ready"
elif command -v docker >/dev/null 2>&1 && docker compose ps 2>/dev/null | grep -q "mysql"; then
  docker compose exec -T mysql mysqladmin ping -s 2>/dev/null && echo "MySQL: ready" || echo "WARNING: MySQL not ready"
fi
```

## Supported Migration Frameworks

| Framework | Conflict Detection | Auto-Merge | Round-Trip Verify | Apply Command |
|-----------|-------------------|------------|-------------------|---------------|
| Alembic | Multiple heads | `merge heads` | downgrade+upgrade | `upgrade head` |
| Django | `showmigrations` CONFLICT | `makemigrations --merge` | — | `migrate --noinput` |
| Rails | Duplicate timestamps | — (manual) | — | `db:migrate` |
| Prisma | `migrate status` + drift | — | — | `migrate deploy` |
| Sequelize | `db:migrate:status` | — | — | `db:migrate` |
| Knex | `migrate:status` | — | — | `migrate:latest` |
| TypeORM | `migration:show` | — | — | `migration:run` |
