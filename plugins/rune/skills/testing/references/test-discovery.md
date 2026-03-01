# Diff-Scoped Test Discovery Algorithm

> **Note**: The set of changed files (`diffFiles`) is resolved upstream by `resolveTestScope()`
> before test discovery begins. See [scope-detection.md](scope-detection.md) for the shared
> scope resolution algorithm (PR number → branch → current branch fallback). Test discovery
> functions receive the already-resolved `files` array — they do NOT call `git diff` themselves.

## Unit Test Discovery (v1: Python + JS/TS)

```
1. Get changed files: resolveTestScope(prNumber || "").files
   (scope resolution is handled upstream — see scope-detection.md)

2. For each changed source file:
   a. Search for corresponding test file by convention:
      - test_{name}.py            (Python — pytest convention)
      - {name}_test.py            (Python — alternate)
      - {name}.test.{ts,tsx,js}   (JS/TS — jest/vitest)
      - {name}.spec.{ts,tsx,js}   (JS/TS — vitest/jest)
      - tests/{path}/test_{name}.py  (Python — mirror directory)
      - __tests__/{name}.test.js  (Jest convention)
   b. If test file exists → add to unit test queue
   c. If test file doesn't exist → flag as "uncovered implementation"

3. If changed file IS a test file → run it directly (BC-4 guard)

4. Shared utility detection:
   If changed file is under lib/, utils/, shared/, core/ →
   trigger FULL unit suite (not just diff-scoped)
   Rationale: shared modules affect many consumers

5. Deduplicate and sort by file path

6. If queue is empty → skip unit tier with WARN
```

## Integration Test Discovery (v1: Python + JS/TS)

```
1. Detect test framework from project files:
   - pytest.ini / pyproject.toml [tool.pytest.ini_options] → pytest
   - setup.cfg [tool:pytest] → pytest
   - package.json scripts.test contains "jest" → jest
   - package.json scripts.test contains "vitest" → vitest
   - jest.config.{js,ts,json} → jest
   - vitest.config.{js,ts} → vitest

2. Search for integration test directories:
   - tests/integration/
   - tests/api/
   - tests/e2e/ (if not browser-based)

3. Filter to tests that touch changed modules (import analysis)

4. If no integration tests found → skip tier

Note: Ruby (spec/requests/), Go, Rust detection deferred to v1.1
```

## E2E Route Discovery

```
1. Auto-detect framework from project structure:
   - Next.js: src/app/**/ or pages/**/ → routes from directory structure
   - Rails: app/views/ + config/routes.rb → routes from controller actions
   - Django: urls.py → route definitions
   - Generic: scan for router/route definitions

2. Map changed frontend files to affected routes:
   - Component file → page that imports it → route

3. Cap at talisman max_routes (default: 3)

4. If no routes detected → skip E2E tier
```

## Framework Detection Shell Pattern

```bash
detect_test_framework() {
  local dir="${1:-.}"

  # Python
  if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/pytest.ini" ] || \
     [ -f "$dir/setup.cfg" ]; then
    echo "pytest"
    return
  fi
  if find "$dir" -maxdepth 3 -name "test_*.py" -quit 2>/dev/null | grep -q .; then
    echo "pytest"
    return
  fi

  # JavaScript/TypeScript
  if [ -f "$dir/package.json" ]; then
    if grep -q '"vitest"' "$dir/package.json" 2>/dev/null; then
      echo "vitest"
    elif grep -q '"jest"' "$dir/package.json" 2>/dev/null; then
      echo "jest"
    fi
    return
  fi

  echo "unknown"
}
```

## Framework-Specific Commands

| Framework | Unit command | Integration command | Coverage flag |
|-----------|------------|-------------------|---------------|
| pytest | `pytest {files} --tb=short -q` | `pytest tests/integration/ --tb=short` | `--cov --cov-report=term-missing` |
| jest | `npx jest {files} --forceExit --verbose` | `npx jest tests/integration/ --forceExit` | `--coverage` |
| vitest | `npx vitest run {files} --reporter=verbose` | `npx vitest run tests/integration/` | `--coverage` |

## Output Format (JUnit XML)

Always emit structured output when possible:
- pytest: `--junit-xml=test-results.xml`
- jest: `--reporters=jest-junit` (requires jest-junit package)
- vitest: `--reporter=junit`
