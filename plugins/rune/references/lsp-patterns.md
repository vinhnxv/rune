# LSP Code Intelligence Patterns

Shared reference for review and investigation agents that benefit from semantic code analysis.

## Availability Check

LSP is available when the user has a code intelligence plugin installed (e.g., pyright-lsp, typescript-lsp, rust-analyzer-lsp). If an LSP call fails with "no language server" or similar error, fall back to Grep immediately.

## Operations Reference

### findReferences — Find all usages of a symbol

Use INSTEAD OF: Grep for symbol name across codebase.

```
LSP({ operation: "findReferences", filePath: "...", line: N, character: N })
```

Returns: List of `{file, line, character}` for every actual reference. Eliminates false positives from comments, strings, and unrelated contexts.

### goToDefinition — Navigate to where a symbol is defined

Use INSTEAD OF: Grep for `class X` or `def X` or `function X`.

```
LSP({ operation: "goToDefinition", filePath: "...", line: N, character: N })
```

Returns: Definition location `{file, line, character}`. Resolves through re-exports and barrel files automatically.

### hover — Get type information and documentation

Use INSTEAD OF: Grep for type annotations or docstrings.

```
LSP({ operation: "hover", filePath: "...", line: N, character: N })
```

Returns: Type info, docstring, and signature. Reveals inferred types even without explicit annotations.

### documentSymbol — List all symbols in a file

Use INSTEAD OF: Grep for `def |class |function ` patterns in a file.

```
LSP({ operation: "documentSymbol", filePath: "..." })
```

Returns: Structured list of functions, classes, and variables with their types and ranges.

### incomingCalls — Find all callers of a function

Use INSTEAD OF: Grep for function name to count callers.

```
LSP({ operation: "incomingCalls", filePath: "...", line: N, character: N })
```

Returns: Call hierarchy of all functions that call this one.

## Fallback Protocol

1. Attempt the LSP operation
2. If LSP returns results → use them (higher confidence: +20% over Grep-based findings)
3. If LSP fails (no language server, timeout, unsupported operation) → fall back to Grep
4. Note the source in findings: `**Source: LSP**` or `**Source: Grep**` for transparency

## When to Use LSP vs Grep

| Task | Prefer LSP | Prefer Grep |
|------|-----------|-------------|
| Find all usages of a symbol | `findReferences` | — |
| Find where a symbol is defined | `goToDefinition` | — |
| Get type information | `hover` | — |
| List file symbols | `documentSymbol` | — |
| Search text in comments/strings | — | Grep (LSP ignores non-code) |
| Search config/YAML/JSON files | — | Grep (LSP doesn't index configs) |
| Search across all file types | — | Grep (LSP is language-specific) |
| Pattern matching (regex) | — | Grep |
