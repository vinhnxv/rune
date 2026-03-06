# Phase 0.3: Context Intelligence + Phase 0.4: Linter Detection

## Phase 0.3: Context Intelligence

Gather PR metadata and linked issue context for downstream Ash consumption. Runs AFTER Phase 0, BEFORE Phase 0.5.

**Skip conditions**: `talisman.review.context_intelligence.enabled === false`, no `gh` CLI, `--partial` mode, non-git repo.

See [context-intelligence.md](../../roundtable-circle/references/context-intelligence.md) for the full contract, schema, and security model.

```javascript
// sanitizeUntrustedText — canonical sanitization for user-authored content
// Used by: Phase 0.3 (PR body, issue body), plan.md (plan content)
// Security: CDX-001 (prompt injection), CVE-2021-42574 (Trojan Source)
function sanitizeUntrustedText(text, maxChars) {
  return (text || '')
    .replace(/<!--[\s\S]*?-->/g, '')              // Strip HTML comments
    .replace(/```[\s\S]*?```/g, '[code-block]')    // Neutralize code fences
    .replace(/!\[.*?\]\(.*?\)/g, '')               // Strip image/link injection
    .replace(/^#{1,6}\s+/gm, '')                   // Strip heading overrides
    .replace(/[\u200B-\u200F\uFEFF\uFE00-\uFE0F]/g, '')  // Strip zero-width chars + variation selectors
    .replace(/\uDB40[\uDC00-\uDC7F]/g, '')         // Strip tag block characters (U+E0000-E007F)
    .replace(/[\u202A-\u202E\u2066-\u2069]/g, '')  // Strip Unicode directional overrides (CVE-2021-42574)
    .replace(/&[a-zA-Z0-9#]+;/g, '')               // Strip HTML entities
    .slice(0, maxChars)
}
```

Context intelligence result (`contextIntel`) is injected into inscription.json in Phase 2, making PR metadata available to all Ashes without increasing per-Ash prompt size.

Each ash-prompt template receives a conditional `## PR Context` section when `context_intelligence.available === true`, injected during Phase 3 prompt construction.

**Note**: During arc `code_review` (Phase 6), no PR exists yet if Phase 9 SHIP hasn't run. Context Intelligence correctly reports `available: false` — this is expected.

## Phase 0.4: Linter Detection

Discover project linters from config files and provide linter awareness context to Ashes. Prevents Ashes from flagging issues that project linters already handle (formatting, import order, unused vars).

**Position**: After Phase 0.3, before Phase 0.5.
**Skip conditions**: `talisman.review.linter_awareness.enabled === false`.

Detects: eslint, prettier, biome, typescript (JS/TS), ruff, black, flake8, mypy, pyright, isort (Python), rubocop, standard (Ruby), golangci-lint (Go), clippy, rustfmt (Rust), editorconfig (general).

```javascript
// linterContext is injected into inscription.json in Phase 2 (linter_context field)
// Ashes receive suppression list in their prompts — DO NOT flag in suppressed categories
// SEC-* and VEIL-* findings are NEVER suppressed by linter awareness
```

Talisman config:
```yaml
review:
  linter_awareness:
    enabled: true
    always_review:          # Categories to review even if linter covers them
      - type-checking
```
