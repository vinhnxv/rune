# Dedup Runes — Deduplication Hierarchy

> Rules for deduplicating findings when multiple Ash flag the same code.

## Deduplication Rules

When the Runebinder aggregates findings into TOME.md, it must deduplicate overlapping findings.

### Same File + Same Line Range (5-line window)

If two Ash flag the same file within a 5-line range:

| Ash A | Ash B | Action |
|-------------|-------------|--------|
| Ward Sentinel (P1) | Forge Warden (P2) | Keep Ward Sentinel's (security wins) |
| Forge Warden (P1) | Pattern Weaver (P1) | Keep both (different perspectives) |
| Pattern Weaver (P2) | Glyph Scribe (P2) | Merge if same issue, keep both if different |
| Any (P1) | Any (P3) | Keep only P1 |

### Confidence Handling During Dedup

When a finding is deduplicated (losing Ash suppressed by winning Ash):
- The **winning Ash's confidence value** (PROVEN/LIKELY/UNCERTAIN) is kept in the TOME finding
- The **losing Ash's confidence** is included in the `also_flagged_by` annotation for transparency:
  `(also flagged by: Forge Warden [UNCERTAIN])`
- **Confidence does NOT influence dedup priority** — the role-based hierarchy (SEC > BACK > VEIL > ...) is the sole determinant of which finding survives

This design preserves auditability: readers can see that a lower-priority Ash flagged the same issue with a different confidence level, without allowing confidence to override the structural dedup logic.

### Priority Hierarchy

**Default (built-in only):**

```
Ward Sentinel > Forge Warden > Veil Piercer > Knowledge Keeper > Pattern Weaver > Glyph Scribe > Aesthetic Quality Reviewer > Design Implementation Reviewer > Codex Oracle > Shard Reviewers > Cross-Shard Sentinel
SEC > BACK > VEIL > DOUBT > FLOW > SH{X} > DOC > QUAL > FRONT > DES > AESTH > UXH > UXF > UXI > UXC > CDX > XSH
```

> **Sharding dedup note (v1.98.0+):** `SH{X}-` prefixes (`SHA-`, `SHB-`, `SHC-`, `SHD-`, `SHE-`)
> represent Shard Reviewers A-E. They slot above DOC/QUAL/FRONT/CDX but below SEC/BACK/VEIL/DOUBT/FLOW.
> `XSH-` (Cross-Shard Sentinel) is always lowest priority — yields to all per-shard findings.
> Sharding and specialist Ash are mutually exclusive by design, so SH{X} vs SEC/BACK collisions
> cannot occur in practice. If a shard contains security-critical files, the shard reviewer
> (not Ward Sentinel) reviews them — its SH{X} findings position in the hierarchy accordingly.

When the same issue is found by multiple Ash:
1. Keep the finding from the highest-priority Ash
2. Note in TOME.md which other Ash also flagged it
3. Use the highest severity (P1 > P2 > P3)

### Extended Hierarchy (with Custom Ashes)

When custom Ash are configured in `talisman.yml`, the dedup hierarchy is extended via `settings.dedup_hierarchy`. Custom prefixes are slotted into the hierarchy at the position specified by the user.

**Example extended hierarchy:**
```
SEC > COMP > BACK > RAIL > PERF > DOC > QUAL > FRONT > CDX
```

**Rules:**
- If `settings.dedup_hierarchy` is defined in config, use it as-is (user controls the order)
- If NOT defined, append custom prefixes AFTER built-in hierarchy (lowest priority):
  ```
  SEC > BACK > VEIL > DOUBT > FLOW > SH{X} > DOC > QUAL > FRONT > DES > AESTH > UXH > UXF > UXI > UXC > CDX > XSH > {custom_1} > {custom_2} > ...
  ```
- **External model prefix ordering (v1.57.0+):** CLI-backed Ash prefixes (from `ashes.custom[]` entries with `cli:` field) are positioned BELOW `CDX` in the default hierarchy. Built-in prefixes (`SEC`, `BACK`, `DOC`, `QUAL`, `FRONT`, `CDX`) MUST always precede external model prefixes. This enforcement applies ONLY to CLI-backed external model prefixes — agent-backed custom Ashes can be placed anywhere in a user-defined hierarchy.
  ```
  Default with external models:
  SEC > BACK > VEIL > DOUBT > FLOW > SH{X} > DOC > QUAL > FRONT > DES > AESTH > UXH > UXF > UXI > UXC > CDX > XSH > {cli_ext_1} > {cli_ext_2} > {agent_custom_1} > ...
  ```
- Every active Ash's prefix MUST appear in the hierarchy. Missing prefixes → warn and append at end
- Prefix format: 2-5 uppercase alphanumeric characters (A-Z, 0-9)
- Reserved built-in prefixes: `SEC`, `BACK`, `VEIL`, `DOUBT`, `FLOW`, `QUAL`, `FRONT`, `DES`, `AESTH`, `DOC`, `CDX`, `UXH`, `UXF`, `UXI`, `UXC`, `PY`, `TSR`, `RST`, `PHP`, `FAPI`, `DJG`, `LARV`, `SQLA`, `TDD`, `DDD`, `DI`, `SHA`, `SHB`, `SHC`, `SHD`, `SHE`, `XSH` — cannot be used by custom Ash
- Reserved meta-prefix: `CUSTOM` — cannot be used as a custom Ash finding prefix. This prefix is reserved to distinguish `source="custom"` findings in dedup logic (see below).
- **`source="custom"` attribute**: Findings emitted by custom-criteria Ashes (i.e., those injected via `customPromptBlock`) carry a `source="custom"` attribute in their RUNE:FINDING markers. The Runebinder uses this attribute to annotate deduplicated findings so reviewers know the finding originated from a user-defined inspection criterion rather than a built-in Ash perspective. Custom-criteria findings use standard finding prefixes (e.g., `SEC-001`, `BACK-001`) — the `source="custom"` attribute is the sole differentiator, NOT a separate prefix namespace.
- Reserved standalone prefixes: `DATA`, `GATE`, `ASYNC`, `DRIFT`, `DEPLOY`, `PARITY`, `SENIOR`, `PAT`, `SIMP`, `TYPE` — used by standalone review/utility agents, mapped to embedded prefixes when inside Ash
- Reserved deep-audit prefixes (active only when `/rune:audit --deep`): `DEBT`, `INTG`, `BIZL`, `EDGE`, `CORR`, `FAIL`, `DSEC`, `DSGN`, `RSRC`, `OBSV`, `MTNB`
- **Note:** `CDX-DRIFT` is an internal Phase 5.6 finding ID used by the Codex gap analysis — it is NOT a custom Ash prefix

### Deep / Cross-Wave Extended Hierarchy

When `depth=deep` is active (via `--deep` flag or audit), the dedup hierarchy extends to include deep investigation prefixes. Waves execute sequentially; dedup runs at two levels:

1. **Intra-wave dedup** — within each wave's Runebinder pass (standard rules)
2. **Cross-wave dedup** — when merging TOME from all waves into final TOME.md

**Standard hierarchy (Wave 1 only)**: `SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > DES > AESTH > CDX`
**Deep hierarchy (full, all waves)**: `SEC > BACK > CORR > FAIL > DSEC > DEBT > INTG > BIZL > EDGE > VEIL > DOUBT > FLOW > DSGN > RSRC > DOC > OBSV > MTNB > QUAL > FRONT > DES > AESTH > CDX`

**Which hierarchy is used where:**
- **Wave 1 Runebinder** (TOME-w1.md): Standard hierarchy
- **Wave 2 Runebinder** (TOME-w2.md): Deep sub-hierarchies (see below)
- **Wave 3 Runebinder** (TOME-w3.md, if not merged into Wave 2): Dimension sub-hierarchy
- **Merge Runebinder** (final TOME.md): Full extended hierarchy with cross-wave dedup

**Merge hierarchy (cross-wave dedup):** `SEC > CORR > FAIL > DSEC > BACK > DSGN > RSRC > VEIL > DOUBT > FLOW > OBSV > MTNB > DOC > QUAL > FRONT > DES > AESTH > CDX`

**Per-wave sub-hierarchies:**
- Wave 2 (deep investigation): `DEBT > INTG > BIZL > EDGE`
- Wave 3 (deep dimension): `CORR > FAIL > DSEC > DSGN > RSRC > OBSV > MTNB`
- Combined deep hierarchy: `CORR > FAIL > DSEC > DEBT > INTG > BIZL > EDGE > DSGN > RSRC > OBSV > MTNB`

**Cross-wave dedup rules:**
- Same file:line, same issue → Later wave finding SUPERSEDES earlier wave (deeper analysis wins)
- Same file, different line → Both kept (different concerns)
- Same concern, different files → Both kept (cross-file pattern)
- Later wave finding contradicts earlier wave → Flag with CONFLICT marker for human review
- DOUBT- prefix findings are exempt from cross-wave dedup (meta-findings preserved across all waves)

### Finding ID Prefixes

Each Ash uses a unique prefix for finding IDs:

| Ash | Prefix | Example | Type |
|-----------|--------|---------|------|
| Ward Sentinel | `SEC-` | `SEC-001` | Built-in |
| Forge Warden | `BACK-` | `BACK-001` | Built-in |
| Veil Piercer | `VEIL-` | `VEIL-001` | Built-in |
| Pattern Weaver | `QUAL-` | `QUAL-001` | Built-in |
| Glyph Scribe | `FRONT-` | `FRONT-001` | Built-in |
| Aesthetic Quality Reviewer | `AESTH-` | `AESTH-001` | Built-in |
| Knowledge Keeper | `DOC-` | `DOC-001` | Built-in |
| Codex Oracle | `CDX-` | `CDX-001` | Built-in |
| Doubt Seer | `DOUBT-` | `DOUBT-001` | Built-in |
| Flow Integrity Tracer | `FLOW-` | `FLOW-001` | Built-in (conditional) |
| rot-seeker | `DEBT-` | `DEBT-001` | Deep-audit |
| strand-tracer | `INTG-` | `INTG-001` | Deep-audit |
| decree-auditor | `BIZL-` | `BIZL-001` | Deep-audit |
| fringe-watcher | `EDGE-` | `EDGE-001` | Deep-audit |
| truth-seeker | `CORR-` | `CORR-001` | Deep-dimension |
| ruin-watcher | `FAIL-` | `FAIL-001` | Deep-dimension |
| breach-hunter | `DSEC-` | `DSEC-001` | Deep-dimension |
| order-auditor | `DSGN-` | `DSGN-001` | Deep-dimension |
| ember-seer | `RSRC-` | `RSRC-001` | Deep-dimension |
| signal-watcher | `OBSV-` | `OBSV-001` | Deep-dimension |
| decay-tracer | `MTNB-` | `MTNB-001` | Deep-dimension |
| Shard Reviewer A | `SHA-` | `SHA-001` | Inscription Sharding (v1.98.0+) |
| Shard Reviewer B | `SHB-` | `SHB-001` | Inscription Sharding (v1.98.0+) |
| Shard Reviewer C | `SHC-` | `SHC-001` | Inscription Sharding (v1.98.0+) |
| Shard Reviewer D | `SHD-` | `SHD-001` | Inscription Sharding (v1.98.0+) |
| Shard Reviewer E | `SHE-` | `SHE-001` | Inscription Sharding (v1.98.0+) |
| Cross-Shard Sentinel | `XSH-` | `XSH-001` | Inscription Sharding cross-file analysis |
| UX Heuristic Reviewer | `UXH-` | `UXH-001` | UX verification (conditional) |
| UX Flow Validator | `UXF-` | `UXF-001` | UX verification (conditional) |
| UX Interaction Auditor | `UXI-` | `UXI-001` | UX verification (conditional) |
| UX Cognitive Walker | `UXC-` | `UXC-001` | UX verification (conditional) |
| *(custom)* | *from config* | e.g., `DOM-001` | Custom |

**Standalone Agent Prefixes** (used when agents run independently, mapped to embedded prefix when inside Ash):

| Agent (standalone) | Standalone Prefix | Embedded As | Notes |
|--------------------|-------------------|-------------|-------|
| forge-keeper | `DATA-` | `BACK-` | Data integrity and migration safety |
| forge-keeper (gatekeeper) | `GATE-` | `BACK-` | Migration gatekeeper verdicts (requires_human_review) |
| tide-watcher | `ASYNC-` | `QUAL-` | Async/concurrency patterns |
| schema-drift-detector | `DRIFT-` | `BACK-` | Schema drift between migrations and models |
| deployment-verifier | `DEPLOY-` | *(informational)* | Deployment artifact generation (utility, not review) |
| agent-parity-reviewer | `PARITY-` | `QUAL-` | Agent-native parity checking |
| senior-engineer-reviewer | `SENIOR-` | `QUAL-` | Persona-based senior engineer review |

Custom Ashes define their prefix in `talisman.yml` → `ashes.custom[].finding_prefix`. Must be 2-5 uppercase chars and unique across all Ashes.

### Veil Piercer vs. Other Ashes

Veil Piercer findings may CONTRADICT findings from other Ashes. This is intentional.

| Scenario | Resolution |
|----------|------------|
| Forge Warden: PASS on architecture, Veil Piercer: wrong architecture | Keep BOTH — Tarnished decides |
| Pattern Weaver: P2 YAGNI, Veil Piercer: P1 solving wrong problem | Veil Piercer wins (higher priority + higher severity) |
| Ward Sentinel: SEC finding, Veil Piercer: security model is wrong | Keep BOTH — different scopes |

Veil Piercer participates in the dedup hierarchy at position `SEC > BACK > VEIL > ...` for ordering and priority purposes. However, cross-Ash dedup (same-file, same-line suppression) rarely triggers for VEIL- findings because truth-telling operates at a different level of abstraction than technical review. A VEIL- finding about "this feature solves the wrong problem" and a BACK- finding about "this function has a null bug" on the same file are different perspectives, not duplicates. In the rare case of a genuine same-line overlap (e.g., both say "this code is unreachable"), VEIL wins over DOC/QUAL/FRONT/CDX but yields to SEC and BACK per the hierarchy.

### Interaction Type (Q/N) Dedup Rules

Findings may carry an `interaction` attribute (`"question"` or `"nit"`) orthogonal to severity. When deduplicating findings that include interaction types:

| Finding A (existing) | Finding B (new, same location) | Action |
|---------------------|-------------------------------|--------|
| Assertion (P1/P2/P3, no interaction) | Q (interaction="question") | Drop Q — assertion supersedes question |
| Assertion (P1/P2/P3, no interaction) | N (interaction="nit") | Drop N — assertion supersedes nit |
| Q (interaction="question") | N (interaction="nit") | Keep both — different interaction types |
| N (interaction="nit") | Q (interaction="question") | Keep both — different interaction types |
| Q (interaction="question") | Q (interaction="question") | Merge into single Q (same location) |
| N (interaction="nit") | N (interaction="nit") | Merge if same issue, keep both if different |
| Q (interaction="question") | Assertion (P1/P2/P3) | Replace Q with assertion — assertion wins |
| N (interaction="nit") | Assertion (P1/P2/P3) | Replace N with assertion — assertion wins |

**Key principle:** Assertions always supersede questions and nits at the same location. Q and N coexist because they represent different interaction modes (clarification vs. cosmetic).

### DOUBT- Prefix Exemption

`DOUBT-` prefix is non-deduplicable. During dedup resolution, skip any finding with `DOUBT-` prefix -- these are meta-findings about other agents' claims and must never be merged or suppressed. DOUBT remains in the hierarchy for ordering purposes (e.g., `SEC > BACK > VEIL > DOUBT > FLOW > DOC > ...`) but is exempt from same-file/same-line dedup suppression. When a DOUBT- finding overlaps with another finding at the same location, both are kept.

### Dedup Algorithm

```
// Pass 0: Exempt DOUBT- prefixed findings from dedup (meta-findings, non-deduplicable)
// DOUBT- findings are added directly to the output without dedup checks.

// Pass 1: Insert all assertion findings (no interaction attribute)
for each finding in all_findings where finding.interaction is undefined:
  key = (file, line_range_bucket(line, 5))

  if key already in seen:
    existing = seen[key]
    if finding.severity > existing.severity:
      replace existing with finding
    elif finding.ash_priority > existing.ash_priority:
      replace existing with finding
    else:
      add finding.ash to existing.also_flagged_by
  else:
    seen[key] = finding

// Pass 2: Insert Q/N findings only if no assertion exists at same location
for each finding in all_findings where finding.interaction is "question" or "nit":
  key = (file, line_range_bucket(line, 5))
  interaction_key = (file, line_range_bucket(line, 5), finding.interaction)

  if key in seen AND seen[key].interaction is undefined:
    // Assertion exists → drop Q/N, record in dedup log
    add finding.ash to seen[key].also_flagged_by
  elif interaction_key in seen_interactions:
    // Same interaction type at same location → merge
    add finding.ash to seen_interactions[interaction_key].also_flagged_by
  else:
    seen_interactions[interaction_key] = finding
```

### TOME.md Format After Dedup

```markdown
# TOME — Review Summary

**PR:** #{pr-number}
**Date:** {timestamp}
**Ash:** {list of active Ash}

## P1 (Critical) — {count}

- [ ] **[SEC-001] SQL Injection in user query** in `api/users.py:42`
  - **Ash:** Ward Sentinel (also flagged by: Forge Warden)
  - **Rune Trace:**
    ```python
    # Lines 40-45 of api/users.py
    query = f"SELECT * FROM users WHERE id = {user_id}"
    ```
  - **Issue:** Unparameterized query allows SQL injection
  - **Fix:** Use parameterized query: `query = "SELECT * FROM users WHERE id = %s"`

## P2 (High) — {count}

[findings...]

## P3 (Medium) — {count}

[findings...]

## Questions — {count}

[Q findings with interaction="question" — clarification needed from author]

## Nits — {count}

[N findings with interaction="nit" — cosmetic, author's discretion]

## Incomplete Deliverables

| Ash | Status | Impact |
|-----------|--------|--------|
| {name} | {timeout/crash/partial} | {uncovered scope} |

## Statistics

- Total findings: {count}
- Deduplicated: {removed_count} (from {original_count})
- P1: {count}, P2: {count}, P3: {count}, Q: {count}, N: {count}
- Evidence coverage: {percentage}%
- Ash completed: {count}/{total}

## Assumption Summary

| Ash | PROVEN | LIKELY | UNCERTAIN | UNTAGGED | Key Assumptions |
|-----|--------|--------|-----------|----------|-----------------|
| {Ash name} | {count} | {count} | {count} | {count} | {top assumption or "None"} |

### High-Risk Assumptions (from UNCERTAIN findings)

{List assumptions from UNCERTAIN findings only}
{If none: "No high-risk assumptions — no UNCERTAIN findings reported."}

### Potential Assumption Conflicts (requires human review)

{Up to 5 cross-Ash assumption conflicts at same file+5-line window}
{If none: "No cross-Ash assumption conflicts detected."}
```
