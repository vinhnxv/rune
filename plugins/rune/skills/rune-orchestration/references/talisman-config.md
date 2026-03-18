# Talisman Example Config — Dispatch-Inspired Enhancements (v1.106.0)

Example `talisman.yml` sections for the worker question relay, context preservation,
and background dispatch features added in v1.106.0.

Drop these sections into your `.rune/talisman.yml` as needed.

## Question Relay

Controls worker question relay protocol (Forge Revision 1 — SendMessage-based).

```yaml
question_relay:
  enabled: true                        # Default: true. Set false to disable question relay entirely.
  timeout_seconds: 180                 # How long a worker waits for an answer before auto-resolving (default: 180s = 3 min).
  poll_interval_seconds: 15            # DOC-004 FIX: Fast-path signal scan interval (default: 15s). Matches question-relay.md and SKILL.md.
  auto_answer_on_timeout: true         # If true, worker resumes with best-judgment answer on timeout (default: true).
                                       # If false, worker marks task BLOCKED on unanswered question timeout.
  max_questions_per_worker: 3          # Max questions a worker may ask per task session (SEC-006, default: 3).
                                       # In background mode, after this cap the worker auto-resolves without asking.
```

**Notes:**
- In foreground mode (default `/rune:strive`), workers use `SendMessage` to the Tarnished and block until answered.
- In background mode (`--background`), workers write `.question` files; the orchestrator or user writes `.answer` files.
- After `timeout_seconds`, unanswered questions are auto-resolved using `auto_answer_on_timeout` behavior.

---

## Background Dispatch

Controls non-blocking dispatch mode (`/rune:strive --background`).

```yaml
dispatch:
  enabled: true                          # Default: true. Set false to disable --background / -bg flag.
  default_mode: foreground               # "background" | "foreground". Default: foreground.
                                         # Set "background" to make --background the default for all strive runs.
  auto_collect_on_complete: true         # Auto-run --collect phase after all workers finish. Default: true.
  status_poll_interval_seconds: 30       # Interval for /rune:status progress refresh. Default: 30s.
  lock_enforcement: true                 # Enforce single active dispatch per session (PERF-005). Default: true.
```

---

## Context Preservation

Controls graceful timeout and task suspension/resume protocol.

```yaml
context_preservation:
  enabled: true                    # Default: true. Set false to disable graceful timeout entirely.
  timeout_warning_seconds: 60      # Warn worker this many seconds before turn limit (FAIL-001). Default: 60s.
  max_resume_count: 2              # Max suspend/resume cycles per task (FAIL-004). Default: 2.
                                   # After max_resume_count, task is marked permanently failed.
  context_truncate_chars: 4000     # Max chars for freeform context body injected on resume (FLAW-004). Default: 4000.
  stash_on_suspend: true           # Workers stash partial work before writing context file (FAIL-006). Default: true.
  integrity_check: true            # SHA-256 context file integrity verification on resume (FAIL-002). Default: true.
```

---

## Complete Example (all three sections)

```yaml
# .rune/talisman.yml

version: 1

# ... other sections ...

question_relay:
  enabled: true
  timeout_seconds: 180
  poll_interval_seconds: 15     # DOC-004 FIX: matches spec default (15s)
  auto_answer_on_timeout: true
  max_questions_per_worker: 3

dispatch:
  enabled: true
  default_mode: foreground
  auto_collect_on_complete: true
  status_poll_interval_seconds: 30
  lock_enforcement: true

context_preservation:
  enabled: true
  timeout_warning_seconds: 60
  max_resume_count: 2
  context_truncate_chars: 4000
  stash_on_suspend: true
  integrity_check: true
```

---

## Security Reference

| Config Key | Security Requirement | Default Safe? |
|-----------|---------------------|---------------|
| `question_relay.max_questions_per_worker` | SEC-006: cap questions in background mode | Yes (3) |
| `dispatch.*` + session isolation triple in state file | SEC-004: config_dir + owner_pid + session_id | Yes (enforced in code) |
| `context_preservation.integrity_check` | FAIL-002: SHA-256 atomic write | Yes (true) |
| `context_preservation.stash_on_suspend` | FAIL-006: no WIP commits | Yes (true) |
| `context_preservation.max_resume_count` | FAIL-004: max 2 suspensions | Yes (2) |

All security defaults are safe. Only override if you have a specific reason.
