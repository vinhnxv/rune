# Phase 1.3: Extract File References

Parse plan content for file paths referenced in code blocks, backtick-wrapped paths, and annotations.
These files become the scope for Lore Layer risk scoring.

```javascript
// Extract file paths mentioned in plan text
// Patterns: `src/foo/bar.py`, backtick-wrapped paths, "File:" / "Path:" / "Module:" annotations,
//           YAML paths, markdown link targets
const fileRefPattern = /(?:`([^`]+\.\w+)`|(?:File|Path|Module):\s*(\S+\.\w+))/g
const planContent = Read(planPath)
const referencedFiles: string[] = []

for (const match of planContent.matchAll(fileRefPattern)) {
  const filePath: string = match[1] || match[2]
  // Validate: must not contain path traversal, must exist on disk
  if (filePath.includes('..')) continue
  try {
    Read(filePath)  // Existence check via Read — TOCTOU safe (we use the content later anyway)
    referencedFiles.push(filePath)
  } catch (readError) {
    // File doesn't exist — skip silently
    continue
  }
}

// Deduplicate
const uniqueFiles: string[] = [...new Set(referencedFiles)]
log(`Phase 1.3: Extracted ${uniqueFiles.length} file references from plan`)
```

**Skip condition**: If `uniqueFiles.length === 0`, skip Phase 1.5 entirely (no files to score).
