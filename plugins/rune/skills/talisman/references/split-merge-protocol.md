# SPLIT / MERGE — File Layout Protocol

Interactive commands for splitting `talisman.yml` into 3 companion files (by audience)
and merging them back into a single file.

## Section Mapping

Each top-level YAML section belongs to exactly one companion file.
The `version:` key NEVER moves — it stays in the main file unconditionally.

### `talisman.yml` (main — core runtime config)

Sections most users interact with:

| Section | Purpose |
|---------|---------|
| `version` | Schema version (always `1`) — NEVER moves |
| `rune-gaze` | File classification (extensions, skip patterns) |
| `settings` | Global settings (max_ashes, dedup_hierarchy) |
| `defaults` | Workflow defaults (scope, depth) |
| `review` | Review settings (diff_scope, convergence, sharding) |
| `work` | Strive settings (ward commands, workers, branch) |
| `arc` | Arc pipeline (timeouts, ship, gap_analysis) |
| `testing` | Test orchestration tiers |
| `audit` | Audit configuration |
| `inspect` | Inspection thresholds |
| `plan` | Research and verification patterns |
| `mend` | Finding resolution (batch_size) |
| `inner_flame` | Self-review protocol |
| `teammate_lifecycle` | Timeout and cleanup settings |
| `context_monitor` | Context usage tracking |
| `context_weaving` | Context compression |
| `devise` | Planning config |
| `strive` | Execution config |
| `discipline` | Proof validation, SCR threshold |
| `solution_arena` | Arena phase weights |

### `talisman.ashes.yml` (agent registry)

Custom agent definitions — only relevant to users who write custom review agents:

| Section | Purpose |
|---------|---------|
| `ashes` | Custom review agents (name, agent, source, workflows) |
| `user_agents` | Inline agent definitions |
| `extra_agent_dirs` | Additional agent directories |
| `doubt_seer` | Cross-agent claim verification |

### `talisman.integrations.yml` (external tools)

External tool configurations — only relevant to power users:

| Section | Purpose |
|---------|---------|
| `codex` | Cross-model verification |
| `codex_review` | Codex review workflow settings |
| `elicitation` | Reasoning method configuration |
| `horizon` | Strategic assessment |
| `evidence` | Evidence verification |
| `echoes` | Agent memory configuration |
| `state_weaver` | State machine validation |
| `file_todos` | Structured todo tracking |

## Companion File Constants

```
ASHES_SECTIONS = ["ashes", "user_agents", "extra_agent_dirs", "doubt_seer"]
INTEGRATIONS_SECTIONS = ["codex", "codex_review", "elicitation", "horizon",
                         "evidence", "echoes", "state_weaver", "file_todos"]
```

Any section NOT in these lists stays in the main file.
`version` is force-pinned to main even if accidentally listed.

---

## `/rune:talisman split`

Extracts sections from a single `talisman.yml` into companion files.

### Pre-flight Checks

```
1. Verify .rune/talisman.yml exists
   → If missing: error "No talisman.yml found. Run /rune:talisman init first."

2. Check companion files do NOT already exist
   → If .rune/talisman.ashes.yml exists: error "Already split. Run /rune:talisman merge first."
   → If .rune/talisman.integrations.yml exists: same error

3. Read .rune/talisman.yml content as raw text lines
```

### Phase 1: Section Discovery (text-based)

Use line-by-line processing to identify top-level YAML sections.
Do NOT parse YAML — this preserves comments, whitespace, and ordering.

```
TOP_LEVEL_KEY_PATTERN = /^([a-z_][a-z0-9_-]*):\s*/

sections = []
current_section = null
header_lines = []    # Lines before the first top-level key (comments, blank lines)

for i, line in enumerate(lines):
    match = TOP_LEVEL_KEY_PATTERN.match(line)
    if match:
        key = match.group(1)
        if current_section:
            current_section.end_line = i
        current_section = { key: key, start_line: i, end_line: len(lines) }
        sections.append(current_section)
    elif not sections:
        # Lines before any section (file header comments, YAML directives)
        header_lines.append(line)

# Close the last section
if current_section:
    current_section.end_line = len(lines)
```

**Structural assumption**: Top-level YAML keys start at column 0 (no leading whitespace).
Indented lines, comments, and blank lines within a section belong to that section.

### Phase 2: Classify Sections

```
ashes_ranges = []
integrations_ranges = []
main_ranges = []

for section in sections:
    if section.key == "version":
        main_ranges.append(section)          # version NEVER moves
    elif section.key in ASHES_SECTIONS:
        ashes_ranges.append(section)
    elif section.key in INTEGRATIONS_SECTIONS:
        integrations_ranges.append(section)
    else:
        main_ranges.append(section)
```

### Phase 3: Preview and Confirm

Present extraction summary to user via AskUserQuestion:

```
message = """
Split preview:
  Main (talisman.yml):              {len(main_ranges)} sections
  Agent registry (talisman.ashes.yml):     {len(ashes_ranges)} sections
    → {', '.join(s.key for s in ashes_ranges)}
  External tools (talisman.integrations.yml): {len(integrations_ranges)} sections
    → {', '.join(s.key for s in integrations_ranges)}

Proceed? (y/n)
"""
```

If no sections would move (both companion lists empty), report:
"Nothing to split — no ashes or integrations sections found in talisman.yml."

### Phase 4: Capture Pre-Split Shard Hashes

Before modifying any files, capture current shard output for verification:

```
Bash("for f in tmp/.talisman-resolved/*.json; do shasum -a 256 \"$f\"; done > /tmp/rune-pre-split-shards.txt")
```

### Phase 5: Write Companion Files (FIRST)

Write companions before modifying main — this ensures atomicity.
If any write fails, no files have been altered.

```
# Build companion file content from line ranges
def extract_companion(ranges, lines, companion_name):
    if not ranges:
        return None

    content = []
    # Add header comment
    content.append(f"# {companion_name}")
    content.append(f"# Split from talisman.yml by /rune:talisman split")
    content.append(f"# Merge back with /rune:talisman merge")
    content.append("")
    content.append("# WARNING: jq merge replaces arrays (not append).")
    content.append("# If main file has ashes.custom: [a] and this file has ashes.custom: [b],")
    content.append("# the result is [b], not [a, b].")
    content.append("")

    for section in ranges:
        # Extract lines[section.start_line : section.end_line]
        content.extend(lines[section.start_line : section.end_line])

    # Trim trailing blank lines, ensure single newline at end
    while content and content[-1].strip() == "":
        content.pop()
    content.append("")

    return "\n".join(content)

# Write ashes companion
if ashes_ranges:
    ashes_content = extract_companion(ashes_ranges, lines, "Talisman Agent Registry")
    Write(".rune/talisman.ashes.yml", ashes_content)

# Write integrations companion
if integrations_ranges:
    integrations_content = extract_companion(integrations_ranges, lines, "Talisman External Integrations")
    Write(".rune/talisman.integrations.yml", integrations_content)
```

### Phase 6: Remove Extracted Sections from Main

```
# Build main file from remaining sections
main_content = []

# Preserve file header (lines before first section)
main_content.extend(header_lines)

for section in main_ranges:
    main_content.extend(lines[section.start_line : section.end_line])

# Trim trailing blank lines, ensure single newline at end
while main_content and main_content[-1].strip() == "":
    main_content.pop()
main_content.append("")

Write(".rune/talisman.yml", "\n".join(main_content))
```

### Phase 7: Verify Shard Equivalence

Run the resolver and compare shard output to pre-split snapshot:

```
Bash("bash ${CLAUDE_PLUGIN_ROOT}/scripts/talisman-resolve.sh")
Bash("for f in tmp/.talisman-resolved/*.json; do shasum -a 256 \"$f\"; done > /tmp/rune-post-split-shards.txt")
diff_result = Bash("diff /tmp/rune-pre-split-shards.txt /tmp/rune-post-split-shards.txt")
```

If diff shows differences → **ROLLBACK**:

```
# Rollback: restore original main, delete companions
Write(".rune/talisman.yml", original_content)
Bash("rm -f .rune/talisman.ashes.yml .rune/talisman.integrations.yml")
error("Split verification FAILED — shards differ. Rolled back. Check talisman-resolve.sh companion support.")
```

If diff is clean → report success:

```
"Split complete.
  {len(ashes_ranges)} sections → talisman.ashes.yml
  {len(integrations_ranges)} sections → talisman.integrations.yml
  {len(main_ranges)} sections remain in talisman.yml
  Shard output verified identical."
```

### Phase 8: Cleanup

```
Bash("rm -f /tmp/rune-pre-split-shards.txt /tmp/rune-post-split-shards.txt")
```

---

## `/rune:talisman merge`

Rejoins companion files into a single `talisman.yml`.

### Pre-flight Checks

```
1. Verify .rune/talisman.yml exists
   → If missing: error "No talisman.yml found."

2. Discover companion files
   companions = []
   if exists(".rune/talisman.ashes.yml"):   companions.append("ashes")
   if exists(".rune/talisman.integrations.yml"): companions.append("integrations")

   → If no companions found: "Nothing to merge — no companion files found."
```

### Phase 1: Capture Pre-Merge Shard Hashes

```
Bash("for f in tmp/.talisman-resolved/*.json; do shasum -a 256 \"$f\"; done > /tmp/rune-pre-merge-shards.txt")
```

### Phase 2: Read All Files

```
main_lines = Read(".rune/talisman.yml").split("\n")

companion_data = {}
for suffix in companions:
    path = f".rune/talisman.{suffix}.yml"
    raw = Read(path)
    # Strip companion header comments (lines starting with # before first section)
    content_lines = raw.split("\n")
    first_section_idx = None
    for i, line in enumerate(content_lines):
        if TOP_LEVEL_KEY_PATTERN.match(line):
            first_section_idx = i
            break
    if first_section_idx is not None:
        # Preserve blank line separator before companion sections
        companion_data[suffix] = content_lines[first_section_idx:]
    else:
        companion_data[suffix] = []  # Empty companion — skip
```

### Phase 3: Concatenate

Merge order: main sections first, then ashes sections, then integrations sections.
This produces a deterministic ordering.

```
merged = []

# Main file content (strip trailing blanks)
merged.extend(main_lines)
while merged and merged[-1].strip() == "":
    merged.pop()

# Append ashes sections
if "ashes" in companion_data and companion_data["ashes"]:
    merged.append("")
    merged.append("# --- Agent Registry (merged from talisman.ashes.yml) ---")
    merged.append("")
    merged.extend(companion_data["ashes"])
    # Strip trailing blanks from ashes block
    while merged and merged[-1].strip() == "":
        merged.pop()

# Append integrations sections
if "integrations" in companion_data and companion_data["integrations"]:
    merged.append("")
    merged.append("# --- External Integrations (merged from talisman.integrations.yml) ---")
    merged.append("")
    merged.extend(companion_data["integrations"])
    while merged and merged[-1].strip() == "":
        merged.pop()

# Final newline
merged.append("")
```

### Phase 4: Write Merged File

```
Write(".rune/talisman.yml", "\n".join(merged))
```

### Phase 5: Verify Shard Equivalence

```
Bash("bash ${CLAUDE_PLUGIN_ROOT}/scripts/talisman-resolve.sh")
Bash("for f in tmp/.talisman-resolved/*.json; do shasum -a 256 \"$f\"; done > /tmp/rune-post-merge-shards.txt")
diff_result = Bash("diff /tmp/rune-pre-merge-shards.txt /tmp/rune-post-merge-shards.txt")
```

If diff shows differences → **WARN** (do NOT rollback — merged file is the canonical truth):

```
warn("Merge verification: shards differ from pre-merge state. Run /rune:talisman audit to check.")
```

If diff is clean → proceed to cleanup.

### Phase 6: Delete Companion Files

Only delete companions AFTER successful verification:

```
for suffix in companions:
    Bash(f"rm -f .rune/talisman.{suffix}.yml")
```

### Phase 7: Report

```
"Merge complete.
  {len(companions)} companion file(s) merged into talisman.yml.
  Companion files deleted.
  Shard output verified identical."
```

### Phase 8: Cleanup

```
Bash("rm -f /tmp/rune-pre-merge-shards.txt /tmp/rune-post-merge-shards.txt")
```

---

## Comment Preservation Strategy

Both `split` and `merge` use **text-based line processing** — never YAML parse-serialize.
This is critical because PyYAML discards all comments during round-trip.

### Core Principle

Operate on raw text lines with section boundary detection. The only structural
assumption is that top-level YAML keys start at column 0 (no leading whitespace).

### Section Boundary Detection

```python
import re

TOP_LEVEL_KEY = re.compile(r'^([a-z_][a-z0-9_-]*):\s*', re.IGNORECASE)

def find_section_ranges(lines):
    """Find (key, start_line, end_line) for each top-level section.

    A section starts at the line matching TOP_LEVEL_KEY and ends
    at the next TOP_LEVEL_KEY match or end-of-file.

    Comments and blank lines between sections belong to the NEXT section
    if they appear immediately before a key, or to the PREVIOUS section
    if they appear after indented content.
    """
    sections = []
    for i, line in enumerate(lines):
        m = TOP_LEVEL_KEY.match(line)
        if m:
            if sections:
                sections[-1] = (*sections[-1][:2], i)  # close previous
            sections.append((m.group(1), i, len(lines)))
    return sections
```

### What Gets Preserved

| Element | Preserved? | How |
|---------|-----------|-----|
| Inline comments (`key: value  # comment`) | Yes | Line is copied verbatim |
| Block comments (`# standalone comment`) | Yes | Attached to containing section |
| Blank lines between keys | Yes | Part of section range |
| Key ordering | Yes | Sections extracted/appended in discovery order |
| Indentation style | Yes | Lines copied without modification |
| YAML anchors (`&anchor`) | Yes | Line-level copy preserves syntax |
| YAML aliases (`*anchor`) | **Partial** | Preserved as text, but cross-file aliases break |
| Trailing whitespace | Yes | No line trimming applied |

### Cross-File Alias Warning

YAML aliases (`*anchor`) reference anchors (`&anchor`) defined elsewhere in the same file.
If an anchor is in the main file and its alias is in a companion file (or vice versa),
the YAML parser will fail to resolve the alias after split.

**Mitigation**: The shard resolver (`talisman-resolve.sh`) merges companions BEFORE
YAML parsing, so aliases work at the resolver level. But direct YAML parsing of a
single companion file will fail if it contains unresolved aliases.

**Recommendation**: Avoid YAML anchors that cross section boundaries. Within a single
section, anchors are safe because the entire section moves together.

### Inter-Section Comment Attribution

Comments between sections present an attribution challenge:

```yaml
# End of arc section comment       ← belongs to arc
arc:
  timeout: 300

# Testing configuration            ← belongs to testing (header comment)
testing:
  tiers: [unit, integration]
```

The algorithm attributes ALL lines between two `TOP_LEVEL_KEY` matches to the
FIRST section (the one being closed). This means:

- Header comments for the NEXT section travel with the PREVIOUS section during split
- On merge, this produces slightly different comment placement than the original

**Accepted trade-off**: Perfect comment attribution would require heuristic analysis
(blank-line gaps, comment content parsing). The simpler "everything belongs to previous
section" rule is predictable and reversible.

### Roundtrip Guarantee

`split → merge` produces output that is **semantically identical** but may differ
in comment placement between sections. The shard verification (SHA-256 comparison)
ensures the resolver produces identical JSON regardless.

`merge → split → merge` is idempotent after the first cycle.
