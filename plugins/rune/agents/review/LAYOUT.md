# agents/review/ Layout

This directory contains **registered review agents** — agents that appear in
Claude Code's agent registry and participate in Forge Gaze topic matching.

**Stack-specific specialist reviewers** (python-reviewer, typescript-reviewer, etc.)
are NOT here. They live at:
`skills/roundtable-circle/references/specialist-prompts/`

Specialists are prompt templates loaded on-demand by `buildAshPrompt()`, not
registered agents. New stack-specific reviewers should be added to
`specialist-prompts/`, not this directory.
