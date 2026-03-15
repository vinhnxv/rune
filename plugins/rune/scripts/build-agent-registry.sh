#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════════
# build-agent-registry.sh — Fast agent registry index generator
# ════════════════════════════════════════════════════════════════════════════════
# Scans plugins/rune/agents/**/*.md for YAML frontmatter and extracts metadata
# into a JSON array at tmp/.agent-registry.json.
#
# Target: <100ms for ~96 agent files (single awk pass, no per-file subprocesses)
#
# Usage:
#     bash plugins/rune/scripts/build-agent-registry.sh
#
# Output: tmp/.agent-registry.json
# ════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="$PLUGIN_ROOT/agents"
OUTPUT_DIR="${PLUGIN_ROOT}/../../tmp"
OUTPUT_FILE="$OUTPUT_DIR/.agent-registry.json"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Single awk pass: concatenate all files with a separator, process in one invocation.
# We use find to get file list, then awk processes each file's frontmatter.
find "$AGENTS_DIR" -name '*.md' -type f \
  -not -path '*/references/*' \
  -not -name 'README.md' \
  -print0 | sort -z | xargs -0 awk \
  -v plugin_root="$PLUGIN_ROOT" \
  -v max_desc=100 \
'
# ── State machine per file ──
# States: 0=before_open, 1=in_frontmatter, 2=after_close
FNR == 1 {
  # New file: emit previous entry if we have one
  if (name != "") emit_entry()
  state = 0
  name = ""; desc = ""; desc_block = 0; primary_phase = ""
  source = ""; priority = ""; categories = ""; tags = ""
  cur_list = ""; cur_list_key = ""
  file_path = FILENAME
  sub("^" plugin_root "/", "", file_path)
  total++
}

state == 0 && /^---$/ { state = 1; next }
state == 1 && /^---$/ { state = 2; next }
state != 1 { next }

# ── Parse frontmatter fields ──

# End any active list if we hit a non-list-item line
cur_list_key != "" && !/^  -/ && !/^$/ {
  if (cur_list_key == "categories") categories = cur_list
  if (cur_list_key == "tags") tags = cur_list
  cur_list_key = ""; cur_list = ""
}

# Scalar fields
/^name: / {
  val = $0; sub(/^name: */, "", val)
  gsub(/["'"'"']/, "", val)
  name = val; next
}

/^primary_phase: / {
  val = $0; sub(/^primary_phase: */, "", val)
  gsub(/["'"'"']/, "", val)
  primary_phase = val; next
}

/^source: / {
  val = $0; sub(/^source: */, "", val)
  gsub(/["'"'"']/, "", val)
  source = val; next
}

/^priority: / {
  val = $0; sub(/^priority: */, "", val)
  gsub(/["'"'"']/, "", val)
  priority = val; next
}

# Description — block scalar
/^description: \|/ { desc_block = 1; desc = ""; next }
/^description: / && !/\|/ {
  val = $0; sub(/^description: */, "", val)
  gsub(/["'"'"']/, "", val)
  desc = val; desc_block = 0; next
}

# Description continuation lines (indented under block scalar)
desc_block && /^  / {
  line = $0; gsub(/^[ \t]+/, "", line)
  if (desc != "") desc = desc " "
  desc = desc line
  next
}
desc_block && /^[^ ]/ { desc_block = 0 }

# List fields: categories and tags
/^categories:/ {
  if ($0 ~ /\[\]/) { categories = ""; next }
  cur_list_key = "categories"; cur_list = ""; next
}
/^tags:/ {
  if ($0 ~ /\[\]/) { tags = ""; next }
  cur_list_key = "tags"; cur_list = ""; next
}

# List items
cur_list_key != "" && /^  - / {
  val = $0; sub(/^  - */, "", val)
  sub(/ *#.*$/, "", val)  # strip inline comments
  gsub(/["'"'"']/, "", val)
  if (cur_list != "") cur_list = cur_list ",\"" val "\""
  else cur_list = "\"" val "\""
  next
}

# ── Emit JSON entry ──
function emit_entry() {
  # Finalize any pending list
  if (cur_list_key == "categories") categories = cur_list
  if (cur_list_key == "tags") tags = cur_list
  cur_list_key = ""

  # Truncate description
  if (length(desc) > max_desc) desc = substr(desc, 1, max_desc) "..."

  # Escape JSON characters in description
  gsub(/\\/, "\\\\", desc)
  gsub(/"/, "\\\"", desc)
  gsub(/\t/, " ", desc)

  # Defaults
  if (source == "") source = "builtin"
  if (priority == "") priority = "100"
  if (primary_phase == "") {
    primary_phase = "unknown"
    warnings++
    print "WARN: Missing primary_phase in " file_path > "/dev/stderr"
  }
  if (tags == "") {
    warnings++
    print "WARN: Missing tags in " file_path > "/dev/stderr"
  }

  # Comma separator
  if (entry_count > 0) printf ","

  printf "{\"name\":\"%s\",\"description\":\"%s\",\"primary_phase\":\"%s\",\"categories\":[%s],\"tags\":[%s],\"source\":\"%s\",\"priority\":%s,\"file_path\":\"%s\"}\n", \
    name, desc, primary_phase, categories, tags, source, priority, file_path

  entry_count++
}

BEGIN {
  printf "["
  entry_count = 0; total = 0; warnings = 0
}

END {
  # Emit last entry
  if (name != "") emit_entry()
  printf "]\n"

  # Summary to stderr
  print "Registry built: " total " agents indexed, " warnings " warnings" > "/dev/stderr"
}
' > "$OUTPUT_FILE.tmp"

# Atomic move
mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

echo "Output: $OUTPUT_FILE"
