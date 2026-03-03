# /rune:brainstorm — Creation Log

## Problem Statement

Rune users who want to explore an idea must run `/rune:devise` — a 7-phase pipeline
that spawns agent teams, runs research, forge, and review. This is overkill for casual
ideation. Users cannot brainstorm casually without triggering heavy infrastructure,
cannot save brainstorm output persistently (devise writes to `tmp/`), cannot stop after
brainstorming without being forced into planning, and cannot resume brainstorming later
or hand off to `/rune:devise` when ready.

The brainstorm logic was embedded in `devise/references/brainstorm-phase.md` (474 lines)
as Phase 0 of the devise pipeline, making it inaccessible as a standalone workflow.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Keep brainstorm inline in devise Phase 0 | Users must commit to full 7-phase pipeline to brainstorm. No standalone access. No persistent output. |
| Duplicate brainstorm logic into a new skill | Code duplication between devise Phase 0 and standalone skill. Two sources of truth for brainstorm behavior. |
| Simple conversational skill (no agents) | Misses the multi-perspective value of advisors. Solo mode covers this case, but Roundtable mode is the differentiator. |
| Full research agents in brainstorm | Over-engineered — deep research belongs in devise Phase 1. Advisors do lightweight 30-second codebase scans instead. |
| Advisors communicating directly with each other | Creates unmoderated cross-talk. All communication through Lead ensures coherent discussion flow and prevents advisor echo chambers. |

## Key Design Decisions

- **Extract-don't-duplicate**: Brainstorm skill becomes the single source of truth.
  Devise Phase 0 delegates to the brainstorm protocol. This mirrors how `/rune:elicit`
  is both standalone AND used internally by devise/forge/review.

- **Three modes (Solo/Roundtable/Deep)**: Provides a spectrum from zero-overhead
  conversation to full multi-agent analysis. Users choose their depth at startup,
  or use `--quick`/`--deep` flag shortcuts.

- **Roundtable Advisors as Agent Team teammates**: Advisors run in their own context
  windows (subagent isolation) with tool access for lightweight codebase research.
  This grounds their questions in codebase reality without needing separate research
  agents. 100-word limit per response prevents context bloat.

- **Lead as moderator (not relay)**: All advisor communication flows through the Lead,
  who curates inputs into a coherent discussion. Advisors never communicate with each
  other. This prevents unmoderated cross-talk and ensures the user gets a synthesized
  perspective, not raw forwarding.

- **Persistent output to docs/brainstorms/**: Unlike devise's `tmp/` output, brainstorm
  documents persist as project knowledge. This enables auto-detection by future devise
  runs and serves as institutional memory.

- **7-dimension quality gate**: Scoring model determines handoff readiness. Score >= 0.70
  triggers devise suggestion. Score < 0.70 suggests another round. Prevents premature
  handoff to planning with underspecified requirements.

- **disable-model-invocation: true**: Prevents Claude from auto-loading this skill
  when it sees brainstorm-related keywords. The skill creates agent teams and interactive
  sessions — user must always consent via explicit invocation.

- **Workspace at tmp/brainstorm-{timestamp}/**: Preserves full context chain (advisor
  observations, codebase scans, round history, elicitation outputs) for devise
  consumption. Cleaned up by `/rune:rest` like other tmp/ artifacts.

## Iteration History

| Date | Version | Change | Trigger |
|------|---------|--------|---------|
| 2026-03-03 | v1.0 | Initial creation — 3 modes, Roundtable Advisors, 7-dimension quality gate, workspace structure | Standalone brainstorm feature (v1.130.0) |
