---
name: pr-guardian
description: |
  Automated PR guardian loop — schedules a recurring cron (every 5 min) that checks
  review comments, CI/CD status, branch freshness, runs browser tests, and auto-merges
  when everything is green. Use when you want hands-off PR shepherding to merge.

  Triggers on "pr guardian", "auto merge loop", "watch my PR", "shepherd PR",
  "auto merge", "monitor PR", "drive PR to merge".

  <example>
  user: "/rune:pr-guardian"
  assistant: "Detecting current PR from branch, scheduling guardian loop..."
  </example>

  <example>
  user: "/rune:pr-guardian 42"
  assistant: "PR Guardian activated for PR #42. Checking every 5 minutes..."
  </example>

  <example>
  user: "/rune:pr-guardian --disable-auto-merge"
  assistant: "PR Guardian activated for PR #N (monitor-only mode). Auto-merge disabled..."
  </example>

  <example>
  user: "/rune:pr-guardian 42 --disable-auto-merge"
  assistant: "PR Guardian activated for PR #42 (monitor-only mode). Auto-merge disabled..."
  </example>
user-invocable: true
disable-model-invocation: false
---

# PR Guardian — Automated PR Shepherd Loop

An autonomous cron-based loop that watches your current PR and drives it to merge.

## What It Does (every 5 minutes)

```
┌─────────────────────────────────────────────────────────────┐
│                      PR Guardian Loop                        │
├─────────────────────────────────────────────────────────────┤
│  1.  Check PR review comments                               │
│      └─ If unresolved → /rune:resolve-all-gh-pr-comments    │
│  1.5 Local quality gate (lint + typecheck)                  │
│      └─ Auto-detect stack → run lint/format/typecheck       │
│      └─ Runs BEFORE every git push                          │
│  2.  Check CI/CD status                                     │
│      └─ If red → diagnose & fix → lint gate → push          │
│  3.  Check branch freshness vs main                         │
│      └─ If behind → rebase → lint gate → push               │
│  3.5 Local services & migration health                      │
│      └─ A: Start Docker Compose / verify dev servers        │
│      └─ B: Detect & resolve migration conflicts             │
│         (Alembic, Django, Rails, Prisma, Sequelize, etc.)   │
│      └─ C: Apply pending migrations + round-trip verify     │
│  4.  Run browser tests (if applicable)                      │
│      └─ Frontend/API changes → test related routes          │
│  5.  All green + no comments?                               │
│      └─ Merge PR (squash + delete branch)                   │
│      └─ Delete this cron job                                │
└─────────────────────────────────────────────────────────────┘
```

## Usage

```
/rune:pr-guardian                              # Start the guardian on current branch's PR
/rune:pr-guardian <PR_NUMBER>                  # Watch a specific PR
/rune:pr-guardian --disable-auto-merge         # Watch PR but skip auto-merge (monitor + fix only)
/rune:pr-guardian <PR_NUMBER> --disable-auto-merge  # Watch specific PR, skip auto-merge
```

## Activation

When this skill is invoked, perform these steps **in order**:

### Step 0 — Parse Arguments & Detect PR

```bash
# Parse arguments — extract PR number and flags
PR_NUMBER=""
DISABLE_AUTO_MERGE=false

for arg in $ARGUMENTS; do
  case "$arg" in
    --disable-auto-merge) DISABLE_AUTO_MERGE=true ;;
    [0-9]*) PR_NUMBER="$arg" ;;
  esac
done

# If no PR number provided, detect from current branch
if [ -z "$PR_NUMBER" ]; then
  gh pr view --json number -q '.number'
fi
```

If no open PR is found on the current branch, **STOP** and tell the user:
> "No open PR found on this branch. Push your branch and create a PR first."

### Step 1 — Schedule the Cron

Use **CronCreate** with:
- **cron**: `*/5 * * * *` (every 5 minutes)
- **recurring**: `true`
- **prompt**: The full guardian loop prompt below

**Save the returned job ID** — you will need it for self-deletion in Step 5.

Tell the user:
- If `DISABLE_AUTO_MERGE=false`:
  > "PR Guardian activated for PR #<NUMBER>. Checking every 5 minutes. I'll auto-merge when everything is green. The cron auto-expires after 7 days if not completed sooner."
- If `DISABLE_AUTO_MERGE=true`:
  > "PR Guardian activated for PR #<NUMBER> (monitor-only mode). Checking every 5 minutes. Auto-merge is disabled — I'll fix issues but won't merge. The cron auto-expires after 7 days."

### Step 2 — The Guardian Loop Prompt

Each cron tick should execute this prompt (adapt the PR number):

---

**You are the PR Guardian. Execute these steps for PR #<PR_NUMBER> in order. Stop at the first step that requires action and re-check on the next tick. Auto-merge is <ENABLED|DISABLED based on DISABLE_AUTO_MERGE flag>.**

#### Phase 1: Review Comments

```bash
gh pr view <PR_NUMBER> --json reviewDecision,reviews,comments --jq '{
  decision: .reviewDecision,
  pending_reviews: [.reviews[] | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED") | {author: .author.login, state: .state}],
  comment_count: (.comments | length)
}'
```

- If there are **unresolved review comments** or **CHANGES_REQUESTED** reviews:
  1. Invoke `/rune:resolve-all-gh-pr-comments` skill to resolve all comments
  2. **Run local quality gate** (Phase 1.5) before pushing
  3. Push fixes
  4. **STOP this tick** — wait for next cycle to re-check

- If no actionable comments → proceed to Phase 1.5 (if code changed since last tick) or Phase 2

#### Phase 1.5: Local Quality Gate (Lint & Typecheck)

Before every `git push`, run the project's lint and typecheck commands to catch errors
locally instead of waiting for a full CI cycle.
See [local-quality-gate.md](references/local-quality-gate.md) for full framework-specific commands.

**Summary**:
1. Auto-detect stack from changed file extensions (frontend: `.tsx/.jsx/.vue`, backend: `.py/.rb/.go/.rs/.php`)
2. **Frontend**: detect package manager → run `$PKG run lint` / eslint → `tsc --noEmit` → prettier auto-fix
3. **Backend**: Python (ruff → flake8 + mypy/pyright) | Ruby (rubocop) | Go (golangci-lint) | Rust (clippy + fmt) | PHP (phpstan + pint)
4. Check for `make check-all` / `make lint` / `task lint` convenience targets
5. Stage auto-fixed files → commit as `style: auto-fix lint and formatting`

| Stack | Lint | Typecheck | Format |
|-------|------|-----------|--------|
| JS/TS | eslint / `$PKG run lint` | `tsc --noEmit` | prettier |
| Python | ruff → flake8 | mypy / pyright | ruff format |
| Ruby | rubocop | — | rubocop |
| Go | golangci-lint → go vet | — | gofmt |
| Rust | cargo clippy | built-in | cargo fmt |
| PHP | phpstan | phpstan | pint / php-cs-fixer |

- If lint/typecheck **fails** with unfixable errors:
  1. Fix the errors in code
  2. Re-run the quality gate
  3. If still failing after 2 attempts → **STOP this tick** and commit what works

- If lint/typecheck **passes** → proceed to push (or Phase 2 if no push needed)

**Key rule**: This phase runs BEFORE every `git push` in the guardian loop — that includes
after Phase 1 (comment fixes), Phase 2 (CI fixes), Phase 3 (rebase), and Phase 4 (browser test fixes).

#### Phase 2: CI/CD Status

```bash
gh pr checks <PR_NUMBER> --json name,state,conclusion --jq '.[] | select(.state != "COMPLETED" or .conclusion != "SUCCESS")'
```

- If any checks are **pending**: **STOP this tick** — wait for CI to finish
- If any checks are **failed/red**:
  1. Read the failed check logs: `gh run view <RUN_ID> --log-failed`
  2. Diagnose the failure (lint errors, test failures, type errors, build errors)
  3. Fix the issues in code
  4. **Run Phase 1.5 quality gate** (lint + typecheck) to prevent pushing broken code again
  5. Commit with message: `fix: resolve CI failure — <brief description>`
  6. Push
  7. **STOP this tick** — wait for CI re-run

- If all checks **green** → proceed to Phase 3

#### Phase 3: Branch Freshness (Rebase onto Main)

```bash
git fetch origin main
BEHIND_COUNT=$(git rev-list --count HEAD..origin/main)
echo "Behind main by: $BEHIND_COUNT commits"
```

- If `BEHIND_COUNT > 0`:
  1. `git rebase origin/main`
  2. If conflicts arise:
     - Resolve code conflicts intelligently (read both sides, pick correct resolution)
     - **Migration conflicts**: Detect the project's migration framework and resolve:
       - Alembic: `alembic heads` → if multiple, `alembic merge heads`
       - Rails: check `db/migrate/` for conflicting timestamps
       - Prisma: `npx prisma migrate resolve`
       - Other: resolve file conflicts manually
     - `git rebase --continue` after resolving
  3. **Run Phase 1.5 quality gate** (lint + typecheck) on rebased code
  4. `git push --force-with-lease` (safe force push after rebase)
  5. **STOP this tick** — wait for CI to re-run on rebased code

- If already up-to-date → proceed to Phase 3.5

#### Phase 3.5: Local Services & Migration Health

Before running browser tests, ensure local services are up and the database schema is current.
See [services-and-migrations.md](references/services-and-migrations.md) for full framework-specific commands.

##### 3.5A: Service Readiness

1. **Docker Compose**: detect `docker-compose.yml` / `compose.yml` → `docker compose up -d --wait` → wait for health checks (max 60s) → rebuild if `Dockerfile` / dependency lockfiles changed
2. **Port check**: probe common ports (8000, 8080, 3000, 5000, 4000, 5432, 3306, 6379) via `nc` / `curl`
3. **Warning**: if no running server and no Docker Compose → warn that browser tests may fail

##### 3.5B: Migration Conflict Detection & Resolution

Auto-detect migration framework and resolve conflicts **before** applying:

| Framework | Conflict Detection | Auto-Resolution |
|-----------|-------------------|-----------------|
| **Alembic** | `alembic heads` → multiple heads? | `alembic merge heads` + commit |
| **Django** | `showmigrations --plan` → CONFLICT? | `makemigrations --merge` per app + commit |
| **Rails** | Duplicate timestamps in `db/migrate/` | Flag for manual resolution |
| **Prisma** | `prisma migrate status` + drift check | Flag drift for review |
| **Sequelize** | `db:migrate:status` | — |
| **Knex** | `migrate:status` | — |
| **TypeORM** | `migration:show` | — |

Command resolution (Python): `uv run alembic` → `.venv/bin/alembic` → `alembic` (same pattern for Django `manage.py`).

##### 3.5C: Apply Migrations & Verify Database

1. **Apply**: run the framework's migrate-forward command
2. **Round-trip verify** (Alembic): `downgrade -1` → `upgrade head` to ensure reversibility
3. **Schema commit** (Rails): auto-stage `db/schema.rb` if changed after migration
4. **Client generation** (Prisma): `npx prisma generate` after deploy
5. **Database health check**: `pg_isready` (PostgreSQL) / `mysqladmin ping` (MySQL) via Docker

- If migrations **fail** or conflicts cannot be resolved:
  1. Attempt to fix the migration code
  2. Re-run conflict detection and apply
  3. If still failing after 2 attempts → **STOP this tick** and ask user for guidance

- If migrations **pass** → proceed to Phase 4

#### Phase 4: Browser Tests

Determine if the PR touches frontend or API-facing code:

```bash
# Get changed files
gh pr diff <PR_NUMBER> --name-only
```

- If **frontend files changed** (components, pages, views, styles):
  - Run `/rune:test-browser` skill for the PR
- If **backend/API-only files changed**:
  - Identify related frontend pages that consume the changed APIs
  - Run targeted browser tests on those related frontend flows
- If **docs/config/infra only**: skip browser tests

If browser tests **fail**:
  1. Fix the failing tests or the code causing failures
  2. **Run Phase 1.5 quality gate** before pushing
  3. Commit and push
  4. **STOP this tick**

If browser tests **pass** → proceed to Phase 5

#### Phase 5: Merge & Cleanup

All conditions met:
- No unresolved review comments
- Local lint + typecheck passes
- All CI/CD checks green
- Branch is up-to-date with main
- Migrations applied, no conflicts, database healthy
- Browser tests pass (or skipped)

**If `DISABLE_AUTO_MERGE=true`** (monitor-only mode):
1. Tell the user:
   > "PR #<PR_NUMBER> is fully green — all checks pass, no unresolved comments, branch is up-to-date. Auto-merge is disabled. Merge manually when ready."
2. **Delete this cron job** using CronDelete with the saved job ID (no further monitoring needed)
3. **STOP** — do not merge

**If `DISABLE_AUTO_MERGE=false`** (default):

Execute the merge:

```bash
# 1. Verify gh CLI
command -v gh && gh auth status

# 2. Switch to correct GitHub account
source "${RUNE_PLUGIN_ROOT}/scripts/lib/gh-account-resolver.sh" && rune_gh_ensure_correct_account

# 3. Verify PR is still open and mergeable
gh pr view <PR_NUMBER> --json state,mergeable --jq '{state, mergeable}'

# 4. Squash merge + delete branch
GH_PROMPT_DISABLED=1 gh pr merge <PR_NUMBER> --squash --delete-branch

# 5. Sync local
git checkout main && git pull origin main
```

After successful merge:
1. **Delete this cron job** using CronDelete with the saved job ID
2. Tell the user:
   > "PR #<PR_NUMBER> has been merged successfully! Guardian loop terminated."

---

## Safety Guardrails

- **Force push**: Only `--force-with-lease` after rebase (never `--force`)
- **Merge conflicts**: Always resolve intelligently, never blindly accept one side
- **Migration conflicts**: Detect framework automatically — verify round-trip after resolution
- **Migration round-trip**: Always verify downgrade+upgrade works (Alembic). Check schema.rb is updated (Rails)
- **Docker services**: Never `docker compose down` — only `up -d`. Guardian should add services, not destroy them
- **Database safety**: Never run destructive database commands (`DROP`, `TRUNCATE`). Only `migrate` forward
- **Max retries**: If the same phase fails 3 consecutive ticks, **pause and ask the user** for guidance instead of looping forever
- **7-day auto-expiry**: CronCreate recurring jobs auto-expire after 7 days — the guardian will not run forever
- **GitHub account**: Always uses `gh-account-resolver.sh` to ensure correct account before merge

## Cancellation

To stop the guardian manually, the user can say:
> "Stop the PR guardian" / "Cancel the loop"

This should trigger `CronDelete` with the saved job ID.
