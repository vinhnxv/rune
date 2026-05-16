# Inspect — STEP A: Deterministic Pre-Team Checks (Sub-Reference)

<!-- v3.0.0-alpha.7 (Day 6): Absorbed from the retired gap_analysis phase's STEP A.
     Invoked by arc-phase-inspect.md as a pre-team orchestrator-only sub-step that
     runs BEFORE the 4 Inspector Ashes spawn. Produces tmp/arc/{id}/inspect/deterministic.md
     which feeds the STEP C aggregate and STEP D halt-gate (inspect-step-d-halt-gate.md). -->

<!-- v3.x: defaults baked from former talisman.{settings,arc}; see references/v3-defaults.md -->

Deterministic, orchestrator-only pre-team checks. Zero LLM cost. Produces
`tmp/arc/{id}/inspect/deterministic.md` with acceptance criteria coverage,
doc consistency, plan-section coverage, evaluator quality metrics, semantic
claims, stale references, scope creep, and a spec compliance matrix.

**Caller**: `arc-phase-inspect.md` (Phase 5.9). Invoked once per inspect run,
before STEP 1 (Prepare Inspect Context). Results are read by STEP D
(halt-gate, in `inspect-step-d-halt-gate.md`).

**Team**: none — orchestrator only.
**Tools**: Read, Glob, Grep, Bash (git diff, grep)
**Timeout**: ~2 minutes (no agent dispatch — bounded by shell extraction speed)

## STEP A: Deterministic Checks

_(Formerly the gap_analysis phase's STEP A. All logic unchanged —
orchestrator-only, zero LLM cost. Output paths migrated to the
`tmp/arc/{id}/inspect/` directory. Checkpoint phase field renamed from
`gap_analysis` to `inspect`. The phase-completion `updateCheckpoint()`
call at the end of STEP A.5 is now intentionally a substate update
(see body) — the caller `arc-phase-inspect.md` owns the final phase
completion after STEP D halt-gate runs.)_

## STEP A.0: Artifact Pre-Extraction (v1.141.0)

```javascript
// ARTIFACT EXTRACTION: Pre-extract plan and work-summary digests via shell script.
// Shell extraction: zero LLM tokens, sub-second. Digests used for orchestrator's
// quick checks only — gap analysis inspectors still read full artifacts for deep context.
// v3.x: settings.artifact_extraction.enabled defaults true — always extract.
try {
  Bash(`cd "${CWD}" && bash plugins/rune/scripts/artifact-extract.sh plan "${id}"`)
} catch (e) { warn(`artifact-extract plan digest failed: ${e.message}`) }

try {
  Bash(`cd "${CWD}" && bash plugins/rune/scripts/artifact-extract.sh work-summary "${id}"`)
} catch (e) { warn(`artifact-extract work-summary digest failed: ${e.message}`) }

// Read digests for orchestrator quick-checks (tiny JSON, ~300 tokens each)
const planDigest = (() => {
  try { return JSON.parse(Read(`tmp/arc/${id}/plan-digest.json`)) } catch { return null }
})()
const workDigest = (() => {
  try { return JSON.parse(Read(`tmp/arc/${id}/work-summary-digest.json`)) } catch { return null }
})()
// Quick-check metrics for downstream use
const acceptanceCriteriaCount = planDigest?.acceptance_criteria_count ?? "unknown"
const committedFileCount = workDigest?.committed_file_count ?? "unknown"
```

## STEP A.1: Extract Acceptance Criteria

```javascript
// Gap analysis inspectors still read full plan (they need deep context for requirement matching)
const enrichedPlan = Read(`tmp/arc/${id}/enriched-plan.md`)
// Parse lines matching: "- [ ] " or "- [x] " (checklist items)
// Also parse lines matching: "**Acceptance criteria**:" section content
// Also parse "**Outputs**:" lines from Plan Section Convention headers
const criteria = extractAcceptanceCriteria(enrichedPlan)
// Returns: [{ text: string, checked: boolean, section: string }]

if (criteria.length === 0) {
  const skipReport = "# Inspect Deterministic Pre-Checks\n\nNo acceptance criteria found in plan. Skipped."
  Write(`tmp/arc/${id}/inspect/deterministic.md`, skipReport)
  // v3.0.0-alpha.7 (Day 6): STEP A is a pre-team sub-step of inspect (Phase 5.9).
  // The caller arc-phase-inspect.md owns final phase completion after STEP D.
  // Record the deterministic-skipped substate so the halt-gate sees an empty result set.
  //
  // CORR-006 FIX: Initialize empty arrays for the variables that downstream STEP D
  // (inspect-step-d-halt-gate.md) reads from this file's scope. Without these,
  // STEP D crashes with ReferenceError on `gaps.filter(…)` and `diffFiles[…]`,
  // and the Task Completion Gate (PR #310 fix) never executes.
  const gaps = []
  const diffFiles = []
  const safeDiffFiles = []
  const taskStats = { total: 0, completed: 0, failed: 0 }
  const specMatrix = []
  const specCounts = { implemented_tested: 0, implemented_untested: 0, not_implemented: 0, drifted: 0 }
  const redCriteriaCount = 0
  const claims = []
  updateCheckpoint({
    phase: "inspect",
    substate: "deterministic_skipped",
    deterministic_artifact: `tmp/arc/${id}/inspect/deterministic.md`,
    deterministic_gaps: { addressed: 0, partial: 0, missing: 0, extra: 0 },
  })
  return  // exit STEP A; arc-phase-inspect.md continues with STEP 1+ and STEP 4.5 (halt-gate is a no-op)
}
```

## STEP A.2: Get Committed Files from Work Phase

```javascript
const workSummary = Read(`tmp/arc/${id}/work-summary.md`)
const committedFiles = extractCommittedFiles(workSummary)
// Also: git diff --name-only {default_branch}...HEAD for ground truth
const diffResult = Bash(`git diff --name-only "${defaultBranch}...HEAD"`)
const diffFiles = diffResult.trim().split('\n').filter(f => f.length > 0)
```

## STEP A.3: Cross-Reference Criteria Against Changes

```javascript
const gaps = []
// CDX-002 FIX: Sanitize diffFiles before use in shell commands (same filter as STEP 4.7)
const safeDiffFiles = diffFiles.filter(f => /^[a-zA-Z0-9._\-\/]+$/.test(f) && !f.includes('..'))
for (const criterion of criteria) {
  const identifiers = extractIdentifiers(criterion.text)

  let status = "UNKNOWN"
  for (const identifier of identifiers) {
    if (!/^[a-zA-Z0-9._\-\/]+$/.test(identifier)) continue
    if (safeDiffFiles.length === 0) break
    const grepResult = Bash(`rg -l --max-count 1 -- "${identifier}" ${safeDiffFiles.map(f => `"${f}"`).join(' ')} 2>/dev/null`)
    if (grepResult.trim().length > 0) {
      status = criterion.checked ? "ADDRESSED" : "PARTIAL"
      break
    }
  }
  if (status === "UNKNOWN") {
    // CDX-007 FIX: No code evidence found — always MISSING regardless of checked state
    status = "MISSING"
  }
  gaps.push({ criterion: criterion.text, status, section: criterion.section })
}
```

## STEP A.4: Check Task Completion Rate

```javascript
const taskStats = extractTaskStats(workSummary)
```

## STEP A.4.5: Doc-Consistency Cross-Checks

Non-blocking sub-step: validates that key values (version, agent count, etc.) are consistent across documentation and config files. Reports PASS/DRIFT/SKIP per check. Uses PASS/DRIFT/SKIP (not ADDRESSED/MISSING) to avoid collision with gap-analysis regex counts.

```javascript
// BACK-009: Guard: Only run doc-consistency if WORK phase succeeded and >=50% tasks completed
let docConsistencySection = ""
const consistencyGuardPass =
  checkpoint.phases?.work?.status !== "failed" &&
  taskStats.total > 0 &&
  (taskStats.completed / taskStats.total) >= 0.5

if (consistencyGuardPass) {
  // v3.x: arc.consistency.checks is no longer configurable — always use DEFAULT_CONSISTENCY_CHECKS.
  const DEFAULT_CONSISTENCY_CHECKS = [
    {
      name: "version_sync",
      description: "Plugin version matches across config and docs",
      source: { file: ".claude-plugin/plugin.json", extractor: "json_field", field: "version" },
      targets: [
        { path: "CLAUDE.md", pattern: "version:\\s*[0-9]+\\.[0-9]+\\.[0-9]+" },
        { path: "README.md", pattern: "version:\\s*[0-9]+\\.[0-9]+\\.[0-9]+" }
      ]
    },
    {
      name: "agent_count",
      description: "Review agent count matches across docs",
      source: { file: "agents/review/*.md", extractor: "glob_count" },
      targets: [
        { path: "CLAUDE.md", pattern: "\\d+\\s+agents" },
        { path: ".claude-plugin/plugin.json", pattern: "\"agents\"" }
      ]
    }
  ]

  const checks = DEFAULT_CONSISTENCY_CHECKS

  // Security patterns: SAFE_REGEX_PATTERN_CC, SAFE_PATH_PATTERN, SAFE_GLOB_PATH_PATTERN — see security-patterns.md
  // QUAL-003: _CC suffix = "Consistency Check" — narrower than SAFE_REGEX_PATTERN (excludes $, |, parens)
  const SAFE_REGEX_PATTERN_CC = /^[a-zA-Z0-9._\-\/ \\\[\]{}^+?*]+$/
  const SAFE_PATH_PATTERN_CC = /^[a-zA-Z0-9._\-\/]+$/
  const SAFE_GLOB_PATH_PATTERN = /^[a-zA-Z0-9._\-\/*]+$/
  const SAFE_DOT_PATH = /^[a-zA-Z0-9._]+$/
  const VALID_EXTRACTORS = ["glob_count", "regex_capture", "json_field", "line_count"]

  const consistencyResults = []

  for (const check of checks) {
    if (!check.name || !check.source || !Array.isArray(check.targets)) {
      consistencyResults.push({ name: check.name || "unknown", status: "SKIP", reason: "Malformed check definition" })
      continue
    }

    // BACK-005: Normalize empty patterns to undefined
    for (const target of check.targets) {
      if (target.pattern === "") target.pattern = undefined
    }

    // Validate source file path (glob_count allows * in path for shell expansion)
    const pathValidator = check.source.extractor === "glob_count" ? SAFE_GLOB_PATH_PATTERN : SAFE_PATH_PATTERN_CC
    if (!pathValidator.test(check.source.file)) {
      consistencyResults.push({ name: check.name, status: "SKIP", reason: `Unsafe source path: ${check.source.file}` })
      continue
    }
    // SEC-002: Path traversal and absolute path check
    if (check.source.file.includes('..') || check.source.file.startsWith('/')) {
      consistencyResults.push({ name: check.name, status: "SKIP", reason: "Path traversal or absolute path in source" })
      continue
    }
    if (!VALID_EXTRACTORS.includes(check.source.extractor)) {
      consistencyResults.push({ name: check.name, status: "SKIP", reason: `Invalid extractor: ${check.source.extractor}` })
      continue
    }
    if (check.source.extractor === "json_field" && check.source.field && !SAFE_DOT_PATH.test(check.source.field)) {
      consistencyResults.push({ name: check.name, status: "SKIP", reason: `Unsafe field path: ${check.source.field}` })
      continue
    }

    // --- Extract source value ---
    let sourceValue = null
    try {
      if (check.source.extractor === "json_field") {
        // BACK-004: Validate file extension for json_field extractor
        if (!check.source.file.match(/\.(json|jsonc|json5)$/i)) {
          consistencyResults.push({ name: check.name, status: "SKIP", reason: "json_field extractor requires .json file" })
          continue
        }
        const content = Read(check.source.file)
        const parsed = JSON.parse(content)
        const FORBIDDEN_KEYS = new Set(['__proto__', 'constructor', 'prototype'])
        sourceValue = String(check.source.field.split('.').reduce((obj, key) => {
          if (FORBIDDEN_KEYS.has(key)) throw new Error(`Forbidden path key: ${key}`)
          return obj[key]
        }, parsed) ?? "")
      } else if (check.source.extractor === "glob_count") {
        // Intentionally unquoted: glob expansion required. SAFE_GLOB_PATH_PATTERN validated above.
        // CDX-003 FIX: Use -- to prevent glob results starting with - being parsed as flags
        const globResult = Bash(`ls -1 -- ${check.source.file} 2>/dev/null | wc -l`)
        sourceValue = globResult.trim()
      } else if (check.source.extractor === "line_count") {
        const lcResult = Bash(`wc -l < "${check.source.file}" 2>/dev/null`)
        sourceValue = lcResult.trim()
      } else if (check.source.extractor === "regex_capture") {
        if (!check.source.pattern || !SAFE_REGEX_PATTERN_CC.test(check.source.pattern)) {
          consistencyResults.push({ name: check.name, status: "SKIP", reason: "Unsafe source regex" })
          continue
        }
        const rgResult = Bash(`rg --no-messages -o "${check.source.pattern}" "${check.source.file}" | head -1`)
        sourceValue = rgResult.trim()
      } else {
        consistencyResults.push({ name: check.name, status: "SKIP", reason: `Unknown extractor: ${check.source.extractor}` })
        continue
      }
    } catch (extractErr) {
      consistencyResults.push({ name: check.name, status: "SKIP", reason: `Source extraction failed: ${extractErr.message}` })
      continue
    }

    if (!sourceValue || sourceValue.length === 0) {
      consistencyResults.push({ name: check.name, status: "SKIP", reason: "Source value empty or not found" })
      continue
    }

    // --- Compare against each target ---
    for (const target of check.targets) {
      if (!target.path || !SAFE_PATH_PATTERN_CC.test(target.path)) {
        consistencyResults.push({ name: `${check.name}->${target.path || "unknown"}`, status: "SKIP", reason: "Unsafe target path" })
        continue
      }
      if (target.pattern && !SAFE_REGEX_PATTERN_CC.test(target.pattern)) {
        consistencyResults.push({ name: `${check.name}->${target.path}`, status: "SKIP", reason: "Unsafe target pattern" })
        continue
      }

      let targetStatus = "SKIP"
      try {
        if (target.pattern) {
          // SEC-001: Use -- separator and shell escape the pattern
          // SEC-003: Cap pattern length to prevent excessively long Bash commands
          if (target.pattern.length > 500) {
            consistencyResults.push({ name: `${check.name}->${target.path}`, status: "SKIP", reason: "Pattern exceeds 500 char limit" })
            continue
          }
          const escapedPattern = target.pattern.replace(/["$\`\\]/g, '\\$&')
          const targetResult = Bash(`rg --no-messages -o -- "${escapedPattern}" "${target.path}" 2>/dev/null | head -1`)
          const targetValue = targetResult.trim()
          if (targetValue.length === 0) {
            targetStatus = "DRIFT"
          } else if (targetValue.includes(sourceValue)) {
            targetStatus = "PASS"
          } else {
            targetStatus = "DRIFT"
          }
        } else {
          // CDX-001 FIX: Escape sourceValue to prevent shell injection
          const escapedSourceValue = sourceValue.replace(/["$`\\]/g, '\\$&')
          const grepResult = Bash(`rg --no-messages --fixed-strings -l -- "${escapedSourceValue}" "${target.path}" 2>/dev/null`)
          targetStatus = grepResult.trim().length > 0 ? "PASS" : "DRIFT"
        }
      } catch (targetErr) {
        targetStatus = "SKIP"
      }

      consistencyResults.push({
        name: `${check.name}->${target.path}`,
        status: targetStatus,
        sourceValue,
        reason: targetStatus === "DRIFT" ? `Source value "${sourceValue}" not matched in ${target.path}` : undefined
      })
    }
  }

  // --- Build doc-consistency report section ---
  // BACK-007: Cap at 100 results
  const MAX_CONSISTENCY_RESULTS = 100
  const displayResults = consistencyResults.length > MAX_CONSISTENCY_RESULTS
    ? consistencyResults.slice(0, MAX_CONSISTENCY_RESULTS)
    : consistencyResults

  const passCount = consistencyResults.filter(r => r.status === "PASS").length
  const driftCount = consistencyResults.filter(r => r.status === "DRIFT").length
  const skipCount = consistencyResults.filter(r => r.status === "SKIP").length
  const overallStatus = driftCount > 0 ? "WARN" : "PASS"

  docConsistencySection = `\n## DOC-CONSISTENCY\n\n` +
    `**Status**: ${overallStatus}\n` +
    `**Issues**: ${driftCount}\n` +
    `**Checked at**: ${new Date().toISOString()}\n` +
    (consistencyResults.length > MAX_CONSISTENCY_RESULTS ? `**Note**: Showing first ${MAX_CONSISTENCY_RESULTS} of ${consistencyResults.length} results\n` : '') +
    `\n| Check | Status | Detail |\n|-------|--------|--------|\n` +
    displayResults.map(r =>
      `| ${r.name} | ${r.status} | ${r.reason || "---"} |`
    ).join('\n') + '\n\n' +
    `Summary: ${passCount} PASS, ${driftCount} DRIFT, ${skipCount} SKIP\n`

  if (driftCount > 0) {
    warn(`Doc-consistency: ${driftCount} drift(s) detected`)
  }
} else {
  docConsistencySection = `\n## DOC-CONSISTENCY\n\n` +
    `**Status**: SKIP\n` +
    `**Reason**: Guard not met (Phase 5 failed or <50% tasks completed)\n` +
    `**Checked at**: ${new Date().toISOString()}\n`
}
```

## STEP A.4.7: Plan Section Coverage

Cross-reference plan H2 headings against committed code changes.

```javascript
let planSectionCoverageSection = ""

if (diffFiles.length === 0) {
  planSectionCoverageSection = `\n## PLAN SECTION COVERAGE\n\n` +
    `**Status**: SKIP\n**Reason**: No files committed during work phase\n`
} else {
  const planContent = Read(enrichedPlanPath)
  const strippedContent = planContent.replace(/```[\s\S]*?```/g, '')
  const planSections = strippedContent.split(/^## /m).slice(1)

  const sectionCoverage = []
  for (const section of planSections) {
    const heading = section.split('\n')[0].trim()

    const skipSections = ['Overview', 'Problem Statement', 'Dependencies',
      'Risk Analysis', 'References', 'Success Metrics', 'Cross-File Consistency',
      'Documentation Impact', 'Documentation Plan', 'Future Considerations',
      'AI-Era Considerations', 'Alternative Approaches', 'Forge Enrichment']
    if (skipSections.some(s => heading.includes(s))) {
      sectionCoverage.push({ heading, status: 'SKIPPED' })
      continue  // Don't search for identifiers — metadata sections don't map to code
    }

    // Extract identifiers from section text
    const backtickIds = (section.match(/`([a-zA-Z0-9._\-\/]+)`/g) || []).map(m => m.replace(/`/g, ''))
    const filePaths = section.match(/[a-zA-Z0-9_\-\/]+\.(py|ts|js|rs|go|md|yml|json)/g) || []
    // DOC-008 FIX: CamelCase length filter (>=6 chars) targets short generics ('Error', 'Field', 'Value').
    // Stopwords handle common verbs ('Create', 'Update', 'Delete') regardless of length.
    const caseNames = (section.match(/\b[A-Z][a-zA-Z0-9]+\b/g) || [])
      .filter(id => id.length >= 6)
    const stopwords = new Set(['Create', 'Add', 'Update', 'Fix', 'Implement', 'Section', 'Phase', 'Check', 'Remove', 'Delete'])
    const candidates = [...new Set([...filePaths, ...backtickIds, ...caseNames])]
      .filter(id => id.length >= 4 && id.length <= 100 && !stopwords.has(id))
      .filter(id => !/^\d+\.\d+(\.\d+)?$/.test(id))
    // Generic term frequency filter: exclude identifiers appearing in >50% of sections (too generic).
    // Math.max(2, ...) is a floor to prevent over-filtering on medium plans.
    // BACK-007 FIX: Skip generic filter entirely for small plans (< 5 sections) via early-exit below,
    // because threshold=2 incorrectly excludes plan-specific terms that naturally appear in most sections.
    const genericThreshold = Math.max(2, Math.floor(planSections.length * 0.5))
    const identifiers = candidates
      .filter(id => {
        if (planSections.length < 5) return true  // Small plan — keep all candidates
        const freq = planSections.filter(s => s.includes(id)).length
        return freq < genericThreshold
      })
      .slice(0, 20)

    const safeDiffFiles = diffFiles.filter(f => /^[a-zA-Z0-9._\-\/]+$/.test(f) && !f.includes('..'))

    let status = "MISSING"
    for (const id of identifiers) {
      if (!/^[a-zA-Z0-9._\-\/]+$/.test(id)) continue
      if (safeDiffFiles.length === 0) break
      const grepResult = Bash(`rg -l --max-count 1 -- "${id}" ${safeDiffFiles.map(f => `"${f}"`).join(' ')} 2>/dev/null`)
      if (grepResult.trim().length > 0) {
        status = "ADDRESSED"
        break
      }
    }
    sectionCoverage.push({ heading, status })
  }

  // Check Documentation Impact items (if present)
  const docImpactSection = planSections.find(s => s.startsWith('Documentation Impact'))
  if (docImpactSection) {
    const impactItems = docImpactSection.match(/- \[[ x]\] .+/g) || []
    for (const item of impactItems) {
      const checked = item.startsWith('- [x]')
      const filePath = item.match(/([a-zA-Z0-9._\-\/]+\.(md|json|yml|yaml))/)?.[1]
      if (filePath && diffFiles.includes(filePath)) {
        sectionCoverage.push({ heading: `Doc Impact: ${filePath}`, status: "ADDRESSED" })
      } else if (filePath) {
        sectionCoverage.push({ heading: `Doc Impact: ${filePath}`, status: checked ? "CLAIMED" : "MISSING" })
      }
    }
  }

  const covAddressed = sectionCoverage.filter(s => s.status === "ADDRESSED").length
  const covMissing = sectionCoverage.filter(s => s.status === "MISSING").length
  const covClaimed = sectionCoverage.filter(s => s.status === "CLAIMED").length
  const covSkipped = sectionCoverage.filter(s => s.status === "SKIPPED").length

  planSectionCoverageSection = `\n## PLAN SECTION COVERAGE\n\n` +
    `**Status**: ${covMissing > 0 ? "WARN" : "PASS"}\n` +
    `**Checked at**: ${new Date().toISOString()}\n\n` +
    `| Section | Status |\n|---------|--------|\n` +
    sectionCoverage.map(s => `| ${s.heading} | ${s.status} |`).join('\n') + '\n\n' +
    `Summary: ${covAddressed} ADDRESSED, ${covMissing} MISSING, ${covClaimed} CLAIMED, ${covSkipped} SKIPPED (metadata)\n`

  if (covMissing > 0) {
    warn(`Plan section coverage: ${covMissing} MISSING section(s)`)
  }
}
```

## STEP A.4.8: Check Evaluator Quality Metrics

Non-blocking sub-step: runs lightweight, evaluator-equivalent quality checks on committed code. Zero LLM cost — uses shell commands and AST analysis only. Score calculations are approximations and may differ from the E2E evaluator's exact algorithm.

```javascript
let evaluatorMetricsSection = ""

// Guard: verify python3 is available
const pythonCheck = Bash(`command -v python3 2>/dev/null`).trim()
if (!pythonCheck) {
  evaluatorMetricsSection = `\n## EVALUATOR QUALITY METRICS\n\n**Status**: SKIP\n**Reason**: python3 not found in PATH\n`
} else {
  // BACK-206 FIX: Exclude evaluation/ test files and remove redundant ./.* exclusion
  const pyFilesRaw = Bash(`find . -name "*.py" -not -path "./.venv/*" -not -path "./__pycache__/*" -not -path "./.tox/*" -not -path "./.pytest_cache/*" -not -path "./build/*" -not -path "./dist/*" -not -path "./.eggs/*" -not -path "./evaluation/*" -not -name "test_*.py" -not -name "*_test.py" | head -200`)
    .trim().split('\n').filter(f => f.length > 0)

  // SEC: Filter file paths through SAFE_PATH_PATTERN_CC before passing to heredoc.
  // CRITICAL: This regex MUST remain strict (alphanumeric + ._-/ only). Weakening it
  // would allow shell metacharacters ($, `, ;, etc.) to reach the heredoc interpolation
  // on the Bash() call below, enabling command injection via crafted filenames.
  const pyFiles = pyFilesRaw.filter(f => /^[a-zA-Z0-9._\-\/]+$/.test(f) && !f.includes('..') && !f.startsWith('/'))

  if (pyFiles.length === 0) {
    evaluatorMetricsSection = `\n## EVALUATOR QUALITY METRICS\n\n**Status**: SKIP\n**Reason**: No Python files found\n`
  } else {
    // 1. Docstring coverage + 2. Function length audit (combined single-pass)
    // SEC-002 FIX: Write file list to temp file instead of heredoc to prevent shell interpretation
    // SEC-008 FIX: Use project-local temp dir instead of /tmp (prevents info disclosure on multi-user systems)
    const pyFileListPath = `tmp/.rune-pyfiles-${Date.now()}.txt`
    Write(pyFileListPath, pyFiles.join('\n'))
    const astResult = Bash(`python3 -c "
import ast, sys
from pathlib import Path
total = with_doc = long_count = skipped = 0
long_fns = []
for f in sys.stdin.read().strip().split('\\n'):
    try:
        tree = ast.parse(Path(f).read_text(encoding='utf-8', errors='ignore'))
    except (SyntaxError, UnicodeDecodeError, OSError):
        skipped += 1
        continue
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            total += 1
            if ast.get_docstring(n): with_doc += 1
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if n.end_lineno and (n.end_lineno - n.lineno) > 40:
                long_count += 1
                long_fns.append(f'{f}:{n.lineno} {n.name} ({n.end_lineno - n.lineno} lines)')
print(f'{with_doc}/{total}/{long_count}/{skipped}')
for fn in long_fns[:10]: print(fn)
" < "${pyFileListPath}"`)
    Bash(`rm -f "${pyFileListPath}"`)  // cleanup temp file
    const parts = astResult.trim().split('\n')
    const [withDoc, totalDefs, longCount, skippedFiles] = parts[0].split('/').map(Number)
    const longFunctions = parts.slice(1)
    const docPct = totalDefs > 0 ? Math.round((withDoc / totalDefs) * 100) : 0
    const docScore = totalDefs > 0 ? ((withDoc / totalDefs) * 10).toFixed(1) : "N/A"
    const docStatus = docPct >= 80 ? "PASS" : docPct >= 50 ? "WARN" : "FAIL"
    const structScore = Math.max(0, 10 - longCount * 1.0).toFixed(1)
    const structStatus = longCount === 0 ? "PASS" : longCount <= 2 ? "WARN" : "FAIL"

    // 3. Evaluation test pass rate
    let evalStatus = "SKIP"
    let evalDetail = "No evaluation/ directory"
    // SEC-005 FIX: Guard against symlink traversal on evaluation/ path
    const evalIsSymlink = Bash(`test -L evaluation && echo "yes" || echo "no"`).trim()
    if (evalIsSymlink === "yes") {
      evalDetail = "evaluation/ is a symlink — skipped for safety"
    }
    const evalExists = evalIsSymlink !== "yes"
      ? Bash(`find evaluation -maxdepth 1 -name "*.py" -type f 2>/dev/null | wc -l`).trim()
      : "0"
    if (parseInt(evalExists) > 0) {
      // BACK-202 FIX: Capture exit code before piping to avoid tail masking pytest status
      // SEC-016 FIX: Use project-local tmp instead of /tmp to avoid shared-temp collisions
      const evalTmpFile = `tmp/.rune-eval-out-${Date.now()}.txt`
      const evalResult = Bash(`timeout 30s python -m pytest evaluation/ -v --tb=line 2>&1 > "${evalTmpFile}"; echo $?`)
      const evalRc = parseInt(evalResult.trim())
      const evalOutput = Bash(`tail -20 "${evalTmpFile}"`).trim()
      Bash(`rm -f "${evalTmpFile}"`)

      const output = evalOutput
      // Parse pass/fail counts from pytest summary
      const summaryMatch = output.match(/(\d+) passed(?:, (\d+) failed)?/)
      const passed = summaryMatch ? parseInt(summaryMatch[1]) : 0
      const failed = summaryMatch ? parseInt(summaryMatch[2] || '0') : 0
      if (evalRc === 0) {
        evalStatus = "PASS"
        evalDetail = summaryMatch ? `${passed} passed` : "all tests passed"
      } else if (evalRc === 5) {
        evalStatus = "SKIP"
        evalDetail = "No tests collected (exit code 5)"
      } else {
        evalStatus = "FAIL"
        evalDetail = summaryMatch ? `${passed} passed, ${failed} failed` : output.split('\n').pop() || "unknown"
      }
    }

    evaluatorMetricsSection = `\n## EVALUATOR QUALITY METRICS\n\n` +
      `**Checked at**: ${new Date().toISOString()}\n\n` +
      `| Metric | Status | Score | Detail |\n|--------|--------|-------|--------|\n` +
      `| Docstring coverage | ${docStatus} | ${docScore}/10 | ${withDoc}/${totalDefs} definitions (${docPct}%)${skippedFiles > 0 ? `, ${skippedFiles} files skipped` : ''} |\n` +
      `| Function length | ${structStatus} | ${structScore}/10 | ${longCount} functions over 40 lines |\n` +
      `| Evaluation tests | ${evalStatus} | — | ${evalDetail} |\n` +
      (longFunctions.length > 0 ? `\n**Long functions**:\n${longFunctions.map(f => '- ' + f).join('\n')}\n` : '') +
      '\n'
  }
}
```

## STEP A.9: Claim Extraction (Semantic Drift Detection)

Parse the synthesized plan for verifiable claims and cross-reference against committed files using multi-keyword grep matching. Zero LLM cost — deterministic extraction only.

```javascript
let semanticClaimsSection = ""
const claimSections = ['Acceptance Criteria', 'Success Criteria', 'Constraints']

// 1. Parse claims from plan headings: ## Acceptance Criteria, ## Success Criteria, ## Constraints
const planRaw = Read(enrichedPlanPath)
const strippedPlan = planRaw.replace(/```[\s\S]*?```/g, '')
const planBlocks = strippedPlan.split(/^## /m).slice(1)

const claims = []
let claimId = 0

for (const heading of claimSections) {
  const block = planBlocks.find(b => b.split('\n')[0].trim() === heading)
  if (!block) continue

  // Extract bullet items (- [ ] ..., - [x] ..., - ..., * ...)
  const bullets = block.match(/^[-*] (?:\[[ x]\] )?.+/gm) || []
  for (const bullet of bullets) {
    const text = bullet.replace(/^[-*] (?:\[[ x]\] )?/, '').trim()
    if (text.length < 5) continue

    // 2. Classify claim type based on source heading
    let claimType = "FUNCTIONAL"
    if (heading === 'Constraints') claimType = "CONSTRAINT"
    // Detect INVARIANT claims (always/never/must not patterns)
    if (/\b(always|never|must not|invariant|unchanged)\b/i.test(text)) claimType = "INVARIANT"
    // Detect INTEGRATION claims (API/endpoint/service/webhook patterns)
    if (/\b(api|endpoint|service|webhook|integration|external|upstream|downstream)\b/i.test(text)) claimType = "INTEGRATION"

    claims.push({ id: `CLAIM-${String(++claimId).padStart(3, '0')}`, text, type: claimType, source: heading })
  }
}

// Fallback: use Acceptance Criteria from STEP A.1 when Success Criteria / Constraints are absent
const hasSuccessCriteria = planBlocks.some(b => b.split('\n')[0].trim() === 'Success Criteria')
const hasConstraints = planBlocks.some(b => b.split('\n')[0].trim() === 'Constraints')
if (!hasSuccessCriteria && !hasConstraints && claims.length === 0) {
  // Fall back to criteria already extracted in STEP A.1
  for (const c of criteria) {
    claims.push({
      id: `CLAIM-${String(++claimId).padStart(3, '0')}`,
      text: c.text,
      type: "FUNCTIONAL",
      source: "Acceptance Criteria (fallback)"
    })
  }
}

// 3. Extract testable identifiers from each claim
// Significant terms: 2+ chars, excluding stop words
const STOP_WORDS = new Set([
  'the', 'is', 'a', 'an', 'and', 'or', 'to', 'in', 'for', 'of', 'on',
  'it', 'be', 'as', 'at', 'by', 'do', 'if', 'no', 'so', 'up', 'we',
  'are', 'was', 'has', 'had', 'not', 'but', 'can', 'all', 'its', 'may',
  'will', 'with', 'from', 'that', 'this', 'have', 'each', 'when', 'then',
  'than', 'into', 'been', 'also', 'must', 'should', 'would', 'could',
  'shall', 'such', 'some', 'only', 'very', 'just'
])

for (const claim of claims) {
  // Extract words: backtick-quoted identifiers, CamelCase, snake_case, file paths
  const backtickIds = (claim.text.match(/`([a-zA-Z0-9._\-\/]+)`/g) || []).map(m => m.replace(/`/g, ''))
  const codeIds = claim.text.match(/\b[a-zA-Z][a-zA-Z0-9_]{2,}\b/g) || []
  const allTerms = [...new Set([...backtickIds, ...codeIds])]
    .filter(t => t.length >= 2 && !STOP_WORDS.has(t.toLowerCase()))
    .slice(0, 15)  // Cap keywords per claim
  claim.keywords = allTerms
}

// 4. Multi-keyword grep matching against committed files
const safeDiffFilesA9 = diffFiles.filter(f => /^[a-zA-Z0-9._\-\/]+$/.test(f) && !f.includes('..'))

for (const claim of claims) {
  if (claim.keywords.length === 0 || safeDiffFilesA9.length === 0) {
    claim.deterministicVerdict = "UNTESTABLE"
    claim.matchCount = 0
    claim.evidence = []
    continue
  }

  let matchCount = 0
  const evidence = []

  for (const keyword of claim.keywords) {
    if (!/^[a-zA-Z0-9._\-\/]+$/.test(keyword)) continue
    const grepResult = Bash(`rg -l --max-count 1 -- "${keyword}" ${safeDiffFilesA9.map(f => `"${f}"`).join(' ')} 2>/dev/null`)
    if (grepResult.trim().length > 0) {
      matchCount++
      evidence.push({ keyword, files: grepResult.trim().split('\n').slice(0, 3) })
    }
  }

  // 5. Classify: SATISFIED (3+ matches) / PARTIAL (1-2 matches) / UNTESTABLE (0 matches)
  if (matchCount >= 3) {
    claim.deterministicVerdict = "SATISFIED"
  } else if (matchCount >= 1) {
    claim.deterministicVerdict = "PARTIAL"
  } else {
    claim.deterministicVerdict = "UNTESTABLE"
  }
  claim.matchCount = matchCount
  claim.evidence = evidence
}

// Summary stats for later use in report (STEP A.5)
const claimsSatisfied = claims.filter(c => c.deterministicVerdict === "SATISFIED").length
const claimsPartial = claims.filter(c => c.deterministicVerdict === "PARTIAL").length
const claimsUntestable = claims.filter(c => c.deterministicVerdict === "UNTESTABLE").length
```

## STEP A.10: Stale Reference Detection

Scan for lingering references to files deleted during the work phase. A deleted file that is still referenced elsewhere = incomplete cleanup = PARTIAL gap.

```javascript
// STEP A.10: Stale Reference Detection
// Post-deletion scan: find codebase references to files removed during work phase.
// Each stale reference becomes a PARTIAL criterion (fixable by removing the reference).

const deletedResult = Bash(`git diff --diff-filter=D --name-only "${defaultBranch}...HEAD" 2>/dev/null`)
const deletedFiles = [...new Set(
  deletedResult.trim().split('\n').filter(f => f.length > 0)
)]

if (deletedFiles.length === 0) {
  log("STEP A.10: No deleted files — skipping stale reference detection.")
} else {
  log(`STEP A.10: Scanning for stale references to ${deletedFiles.length} deleted file(s)...`)

  for (const deleted of deletedFiles) {
    const basename = deleted.split('/').pop()

    // CDX-002 FIX: Sanitize basename before shell use
    if (!/^[a-zA-Z0-9._\-]+$/.test(basename)) continue

    // Search across plugins/ (primary), .rune/ (legacy configs), .claude/ (legacy), scripts/ (hooks)
    // Uses Bash+rg to match existing gap-analysis.md tool pattern
    const grepResult = Bash(`rg -l --fixed-strings "${basename}" plugins/ .rune/ .claude/ scripts/ --glob '*.md' --glob '*.yml' --glob '*.sh' 2>/dev/null`)
    const referrers = grepResult.trim().split('\n')
      .filter(f => f.length > 0 && f !== deleted && !f.startsWith('tmp/') && !f.includes('gap-analysis.md'))

    if (referrers.length > 0) {
      gaps.push({
        criterion: `Cleanup: deleted file '${basename}' still referenced in ${referrers.length} file(s)`,
        status: "PARTIAL",
        section: "Stale References",
        evidence: `Stale references found in: ${referrers.slice(0, 5).join(', ')}${referrers.length > 5 ? ` (+${referrers.length - 5} more)` : ''}`,
        source: "STEP_A10_STALE_REF"
      })
    }
  }

  const staleCount = gaps.filter(g => g.source === "STEP_A10_STALE_REF").length
  log(`STEP A.10: Found ${staleCount} stale reference(s) across ${deletedFiles.length} deleted file(s).`)
}
```

## STEP A.11: Flag Scope Creep Detection

Identify CLI flags added in the implementation that were NOT specified in the plan. EXTRA scope items are advisory — flagged for review but not counted as fixable gaps.

```javascript
// STEP A.11: Flag Scope Creep Detection
// Compare --flag patterns in plan vs implementation diff.
// Unplanned flags → EXTRA status (advisory, not blocking).

// Extract planned flags/modes from plan content (--flag patterns)
// Pre-filter: remove code blocks and negative instruction contexts to reduce false positives
const strippedPlanContent = planContent.replace(/```[\s\S]*?```/g, '').replace(/`[^`]+`/g, '')
const planFlagPattern = /--([a-z][a-z0-9-]*)/g
const planFlags = [...new Set(
  [...strippedPlanContent.matchAll(planFlagPattern)].map(m => m[1])
)]

// Extract implemented flags/modes from the diff (added lines only, excluding comments)
const diffContent = Bash(`git diff "${defaultBranch}...HEAD" -- '*.md' '*.sh' '*.json' '*.yml' 2>/dev/null`)
const addedLines = diffContent.stdout
  .split('\n')
  .filter(l => l.startsWith('+') && !l.startsWith('+++'))
  .filter(l => { const trimmed = l.slice(1).trimStart(); return !trimmed.startsWith('//') && !trimmed.startsWith('#') && !trimmed.startsWith('*') && !trimmed.startsWith('<!--') })
  .join('\n')

const implFlagPattern = /--([a-z][a-z0-9-]*)/g
const implFlags = [...new Set(
  [...addedLines.matchAll(implFlagPattern)].map(m => m[1])
)]

// Find unplanned flags (in implementation but not in plan)
// Exclude common/infrastructure flags that are always valid
// NOTE: Consider auto-generating from SKILL.md argument-hint fields if FP rate > 3 per 5 runs
const infraFlags = new Set([
  'deep', 'dry-run', 'no-lore', 'deep-lore', 'verbose', 'help',
  'max-agents', 'focus', 'partial', 'cycles', 'quick', 'resume',
  'approve', 'no-forge', 'skip-freshness', 'confirm', 'no-test',
  'worktree', 'exhaustive', 'no-brainstorm', 'no-arena',
  'no-chunk', 'chunk-size', 'no-converge', 'scope-file', 'auto-mend',
  'no-pr', 'no-merge', 'draft', 'no-shard-sort',
  'threshold', 'fix', 'max-fixes', 'mode', 'output-dir', 'timeout',
  'lore', 'full-auto', 'json'
])

const unplannedFlags = implFlags.filter(f =>
  !planFlags.includes(f) && !infraFlags.has(f)
)

if (unplannedFlags.length > 0) {
  for (const flag of unplannedFlags) {
    // Find where this flag is introduced (uses Bash+rg per tool pattern convention)
    const flagResult = Bash(`rg -l -- "--${flag}" plugins/ 2>/dev/null`)
    const flagRefs = flagResult.trim().split('\n').filter(f => f.length > 0)

    gaps.push({
      criterion: `Scope creep: '--${flag}' added in implementation but not defined in plan`,
      status: "EXTRA",
      section: "Scope Creep",
      evidence: flagRefs.length > 0 ? `Found in: ${flagRefs.slice(0, 3).join(', ')}` : null,
      source: "STEP_A11_SCOPE_CREEP"
    })
  }

  const creepCount = unplannedFlags.length
  log(`STEP A.11: Found ${creepCount} unplanned flag(s): ${unplannedFlags.join(', ')}`)
} else {
  log("STEP A.11: No flag scope creep detected — all implementation flags match plan.")
}
```

## STEP A.12: Spec Compliance Matrix (Discipline-Aware)

Cross-reference ALL acceptance criteria from the plan against implementation evidence AND test coverage.
Produces a per-criterion status matrix with 4 states. Feeds into the gap analysis report and the STEP D
halt decision via RED criteria counts.

**CDX-SV-002**: Initial rollout uses WARN mode — RED criteria create remediation tasks rather than BLOCK.
v3.x bakes `specComplianceMode = "warn"` (see STEP A.12 below); flip the literal to `"block"` when ready.

```javascript
// STEP A.12: Spec Compliance Matrix
// Read ALL acceptance criteria from plan (reuses criteria from STEP A.1)
// Cross-reference against: (1) code evidence in diff, (2) test evidence in diff

// v3.x: arc.gap_analysis.spec_compliance_mode baked at "warn" (initial rollout posture).
const specComplianceMode = "warn"  // "warn" | "block"

// Parse test files from diff (files matching common test patterns)
const testFilePattern = /\b(test|spec|__tests__|__mocks__|e2e|integration)\b/i
const testFiles = safeDiffFiles.filter(f => testFilePattern.test(f) || /\.(test|spec)\.\w+$/.test(f))
const implFiles = safeDiffFiles.filter(f => !testFilePattern.test(f))

const specMatrix = []

for (const criterion of criteria) {
  const identifiers = extractIdentifiers(criterion.text)

  // Check implementation evidence (non-test files)
  let hasImplEvidence = false
  let implEvidenceFiles = []
  for (const identifier of identifiers) {
    if (!/^[a-zA-Z0-9._\-\/]+$/.test(identifier)) continue
    if (implFiles.length === 0) break
    const grepResult = Bash(`rg -l --max-count 1 -- "${identifier}" ${implFiles.map(f => `"${f}"`).join(' ')} 2>/dev/null`)
    if (grepResult.trim().length > 0) {
      hasImplEvidence = true
      implEvidenceFiles = grepResult.trim().split('\n').slice(0, 3)
      break
    }
  }

  // Check test evidence (test files only)
  let hasTestEvidence = false
  let testEvidenceFiles = []
  for (const identifier of identifiers) {
    if (!/^[a-zA-Z0-9._\-\/]+$/.test(identifier)) continue
    if (testFiles.length === 0) break
    const grepResult = Bash(`rg -l --max-count 1 -- "${identifier}" ${testFiles.map(f => `"${f}"`).join(' ')} 2>/dev/null`)
    if (grepResult.trim().length > 0) {
      hasTestEvidence = true
      testEvidenceFiles = grepResult.trim().split('\n').slice(0, 3)
      break
    }
  }

  // Check for drift: criterion marked as checked in plan but no code evidence
  const isDrifted = criterion.checked && !hasImplEvidence

  // Classify into 4-state matrix
  let specStatus
  if (isDrifted) {
    specStatus = "DRIFTED"
  } else if (hasImplEvidence && hasTestEvidence) {
    specStatus = "IMPLEMENTED_TESTED"
  } else if (hasImplEvidence && !hasTestEvidence) {
    specStatus = "IMPLEMENTED_UNTESTED"
  } else {
    specStatus = "NOT_IMPLEMENTED"
  }

  specMatrix.push({
    criterion: criterion.text,
    section: criterion.section,
    specStatus,
    hasImplEvidence,
    hasTestEvidence,
    isDrifted,
    implFiles: implEvidenceFiles,
    testFiles: testEvidenceFiles
  })
}

// Aggregate counts
const specCounts = {
  implemented_tested: specMatrix.filter(s => s.specStatus === "IMPLEMENTED_TESTED").length,
  implemented_untested: specMatrix.filter(s => s.specStatus === "IMPLEMENTED_UNTESTED").length,
  not_implemented: specMatrix.filter(s => s.specStatus === "NOT_IMPLEMENTED").length,
  drifted: specMatrix.filter(s => s.specStatus === "DRIFTED").length
}

// RED criteria = NOT_IMPLEMENTED + DRIFTED (these need remediation)
const redCriteriaCount = specCounts.not_implemented + specCounts.drifted
const redCriteria = specMatrix.filter(s =>
  s.specStatus === "NOT_IMPLEMENTED" || s.specStatus === "DRIFTED"
)

// Build report section
const specComplianceSection = `\n## SPEC COMPLIANCE MATRIX\n\n` +
  `**Mode**: ${specComplianceMode.toUpperCase()}\n` +
  `**Checked at**: ${new Date().toISOString()}\n\n` +
  `| Status | Count | Description |\n|--------|-------|-------------|\n` +
  `| IMPLEMENTED+TESTED | ${specCounts.implemented_tested} | Code evidence AND test evidence found |\n` +
  `| IMPLEMENTED+UNTESTED | ${specCounts.implemented_untested} | Code evidence found but NO test coverage |\n` +
  `| NOT_IMPLEMENTED | ${specCounts.not_implemented} | No code evidence found |\n` +
  `| DRIFTED | ${specCounts.drifted} | Marked complete in plan but no code evidence |\n\n` +
  (redCriteria.length > 0
    ? `### RED Criteria (${specComplianceMode === "block" ? "BLOCKING" : "WARN — remediation tasks created"})\n\n` +
      redCriteria.map(r =>
        `- **${r.specStatus}**: ${r.criterion.slice(0, 120)}${r.criterion.length > 120 ? '...' : ''} ` +
        `(section: ${r.section})`
      ).join('\n') + '\n\n'
    : `All criteria have implementation evidence.\n\n`) +
  `### Per-Criterion Detail\n\n` +
  `| Criterion | Status | Impl Evidence | Test Evidence |\n` +
  `|-----------|--------|---------------|---------------|\n` +
  specMatrix.map(s => {
    const implRef = s.implFiles.length > 0 ? s.implFiles[0] : '—'
    const testRef = s.testFiles.length > 0 ? s.testFiles[0] : '—'
    return `| ${s.criterion.slice(0, 60)}${s.criterion.length > 60 ? '...' : ''} | ${s.specStatus} | ${implRef} | ${testRef} |`
  }).join('\n') + '\n'

// CDX-SV-002: In WARN mode, RED criteria create remediation task entries (not BLOCK)
// In BLOCK mode, RED criteria contribute to halt decision in STEP D
if (redCriteriaCount > 0) {
  if (specComplianceMode === "warn") {
    warn(`Spec compliance: ${redCriteriaCount} RED criteria (WARN mode — remediation tasks will be created)`)
    // Append RED criteria as PARTIAL gaps for downstream remediation
    for (const red of redCriteria) {
      gaps.push({
        criterion: `Spec: ${red.criterion}`,
        status: "PARTIAL",
        section: red.section,
        evidence: red.specStatus === "DRIFTED"
          ? "Marked complete in plan but no implementation evidence"
          : "No implementation evidence found",
        source: "STEP_A12_SPEC_COMPLIANCE"
      })
    }
  } else {
    warn(`Spec compliance: ${redCriteriaCount} RED criteria (BLOCK mode — halt will trigger)`)
  }
}

log(`STEP A.12: Spec compliance matrix — ` +
  `${specCounts.implemented_tested} tested, ` +
  `${specCounts.implemented_untested} untested, ` +
  `${specCounts.not_implemented} not implemented, ` +
  `${specCounts.drifted} drifted`)
```

## STEP A.5: Write Deterministic Gap Analysis Report

```javascript
const addressed = gaps.filter(g => g.status === "ADDRESSED").length
const partial = gaps.filter(g => g.status === "PARTIAL").length
const missing = gaps.filter(g => g.status === "MISSING").length
const extra = gaps.filter(g => g.status === "EXTRA").length

const report = `# Implementation Gap Analysis\n\n` +
  `**Plan**: ${checkpoint.plan_file}\n` +
  `**Date**: ${new Date().toISOString()}\n` +
  `**Criteria found**: ${criteria.length}\n\n` +
  `## Summary\n\n` +
  `| Status | Count |\n|--------|-------|\n` +
  `| ADDRESSED | ${addressed} |\n| PARTIAL | ${partial} |\n| MISSING | ${missing} |\n| EXTRA | ${extra} |\n\n` +
  (missing > 0 ? `## MISSING (not found in committed code)\n\n` +
    gaps.filter(g => g.status === "MISSING").map(g =>
      `- [ ] ${g.criterion} (from section: ${g.section})`
    ).join('\n') + '\n\n' : '') +
  (partial > 0 ? `## PARTIAL (some evidence, not fully addressed)\n\n` +
    gaps.filter(g => g.status === "PARTIAL").map(g =>
      `- [ ] ${g.criterion} (from section: ${g.section})` +
      (g.evidence ? `\n  Evidence: ${g.evidence}` : '')
    ).join('\n') + '\n\n' : '') +
  (extra > 0 ? `## EXTRA (scope creep — not in plan)\n\n` +
    gaps.filter(g => g.status === "EXTRA").map(g =>
      `- [ ] ${g.criterion} (from section: ${g.section})` +
      (g.evidence ? `\n  Evidence: ${g.evidence}` : '')
    ).join('\n') + '\n\n' : '') +
  `## ADDRESSED\n\n` +
  gaps.filter(g => g.status === "ADDRESSED").map(g =>
    `- [x] ${g.criterion}`
  ).join('\n') + '\n\n' +
  `## Task Completion\n\n` +
  `- Completed: ${taskStats.completed}/${taskStats.total} tasks\n` +
  `- Failed: ${taskStats.failed} tasks\n` +
  specComplianceSection +
  docConsistencySection +
  planSectionCoverageSection +
  evaluatorMetricsSection +
  // STEP A.9: Semantic Claims section
  (claims.length > 0 ? `\n## Semantic Claims\n\n` +
    `| Claim | Type | Deterministic | Evidence |\n` +
    `|-------|------|---------------|----------|\n` +
    claims.map(c => {
      const evidenceLinks = (c.evidence || []).slice(0, 3)
        .map(e => `${e.keyword} in ${e.files[0] || '?'}`)
        .join('; ') || '—'
      return `| ${c.id}: ${c.text.slice(0, 80)}${c.text.length > 80 ? '...' : ''} | ${c.type} | ${c.deterministicVerdict} | ${evidenceLinks} |`
    }).join('\n') + '\n\n' +
    `Semantic drift score: ${claimsSatisfied}/${claims.length} claims verified\n` : '')

// STEP A.9 exhausts the A.x numbering space. Future additions should use STEP A.10+ or promote STEP A into sub-phases.

Write(`tmp/arc/${id}/inspect/deterministic.md`, report)

// v3.0.0-alpha.7 (Day 6): STEP A is a pre-team sub-step of inspect (Phase 5.9).
// Record the deterministic substate + artifact path on the inspect checkpoint so
// STEP D halt-gate can read both. The caller arc-phase-inspect.md owns final
// phase completion after STEP D runs.
updateCheckpoint({
  phase: "inspect",
  substate: "deterministic_done",
  deterministic_artifact: `tmp/arc/${id}/inspect/deterministic.md`,
  deterministic_artifact_hash: sha256(report),
  // Carry forward STEP A summary metrics for STEP D halt evaluation.
  deterministic_gaps: { addressed, partial, missing, extra },
})
```

**Output**: `tmp/arc/{id}/inspect/deterministic.md`

**Failure policy**: Non-blocking at STEP A. STEP D (`inspect-step-d-halt-gate.md`) reads this report and applies the dual-gate halt: a task completion gate (always active, floor 100%) and a quality score gate (threshold 70, halt enabled). When task completion falls below floor or the quality score falls below threshold, STEP D writes `checkpoint.phases.inspect.needs_remediation: true` and the existing inspect-fix sub-step (STEP 5 in `arc-phase-inspect.md`) spawns gap-fixers to remediate. See [v3-defaults.md](../../../references/v3-defaults.md) for baked-in values.

## Execution Log Integration

Phase-specific execution logging for QA gate verification. The Tarnished writes one entry per manifest step.

```javascript
// At phase start — initialize execution log
// v3.0.0-alpha.7 (Day 6): phase renamed from gap_analysis → inspect (sub-step "deterministic").
// The qa-manifests/gap-analysis.yaml manifest was retired (Q3 resolution); STEP A no
// longer drives a QA-gated manifest. The execution log remains for diagnostic visibility.
Bash(`mkdir -p "tmp/arc/${id}/execution-logs"`)
const executionLog = {
  phase: "inspect",
  sub_step: "deterministic",
  manifest: null,  // (retired in v3.0.0-alpha.7 Day 6 Q3)
  started_at: new Date().toISOString(),
  steps: [],
  skipped_steps: []
}

// After each step — record completion
executionLog.steps.push({
  id: "GAP-STEP-{NN}",
  status: "completed",  // or "skipped"
  started_at: stepStartTs,
  completed_at: new Date().toISOString(),
  artifact_produced: artifactPath || null,
  notes: ""
})

// For skipped steps (conditional steps that didn't execute)
executionLog.skipped_steps.push({
  id: "GAP-STEP-{NN}",
  reason: "condition not met: {description}"
})

// At phase end (BEFORE updateCheckpoint)
executionLog.completed_at = new Date().toISOString()
executionLog.completed_steps = executionLog.steps.length
executionLog.total_steps = 13  // from manifest
executionLog.skipped_count = executionLog.skipped_steps.length
executionLog.completion_pct = Math.round((executionLog.completed_steps / executionLog.total_steps) * 100)
Write(`tmp/arc/${id}/execution-logs/inspect-deterministic-execution.json`, JSON.stringify(executionLog, null, 2))
```
