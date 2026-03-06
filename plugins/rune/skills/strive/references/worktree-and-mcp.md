# Worktree Mode Detection & MCP Integration Discovery

## Worktree Mode Detection (Phase 0)

Parse `--worktree` flag from `$ARGUMENTS` and read talisman configuration. This follows the same pattern as `--approve` flag parsing.

```javascript
// Parse --worktree flag from $ARGUMENTS (same pattern as --approve)
const args = "$ARGUMENTS"
const worktreeFlag = args.includes("--worktree")

// readTalismanSection: "work"
const work = readTalismanSection("work")
const worktreeEnabled = work?.worktree?.enabled || false

// worktreeMode: flag wins, talisman is fallback default
const worktreeMode = worktreeFlag || worktreeEnabled
```

When `worktreeMode === true`:
- Load `git-worktree` skill for merge strategy knowledge
- Phase 1 computes wave groupings after task extraction (step 5.3)
- Phase 2 spawns workers with `isolation: "worktree"` per wave
- Phase 3 uses wave-aware monitoring loop
- Phase 3.5 uses `mergeBroker()` instead of `commitBroker()`
- Workers commit directly instead of generating patches

## MCP Integration Discovery (Phase 1.6, conditional)

Zero cost when no integrations configured.

See [mcp-integration.md](mcp-integration.md) for the shared resolver algorithm.

```javascript
// After design context discovery, before file ownership
const mcpIntegrations = resolveMCPIntegrations("strive", {
  changedFiles: extractedTasks.flatMap(t => t.metadata?.file_targets || []),
  taskDescription: planContent
})

if (mcpIntegrations.length > 0) {
  // Load companion skills
  const mcpSkills = loadMCPSkillBindings(mcpIntegrations)
  loadedSkills.push(...mcpSkills)

  // Build context block for worker prompts (injected in Phase 2)
  const mcpContextBlock = buildMCPContextBlock(mcpIntegrations)
  // mcpContextBlock passed to worker prompt builder alongside designContextBlock
}
```
