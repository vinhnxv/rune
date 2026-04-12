# --improve Mode: Convergence Algorithm

Detailed documentation for the skill-testing `--improve` convergence loop.

## Convergence Algorithm Pseudocode

```
function improveSkill(skillName, maxIterations = 3):
  assert maxIterations >= 1 and maxIterations <= 5  // hard cap

  skillPath = resolveSkillPath(skillName)
  reportDir = "tmp/skill-improve/{skillName}"
  mkdir(reportDir)

  iteration = 0
  previousFindingCount = Infinity

  while iteration < maxIterations:
    iteration += 1

    // Phase 1: TEST
    findings = runComplianceChecks(skillPath)
    findings += runPressureScenarios(skillPath)

    // Phase 2: CATEGORIZE
    for finding in findings:
      finding.severity = classifySeverity(finding)      // CRITICAL | MAJOR | MINOR
      finding.type = classifyType(finding)               // structural | semantic
      finding.category = classifyCategory(finding)       // from STRUCTURAL_CATEGORIES enum

    // Phase 3: FIX (structural only)
    fixable = findings.filter(f =>
      f.type == "structural"
      and f.severity in ["CRITICAL", "MAJOR"]
      and isStructuralFix(f.category)
    )

    fixCount = 0
    for finding in fixable:
      applied = applyFix(skillPath, finding)
      if applied:
        fixCount += 1

    // Stagnation detection
    if fixCount == 0:
      writeReport(reportDir, iteration, findings, "STAGNATED")
      break

    // Phase 4: RE-TEST
    reFindings = runComplianceChecks(skillPath)
    critMajor = reFindings.filter(f => f.severity in ["CRITICAL", "MAJOR"])

    writeReport(reportDir, iteration, findings, fixCount)

    // Phase 5: CONVERGE
    if critMajor.length == 0:
      writeReport(reportDir, iteration, reFindings, "CONVERGED")
      break

    previousFindingCount = critMajor.length

  // Post-loop: persist patterns to echoes
  persistToEchoes(skillName, reportDir)
  return loadFinalReport(reportDir)
```

## Classification Functions

### isStructuralFix(category)

Returns `true` when the finding category is safe for automated fixing.

```
STRUCTURAL_CATEGORIES = enum {
  "frontmatter-missing",     // Missing required YAML fields (name, description)
  "frontmatter-invalid",     // Malformed YAML syntax in frontmatter block
  "reference-broken",        // Link target file does not exist at path
  "reference-backtick",      // Backtick code path instead of markdown link
  "section-missing",         // Missing standard skill sections
  "line-limit-exceeded",     // SKILL.md exceeds 500-line limit
  "namespace-bare",          // Skill() call without rune: prefix
  "creation-log-missing"     // No CREATION-LOG.md in skill directory
}

function isStructuralFix(category):
  return category in STRUCTURAL_CATEGORIES
```

Any category NOT in this enum is classified as semantic and blocked from auto-fix.

### classifySeverity(finding)

```
function classifySeverity(finding):
  if finding.category in ["frontmatter-missing", "frontmatter-invalid", "namespace-bare"]:
    return "CRITICAL"    // Skill won't load or resolve correctly
  if finding.category in ["reference-broken", "line-limit-exceeded"]:
    return "MAJOR"       // Skill loads but has broken references or compliance issues
  if finding.category in ["reference-backtick", "section-missing", "creation-log-missing"]:
    return "MINOR"       // Style/completeness issues
  // Semantic findings
  return finding.observedSeverity or "MINOR"
```

### classifyType(finding)

```
function classifyType(finding):
  if finding.category in STRUCTURAL_CATEGORIES:
    return "structural"
  return "semantic"
```

## Per-Iteration Report Schema

Each iteration appends to `tmp/skill-improve/{skill-name}/improvement-report.md`:

```yaml
# Report entry structure (per iteration)
iteration: N
status: IN_PROGRESS | CONVERGED | STAGNATED | MAX_ITERATIONS
timestamp: ISO-8601
findings_total: <count>
findings_critical: <count>
findings_major: <count>
findings_minor: <count>
fixes_applied: <count>
fixes_skipped: <count>     # semantic findings left for manual review
changes:
  - finding: "<description>"
    category: "<STRUCTURAL_CATEGORIES value>"
    action: "FIXED | SKIPPED"
    confidence: "HIGH | MEDIUM | LOW"
    detail: "<what was changed or why it was skipped>"
```

Terminal statuses:
- **CONVERGED**: No CRITICAL or MAJOR findings remain after re-test
- **STAGNATED**: Iteration applied 0 fixes (all remaining findings are semantic or unfixable)
- **MAX_ITERATIONS**: Hard cap reached with findings still present

## Echo Persistence Format

After the loop completes, patterns are persisted using the echo-append infrastructure:

```
function persistToEchoes(skillName, reportDir):
  report = loadFinalReport(reportDir)

  // Build echo entry
  entry = {
    role: "skill-tester",
    layer: "observations",
    tags: ["skill-improvement", "meta-qa", skillName],
    content: formatEchoContent(report)
  }

  // Use echo-append.sh from lib
  source "${RUNE_PLUGIN_ROOT}/scripts/lib/echo-append.sh"
  rune_echo_append(
    role = "skill-tester",
    layer = "observations",
    content = entry.content,
    dedup_key = "skill-improve-${skillName}-${report.iteration}"
  )
```

The `rune_echo_append()` function from `scripts/lib/echo-append.sh` handles:
- Dedup key checking (prevents duplicate entries across runs)
- MEMORY.md append with YAML frontmatter
- Dirty signal for echo-search auto-reindex

## Cross-Skill Pattern Promotion

When the same structural category appears in 2+ skills during separate `--improve` runs,
it qualifies as a cross-skill pattern eligible for batch fixing:

```
function detectCrossSkillPatterns():
  // Scan all improvement reports
  reports = glob("tmp/skill-improve/*/improvement-report.md")

  // Count category occurrences across skills
  categoryCounts = {}
  for report in reports:
    for change in report.changes:
      if change.action == "FIXED":
        categoryCounts[change.category] += 1

  // Promote patterns appearing in 2+ skills
  crossPatterns = categoryCounts.filter(count >= 2)

  if crossPatterns.length > 0:
    rune_echo_append(
      role = "skill-tester",
      layer = "inscribed",        // promoted layer for cross-skill patterns
      content = formatCrossPatterns(crossPatterns),
      dedup_key = "cross-skill-patterns-${date}"
    )

  return crossPatterns
```

Cross-skill patterns are persisted at the **inscribed** layer (higher than observations)
because they represent validated, recurring issues worthy of systemic attention.
