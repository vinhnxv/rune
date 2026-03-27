---
name: variant-hunt
description: |
  Find similar bugs across the codebase based on a confirmed finding.
  Takes a TOME finding ID or pattern description, extracts the root cause,
  and systematically searches for variants using progressive generalization.
  Use when: "find more like this", "variant analysis", "similar bugs",
  "same pattern elsewhere", "hunt for variants", "variant hunt".
user-invocable: true
disable-model-invocation: false
argument-hint: "<finding-id | pattern-description | TOME-path>"
---

# /rune:variant-hunt — Find Similar Bugs

Systematic variant analysis: given a confirmed finding, search the codebase for
similar patterns that may have the same defect.

**Load skills**: `team-sdk`, `polling-guard`, `zsh-compat`

## Usage

```
/rune:variant-hunt SEC-003                              # Hunt variants of a specific TOME finding
/rune:variant-hunt "missing null check before .access"  # Hunt by pattern description
/rune:variant-hunt tmp/reviews/abc/TOME.md              # Hunt variants for all P1 findings
```

## Workflow

```javascript
const args = "$ARGUMENTS".trim()
const timestamp = new Date().toISOString().slice(0, 19).replace(/[-:T]/g, "")
const outputDir = `tmp/variant-hunt/${timestamp}/`

// Step 1: Parse input — determine what we're hunting for
let findings = []

if (args.endsWith(".md") && args.includes("TOME")) {
  // Input is a TOME path — extract all P1 findings
  const tome = Read(args)
  // Parse RUNE:FINDING markers for P1 findings
  const p1Regex = /<!-- RUNE:FINDING.*?-->([\s\S]*?)<!-- \/RUNE:FINDING -->/g
  let match
  while ((match = p1Regex.exec(tome)) !== null) {
    if (match[1].includes("P1")) {
      findings.push({ source: "tome", content: match[1].trim() })
    }
  }
  if (findings.length === 0) {
    log("No P1 findings in TOME — nothing to hunt variants for.")
    return
  }
} else if (/^[A-Z]+-\d+$/.test(args)) {
  // Input is a finding ID — look up in most recent TOME
  const tomes = Glob("tmp/reviews/*/TOME.md")
  if (tomes.length === 0) {
    error("No TOME found. Run /rune:review first, then hunt variants.")
    return
  }
  const tome = Read(tomes[0])
  const findingRegex = new RegExp(`\\[${args}\\].*?(?=\\n### |\\n## |$)`, "s")
  const findingMatch = tome.match(findingRegex)
  if (!findingMatch) {
    error(`Finding ${args} not found in ${tomes[0]}`)
    return
  }
  findings.push({ source: "finding-id", id: args, content: findingMatch[0] })
} else {
  // Input is a pattern description
  findings.push({ source: "description", content: args })
}

// Step 2: Create output directory and team
Bash(`mkdir -p ${outputDir}`)

const teamName = `rune-variant-${timestamp.slice(0, 8)}`
TeamCreate({ name: teamName })

// Step 3: Spawn variant-hunter for each finding (max 3 concurrent)
const maxHunters = Math.min(findings.length, 3)
for (let i = 0; i < maxHunters; i++) {
  const finding = findings[i]
  const outputPath = `${outputDir}variants-${i + 1}.md`

  TaskCreate({
    subject: `Hunt variants for finding ${finding.id ?? (i + 1)}`,
    description: `Source finding:\n${finding.content}\n\nOutput: ${outputPath}`
  })

  Agent({
    prompt: `Hunt for variants of this finding across the codebase.

## Source Finding
${finding.content}

## Output
Write variant report to: ${outputPath}
Team: ${teamName}. Claim your task via TaskList.`,
    subagent_type: "rune:investigation:variant-hunter",
    team_name: teamName,
    name: `variant-hunter-${i + 1}`
  })
}

// Step 4: Monitor
waitForCompletion(teamName, maxHunters, {
  timeoutMs: 300_000,  // 5 min
  pollIntervalMs: 30_000,
  label: "Variant Hunt"
})

// Step 5: Collect and present results
let totalVariants = 0
for (let i = 0; i < maxHunters; i++) {
  const outputPath = `${outputDir}variants-${i + 1}.md`
  try {
    const report = Read(outputPath)
    const variantCount = (report.match(/### VARIANT-/g) || []).length
    totalVariants += variantCount
  } catch (e) {
    log(`Variant report ${i + 1} not available`)
  }
}

// Step 6: Cleanup
// Standard shutdown + TeamDelete pattern (see CLAUDE.md Agent Team Cleanup)

// Step 7: Present summary
log(`Variant hunt complete: ${totalVariants} variant(s) found across ${maxHunters} finding(s).`)
log(`Reports: ${outputDir}`)
```

## Talisman Configuration

```yaml
variant_analysis:
  enabled: false             # Opt-in (adds time to review cycle)
  auto_trigger: "p1_only"   # "p1_only" | "p1_p2" | "all"
  max_variants_per_finding: 10
```

## Error Handling

| Error | Recovery |
|-------|----------|
| No TOME found | Stop, suggest `/rune:review` first |
| Finding ID not found | Stop, list available finding IDs |
| Variant hunter timeout | Proceed with partial results |
| No variants found | Report "clean" — pattern is isolated |
