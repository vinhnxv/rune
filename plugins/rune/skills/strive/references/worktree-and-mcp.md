# Worktree Mode Detection & MCP Integration Discovery

<!-- v3.x: defaults baked from former talisman.work.worktree; see references/v3-defaults.md -->

## Worktree Mode Detection (Phase 0)

Parse `--worktree` flag from `$ARGUMENTS`. v3.x bakes `work.worktree.enabled = false`, so worktree mode is opt-in via the CLI flag only.

```javascript
// Parse --worktree flag from $ARGUMENTS (same pattern as --approve)
const args = "$ARGUMENTS"
const worktreeFlag = args.includes("--worktree")

// v3.x: work.worktree.enabled defaults to false — flag is the only switch
const worktreeMode = worktreeFlag
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
