# Phase 3: Initialize Progress File

```javascript
const progressFile = "tmp/arc-batch/batch-progress.json"
if (!resumeMode) {
  Bash("mkdir -p tmp/arc-batch")
  Write(progressFile, JSON.stringify({
    schema_version: 2,  // v2: shard metadata (v1.66.0+)
    status: "running",
    started_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    total_plans: planPaths.length,
    // NEW (v1.66.0): shard group summary for progress display
    shard_groups: (shardGroups.size > 0)  // F-004: outer-scope Map, always defined
      ? Array.from(shardGroups.entries()).map(([prefix, shards]) => ({
          feature: prefix.replace(/.*\//, ''),  // basename of prefix
          shards: shards.map(s => s.shardNum),
          total: shards.length
        }))
      : [],
    plans: planPaths.map(p => {
      const shardMatch = p.match(/-shard-(\d+)-/)
      return {
        path: p,
        status: "pending",
        error: null,
        completed_at: null,
        arc_session_id: null,
        // NEW (v1.66.0): shard metadata (null for non-shard plans)
        shard_group: shardMatch ? p.replace(/-shard-\d+-[^/]*$/, '').replace(/.*\//, '') : null,
        shard_num: shardMatch ? parseInt(shardMatch[1]) : null
      }
    })
  }, null, 2))
}
```
