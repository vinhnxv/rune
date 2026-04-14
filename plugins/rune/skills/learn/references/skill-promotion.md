# skill-promotion Detector — Algorithm, Draft Generator, and Dedup

**Owner detector**: `--detector skill-promotion|all`
**Gated by**: `echoes.skill_promotion.enabled` in talisman (default: true)
**Target**: `.claude/skills/<slug>/SKILL.md` (project) or `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/<slug>/SKILL.md` (user)

## Overview

Promotes **procedural patterns** stored as Rune Echoes into project-level Agent Skills. A promoted skill is a persistent behavioral rule loaded every session, whereas an echo is passive reference memory. Promotion is always gated by user confirmation — never automatic.

**Why not automatic?** Echoes accumulate quickly (dozens per month); skills are expensive context (loaded on every session). A promotion permanently changes Claude's behavior in this project. The user must consent.

## Detector Algorithm

### Input

- Echo database (`.rune/echoes/*/MEMORY.md` + sqlite FTS index via `echo-search`)
- `echo_access_log` access counts via `_get_access_counts()` (see `plugins/rune/scripts/echo-search/server.py:78`)
- Talisman config: `echoes.skill_promotion.{enabled,min_access_count,min_score,target}`

### Procedure

```python
def detect_skill_promotion_candidates(
    echo_conn,                  # sqlite connection to echo-search db
    min_access_count: int = 5,  # from talisman
    min_score: float = 0.6,     # from talisman
    max_content_len: int = 1500 # cap to prevent context-bomb promotion
) -> list[dict]:
    """
    Return candidate echoes eligible for skill promotion.

    SQL filter: layer IN ('etched', 'notes') AND length(content) BETWEEN 100 AND max_content_len.
    Also respects max_content_len as content-length cap to prevent promotion of
    sprawling echo entries that would blow skill-file context budgets.
    """
    candidates = []

    # Fetch eligible echoes — filter in SQL (indexed on layer) then score in Python
    rows = echo_conn.execute("""
        SELECT id, layer, role, title, content, source_file
        FROM echo_entries
        WHERE layer IN ('etched', 'notes')
          AND length(content) > 100
          AND length(content) < ?
        LIMIT 50
    """, (max_content_len,)).fetchall()

    if not rows:
        return []

    # Bulk-fetch access counts (single query vs N queries)
    access_counts = _get_access_counts(echo_conn, [r["id"] for r in rows])

    for row in rows:
        eid = row["id"]
        access = access_counts.get(eid, 0)
        if access < min_access_count:
            continue

        content = row["content"] or ""
        score, signals = _score_promotion(content, access)

        if score >= min_score:
            candidates.append({
                "type": "skill-promotion",
                "pattern_key": f"promote:{eid}",
                "description": row["title"] or "(untitled echo)",
                "echo_id": eid,
                "echo_layer": row["layer"],
                "access_count": access,
                "promotion_score": round(score, 3),
                "content": content,
                "source_file": row["source_file"],
                "suggested_invocable": _suggest_invocable(content),
                "signals": signals,
                "confidence": min(1.0, 0.6 + (score - min_score)),
            })

    # Sort by score desc
    candidates.sort(key=lambda c: c["promotion_score"], reverse=True)
    return candidates
```

### Scoring Formula

```python
import re

ACTION_KEYWORD_RE = re.compile(r"\b(always|never|must|should|before\s+\S+\s+do)\b", re.I)
CODE_BLOCK_RE    = re.compile(r"```|`[^`]+`|/[a-z_][\w/.-]+\.(md|py|sh|ts|js)\b", re.I)

def _score_promotion(content: str, access_count: int) -> tuple[float, dict]:
    action_hits = len(ACTION_KEYWORD_RE.findall(content))
    code_hits   = len(CODE_BLOCK_RE.findall(content))
    length      = len(content)

    score = (
        (action_hits * 0.30) +
        (code_hits   * 0.30) +
        (access_count / 10 * 0.20) +
        (length      / 500 * 0.20)
    )
    # Clamp to [0, 1]
    score = max(0.0, min(1.0, score))

    return score, {
        "action_keywords": action_hits,
        "code_patterns":   code_hits,
        "access_count":    access_count,
        "content_length":  length,
    }
```

### `user-invocable` Heuristic

The draft generator chooses between `user-invocable: true` (slash command) and `user-invocable: false` (autoload-only) based on whether the echo reads as a procedure or a constraint:

```python
WORKFLOW_SIGNAL_RE = re.compile(
    r"\b(step\s*\d|phase\s*\d|first.*then|1\.\s|2\.\s|workflow|procedure|run\s+\S+\s+then)\b",
    re.I,
)
CONSTRAINT_SIGNAL_RE = re.compile(r"\b(always|never|must|should)\b", re.I)

def _suggest_invocable(content: str) -> bool:
    """
    True  = workflow/procedure pattern — expose as /slash-command (user-invocable: true)
    False = constraint/rule pattern    — autoload as background knowledge (user-invocable: false)
    """
    workflow_hits   = len(WORKFLOW_SIGNAL_RE.findall(content))
    constraint_hits = len(CONSTRAINT_SIGNAL_RE.findall(content))
    # Procedure wins when workflow signals >= constraint signals
    return workflow_hits >= constraint_hits and workflow_hits >= 2
```

The user sees and can override the heuristic's choice via the "Preview first" option in the confirmation gate.

## Draft Generator

Given a candidate from `detect_skill_promotion_candidates()`, produce the SKILL.md content:

```python
import re, datetime

SLUG_SANITIZE_RE = re.compile(r"[^a-z0-9-]")

def _sanitize_slug(raw: str, max_len: int = 64) -> str:
    """CLAUDE.md skill naming rule: lowercase-with-hyphens, max 64 chars."""
    slug = raw.lower().strip()
    slug = re.sub(r"\s+", "-", slug)
    slug = SLUG_SANITIZE_RE.sub("-", slug)
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug[:max_len] or "promoted-echo"

def generate_skill_draft(candidate: dict) -> tuple[str, str]:
    """Return (slug, skill_md_content)."""
    title = candidate["description"] or f"promoted-{candidate['echo_id']}"
    slug = _sanitize_slug(title)
    invocable = candidate.get("suggested_invocable", False)
    now = datetime.date.today().isoformat()

    # Content body — truncate aggressively to fit skill context budget
    body = candidate["content"].strip()
    if len(body) > 1500:
        body = body[:1500].rstrip() + "\n\n...(truncated — see source echo for full content)"

    skill_md = f"""---
name: {slug}
description: |
  Auto-generated from Rune Echo: {title}.
  {body[:160].replace(chr(10), ' ')}...
user-invocable: {"true" if invocable else "false"}
disable-model-invocation: false
allowed-tools:
  - Read
  - Grep
  - Glob
---

# {title}

{body}

## Source

- **Echo ID**: {candidate['echo_id']}
- **Layer**: {candidate['echo_layer']}
- **Access count**: {candidate['access_count']} references
- **Promotion score**: {candidate['promotion_score']}
- **Suggested user-invocable**: {invocable}
- **Promoted**: {now}
- **Source file**: {candidate['source_file']}
"""
    return slug, skill_md
```

## Dedup Guard (Task 4)

Before writing a new SKILL.md, compare the candidate against existing `.claude/skills/*/SKILL.md` files. If a close match exists, the confirmation gate surfaces an "Update existing" option instead of "Create skill."

```python
from pathlib import Path

def find_existing_similar_skill(
    candidate: dict,
    skills_dir: str = ".claude/skills",
    title_ratio_threshold: float = 0.6,
    content_ratio_threshold: float = 0.7,
) -> dict | None:
    """
    Dual-gate similarity: title_ratio > 0.6 OR content_ratio > 0.7.
    Uses Jaccard on word tokens (rapidfuzz not a hard dep).
    """
    title = candidate["description"]
    content_preview = candidate["content"][:200]

    for skill_md in Path(skills_dir).glob("*/SKILL.md"):
        try:
            existing = skill_md.read_text(encoding="utf-8")
        except Exception:
            continue
        # Extract existing skill's title and first 200 content chars
        m = re.search(r"^#\s+(.+)$", existing, re.MULTILINE)
        existing_title = m.group(1).strip() if m else skill_md.parent.name
        existing_preview = _extract_first_body(existing)[:200]

        t_ratio = _jaccard_word_tokens(title, existing_title)
        c_ratio = _jaccard_word_tokens(content_preview, existing_preview)

        if t_ratio > title_ratio_threshold or c_ratio > content_ratio_threshold:
            return {
                "slug": skill_md.parent.name,
                "path": str(skill_md),
                "title_ratio": round(t_ratio, 2),
                "content_ratio": round(c_ratio, 2),
            }
    return None

def _jaccard_word_tokens(a: str, b: str) -> float:
    ta = {w.lower() for w in re.findall(r"\w+", a)}
    tb = {w.lower() for w in re.findall(r"\w+", b)}
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)

def _extract_first_body(skill_md: str) -> str:
    """Strip YAML frontmatter and return first paragraph of body."""
    body = re.sub(r"^---\n.*?\n---\n", "", skill_md, count=1, flags=re.DOTALL)
    return body.split("\n\n", 1)[0] if body else ""
```

**Dedup rationale**: For short skill titles (< 50 chars), pure Jaccard is noisy. Using the dual gate (title_ratio > 0.6 **OR** content_ratio > 0.7) catches both near-identical titles and paraphrased descriptions covering the same rule.

## Write Protocol

When the user accepts promotion:

```python
def write_promoted_skill(
    candidate: dict,
    target: str,                 # "project" or "user"
    dup: dict | None = None,     # from find_existing_similar_skill()
) -> Path:
    slug, skill_md = generate_skill_draft(candidate)

    if target == "user":
        # CLAUDE.md multi-account rule — NEVER hardcode ~/.claude/
        import os
        base = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
        skills_root = Path(base) / "skills"
    else:  # "project"
        skills_root = Path(".claude/skills")

    # If dedup returned a match, write to the existing slug instead of a new one
    if dup:
        target_path = Path(dup["path"])
    else:
        target_path = skills_root / slug / "SKILL.md"

    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_text(skill_md, encoding="utf-8")
    return target_path
```

**Post-write reminder** (printed by Phase 4.1 gate, not the writer function):
```
✓ Skill written to <path>
  Run `/reload-plugins` or restart Claude Code to activate this skill.
```

## Skip Conditions

| Condition | Effect |
|-----------|--------|
| `echoes.skill_promotion.enabled: false` in talisman | Detector skipped entirely |
| Echo layer not in `{etched, notes}` | Candidate excluded at SQL filter |
| `access_count < min_access_count` | Candidate excluded |
| `content` length not in `[100, 1500]` | Candidate excluded |
| `promotion_score < min_score` | Candidate excluded |
| Session-wide "Skip all" flag active | All remaining prompts suppressed |

## Security

- **Slug sanitization**: `_sanitize_slug` removes all characters outside `[a-z0-9-]`, caps at 64 chars, falls back to `promoted-echo` for empty results. Defense against path-traversal if echo titles contain `../` or shell metacharacters.
- **Content cap**: `max_content_len=1500` bounds the skill body — prevents promotion of sprawling echoes that would blow subsequent sessions' context budgets.
- **Target path**: `write_promoted_skill` builds paths via `pathlib.Path` joining; no shell interpolation of user content.
- **CLAUDE_CONFIG_DIR**: When `target: user`, the path uses `os.environ["CLAUDE_CONFIG_DIR"]` with `$HOME/.claude` fallback — matches CLAUDE.md multi-account rule. Never hardcode `~/.claude/`.

## Edge Cases

| Case | Handling |
|------|----------|
| Echo with empty/missing title | Filter out before scoring (generated slug becomes `promoted-echo-{id}` fallback) |
| Multi-session race (two `/rune:learn` in parallel) | Acquire `rune_acquire_lock("learn")` before Phase 4.1 — same lock pattern as other workflows |
| Re-promotion of updated echo | Dedup returns match → "Update existing" merges new content into existing skill slug |
| Candidate content > 1500 chars | Truncate body with `...(see source echo for full content)` footer |
| `.claude/skills/` directory missing | `mkdir -p` in `write_promoted_skill` (creates on first promotion) |
