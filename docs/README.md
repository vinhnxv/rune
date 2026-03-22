# Rune Documentation Hub

Use this page to quickly find the right Rune docs.

## What Is This?

Rune is a multi-agent engineering orchestration plugin for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). It coordinates 142 specialized AI agents across planning, implementation, code review, testing, and deployment — each with its own dedicated context window.

## Why This Exists

A single AI agent loses effectiveness as tasks grow in scope. Rune splits work across specialized agents that run in parallel: security reviewers catch vulnerabilities while performance reviewers find N+1 queries while consistency reviewers flag naming drift — all simultaneously. The result is higher quality output at the cost of more tokens.

## Compatibility

- **Claude Code 2.1.81+** with Agent Teams enabled
- macOS 12+ or Linux (Ubuntu 20.04+)
- Python 3.11+ (for MCP servers)
- **Claude Max ($200/mo) recommended** for full Arc pipeline

## Start Here

- New user (English): [Getting started](guides/rune-getting-started.en.md)
- Người dùng mới (Tiếng Việt): [Bắt đầu nhanh](guides/rune-getting-started.vi.md)
- Need one-page command picks (English): [Quick Cheat Sheet](guides/rune-quick-cheat-sheet.en.md)
- Need common Q&A (English): [Rune FAQ](guides/rune-faq.en.md)
- Need term explanations (English): [Rune Glossary](guides/rune-glossary.en.md)
- Cần lệnh nhanh trong 1 trang (Tiếng Việt): [Quick Cheat Sheet](guides/rune-quick-cheat-sheet.vi.md)
- Câu hỏi thường gặp (Tiếng Việt): [FAQ Rune](guides/rune-faq.vi.md)
- Cần giải thích thuật ngữ (Tiếng Việt): [Thuật ngữ Rune](guides/rune-glossary.vi.md)
- Prefer natural language routing: [`/rune:tarnished`](../README.md#rune:tarnished--the-unified-entry-point)

## Guide Map

| Goal | Commands | English | Tiếng Việt |
|------|----------|---------|------------|
| See the full command catalog | all user-facing slash commands | [Command reference](guides/rune-command-reference.en.md) | [Bảng tra lệnh](guides/rune-command-reference.vi.md) |
| Plan and validate work | `/rune:devise`, `/rune:forge`, `/rune:plan-review`, `/rune:inspect` | [Planning guide](guides/rune-planning-and-plan-quality-guide.en.md) | [Hướng dẫn planning](guides/rune-planning-and-plan-quality-guide.vi.md) |
| Implement from plans | `/rune:strive`, `/rune:goldmask` | [Work execution guide](guides/rune-work-execution-guide.en.md) | [Hướng dẫn thực thi](guides/rune-work-execution-guide.vi.md) |
| Review and fix findings | `/rune:appraise`, `/rune:audit`, `/rune:mend` | [Review and audit guide](guides/rune-code-review-and-audit-guide.en.md) | [Hướng dẫn review và audit](guides/rune-code-review-and-audit-guide.vi.md) |
| End-to-end orchestration | `/rune:arc`, `/rune:arc-batch` | [Arc and batch guide](guides/rune-arc-and-batch-guide.en.md) | [Hướng dẫn arc và arc-batch](guides/rune-arc-and-batch-guide.vi.md) |
| Use copy-paste command recipes | quick command picks and common workflows | [Quick Cheat Sheet](guides/rune-quick-cheat-sheet.en.md) | [Quick Cheat Sheet](guides/rune-quick-cheat-sheet.vi.md) |
| Resolve common questions fast | setup, token cost, resume, cancel, paths | [Rune FAQ](guides/rune-faq.en.md) | [FAQ Rune](guides/rune-faq.vi.md) |
| Explain Rune terms quickly | glossary of key workflow terms | [Rune Glossary](guides/rune-glossary.en.md) | [Thuật ngữ Rune](guides/rune-glossary.vi.md) |
| Advanced workflows | `/rune:arc-hierarchy`, `/rune:arc-issues`, `/rune:echoes`, `/rune:learn`, `/rune:test-browser`, `/rune:debug` | [Advanced workflows](guides/rune-advanced-workflows-guide.en.md) | [Workflow nâng cao](guides/rune-advanced-workflows-guide.vi.md) |
| Configure Rune behavior | `/rune:talisman` | [Talisman deep dive](guides/rune-talisman-deep-dive-guide.en.md) | [Talisman chuyên sâu](guides/rune-talisman-deep-dive-guide.vi.md) |
| Extend Rune with custom agents | custom Ashes, Forge Gaze, CLI-backed reviewers | [Custom agents and extensions](guides/rune-custom-agents-and-extensions-guide.en.md) | [Custom agent và mở rộng](guides/rune-custom-agents-and-extensions-guide.vi.md) |
| Troubleshoot failures and optimize cost | diagnostics, cleanup, tuning | [Troubleshooting and optimization](guides/rune-troubleshooting-and-optimization-guide.en.md) | [Xử lý sự cố và tối ưu](guides/rune-troubleshooting-and-optimization-guide.vi.md) |
| Use GLM-5 via claude-code-router | Alibaba Cloud Coding Plan setup | [GLM-5 setup guide](glm-5-setup.md) | [Hướng dẫn GLM-5](glm-5-setup.md#tiếng-việt) |

## Core References

- [State machine reference](state-machine.md) for all workflow phase diagrams
- [Remembrance solutions (English)](solutions/README.md) for curated problem/solution writeups
- [Remembrance solutions (Tiếng Việt)](solutions/README.vi.md) cho tài liệu giải pháp dễ đọc
- [Plugin component reference](../plugins/rune/README.md) for full agents, skills, commands, and hooks

## Repo Knowledge Artifacts

- `docs/plans/`: archived planning documents
- `docs/analysis/`: research and gap-analysis docs
- `docs/brainstorms/`: brainstorming outputs and exploration notes

These folders are mostly for maintainers and contributors, while `docs/guides/` is the main user path.
