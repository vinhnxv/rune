# Inscription Schema

> JSON schema for `inscription.json` — the output contract for Rune workflows.

## Complete Schema

```json
{
  "workflow": "string — rune-review | rune-audit | rune-audit-deep | rune-plan | rune-work | rune-mend | rune-forge | rune-inspect",
  "timestamp": "ISO-8601 datetime",
  "pr_number": "integer (optional — for reviews)",
  "branch": "string (optional)",
  "output_dir": "string — path to output directory",

  "teammates": [
    {
      "name": "string — ash role name",
      "output_file": "string — filename relative to output_dir",
      "required_sections": ["array of section header strings"],
      "role": "string — human-readable role description",
      "perspectives": ["array of embedded review perspectives"],
      "file_scope": ["array of file patterns assigned to this teammate"]
    }
  ],

  "deep_context": {
    "standard_tome": "string — path to pass-1 TOME (required for rune-audit-deep)",
    "coverage_map": "string — path to coverage-map.json (required for rune-audit-deep)"
  },

  "aggregator": {
    "name": "runebinder",
    "output_file": "TOME.md"
  },

  "verification": {
    "enabled": "boolean",
    "layer_0_circuit": {
      "failure_threshold": "integer — max inline check failures before pause",
      "recovery_seconds": "integer — wait before retry"
    },
    "layer_2_circuit": {
      "failure_threshold": "integer — max hallucinated findings before flagging",
      "recovery_seconds": "integer — wait before retry"
    },
    "max_reverify_agents": "integer — max re-verify agents to summon",
    "research_verification": {
      "enabled": "boolean — true when research verification ran (Phase 1C.5 during /rune:devise)",
      "findings_count": {
        "trusted": "integer — findings with score >= trust_threshold",
        "caution": "integer — findings with minor issues (version drift, single-source)",
        "untrusted": "integer — findings below trust_threshold (excluded from synthesis)",
        "flagged": "integer — findings with security concerns (prompt injection, suspicious URLs)"
      },
      "aggregate_score": "number — 0.0-1.0 weighted average trust score across all findings",
      "version_mismatches": ["array of { library, research_version, project_version, severity } objects — detected version drift between research claims and project dependencies"]
    }
  },

  "detected_stack": {
    "primary_language": "string — python | typescript | rust | php | null",
    "frameworks": ["array of detected framework strings"],
    "libraries": ["array of detected library strings"],
    "databases": ["array of detected database strings"],
    "tooling": ["array of detected tooling strings"],
    "patterns": ["array of detected pattern strings — tdd, ddd, di"],
    "design_tools": ["array of available design MCP tool strings — e.g. figma_fetch_design, figma_inspect_node, figma_list_components"],
    "confidence": "number — 0.0-1.0 detection confidence"
  },

  "context_manifest": {
    "domains": ["array of domain strings — backend, frontend, infra, docs, config"],
    "skills_to_load": ["array of skill paths to load for this context"],
    "agents_to_summon": ["array of stack-specialist agent names"],
    "reference_docs": ["array of reference doc paths relevant to detected stack"]
  },

  "design_context": {
    "enabled": "boolean — true when design_sync.enabled AND frontend files AND VSM available",
    "vsm_dir": "string | null — path to VSM directory (e.g., 'tmp/arc/{id}/vsm/')",
    "dcd_dir": "string | null — path to DCD directory (e.g., 'tmp/arc/{id}/design/')",
    "figma_urls": [
      {
        "url": "string — full Figma URL",
        "role": "string — primary | variant | breakpoint | unknown",
        "screen": "string | null — human-readable screen label (e.g., 'Desktop', 'Mobile')"
      }
    ],
    "figma_url": "string | null — DEPRECATED: first entry of figma_urls[].url. Kept for backward compat. New consumers MUST read figma_urls[] instead.",
    "fidelity_threshold": "number — minimum fidelity score (default: 0.8, from talisman.design_sync.fidelity_threshold)",
    "components": ["array of component name strings extracted from VSM"],
    "token_system": "string | null — design token system identifier (e.g., 'figma-tokens', 'style-dictionary')"
  },

  "specialist_ashes": ["array of stack-specialist Ash names selected by Phase 1A"],

  "dir_scope": {
    "include": ["array of directory strings — restrict audit to these paths (e.g., ['src/', 'lib/']). null when no --dirs specified (= full repo)."],
    "exclude": ["array of directory strings — suppress these paths even if matched by include (e.g., ['vendor/']). May be non-empty even when include is null (talisman excludes)."]
  },
  // Note: dir_scope is null (not the object) when neither --dirs nor talisman.audit.dirs is set.
  // Only consumed by rune-audit and rune-audit-deep.

  "custom_prompt": {
    "active": "boolean — whether prompt injection is enabled (default: false)",
    "prompt_file": "string — path to Markdown prompt file relative to repo root (e.g., '.claude/audit-prompt.md'). Only consumed by rune-audit and rune-audit-deep."
  },

  "diff_scope": {
    "enabled": "boolean — whether diff-scope tagging is active (default: true)",
    "base": "string — base branch for diff (e.g., 'main')",
    "expansion": "integer — ±N lines expansion zone (default: 8)",
    "ranges": {
      "file/path.ts": "[[startLine, endLine], ...] — expanded line ranges. null endLine = to end of file (new/renamed files)"
    },
    "head_sha": "string — HEAD commit SHA at diff generation time (for stale detection)",
    "version": "integer — schema version (currently: 1)"
  },

  "todos": {
    "enabled": "boolean — whether per-worker todo files are active (default: true, v1.43.0+)",
    "dir": "string — relative path to todos directory within output_dir (default: 'todos/'). Must match /^[a-zA-Z0-9_-]+\\/$/ — no path traversal",
    "schema": "string — 'per-task' (one file per task, always active)",
    "fields": ["array of required frontmatter fields. per-worker v1: worker, role, status, plan_path. per-task v2: schema_version, status, priority, issue_id, source, source_ref, tags, dependencies, files, assigned_to, work_session, created, updated"],
    "filename_template": "string — per-task only: '{issue_id}-{status}-{priority}-{slug}.md'. Status encodes INITIAL status only (Option A: no renames). Frontmatter status is authoritative.",
    "summary_file": "string — filename for orchestrator-generated summary (default: '_summary.md')"
  },

  "context_intelligence": {
    "available": "boolean — whether PR context was gathered (Phase 0.3)",
    "pr": {
      "number": "integer",
      "title": "string (max 200 chars)",
      "url": "string",
      "body": "string (sanitized, max configurable via max_pr_body_chars)",
      "labels": ["array of label strings (max 10, each max 50 chars)"],
      "additions": "integer",
      "deletions": "integer",
      "changed_files_count": "integer",
      "linked_issues": ["array of linked issue objects"]
    },
    "scope_warning": {
      "total_changes": "integer",
      "threshold": "integer",
      "severity": "string — medium | high",
      "message": "string"
    },
    "intent_summary": {
      "pr_type": "string — bugfix | feature | refactor | docs | test | chore | unknown",
      "context_quality": "string — good | fair | poor",
      "context_warnings": ["array of warning strings"],
      "has_linked_issue": "boolean",
      "has_why_explanation": "boolean"
    },
    "linked_issue": {
      "number": "integer",
      "title": "string (max 200 chars)",
      "body": "string (sanitized, max 2000 chars)",
      "labels": ["array of label strings"]
    }
  },

  "linter_context": {
    "detected": [
      {
        "name": "string — linter name (e.g., eslint, prettier, ruff)",
        "config": "string — config file path",
        "categories": ["array of category strings"]
      }
    ],
    "rule_categories": ["array of all detected categories"],
    "suppress_categories": ["array of categories Ashes should skip"]
  },

  "taxonomy_version": "integer — 1 (P1/P2/P3 only) or 2 (P1/P2/P3 + Q/N interaction types)",

  "context_engineering": {
    "read_ordering": "source_first | reference_first",
    "instruction_anchoring": "boolean — ANCHOR + RE-ANCHOR in prompts",
    "reanchor_interval": "integer — re-anchor every N files",
    "context_budget": {
      "backend": "integer — max files for backend reviewer",
      "security": "integer — max files for security reviewer",
      "frontend": "integer — max files for frontend reviewer",
      "docs": "integer — max files for docs reviewer"
    }
  },

  "sharding": {
    "enabled": "boolean — true when diff exceeds shard_threshold and scope=diff",
    "strategy": "string — always 'domain-affinity' (v1.98.0)",
    "shard_count": "integer — number of shard reviewers spawned",
    "shard_threshold": "integer — file count threshold used (from talisman or default 15)",
    "shard_size": "integer — max files per shard (from talisman or default 12)",
    "shards": [
      {
        "shard_id": "string — single uppercase letter A-E",
        "files": ["array of file paths assigned to this shard"],
        "file_count": "integer",
        "primary_domain": "string — dominant domain (security_critical|backend|frontend|infra|config|docs|tests|mixed)",
        "domains": ["array of domain strings present in this shard"],
        "model": "string — sonnet|haiku",
        "reviewer_name": "string — e.g. 'shard-reviewer-a'",
        "output_file": "string — e.g. 'shard-a-findings.md'",
        "summary_file": "string — e.g. 'shard-a-summary.json'"
      }
    ],
    "cross_shard": {
      "enabled": "boolean — whether Cross-Shard Sentinel is active",
      "reviewer_name": "string — 'cross-shard-sentinel'",
      "output_file": "string — 'cross-shard-findings.md'",
      "input_files": ["array of shard summary JSON paths"]
    }
  }
}
```

## Example: Review Inscription

```json
{
  "workflow": "rune-review",
  "timestamp": "2026-02-11T10:30:00Z",
  "pr_number": 142,
  "branch": "feat/user-authentication",
  "output_dir": "tmp/reviews/142/",
  "teammates": [
    {
      "name": "forge-warden",
      "output_file": "forge-warden.md",
      "required_sections": ["P1 (Critical)", "P2 (High)", "P3 (Medium)", "Reviewer Assumptions", "Self-Review Log"],
      "role": "Backend code review",
      "perspectives": ["architecture", "performance", "logic-bugs", "duplication"],
      "file_scope": ["backend/**/*.py"]
    },
    {
      "name": "ward-sentinel",
      "output_file": "ward-sentinel.md",
      "required_sections": ["P1 (Critical)", "P2 (High)", "P3 (Medium)", "Reviewer Assumptions", "Self-Review Log"],
      "role": "Security review",
      "perspectives": ["vulnerabilities", "auth", "injection", "owasp"],
      "file_scope": ["**/*"]
    },
    {
      "name": "pattern-weaver",
      "output_file": "pattern-weaver.md",
      "required_sections": ["P1 (Critical)", "P2 (High)", "P3 (Medium)", "Reviewer Assumptions", "Self-Review Log"],
      "role": "Quality and patterns review",
      "perspectives": ["simplicity", "tdd", "dead-code", "patterns"],
      "file_scope": ["**/*"]
    },
    {
      "name": "doubt-seer",
      "output_file": "doubt-seer.md",
      "required_sections": ["Doubt Seer Challenges", "Challenge Summary"],
      "role": "Cross-agent claim verification",
      "perspectives": ["claim-validity", "evidence-quality"]
    }
  ],
  "aggregator": {
    "name": "runebinder",
    "output_file": "TOME.md"
  },
  "verification": {
    "enabled": true,
    "layer_0_circuit": { "failure_threshold": 3, "recovery_seconds": 60 },
    "layer_2_circuit": { "failure_threshold": 2, "recovery_seconds": 120 },
    "max_reverify_agents": 2
  },
  "context_engineering": {
    "read_ordering": "source_first",
    "instruction_anchoring": true,
    "reanchor_interval": 5,
    "context_budget": {
      "backend": 30,
      "security": 20,
      "frontend": 25,
      "docs": 25
    }
  }
}
```

> **Note:** All built-in Ashes use `required_sections: ["P1 (Critical)", "P2 (High)", "P3 (Medium)", "Reviewer Assumptions", "Self-Review Log"]` unless otherwise specified (e.g., doubt-seer uses `["Doubt Seer Challenges", "Challenge Summary"]`, runebinder uses its own format).

## Required Fields

| Field | Required | Default |
|-------|----------|---------|
| `workflow` | Yes | — |
| `timestamp` | Yes | — |
| `output_dir` | Yes | — |
| `team_name` | Yes | — |
| `teammates` | Yes | — |
| `teammates[].name` | Yes | — |
| `teammates[].output_file` | Yes | — |
| `teammates[].required_sections` | Yes | — |
| `dir_scope` | No | `null` (full repo). Array of directory glob strings. Only consumed by audit workflows. (v1.90.0+) |
| `custom_prompt` | No | `{ "active": false }`. Only consumed by audit workflows. (v1.90.0+) |
| `diff_scope` | No | `{ "enabled": false }` |
| `context_intelligence` | No | `{ "available": false }` (v1.60.0+) |
| `linter_context` | No | `{ "detected": [], "rule_categories": [], "suppress_categories": [] }` (v1.60.0+) |
| `taxonomy_version` | No | `1` (v1.60.0+: set to `2` when Q/N interaction types are active) |
| `todos` | No | `{ "enabled": true, "dir": "todos/", "schema": "per-task", "filename_template": "{id}-{status}-{priority}-{slug}.md", "summary_file": "_summary.md" }` (v1.43.0+, rune-work only). Always uses `per-task` schema. |
| `aggregator` | No | No aggregation |
| `verification` | No | `{ "enabled": false }` |
| `verification.research_verification` | No | `{ "enabled": false }` — populated by Phase 1C.5 during `/rune:devise` when external research runs. Contains trust verdicts and version mismatch data. (v1.123.0+) |
| `context_engineering` | No | Defaults applied |
| `sharding` | No | `{ "enabled": false }` — when absent or `enabled: false`, `teammates[]` works exactly as before (fully backward-compatible). The `sharding` field is purely additive. (v1.98.0+, rune-review `scope=diff` only) |
| `design_context.figma_urls` | No | `[]` — array of `{ url, role, screen }` objects. Replaces deprecated `figma_url` scalar. Populated by arc Phase 3 (design extraction) when `design_sync.enabled: true`. (v1.201.0+) |
| `design_context.figma_url` | No | `null` — DEPRECATED scalar. Set to `figma_urls[0].url` for backward compat. New consumers MUST read `figma_urls[]`. |
