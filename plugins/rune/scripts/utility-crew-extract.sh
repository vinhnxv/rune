#!/usr/bin/env bash
# utility-crew-extract.sh — Shell-based artifact digest extraction
# Resolves decree-arbiter P1: Explore subagents cannot Write files.
# Uses grep/awk/jq for mechanical extraction — zero LLM tokens.
#
# Usage: utility-crew-extract.sh <mode> <arc_id> [extra_args]
# Modes: tome-digest, gap-analysis, verdict, plan, work-summary
#
# Each mode reads a specific artifact and writes a JSON digest file.
# Token cost: ZERO (pure shell extraction).
set -euo pipefail

# Sanitize a string for safe JSON interpolation
_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr -d '\n'
}

# Check jq availability (required for JSON array construction)
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not available — utility-crew-extract requires jq" >&2
  exit 1
fi

MODE="${1:?Missing mode (tome-digest|gap-analysis|verdict|plan|work-summary)}"
ARC_ID="${2:?Missing arc ID}"
MEND_ROUND="${3:-0}"

# SEC-003: Validate arc ID
if [[ ! "$ARC_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: Invalid arc ID: $ARC_ID" >&2
  exit 1
fi

ARC_DIR="tmp/arc/${ARC_ID}"

case "$MODE" in
  tome-digest)
    # Determine TOME source (round-aware)
    if [[ "$MEND_ROUND" -gt 0 ]]; then
      TOME_SOURCE="${ARC_DIR}/tome-round-${MEND_ROUND}.md"
      DIGEST_PATH="${ARC_DIR}/tome-digest-round-${MEND_ROUND}.json"
    else
      # Find TOME: try direct path first, then glob for any tome file
      TOME_SOURCE=""
      for candidate in "${ARC_DIR}/tome.md" "${ARC_DIR}/TOME.md"; do
        if [[ -f "$candidate" ]]; then
          TOME_SOURCE="$candidate"
          break
        fi
      done
      # Try review output directories
      if [[ -z "$TOME_SOURCE" ]]; then
        for f in tmp/reviews/*/TOME.md; do
          [[ -f "$f" ]] || continue
          TOME_SOURCE="$f"
          break
        done
      fi
      DIGEST_PATH="${ARC_DIR}/tome-digest.json"
    fi

    if [[ -z "$TOME_SOURCE" ]] || [[ ! -f "$TOME_SOURCE" ]]; then
      echo "{\"error\": \"TOME not found\", \"fallback\": true}" > "$DIGEST_PATH"
      echo "WARN: TOME file not found — wrote fallback digest" >&2
      exit 0
    fi

    # Extract counts using grep
    P1_COUNT=$(grep -c '<!-- RUNE:FINDING.*severity="P1"' "$TOME_SOURCE" 2>/dev/null || echo 0)
    P2_COUNT=$(grep -c '<!-- RUNE:FINDING.*severity="P2"' "$TOME_SOURCE" 2>/dev/null || echo 0)
    P3_COUNT=$(grep -c '<!-- RUNE:FINDING.*severity="P3"' "$TOME_SOURCE" 2>/dev/null || echo 0)
    TOTAL=$(grep -c '<!-- RUNE:FINDING' "$TOME_SOURCE" 2>/dev/null || echo 0)

    # Extract unique file paths from file= attribute
    FILES_JSON=$(grep -oP 'file="[^"]*"' "$TOME_SOURCE" 2>/dev/null | sed 's/file="//;s/"//' | sort -u | jq -R . | jq -s . 2>/dev/null || echo '[]')

    # Extract first 5 P1 finding summaries (text after the marker, first line)
    TOP_P1=$(grep -A1 '<!-- RUNE:FINDING.*severity="P1"' "$TOME_SOURCE" 2>/dev/null | grep -v '^--$' | grep -v '<!-- RUNE:FINDING' | head -5 | sed 's/^[[:space:]]*//' | jq -R . | jq -s . 2>/dev/null || echo '[]')

    # Detect recurring prefixes (id prefixes appearing 2+ times)
    RECURRING=$(grep -oP 'id="([A-Z]+)-' "$TOME_SOURCE" 2>/dev/null | sed 's/id="//;s/-$//' | sort | uniq -c | awk '$1 >= 2 {print $2}' | jq -R . | jq -s . 2>/dev/null || echo '[]')
    RECURRING_COUNT=$(echo "$RECURRING" | jq 'length' 2>/dev/null || echo 0)

    # Calculate needs_elicitation
    NEEDS_ELICIT="false"
    if [[ "$P1_COUNT" -gt 0 ]] || [[ "$TOTAL" -ge 5 ]]; then
      NEEDS_ELICIT="true"
    fi

    cat > "$DIGEST_PATH" <<EOJSON
{
  "schema_version": 1,
  "p1_count": ${P1_COUNT},
  "p2_count": ${P2_COUNT},
  "p3_count": ${P3_COUNT},
  "total_findings": ${TOTAL},
  "recurring_patterns_count": ${RECURRING_COUNT},
  "files_affected": ${FILES_JSON},
  "top_p1_findings": ${TOP_P1},
  "recurring_prefixes": ${RECURRING},
  "needs_elicitation": ${NEEDS_ELICIT},
  "tome_source": "$(_json_escape "$TOME_SOURCE")",
  "mend_round": ${MEND_ROUND}
}
EOJSON
    echo "Digest written: ${DIGEST_PATH}"
    ;;

  gap-analysis)
    INPUT="${ARC_DIR}/gap-analysis.md"
    OUTPUT="${ARC_DIR}/gap-analysis-digest.json"

    if [[ ! -f "$INPUT" ]]; then
      echo "{\"error\": \"gap-analysis.md not found\", \"fallback\": true}" > "$OUTPUT"
      exit 0
    fi

    # Count requirement statuses from table rows
    MISSING_COUNT=$(grep -ciP '\|\s*MISSING\s*\|' "$INPUT" 2>/dev/null || echo 0)
    PARTIAL_COUNT=$(grep -ciP '\|\s*PARTIAL\s*\|' "$INPUT" 2>/dev/null || echo 0)
    ADDRESSED_COUNT=$(grep -ciP '\|\s*ADDRESSED\s*\|' "$INPUT" 2>/dev/null || echo 0)
    COMPLETE_COUNT=$(grep -ciP '\|\s*COMPLETE\s*\|' "$INPUT" 2>/dev/null || echo 0)
    TOTAL=$((MISSING_COUNT + PARTIAL_COUNT + ADDRESSED_COUNT + COMPLETE_COUNT))

    if [[ "$TOTAL" -gt 0 ]]; then
      COMPLETION_PCT=$(( (ADDRESSED_COUNT + COMPLETE_COUNT) * 100 / TOTAL ))
    else
      COMPLETION_PCT=0
    fi

    # Extract MISSING requirement names
    MISSING_REQS=$(grep -iP '\|\s*MISSING\s*\|' "$INPUT" 2>/dev/null | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' | jq -R . | jq -s . 2>/dev/null || echo '[]')

    REVIEW_CTX="Gap Analysis Context: ${MISSING_COUNT} MISSING, ${PARTIAL_COUNT} PARTIAL criteria."

    cat > "$OUTPUT" <<EOJSON
{
  "mode": "gap-analysis",
  "missing_count": ${MISSING_COUNT},
  "partial_count": ${PARTIAL_COUNT},
  "addressed_count": ${ADDRESSED_COUNT},
  "complete_count": ${COMPLETE_COUNT},
  "total_requirements": ${TOTAL},
  "completion_pct": ${COMPLETION_PCT},
  "missing_requirements": ${MISSING_REQS},
  "partial_requirements": [],
  "review_context": "$(_json_escape "$REVIEW_CTX")"
}
EOJSON
    echo "Digest written: ${OUTPUT}"
    ;;

  verdict)
    INPUT="${ARC_DIR}/gap-analysis-verdict.md"
    OUTPUT="${ARC_DIR}/verdict-digest.json"

    if [[ ! -f "$INPUT" ]]; then
      echo "{\"error\": \"verdict not found\", \"fallback\": true}" > "$OUTPUT"
      exit 0
    fi

    # Extract dimension scores from table: | Name | X/10 | or | Name | X.Y |
    DIMENSIONS=$(grep -P '\|\s*\S+.*\|\s*[\d.]+\s*(\/10)?\s*\|' "$INPUT" 2>/dev/null | \
      awk -F'|' '{
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);
        gsub(/\/10/, "", $3);
        if ($3+0 > 0) printf "{\"name\":\"%s\",\"score\":%s}\n", $2, $3
      }' | jq -s . 2>/dev/null || echo '[]')

    LOW_SCORING=$(echo "$DIMENSIONS" | jq '[.[] | select(.score < 7)]' 2>/dev/null || echo '[]')

    FOCUS_AREAS=$(echo "$LOW_SCORING" | jq -r 'if length > 0 then "Focus areas: " + ([.[] | "\(.name) (\(.score)/10)"] | join(", ")) + "." else "" end' 2>/dev/null || echo "")

    cat > "$OUTPUT" <<EOJSON
{
  "mode": "verdict",
  "dimensions": ${DIMENSIONS},
  "low_scoring": ${LOW_SCORING},
  "focus_areas_text": "$(_json_escape "$FOCUS_AREAS")"
}
EOJSON
    echo "Digest written: ${OUTPUT}"
    ;;

  plan)
    INPUT="${ARC_DIR}/enriched-plan.md"
    OUTPUT="${ARC_DIR}/plan-digest.json"

    if [[ ! -f "$INPUT" ]]; then
      echo "{\"error\": \"enriched-plan.md not found\", \"fallback\": true}" > "$OUTPUT"
      exit 0
    fi

    # Extract YAML frontmatter fields
    PLAN_TYPE=$(sed -n '/^---$/,/^---$/{ /^type:/{ s/type:[[:space:]]*//; p; } }' "$INPUT" 2>/dev/null | head -1 || echo "unknown")
    PLAN_NAME=$(sed -n '/^---$/,/^---$/{ /^name:/{ s/name:[[:space:]]*//; p; } }' "$INPUT" 2>/dev/null | head -1 || echo "unknown")
    COMPLEXITY=$(sed -n '/^---$/,/^---$/{ /^complexity:/{ s/complexity:[[:space:]]*//; p; } }' "$INPUT" 2>/dev/null | head -1 || echo "M")

    # Count ## headings
    SECTION_COUNT=$(grep -c '^## ' "$INPUT" 2>/dev/null || echo 0)
    SECTIONS=$(grep '^## ' "$INPUT" 2>/dev/null | sed 's/^## //' | jq -R . | jq -s . 2>/dev/null || echo '[]')

    # Count acceptance criteria
    AC_COUNT=$(grep -c -E '^\s*- \[ \]|^\s*- AC-' "$INPUT" 2>/dev/null || echo 0)
    AC_LIST=$(grep -E '^\s*- \[ \]|^\s*- AC-' "$INPUT" 2>/dev/null | sed 's/^[[:space:]]*- \[ \] //' | head -20 | jq -R . | jq -s . 2>/dev/null || echo '[]')

    # Count tasks (numbered items)
    TASK_COUNT=$(grep -c -E '^\s*[0-9]+\.' "$INPUT" 2>/dev/null || echo 0)

    # Extract file targets
    FILE_TARGETS=$(grep -oE '`[a-zA-Z0-9_./-]+\.(md|sh|ts|tsx|js|jsx|py|rs|go|yml|yaml|json|toml)`' "$INPUT" 2>/dev/null | tr -d '`' | sort -u | jq -R . | jq -s . 2>/dev/null || echo '[]')

    cat > "$OUTPUT" <<EOJSON
{
  "mode": "enriched-plan",
  "frontmatter": {"type": "$(_json_escape "$PLAN_TYPE")", "name": "$(_json_escape "$PLAN_NAME")", "complexity": "$(_json_escape "$COMPLEXITY")"},
  "section_count": ${SECTION_COUNT},
  "sections": ${SECTIONS},
  "acceptance_criteria_count": ${AC_COUNT},
  "acceptance_criteria": ${AC_LIST},
  "task_count": ${TASK_COUNT},
  "file_targets": ${FILE_TARGETS},
  "estimated_size": "$(_json_escape "$COMPLEXITY")"
}
EOJSON
    echo "Digest written: ${OUTPUT}"
    ;;

  work-summary)
    INPUT="${ARC_DIR}/work-summary.md"
    OUTPUT="${ARC_DIR}/work-summary-digest.json"

    if [[ ! -f "$INPUT" ]]; then
      # Try alternative locations
      for candidate in "${ARC_DIR}"/worker-logs/_summary.md; do
        if [[ -f "$candidate" ]]; then
          INPUT="$candidate"
          break
        fi
      done
    fi

    if [[ ! -f "$INPUT" ]]; then
      echo "{\"error\": \"work-summary not found\", \"fallback\": true}" > "$OUTPUT"
      exit 0
    fi

    # Extract committed files
    COMMITTED_FILES=$(grep -E '^\s*-\s+`?[a-zA-Z0-9_./-]+\.(md|sh|ts|tsx|js|jsx|py|rs|go|yml|yaml|json|toml)`?' "$INPUT" 2>/dev/null | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d '`' | jq -R . | jq -s . 2>/dev/null || echo '[]')
    FILE_COUNT=$(echo "$COMMITTED_FILES" | jq 'length' 2>/dev/null || echo 0)

    # Extract task counts (look for X/Y pattern)
    TASKS_LINE=$(grep -oP '\d+/\d+\s*tasks' "$INPUT" 2>/dev/null | head -1 || echo "")
    if [[ -n "$TASKS_LINE" ]]; then
      TASKS_COMPLETED=$(echo "$TASKS_LINE" | grep -oP '^\d+')
      TASKS_TOTAL=$(echo "$TASKS_LINE" | grep -oP '/\K\d+')
    else
      TASKS_COMPLETED=0
      TASKS_TOTAL=0
    fi

    # Extract warnings
    WARNINGS=$(grep -iP '(warn|issue|error|failed)' "$INPUT" 2>/dev/null | head -5 | sed 's/^[[:space:]]*//' | jq -R . | jq -s . 2>/dev/null || echo '[]')

    cat > "$OUTPUT" <<EOJSON
{
  "mode": "work-summary",
  "committed_files": ${COMMITTED_FILES},
  "committed_file_count": ${FILE_COUNT},
  "tasks_completed": ${TASKS_COMPLETED:-0},
  "tasks_total": ${TASKS_TOTAL:-0},
  "warnings": ${WARNINGS}
}
EOJSON
    echo "Digest written: ${OUTPUT}"
    ;;

  *)
    echo "ERROR: Unknown mode: $MODE" >&2
    echo "Valid modes: tome-digest, gap-analysis, verdict, plan, work-summary" >&2
    exit 1
    ;;
esac
