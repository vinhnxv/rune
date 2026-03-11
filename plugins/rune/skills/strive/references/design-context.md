# Design Context Discovery (Phase 1 — Conditional)

After task extraction, discover design artifacts using a 5-strategy cascade. Triple-gated: `design_sync.enabled` + frontend task signals + design artifact presence. Zero overhead when any gate is closed.

```javascript
// Design context discovery — 5-strategy cascade
// Triple-gated: design_sync.enabled + frontend signals + artifacts
function discoverDesignContext(talisman, frontmatter, tasks) {
  // Gate 1: design_sync.enabled
  const designEnabled = readTalismanSection("misc")?.design_sync?.enabled === true
  if (!designEnabled) return { strategy: 'none' }

  // Gate 2: Any frontend tasks? (isFrontend set by classifyFrontendTask in parse-plan.md)
  const hasFrontendTasks = tasks.some(t => t.isFrontend)
  if (!hasFrontendTasks) return { strategy: 'none' }

  // Gate 3: Design artifacts — try 5 strategies in priority order

  // Strategy 1: Design packages (from arc design_extraction phase)
  const designPackages = Glob('tmp/arc/*/design/design-package.json')
  if (designPackages.length > 0) {
    const pkg = JSON.parse(Read(designPackages[0]))
    return {
      strategy: 'design-package',
      designPackagePath: designPackages[0],
      vsmFiles: pkg.vsm_files || [],
      dcdFiles: pkg.dcd_files || [],
      figmaUrl: pkg.figma_url || frontmatter.figma_url
    }
  }

  // Strategy 2: Arc VSM/DCD files (from previous arc run)
  const vsmFiles = Glob('tmp/arc/*/vsm/*.json')
  const dcdFiles = Glob('tmp/arc/*/design/*.md')
  if (vsmFiles.length > 0 || dcdFiles.length > 0) {
    return {
      strategy: 'arc-artifacts',
      vsmFiles, dcdFiles,
      figmaUrl: frontmatter.figma_url
    }
  }

  // Strategy 3: design-sync output (from /rune:design-sync)
  const dsVsm = Glob('.claude/design-sync/vsm/*.json')
  const dsDcd = Glob('.claude/design-sync/dcd/*.md')
  if (dsVsm.length > 0 || dsDcd.length > 0) {
    return {
      strategy: 'design-sync',
      vsmFiles: dsVsm, dcdFiles: dsDcd,
      figmaUrl: frontmatter.figma_url
    }
  }

  // Strategy 5: design-prototype output (from /rune:design-prototype via devise Phase 0)
  // Gate: plan frontmatter has design_references_path AND directory exists with artifacts
  // Position: AFTER design-sync (Strategy 3) because design-sync produces VSM/DCD which
  // are higher fidelity than design-prototype output. BEFORE figma-url-only (Strategy 4)
  // because design-prototype artifacts are richer than a bare URL.
  let designRefPath = frontmatter.design_references_path
  // SEC-002: Validate designRefPath against path traversal
  if (designRefPath && (designRefPath.includes('..') || designRefPath.startsWith('/') || !/^(tmp|plans)\//.test(designRefPath))) {
    warn('Invalid design_references_path — skipping design-prototype strategy')
    designRefPath = null
  }
  if (designRefPath) {
    const refDirContents = Glob(`${designRefPath}/*`)
    if (refDirContents.length > 0) {
      const prototypesManifest = tryRead(`${designRefPath}/prototypes-manifest.json`)
      const libraryManifest = tryRead(`${designRefPath}/library-manifest.json`)
      const flowMap = tryRead(`${designRefPath}/flow-map.md`)
      const summary = tryRead(`${designRefPath}/SUMMARY.md`)

      return {
        strategy: 'design-prototype',
        designReferencesPath: designRefPath,
        prototypesManifest: prototypesManifest ? JSON.parse(prototypesManifest) : null,
        libraryManifest: libraryManifest ? JSON.parse(libraryManifest) : null,
        hasFlowMap: !!flowMap,
        hasSummary: !!summary,
        figmaUrl: frontmatter.figma_url,
        // Trust hierarchy for design-prototype (applies when ONLY design-prototype
        // artifacts exist, not when VSM/DCD from design-sync also present):
        //   library-match > prototype > figma-reference
        // This is non-overlapping with design-sync's hierarchy (VSM > library > figma_to_react)
        // because Strategy 5 only fires when Strategies 1-3 found no VSM/DCD artifacts.
        trustHierarchy: 'library-match > prototype > figma-reference',
        vsmFiles: [], dcdFiles: []  // No VSM/DCD in design-prototype output
      }
    }
  }

  // Strategy 4: Figma URL only (from plan frontmatter — no extracted artifacts yet)
  if (frontmatter.figma_url) {
    return {
      strategy: 'figma-url-only',
      figmaUrl: frontmatter.figma_url,
      vsmFiles: [], dcdFiles: []
    }
  }

  return { strategy: 'none' }
}

const designContext = discoverDesignContext(talisman, frontmatter, extractedTasks)
const hasDesignContext = designContext.strategy !== 'none'

// Pass designContext to task annotation (parse-plan.md § Design Context Detection)
// Each task gets has_design_context + design_artifacts based on isFrontend flag
// Pass to worker prompt generation (worker-prompts.md § Design Context Injection)
// Workers receive DCD/VSM content in their spawn prompts when applicable
```

## Conditional Skill Loading

When `hasDesignContext` is true, conditionally load design skills for worker context:

```javascript
// Conditional loaded skills — only when design context is active
if (hasDesignContext) {
  loadedSkills.push('frontend-design-patterns')  // Design tokens, accessibility, responsive patterns
  loadedSkills.push('figma-to-react')             // Component mapping, variant extraction

  // design-sync skill only needed when VSM/DCD artifacts are present (Strategies 1-3)
  // When strategy is 'design-prototype' (Strategy 5), workers use prototype artifacts
  // instead of VSM/DCD — loading design-sync would add ~2k tokens of irrelevant context
  if (designContext.strategy !== 'design-prototype') {
    loadedSkills.push('design-sync')              // VSM/DCD knowledge
  }

  // design-prototype skill loaded when Strategy 5 is active — workers need prototype
  // interpretation guidance (trust hierarchy, library-match usage, preview-only rules)
  if (designContext.strategy === 'design-prototype') {
    loadedSkills.push('design-prototype')          // Prototype interpretation, library matching
  }
}
```

The `classifyFrontendTask()` function in `parse-plan.md` tags each task with `isFrontend`, and the Design Context Detection section attaches artifact paths to frontend tasks only.
