# Sharded Review Path — Phase 3 Orchestration

> Orchestrates shard reviewer spawning, monitoring, and cross-shard analysis when
> `inscription.sharding?.enabled === true` (standard depth + large diff, v1.98.0+).
> Called from SKILL.md Phase 3 as an alternative to the standard single-pass or chunked paths.
> See [shard-allocator.md](shard-allocator.md) for the file partitioning algorithm.

## Sharded Review Orchestration

When `inscription.sharding?.enabled === true`, Phase 3 spawns shard reviewers in parallel
then a single Cross-Shard Sentinel after all shards complete.
See [shard-allocator.md](shard-allocator.md) for allocator algorithm and
[shard-reviewer.md](../../../prompts/ash/shard-reviewer.md) for reviewer prompt template.

```javascript
if (inscription.sharding?.enabled) {
  // ─── SHARDED REVIEW PATH ───────────────────────────────────────────────────
  const { shards, cross_shard } = inscription.sharding

  // Step 1: Register shard reviewers in teammates[] for TeammateIdle hook
  for (const shard of shards) {
    inscription.teammates.push({
      name: shard.reviewer_name,
      output_file: shard.output_file,
      required_sections: ["P1 (Critical)", "P2 (High)", "P3 (Medium)", "Self-Review Log"]
    })
  }

  // Step 2: Spawn shard reviewers in PARALLEL
  for (const shard of shards) {
    const prompt = buildShardReviewerPrompt(shard, {
      outputDir,
      diffScope: inscription.diff_scope,
      innerFlame: true,
      seal: true
    })
    Agent({
      team_name: teamName,
      name: shard.reviewer_name,
      subagent_type: "general-purpose",
      model: shard.model,
      prompt,
      run_in_background: true
    })
  }

  // Step 3: Monitor shard reviewers
  waitForCompletion(teamName, shards.length, {
    timeoutMs: 600_000,
    staleWarnMs: 300_000,
    pollIntervalMs: 30_000,
    label: `Shard review (${shards.length} shards)`
  })

  // Step 3.5: Validate shard outputs — handle timeout/crash gracefully
  const availableSummaries = []
  for (const shard of shards) {
    const summaryPath = `${outputDir}${shard.summary_file}`
    const findingsPath = `${outputDir}${shard.output_file}`
    if (fileExists(summaryPath)) {
      availableSummaries.push(summaryPath)
    } else if (fileExists(findingsPath)) {
      // Findings exist but summary missing — reviewer crashed mid-output
      // Generate minimal stub summary for Cross-Shard Sentinel
      log(`WARN: Shard ${shard.shard_id} missing summary JSON — generating stub`)
      Write(summaryPath, JSON.stringify({
        shard_id: shard.shard_id,
        files_reviewed: 0,
        finding_count: 0,
        finding_ids: [],
        file_summaries: [],
        cross_shard_signals: [],
        stub: true,
        stub_reason: "crash"
      }))
      availableSummaries.push(summaryPath)
    } else {
      // Both missing — shard reviewer fully timed out
      log(`WARN: Shard ${shard.shard_id} produced no output (timeout/crash)`)
      // Write stub so Cross-Shard Sentinel treats as coverage blind spot
      Write(summaryPath, JSON.stringify({
        shard_id: shard.shard_id,
        files_reviewed: 0,
        finding_count: 0,
        finding_ids: [],
        file_summaries: [],
        cross_shard_signals: [],
        stub: true,
        stub_reason: "timeout"
      }))
      availableSummaries.push(summaryPath)
    }
  }

  // Step 4: Spawn Cross-Shard Sentinel (SEQUENTIAL, after all shards done)
  // Note: subagent_type is "general-purpose" per ATE-1 (Agent Teams Enforcement).
  // The cross-shard-sentinel.md agent definition (tools: Read, Write) serves as
  // the prompt template, NOT as a platform-enforced tool restriction. The metadata-only
  // constraint is enforced via prompt ("MUST NOT read source files") — not platform-level.
  // This is an accepted design tradeoff: ATE-1 requires general-purpose for all teammates.
  if (cross_shard?.enabled && availableSummaries.length > 0) {
    // Reset .expected count: shards.length → 1 (for sentinel monitoring)
    Write(`${signalDir}/.expected`, "1")

    Agent({
      team_name: teamName,
      name: cross_shard.reviewer_name,
      subagent_type: "general-purpose",
      model: resolveModelForAgent("cross-shard-sentinel", talisman),  // Cost tier mapping (references/cost-tier-mapping.md)
      prompt: buildCrossShardPrompt(availableSummaries, { outputDir }),
      run_in_background: true
    })

    waitForCompletion(teamName, 1, {
      timeoutMs: 180_000,
      staleWarnMs: 90_000,
      pollIntervalMs: 30_000,
      label: "Cross-shard analysis"
    })
  }

} else {
  // ─── NON-SHARDED PATH (chunked or standard single-pass — unchanged) ─────────
```

## Prompt Builder Contracts

```javascript
// buildCrossShardPrompt: generates the Cross-Shard Sentinel spawn prompt
function buildCrossShardPrompt(summaryFiles, opts) {
  // summaryFiles: array of absolute paths to shard-*-summary.json files
  // opts: { outputDir }
  // Returns: string — complete spawn prompt for the cross-shard sentinel
  const fileList = summaryFiles.map((f, i) => `${i + 1}. ${f}`).join('\n')
  return CROSS_SHARD_SENTINEL_TEMPLATE
    .replace('{summary_file_list}', fileList)
    .replace('{output_dir}', opts.outputDir)
}
```

## Phase 5 Aggregation Note

Runebinder already reads all `*.md` files in `outputDir`.
Shard findings (`shard-a-findings.md`, etc.) and cross-shard findings (`cross-shard-findings.md`)
are standard finding files — Runebinder reads them without modification.
Shard summary JSONs (`shard-*-summary.json`) are skipped (JSON, not MD).
Finding prefixes `SH{X}-` and `XSH-` follow the 2-5 char convention — no Runebinder changes.

## Communication Protocol

All shard reviewers and cross-shard analysts follow this communication protocol:
- **Heartbeat**: Send "Starting: reviewing shard {N}" via SendMessage after claiming task.
- **Seal**: On completion, TaskUpdate(completed) then SendMessage with Review Seal format (see team-sdk/references/seal-protocol.md).
- **Inner-flame**: Always include Inner-flame: {pass|fail|partial} in Seal.
- **Recipient**: Always use recipient: "team-lead".
- **Shutdown**: When you receive a shutdown_request, respond with shutdown_response({ approve: true }).
