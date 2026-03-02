# Rune Quick Cheat Sheet

One-page cheat sheet to pick the right Rune command for each situation.
This guide intentionally keeps key technical terms as-is: `workflow`, `phase`, `checkpoint`, `quality gate`.

Related guides:
- [Getting Started](rune-getting-started.en.md)
- [Command Reference](rune-command-reference.en.md)
- [Rune FAQ](rune-faq.en.md)

## Start in 60 Seconds

```bash
/plugin marketplace add https://github.com/vinhnxv/rune-plugin
/plugin install rune
```

In `.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Optional:

```bash
/rune:talisman init
```

---

## Pick Commands by Goal

| What do you want to do? | Command |
|-------------------------|---------|
| Turn an idea into a plan | `/rune:plan` (`/rune:devise`) |
| Implement from a plan | `/rune:work` (`/rune:strive`) |
| Review current code changes | `/rune:review` (`/rune:appraise`) |
| Fix findings from review/audit | `/rune:mend tmp/reviews/{id}/TOME.md` or `tmp/audit/{id}/TOME.md` |
| Audit a broader codebase scope | `/rune:audit` |
| Run full end-to-end pipeline | `/rune:arc plans/my-plan.md` |
| Run multiple plans sequentially | `/rune:arc-batch plans/*.md` |
| Use natural language routing | `/rune:tarnished ...` |
| Clean temporary workflow artifacts | `/rune:rest` |
| Stop a running workflow | matching `/rune:cancel-*` command |

---

## 5 Copy-Paste Workflows

### 1) Daily baseline flow

```bash
/rune:plan add user authentication
/rune:work
/rune:review
```

### 2) Fast bug-fix loop (token-aware)

```bash
/rune:plan --quick fix pagination bug
/rune:work
/rune:review
```

### 3) Deep review and auto-fix

```bash
/rune:appraise --deep --auto-mend
```

### 4) Full pipeline from plan to PR

```bash
/rune:arc plans/2026-03-01-feat-x-plan.md
```

### 5) Process backlog by issue label

```bash
/rune:arc-issues --label "rune:ready"
```

---

## Most Useful Flags

| Command | Flag | Use when |
|---------|------|----------|
| `/rune:devise` | `--quick` | Plan is small or low-risk |
| `/rune:strive` | `--approve` | You want task-by-task approval |
| `/rune:appraise` | `--deep` | You want deeper review coverage |
| `/rune:audit` | `--incremental` | Codebase is large and needs batching |
| `/rune:arc` | `--resume` | Pipeline was interrupted |
| `/rune:arc-batch` | `--dry-run` | Preview queue before running |

---

## Where Outputs Go

| Output type | Path |
|-------------|------|
| Plan | `plans/YYYY-MM-DD-...-plan.md` |
| Review report (TOME) | `tmp/reviews/{id}/TOME.md` |
| Audit report (TOME) | `tmp/audit/{id}/TOME.md` |
| Arc checkpoint | `.claude/arc/{id}/checkpoint.json` |
| Echoes memory | `.claude/echoes/` |

---

## If You Get Stuck, Try This First

1. `arc` or `arc-batch` interrupted: run `--resume`.
2. Plan blocked as stale: regenerate with `/rune:devise` or intentionally use `--skip-freshness`.
3. Custom Ash not running: check `trigger.extensions`, `trigger.paths`, `workflows`, `settings.max_ashes`.
4. Token usage too high: prefer `plan -> work -> review` over `arc`, reduce `--deep`, use `--quick`.
5. Want to clean workspace artifacts: run `/rune:rest`.

