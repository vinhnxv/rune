# Contributing to Rune

Thank you for your interest in contributing to the Rune plugin! This guide will help you get started.

## Quick Links

- [GitHub Discussions](https://github.com/vinhnxv/rune/discussions) — questions, ideas, show & tell
- [Issue Tracker](https://github.com/vinhnxv/rune/issues) — bug reports, feature requests
- [Getting Started Guide](docs/guides/rune-getting-started.en.md)
- [FAQ](docs/guides/rune-faq.en.md)

## Ways to Contribute

1. **Report bugs** — use the [bug report template](https://github.com/vinhnxv/rune/issues/new?template=bug_report.md)
2. **Suggest features** — use the [feature request template](https://github.com/vinhnxv/rune/issues/new?template=feature_request.md)
3. **Improve documentation** — PRs welcome for typos, clarity, or new guides
4. **Share your experience** — post in [Discussions](https://github.com/vinhnxv/rune/discussions)

## Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/vinhnxv/rune.git
   cd rune-plugin
   ```

2. Run Claude Code with the plugin:
   ```bash
   claude --plugin-dir ./
   ```

3. Validate plugin wiring before committing:
   ```bash
   bash plugins/rune/scripts/validate-plugin-wiring.sh
   ```

## Plugin Architecture

```
plugins/rune/
├── skills/           # Slash command skills (e.g., /rune:plan, /rune:arc)
├── agents/           # Agent definitions (.md files with YAML frontmatter)
├── hooks/            # Event hook scripts (PreToolUse, PostToolUse, etc.)
├── scripts/          # Shared utility scripts
├── prompts/          # Shared prompt templates
├── .claude-plugin/   # Plugin manifest (plugin.json)
└── CLAUDE.md         # Plugin-level instructions
```

Key directories outside the plugin:
- `docs/guides/` — user-facing documentation
- `.rune/` — project-level configuration and echoes (memory)
- `tmp/` — workflow artifacts (gitignored)

## Commit Convention

We use [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Use |
|--------|-----|
| `feat:` | New feature or skill |
| `fix:` | Bug fix |
| `docs:` | Documentation changes |
| `chore:` | Maintenance (version bumps, CI, etc.) |
| `refactor:` | Code restructuring (no behavior change) |

### Pre-Commit Checklist

Before submitting a PR, ensure:

1. Plugin version is in sync across all manifest files (see `CLAUDE.md` for the full list)
2. `bash plugins/rune/scripts/validate-plugin-wiring.sh` passes
3. No plan files (`plans/*.md`) are included in the commit
4. New skills have `description` in frontmatter
5. New agents have `name` and `description` in frontmatter
6. Hook scripts are executable (`chmod +x`)

## Pull Request Process

1. Fork the repository and create a feature branch
2. Make your changes following the conventions above
3. Run the validation script
4. Submit a PR with a clear description of the changes
5. Wait for review — maintainers will respond within a few days

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## Questions?

If you're unsure about anything, open a [Discussion](https://github.com/vinhnxv/rune/discussions) — we're happy to help!
