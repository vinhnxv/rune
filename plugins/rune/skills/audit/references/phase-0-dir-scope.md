# Phase 0: Directory Scope Resolution

Pre-filter for `--dirs` and `--exclude-dirs` flags. Runs before Rune Gaze, incremental layer, and Lore Layer — those components receive a smaller `all_files` array with zero changes.

```javascript
// ── Directory Scope Resolution (Phase 0 pre-filter) ──
// Security pattern: SAFE_PATH_PATTERN — rejects path traversal and absolute escape
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\/-]+$/

// 1. Parse flag values (comma-separated lists)
const flagDirs     = (flags['--dirs']         || "").split(",").map(s => s.trim()).filter(Boolean)
const flagExcludes = (flags['--exclude-dirs'] || "").split(",").map(s => s.trim()).filter(Boolean)

// 2. Merge with talisman defaults (flags override when both present)
//    Array.isArray() guard: talisman values may be strings or undefined
const talismanDirs     = Array.isArray(talisman?.audit?.dirs)         ? talisman.audit.dirs         : []
const talismanExcludes = Array.isArray(talisman?.audit?.exclude_dirs) ? talisman.audit.exclude_dirs : []
const includeDirs  = flagDirs.length     > 0 ? flagDirs     : talismanDirs      // flags override talisman
const excludeDirs  = [...new Set([...talismanExcludes, ...flagExcludes])]        // merge both exclude lists

// 3. Validate paths — reject absolute paths and path traversal
const validateDir = (p) => {
  if (p === "." || p === "./") throw `Rejected "." as dir — use explicit subdirectory paths (e.g., "src/")`
  if (p.startsWith("/"))    throw `Rejected absolute path: "${p}" — use paths relative to project root`
  if (p.includes(".."))     throw `Rejected path traversal: "${p}" — ".." not allowed`
  if (!SAFE_PATH_PATTERN.test(p)) throw `Rejected unsafe path characters in: "${p}"`
  // SECURITY INVARIANT: SAFE_PATH_PATTERN must be checked BEFORE this Bash call.
  // The regex eliminates shell metacharacters, making the interpolation safe.
  const resolved  = Bash(`realpath -m "${p}" 2>/dev/null || echo "INVALID"`).trim()
  const projectRoot = Bash(`pwd -P`).trim()
  if (!resolved.startsWith(projectRoot)) throw `Rejected path escaping project root: "${p}"`
  return true
}
;[...includeDirs, ...excludeDirs].forEach(validateDir)

// 4. Normalize: strip trailing slashes, ensure relative, deduplicate
const normalize = (p) => p.replace(/\/+$/, "").replace(/^\.\//, "")
const normInclude  = [...new Set(includeDirs.map(normalize))]
const normExclude  = [...new Set(excludeDirs.map(normalize))]

// 5. Remove subdirs already covered by a parent (dedup overlapping dirs)
const removeRedundant = (dirs) => dirs.filter(d =>
  !dirs.some(parent => parent !== d && d.startsWith(parent + "/"))
)
const dedupedInclude = removeRedundant(normInclude)

// 6. Verify dirs exist — warn and skip missing, abort if ALL missing
const verifiedInclude = dedupedInclude.filter(d => {
  const exists = Bash(`test -d "${d}" && echo yes || echo no`).trim() === "yes"
  if (!exists) log(`[warn] --dirs path not found, skipping: ${d}`)
  return exists
})
if (dedupedInclude.length > 0 && verifiedInclude.length === 0) {
  throw "All --dirs paths are missing or invalid — nothing to audit."
}

// 7. Record dir_scope metadata for downstream phases
// Contract: when include=null, full repo scope. Excludes are already applied at the find step
// and need not be re-applied by Ashes. Ashes receiving dir_scope in inscription should check
// include !== null before scoping — a truthy object with include=null means "full repo with excludes".
const dir_scope = {
  include: verifiedInclude.length > 0 ? verifiedInclude : null,  // null = scan everything
  exclude: normExclude
}
```

## File Scanning

```bash
# Scan all project files (excluding non-project directories)
# When --dirs provided, scope find to verified include paths instead of '.'
# dir_scope.include and dir_scope.exclude are resolved from the JavaScript block above.
all_files=$(find ${dir_scope.include ? dir_scope.include.map(p => `"${p}"`).join(" ") : "."} -type f \
  ! -path '*/.git/*' \
  ! -path '*/node_modules/*' \
  ! -path '*/__pycache__/*' \
  ! -path '*/tmp/*' \
  ! -path '*/dist/*' \
  ! -path '*/build/*' \
  ! -path '*/.next/*' \
  ! -path '*/.venv/*' \
  ! -path '*/venv/*' \
  ! -path '*/target/*' \
  ! -path '*/.tox/*' \
  ! -path '*/vendor/*' \
  ! -path '*/.cache/*' \
$(dir_scope.exclude.map(d => `  ! -path '*/${d}/*'`).join(" \\\n")) \
  | sort)

# Optional: get branch name for metadata (not required — audit works without git)
branch=$(git branch --show-current 2>/dev/null || echo "n/a")
```

**Abort conditions:**
- No files found -> "No files to audit in current directory."
- Only non-reviewable files -> "No auditable code found."

**Note:** Unlike `/rune:appraise`, audit does NOT require a git repository.
