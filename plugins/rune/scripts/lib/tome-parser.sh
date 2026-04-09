#!/bin/bash
# scripts/lib/tome-parser.sh
# Parse RUNE:FINDING markers from TOME.md files into JSON array.
#
# USAGE:
#   tome-parser.sh <tome_path>
#
# OUTPUT: JSON array of findings to stdout (via jq).
#   Each finding: { id, file, line, severity, confidence, confidence_score, title, body, ash }
#
# FORMATS SUPPORTED:
#   Format A (canonical):  <!-- RUNE:FINDING nonce="..." id="SEC-001" file="..." line="42" severity="P1" ... -->
#                          ... content ...
#                          <!-- /RUNE:FINDING id="SEC-001" -->
#   Format B (codex positional): <!-- RUNE:FINDING xsec-001 P1 -->
#                                ... content ...
#                                (no closer — delimited by next marker, HR, heading, or EOF)
#   Format D (UX alternate close): Same attrs as Format A but uses <!-- RUNE:FINDING:END --> as closer
#
# SEC-004: Input length validation (id max 32, file max 500, line max 10, severity max 8)
# COMPAT: Uses bash [[ =~ ]] for regex matching (no grep -P), sed -E (not sed -r).
# REQUIRES: jq (guarded)

set -euo pipefail

# --- Input Validation ---

if [[ $# -lt 1 ]]; then
  echo "ERROR: Usage: tome-parser.sh <tome_path>" >&2
  exit 1
fi

tome_path="$1"

if [[ "$tome_path" == *".."* ]]; then
  echo "ERROR: Path traversal detected in tome_path" >&2
  exit 1
fi

if [[ ! -f "$tome_path" ]]; then
  echo "ERROR: TOME file not found: $tome_path" >&2
  exit 1
fi

if [[ ! -s "$tome_path" ]]; then
  # Empty TOME — return empty array
  printf '[]'
  exit 0
fi

# Guard jq availability
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found. Install via: brew install jq" >&2
  exit 1
fi

# --- SEC-004: Length Validation ---

_validate_length() {
  local value="$1" field="$2" max="$3"
  if [[ ${#value} -gt $max ]]; then
    echo "WARNING: SEC-004: $field exceeds max length ($max): truncating" >&2
    printf '%s' "${value:0:$max}"
  else
    printf '%s' "$value"
  fi
}

# --- Attribute Extraction Helpers ---

# Extract key="value" from a marker line via bash regex
_extract_attr() {
  local marker="$1" key="$2"
  if [[ "$marker" =~ [[:space:]]${key}=\"([^\"]*) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf ''
  fi
}

# --- Main Parser ---

# FLAW-003 fix: collect findings as newline-delimited JSON, combine once at end (O(n) vs O(n²))
findings_ndjson=""
in_finding=0
current_marker=""
current_body=""
current_id=""
current_file=""
current_line=""
current_severity=""
current_confidence=""
current_confidence_score=""
current_title=""
current_ash=""
current_format=""

_flush_finding() {
  # Only flush if we have a valid id
  if [[ -z "$current_id" ]]; then
    current_marker=""
    current_body=""
    current_id=""
    current_file=""
    current_line=""
    current_severity=""
    current_confidence=""
    current_confidence_score=""
    current_title=""
    current_ash=""
    current_format=""
    in_finding=0
    return
  fi

  # SEC-004: Validate lengths
  current_id=$(_validate_length "$current_id" "id" 32)
  current_file=$(_validate_length "$current_file" "file" 500)
  current_line=$(_validate_length "$current_line" "line" 10)
  current_severity=$(_validate_length "$current_severity" "severity" 8)

  # Extract title from body (first non-empty line, strip markdown formatting)
  if [[ -z "$current_title" ]]; then
    # Use || true to protect grep from failing under set -e when no match
    local safe_id
    safe_id=$(printf '%s' "$current_id" | sed -E 's/[][()+*?.\\^${}|]/\\&/g')
    current_title=$(printf '%s' "$current_body" | grep -E -m 1 '\S' | sed -E 's/^[#* -]+//' | sed -E 's/\*\*//g' | sed -E 's/^\[[ xX]*\][[:space:]]*//' | sed -E "s/^\[${safe_id}\][: ]*//" | head -c 500 || true)
  fi

  # Extract ash name from body ("Ash:" or "**Ash**:" line)
  if [[ -z "$current_ash" ]]; then
    current_ash=$(printf '%s' "$current_body" | grep -E -i 'Ash.*:' | head -1 | sed -E 's/.*[Aa]sh[*]*:\s*//' | sed -E 's/\*//g' | sed -E 's/^[[:space:]]*//' | sed -E 's/[[:space:]]*$//' | head -c 200 || true)
  fi

  # Build JSON object using jq for safe escaping
  local finding
  finding=$(jq -n \
    --arg id "$current_id" \
    --arg file "$current_file" \
    --arg line "$current_line" \
    --arg severity "$current_severity" \
    --arg confidence "$current_confidence" \
    --arg confidence_score "$current_confidence_score" \
    --arg title "$current_title" \
    --arg body "$current_body" \
    --arg ash "$current_ash" \
    '{
      id: $id,
      file: $file,
      line: (if $line == "" then null else ($line | tonumber? // null) end),
      severity: $severity,
      confidence: $confidence,
      confidence_score: (if $confidence_score == "" then null else ($confidence_score | tonumber? // null) end),
      title: $title,
      body: $body,
      ash: $ash
    }')

  # FLAW-003 fix: append to newline-delimited buffer instead of O(n²) jq re-parse
  if [[ -n "$findings_ndjson" ]]; then
    findings_ndjson="${findings_ndjson}
${finding}"
  else
    findings_ndjson="$finding"
  fi

  # Reset state
  current_marker=""
  current_body=""
  current_id=""
  current_file=""
  current_line=""
  current_severity=""
  current_confidence=""
  current_confidence_score=""
  current_title=""
  current_ash=""
  current_format=""
  in_finding=0
}

_parse_format_a_or_d() {
  local marker="$1"
  current_id=$(_extract_attr "$marker" "id")
  current_file=$(_extract_attr "$marker" "file")
  current_line=$(_extract_attr "$marker" "line")
  current_severity=$(_extract_attr "$marker" "severity")
  # Handle both "severity" and "priority" attribute names
  if [[ -z "$current_severity" ]]; then
    current_severity=$(_extract_attr "$marker" "priority")
  fi
  current_confidence=$(_extract_attr "$marker" "confidence")
  current_confidence_score=$(_extract_attr "$marker" "confidence_score")
}

_parse_format_b() {
  local marker="$1"
  # Format B: <!-- RUNE:FINDING xsec-001 P1 -->
  # Two positional tokens after RUNE:FINDING
  local tokens
  tokens=$(printf '%s' "$marker" | sed -E 's/.*RUNE:FINDING[[:space:]]+//' | sed -E 's/[[:space:]]*-->.*//')
  current_id=$(printf '%s' "$tokens" | awk '{print $1}')
  current_severity=$(printf '%s' "$tokens" | awk '{print $2}')
  if [[ -z "$current_severity" ]]; then
    echo "WARNING: Format B marker missing severity for id=$current_id — defaulting to P3" >&2
    current_severity="P3"
  fi
}

# Regex patterns for bash [[ =~ ]] matching
# Note: bash =~ does not support \s — use [[:space:]] instead
re_format_ad='<!--[[:space:]]*RUNE:FINDING[[:space:]]+.*='
re_format_b='<!--[[:space:]]*RUNE:FINDING[[:space:]]+[^=]+-->'
re_close_a='<!--[[:space:]]*/RUNE:FINDING'
re_close_d='<!--[[:space:]]*RUNE:FINDING:END[[:space:]]*-->'
re_attr_prefix='(prefix|blocking)='
re_hr='^[[:space:]]*(---|___|\*\*\*)[[:space:]]*$'
re_heading='^#{1,3}[[:space:]]+'

# Read TOME line by line
while IFS= read -r line || [[ -n "$line" ]]; do

  # --- Detect RUNE:FINDING open markers ---

  # Format A/D open: <!-- RUNE:FINDING ... id="..." ... -->
  if [[ "$line" =~ $re_format_ad ]]; then
    # Flush any previous finding
    if [[ $in_finding -eq 1 ]]; then
      _flush_finding
    fi

    in_finding=1
    current_marker="$line"
    _parse_format_a_or_d "$line"

    # Check if it looks like Format D (presence of prefix= or blocking= attributes)
    if [[ "$line" =~ $re_attr_prefix ]]; then
      current_format="D"
    else
      current_format="A"
    fi
    continue
  fi

  # Format B open: <!-- RUNE:FINDING token1 token2 --> (no = sign)
  if [[ "$line" =~ $re_format_b ]]; then
    # Flush any previous finding
    if [[ $in_finding -eq 1 ]]; then
      _flush_finding
    fi

    in_finding=1
    current_marker="$line"
    current_format="B"
    _parse_format_b "$line"
    continue
  fi

  # --- Detect close markers ---

  # Format A close: <!-- /RUNE:FINDING id="..." -->
  if [[ "$line" =~ $re_close_a ]]; then
    if [[ $in_finding -eq 1 ]]; then
      _flush_finding
    fi
    continue
  fi

  # Format D close: <!-- RUNE:FINDING:END -->
  if [[ "$line" =~ $re_close_d ]]; then
    if [[ $in_finding -eq 1 ]]; then
      _flush_finding
    fi
    continue
  fi

  # --- Format B delimiter detection (no explicit closer) ---
  if [[ $in_finding -eq 1 ]] && [[ "$current_format" == "B" ]]; then
    # HR delimiter: --- or ***
    if [[ "$line" =~ $re_hr ]]; then
      _flush_finding
      continue
    fi
    # Heading delimiter: ## or higher
    if [[ "$line" =~ $re_heading ]]; then
      _flush_finding
      continue
    fi
  fi

  # --- Accumulate body ---

  if [[ $in_finding -eq 1 ]]; then
    if [[ -n "$current_body" ]]; then
      current_body="${current_body}
${line}"
    else
      current_body="$line"
    fi
  fi

done < "$tome_path"

# Flush last finding (EOF delimiter for Format B)
if [[ $in_finding -eq 1 ]]; then
  _flush_finding
fi

# Output findings JSON
# FLAW-003 fix: combine all findings into JSON array in a single jq pass
if [[ -n "$findings_ndjson" ]]; then
  printf '%s\n' "$findings_ndjson" | jq -s '.'
else
  echo "[]"
fi
