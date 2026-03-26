# Rune User Guide (English): `/rune:appraise`, `/rune:audit`, and `/rune:mend`

This guide covers Rune's quality assurance workflows:
- `/rune:appraise` for multi-agent code review of changed files.
- `/rune:audit` for full codebase audit.
- `/rune:mend` for parallel resolution of review findings.

Related guides:
- [Arc and batch guide (arc/arc-batch)](rune-arc-and-batch-guide.en.md)
- [Planning guide (devise/forge/plan-review/inspect)](rune-planning-and-plan-quality-guide.en.md)
- [Work execution guide (strive/goldmask)](rune-work-execution-guide.en.md)

---

## 1. Quick Command Selection

| Situation | Recommended command |
|---|---|
| Review changed files on your branch | `/rune:appraise` |
| Review only staged files | `/rune:appraise --partial` |
| Deep multi-wave review (3 waves, up to 18 Ashes) | `/rune:appraise --deep` |
| Full codebase audit | `/rune:audit` |
| Audit specific directories only | `/rune:audit --dirs src,lib` |
| Security-focused audit | `/rune:audit --focus security` |
| Stateful incremental audit across sessions | `/rune:audit --incremental` |
| Custom compliance check | `/rune:audit --prompt-file .claude/prompts/hipaa.md` |
| Fix findings from a review | `/rune:mend tmp/reviews/{id}/TOME.md` |
| Review and auto-fix in one command | `/rune:appraise --auto-mend` |
| Preview scope without running agents | `/rune:appraise --dry-run` or `/rune:audit --dry-run` |

---

## 2. Prerequisites

### Required
- Claude Code with Rune plugin installed.
- Agent Teams enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).

### Recommended
- Git repository with changes on a feature branch (for appraise).
- Sufficient token budget — each workflow spawns multiple agents with dedicated context windows.

### Optional
- `codex` CLI for cross-model verification (Codex Oracle joins as additional reviewer).
- `.rune/talisman.yml` for tuning timeouts, Ash selection, and custom reviewers.

---

## 3. `/rune:appraise` — Code Review

### 3.1 Basic usage

```bash
/rune:appraise
```

Rune detects changed files on your branch, selects appropriate reviewers, and produces a TOME with prioritized findings.

### 3.2 Flags

| Flag | Effect |
|---|---|
| `--deep` | 3-wave deep review: core Ashes → investigation Ashes → dimension Ashes (up to 18 total) |
| `--partial` | Review staged files only (`git diff --cached`) instead of full branch diff |
| `--dry-run` | Show scope and Ash selection without summoning agents |
| `--max-agents <N>` | Cap total Ashes (1-8) |
| `--cycles <N>` | Run N independent review passes with merged TOME (1-5) |
| `--no-chunk` | Force single-pass review (disable chunking for large diffs) |
| `--chunk-size <N>` | Override auto-chunk threshold (default: 20 files) |
| `--no-converge` | Single pass per chunk (disable convergence loop) |
| `--no-lore` | Skip Lore Layer risk scoring (git history analysis) |
| `--scope-file <path>` | Override changed files with JSON `{focus_files: [...]}` |
| `--auto-mend` | Auto-invoke `/rune:mend` if P1/P2 findings exist |

### 3.3 What happens during review

1. **Scope detection** — collects changed files, classifies by extension.
2. **Lore Layer** — risk-scores files by git history (churn, ownership concentration).
3. **Rune Gaze** — selects matching Ashes based on file types.
4. **Team creation** — spawns all Ashes in parallel, each with its own dedicated context window.
5. **Parallel review** — Ashes write findings to files (not to chat).
6. **Pre-Aggregation (Phase 5.0)** — condenses individual agent outputs before feeding to Runebinder, reducing context saturation (v1.116.0+).
7. **Aggregation** — Runebinder deduplicates, prioritizes, produces TOME.
8. **Citation Verification (Phase 5.2)** — deterministic grep-based verification of TOME `file:line` citations (v1.117.0+). Catches phantom citations (non-existent files, out-of-range lines). Tags unreliable findings as `UNVERIFIED` or `SUSPECT`.
9. **Truthsight** — validates P1 evidence against source code.
10. **Cleanup** — shutdown teammates, persist echoes, present TOME.

### 3.4 Understanding the TOME

The TOME contains structured findings with priority levels:

| Priority | Meaning | Action |
|---|---|---|
| **P1** | Critical — security, data loss, crash | Must fix before merge |
| **P2** | Important — logic bugs, performance issues | Should fix |
| **P3** | Advisory — style, minor improvements | May fix |
| **Q** | Question — needs clarification | Filtered out in mend |
| **N** | Nit — trivial suggestion | Filtered out in mend |

Each finding includes: file path, line range, code evidence (Rune Trace), and fix guidance.

**Citation tags (v1.117.0+):**

| Tag | Meaning | Mend behavior |
|---|---|---|
| *(none)* | Citation verified successfully | Normal fix |
| **SUSPECT** | Citation partially verified (pattern mismatch) | Extra caution applied |
| **UNVERIFIED** | Citation failed verification (file/line not found) | Skipped by mend-fixer |

Output: `tmp/reviews/{id}/TOME.md`

### 3.5 Flag interactions

- `--deep + --partial`: Works but may produce sparse investigation findings. Warning issued.
- `--deep + --cycles N`: Expensive (N x 3 waves). Warning issued.
- `--deep + --max-agents`: Max applies to Wave 1 only. Wave 2/3 agents are not capped.

---

## 4. `/rune:audit` — Codebase Audit

### 4.1 Basic usage

```bash
/rune:audit
```

Scans your entire codebase (not just changed files) with deep analysis by default.

### 4.2 Flags

| Flag | Effect |
|---|---|
| `--focus <area>` | Limit to: `security`, `performance`, `quality`, `frontend`, `docs`, `backend`, `full` |
| `--deep` | Multi-wave deep audit (default for audit) |
| `--standard` | Override deep — single-wave standard audit |
| `--max-agents <N>` | Cap total Ashes (1-8) |
| `--dry-run` | Show scope and exit without running agents |
| `--no-lore` | Skip git history risk scoring |
| `--dirs <path,...>` | Audit only these directories (comma-separated) |
| `--exclude-dirs <path,...>` | Exclude these directories |
| `--prompt <text>` | Inline custom inspection criteria |
| `--prompt-file <path>` | File-based custom criteria (takes precedence over `--prompt`) |
| `--incremental` | Enable stateful 3-tier audit with persistent history |
| `--resume` | Resume interrupted incremental audit |
| `--status` | Show coverage dashboard only (no audit) |
| `--reset` | Clear audit history, start fresh |
| `--tier <tier>` | Limit incremental to: `file`, `workflow`, `api`, `all` |

### 4.3 Directory scoping

Narrow audit scope to specific directories:

```bash
/rune:audit --dirs src,lib                         # Audit only src/ and lib/
/rune:audit --exclude-dirs vendor,dist             # Exclude vendor/ and dist/
/rune:audit --dirs src --exclude-dirs src/generated # Include src/ except generated/
```

Directory scoping applies at the earliest phase — downstream agents only see pre-filtered files.

### 4.4 Custom prompts

Inject domain-specific criteria for reviewers:

```bash
/rune:audit --prompt "Flag all direct SQL string interpolation as P1"
/rune:audit --prompt-file .claude/prompts/hipaa-audit.md
```

Custom findings are tagged `source="custom"` in the TOME.

### 4.5 Incremental audit

For large codebases, stateful audit tracks what has been reviewed across sessions:

```bash
/rune:audit --incremental                # First run: prioritize by risk, audit a batch
/rune:audit --incremental                # Next run: skip already-audited files
/rune:audit --incremental --status       # View coverage dashboard (no agents)
/rune:audit --incremental --resume       # Resume interrupted batch
/rune:audit --incremental --tier file    # File-level audit only
/rune:audit --incremental --reset        # Clear state, start fresh
```

Incremental state is stored in `.rune/audit-state/` and survives across sessions.

### 4.6 Differences from appraise

| Aspect | `/rune:appraise` | `/rune:audit` |
|---|---|---|
| Scope | Changed files only | Entire codebase |
| Requires git | Yes (needs diff) | No (uses file scan) |
| Default depth | Standard | Deep |
| Timeout | 10 minutes | 15 minutes |
| Use case | PR review | Codebase health check |

---

## 5. `/rune:mend` — Fix Findings

### 5.1 Basic usage

```bash
/rune:mend tmp/reviews/{id}/TOME.md
```

Parses findings from a TOME and dispatches parallel fixers to resolve them.

### 5.2 What happens during mend

1. **Parse TOME** — extracts findings, filters out Q/N (nits/questions), deduplicates.
2. **Goldmask discovery** — reads existing risk data (if available) for risk-aware prioritization.
3. **Plan** — groups findings by file, determines fixer count (max 5).
4. **Spawn fixers** — restricted mend-fixer agents (no Bash, no TeamCreate).
5. **Monitor** — polls progress, detects stalled fixers (5-min warn, 10-min auto-release).
6. **Ward check** — runs quality gates once after all fixers complete.
7. **Cross-file mend** — fixes SKIPPED findings with cross-file dependencies (max 5).
8. **Doc-consistency** — fixes drift between source-of-truth files and downstream targets.
9. **Resolution report** — produces `tmp/mend/{id}/resolution-report.md`.

### 5.3 Resolution categories

| Status | Meaning |
|---|---|
| **FIXED** | Finding resolved by fixer |
| **FIXED_CROSS_FILE** | Fixed during cross-file mend pass |
| **FALSE_POSITIVE** | Fixer determined finding is not a real issue |
| **FAILED** | Fix attempted but could not be applied |
| **SKIPPED** | Finding not addressed (low priority or complex) |
| **CONSISTENCY_FIX** | Doc/config drift corrected |

SEC-prefix findings (security) cannot be marked FALSE_POSITIVE by fixers — they require human approval.

### 5.4 Mend flags

| Flag | Effect |
|---|---|
| `tome-path` | Path to TOME (or auto-detect most recent) |
| `--output-dir <path>` | Custom output directory |
| `--timeout <ms>` | Time budget (default: 15 minutes) |

---

## 6. Chaining Workflows

### Review then fix

```bash
/rune:appraise
# Inspect TOME, then fix findings:
/rune:mend tmp/reviews/{id}/TOME.md
```

Or use the streamlined flag:

```bash
/rune:appraise --auto-mend
```

### Audit then fix

```bash
/rune:audit --focus security
/rune:mend tmp/audit/{id}/TOME.md
```

### Cross-model review

For critical changes, get a second opinion from an independent model:

```bash
/rune:codex-review
```

This runs Claude and OpenAI Codex reviewers in parallel, cross-verifies findings between models, and merges consensus issues into a unified TOME. Requires `codex` CLI installed.

### Full cycle in arc

`/rune:arc` runs review → mend → verify-mend automatically as part of its 43-phase pipeline. Use standalone appraise/mend when you want targeted review without the full pipeline.

---

## 7. Use Cases

### 7.1 PR review before merge

```bash
/rune:appraise
```

Standard review of your branch diff. Good for most PRs.

### 7.2 Deep review for risky changes

```bash
/rune:appraise --deep --auto-mend
```

Three-wave review catches subtle issues. Auto-mend saves a manual step.

### 7.3 Security audit before release

```bash
/rune:audit --focus security --dirs src
```

Focused security scan of source code only (excludes tests, docs, config).

### 7.4 Compliance audit with custom rules

```bash
/rune:audit --prompt-file .claude/prompts/hipaa-audit.md --dirs backend
```

Inject domain-specific criteria for regulated environments.

### 7.5 Incremental audit for large codebases

```bash
/rune:audit --incremental          # First batch
/rune:audit --incremental          # Next batch (skips already-covered files)
/rune:audit --incremental --status # Check coverage progress
```

Spread audit work across multiple sessions without re-scanning reviewed files.

---

## 8. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| "Concurrent review running" | Previous review session active | `/rune:cancel-review` then retry |
| No files to review | No changes on branch (or on main) | Ensure you have uncommitted changes on a feature branch |
| Ash times out (>5 min) | Large file set or complex code | Rune proceeds with partial results. Check TOME for coverage gaps |
| TOME has few findings | Scope too narrow or code is clean | Verify with `--dry-run` that expected files are in scope |
| Mend fixer stalled | Complex cross-file dependency | Auto-released at 10 min. Check resolution report for SKIPPED items |
| Ward check fails after mend | Fix introduced a regression | Mend bisects to identify failing fix, marks it NEEDS_REVIEW |
| "No TOME found" on mend | No prior review/audit run | Run `/rune:appraise` or `/rune:audit` first |
| Incremental audit stuck | Lock held by dead session | Lock auto-recovers (PID liveness check). If stuck, `--reset` |
| TOME has many UNVERIFIED findings | Phantom citations in code references | Phase 5.2 caught bad citations. Check if file paths changed since review |
| Pre-aggregation skipped | Single agent or very short output | Phase 5.0 only activates when multiple agents produce substantial output |
| Context saturation during aggregation | Too many Ash outputs for Runebinder | Phase 5.0 pre-aggregation (v1.116.0+) should prevent this; check `pre_aggregate.enabled` |

---

## 9. Compact Command Reference

```bash
# Code review
/rune:appraise                                     # Standard review
/rune:appraise --deep                              # 3-wave deep review
/rune:appraise --partial                           # Staged files only
/rune:appraise --deep --auto-mend                  # Deep review + auto-fix
/rune:appraise --dry-run                           # Preview scope

# Codebase audit
/rune:audit                                        # Full deep audit
/rune:audit --standard                             # Standard depth
/rune:audit --focus security                       # Security-focused
/rune:audit --dirs src --exclude-dirs src/generated # Directory scoped
/rune:audit --prompt "Flag SQL injection as P1"    # Custom criteria
/rune:audit --incremental                          # Stateful audit
/rune:audit --incremental --status                 # Coverage dashboard

# Fix findings
/rune:mend tmp/reviews/{id}/TOME.md                # Fix review findings
/rune:mend tmp/audit/{id}/TOME.md                  # Fix audit findings

# Cross-model review
/rune:codex-review                                 # Claude + Codex in parallel

# Cancel
/rune:cancel-review
/rune:cancel-audit
/rune:cancel-codex-review
```
