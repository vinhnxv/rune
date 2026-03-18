# Prompt Audit — Custom Prompt File Format

Reference for `--prompt-file` and talisman `audit.default_prompt_file`. Describes allowed file format, sanitization rules, examples, and edge cases.

## Overview

Custom prompts let users inject project-specific instructions into every Ash reviewer prompt during an audit session. Common use cases:

- Compliance checklists (HIPAA, PCI-DSS, OWASP Top 10)
- Team coding conventions (naming standards, architecture rules)
- Domain-specific review focus (e.g., "flag all direct SQL string concatenation")
- Language-specific idiom enforcement

**Injection point**: The sanitized custom prompt block is appended to each Ash prompt **immediately before the RE-ANCHOR Truthbinding boundary**. Ashes still apply their standard review logic — the custom block is additive, not a replacement.

**CONCERN-1 compliance**: Ashes use standard finding prefixes (SEC, BACK, PERF, etc.) with `source="custom"` attribute in finding metadata. Custom prompts do NOT create new CUSTOM- compound prefixes.

---

## File Format

Prompt files are plain Markdown or plain text. YAML frontmatter is stripped automatically (see sanitization rules).

### Minimal example

```markdown
Focus especially on SQL injection vectors in all database query functions.
Flag any string interpolation directly inside SQL statements as P1.
```

### HIPAA compliance example

```markdown
# HIPAA Review Focus

For all files in this audit, additionally check:
- PHI (Protected Health Information) is never logged at debug level
- All PHI fields are encrypted at rest (look for unencrypted string fields on patient models)
- Audit logs exist for all PHI access events
- No PHI appears in URL parameters or query strings
```

### OWASP Top 10 example

```markdown
Apply OWASP Top 10 (2021) coverage for each file:
- A01: Broken Access Control — check for missing authorization checks on data mutations
- A02: Cryptographic Failures — flag MD5/SHA1 for passwords or sensitive data
- A03: Injection — flag any dynamic query construction, shell exec with user input
- A04: Insecure Design — note missing rate limiting on auth endpoints
- A05: Security Misconfiguration — flag debug=True in production configs
```

### Team conventions example

```markdown
Enforce our team conventions:
- All public functions MUST have a docstring (flag as P2 if missing)
- No function body may exceed 50 lines (flag as P3)
- Repository layer functions MUST NOT import from the controller layer
- Use `logger.warning()` not `print()` for diagnostic output (flag as P3)
```

---

## Sanitization Rules

`sanitizePromptContent()` applies the following transformations in order:

| Step | What is stripped | Reason |
|------|-----------------|--------|
| YAML frontmatter | `--- ... ---` block at file start | Format normalization |
| HTML/XML comments | `<!-- ... -->` (including multiline) | Hidden instruction injection vector |
| Null bytes | `\x00` | Binary content / injection |
| Zero-width chars | U+200B, U+200C, U+200D, U+FEFF | Invisible text injection |
| BiDi overrides | U+202A–U+202E, U+2066–U+2069 | Directional override attacks |
| ANSI escapes | `\x1B[...]` sequences | Terminal injection |
| Rune nonce markers | `<!-- RUNE:SEAL:xxx -->`, `<!-- RUNE:* -->` | Prevent seal forgery |
| ANCHOR patterns | Lines containing `ANCHOR` or `RE-ANCHOR` | Prevent Truthbinding boundary injection |
| Reserved headers | H1–H6 starting with `SEAL`, `TOME`, `Truthbinding`, `RE-ANCHOR`, `ANCHOR`, `Inscription Contract` | Prevent structural spoofing |

**Post-sanitization guard**: If the result is whitespace-only, the audit aborts with an error rather than silently injecting an empty block.

---

## Validation Rules

Before content is loaded, the file path is validated:

| Check | Rule |
|-------|------|
| Path traversal | `..` in path → rejected |
| Unsafe characters | Only `[a-zA-Z0-9._/-]` allowed (after stripping `~/` prefix) |
| Absolute paths | Must be within project root OR `~/.claude/` |
| Symlink escape | `realpath -m` + project root prefix check |
| Not a directory | `Read()` returns null for directories → clear error |
| Not binary | Sanitization step catches null bytes; binary content produces near-empty result → whitespace guard catches it |

---

## Edge Cases

| Situation | Behavior |
|-----------|----------|
| File not found | Abort: `--prompt-file not found: "<path>"` |
| File is a directory | `Read()` returns null → abort with "not found" message |
| File contains only YAML frontmatter | Sanitization strips it → whitespace-only guard fires → abort |
| File is binary | Null byte stripping + whitespace guard → abort |
| File is 0 bytes | Whitespace guard fires → abort |
| Both `--prompt` and `--prompt-file` | `--prompt-file` wins (file takes precedence) |
| `--prompt-file` path is `~/.claude/my-prompt.md` | Allowed — within `~/.claude/` (global config) |
| Absolute path escaping both project root and `~/.claude/` | Abort with path rejection message |
| Very large file (>100KB) | No hard limit — sanitize and use; downstream Ash context budget is the real constraint |
| Prompt tries to add `<seal>` tag | RUNE nonce marker stripping removes `<!-- RUNE:SEAL:xxx -->` patterns; plain `<seal>`/`</seal>` tags are replaced with escaped equivalents (`&lt;seal&gt;`) to prevent completion detection bypass |
| Prompt includes RE-ANCHOR text | Lines containing `RE-ANCHOR` are stripped entirely to prevent Truthbinding boundary spoofing |
| Prompt contains `── END CUSTOM CRITERIA ──` | Marker string stripped to prevent premature termination of custom criteria boundary in `buildAshPrompt()` |

---

## Talisman Configuration

Configure a project-wide default prompt file in `.rune/talisman.yml`:

```yaml
audit:
  default_prompt_file: ".rune/prompts/audit-focus.md"
```

The flag `--prompt-file` overrides this talisman default. When both `--prompt` and `--prompt-file` are provided, `--prompt-file` takes precedence.

**Validation**: Talisman-sourced `default_prompt_file` paths undergo the same validation chain as the `--prompt-file` CLI flag: `..` rejection → `SAFE_PROMPT_PATH` regex → must be within project root or `~/.claude/` → `realpath -m` symlink escape check. The `resolveCustomPromptBlock(flags, talisman)` helper applies this validation to both sources via a shared `validatePromptFilePath()` step.

---

## Finding Attribution

When a custom prompt causes an Ash to report a finding, the finding metadata includes `source="custom"` to distinguish it from built-in review criteria. Standard prefixes (SEC, PERF, BACK, etc.) are still used — no CUSTOM- compound prefix is created.

Example finding line in TOME.md:
```
- **SEC-001** [source=custom] Missing authorization check on `/admin/delete` endpoint
```

---

## References

- [audit SKILL.md](../SKILL.md) — Phase 0.5B: Custom Prompt Resolution pseudocode
- [orchestration-phases.md](../../roundtable-circle/references/orchestration-phases.md) — Parameter #21 `customPromptBlock` threading
- [talisman.example.yml](../../../talisman.example.yml) — `audit.default_prompt_file` schema
