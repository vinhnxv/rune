# Intent Patterns

Classification patterns for `/rune:tarnished` routing.

## Fast-Path Keywords

These keywords at the START of `$ARGUMENTS` trigger immediate routing (no classification needed):

| Keyword | Route To | Pass Remaining Args |
|---------|----------|---------------------|
| `plan` | `/rune:devise` | Yes |
| `work` | `/rune:strive` | Yes |
| `review` | `/rune:appraise` | Yes |
| `devise` | `/rune:devise` | Yes |
| `strive` | `/rune:strive` | Yes |
| `appraise` | `/rune:appraise` | Yes |
| `audit` | `/rune:audit` | Yes |
| `arc` | `/rune:arc` | Yes |
| `forge` | `/rune:forge` | Yes |
| `mend` | `/rune:mend` | Yes |
| `inspect` | `/rune:inspect` | Yes |
| `goldmask` | `/rune:goldmask` | Yes |
| `elicit` | `/rune:elicit` | Yes |
| `rest` | `/rune:rest` | Yes |
| `echoes` | `/rune:echoes` | Yes |
| `clean` | `/rune:rest` | Yes |
| `arc-batch` | `/rune:arc-batch` | Yes |
| `arc-issues` | `/rune:arc-issues` | Yes |
| `arc-hierarchy` | `/rune:arc-hierarchy` | Yes |
| `ship` | `/rune:arc` | Yes |
| `fix` | `/rune:mend` | Yes — check for TOME prerequisite |
| `brainstorm` | `/rune:brainstorm` | Yes |
| `explore` | `/rune:brainstorm` | Yes — alias for brainstorm |
| `debug` | `/rune:debug` | Yes |
| `talisman` | `/rune:talisman` | Yes |
| `config` | `/rune:talisman` | Yes — alias for talisman |
| `setup` | `/rune:talisman` | Yes — alias for talisman init |
| `mcp` | `/rune:talisman guide integrations` | Yes — MCP integration guidance |
| `mcp setup` / `setup mcp` / `add mcp` | `/rune:talisman guide integrations` | MCP integration setup walkthrough |
| `untitledui` / `untitled-ui` | `/rune:talisman guide integrations` | UntitledUI MCP integration guidance |
| `codex review` / `cross-model review` / `second opinion` / `codex check` | `/rune:codex-review` | Cross-model code review with Codex |
| `cancel` | (cancel mode) | Detect active workflow → route to correct cancel command |
| `help` | (guidance mode) | Show Rune overview + suggest next action |
| `status` | (guidance mode) | Scan artifacts + recommend next step |

## Vietnamese Fast-Path Keywords

| Keyword | Route To |
|---------|----------|
| `lên kế hoạch` / `tạo plan` | `/rune:devise` |
| `triển khai` / `thực hiện` | `/rune:strive` |
| `kiểm tra` / `đánh giá` | `/rune:appraise` |
| `sửa` / `fix lỗi` | `/rune:mend` |
| `khám phá` / `khám phá ý tưởng` | `/rune:brainstorm` |
| `thảo luận` / `brainstorm` | `/rune:brainstorm` |
| `dọn dẹp` | `/rune:rest` |
| `cấu hình` / `thiết lập` | `/rune:talisman` |
| `tạo talisman` / `init talisman` | `/rune:talisman init` |
| `cài đặt mcp` / `thêm mcp` / `tích hợp mcp` | `/rune:talisman guide integrations` |

## Intent Classification (for non-keyword input)

### Category: chain

Multi-step workflows detected by connectors: "then", "and then", "after that",
"rồi", "sau đó", "xong thì".

| Pattern | Chain |
|---------|-------|
| `{plan-intent} then {work-intent}` | devise → strive |
| `{plan-intent} then {arc-intent}` | devise → arc |
| `{review-intent} then {fix-intent}` | appraise → mend |
| `{brainstorm-intent} then {plan-intent}` | brainstorm → devise |
| `{discuss-intent} then {plan-intent}` | elicit → devise |
| `{work-intent} then {review-intent}` | strive → appraise |

### Category: contextual

Requires artifact scanning before routing.

| Pattern | Action |
|---------|--------|
| "plan this brainstorm" / "plan from brainstorm" | Scan `docs/brainstorms/` → latest → devise --brainstorm-context |
| "implement it" / "build it" (no plan specified) | Scan `plans/` → latest plan → strive |
| "fix the findings" (no TOME specified) | Scan `tmp/reviews/` → latest TOME → mend |
| "continue" / "tiếp tục" | Check last workflow artifacts → resume |
| "enrich the plan" (no plan specified) | Scan `plans/` → latest plan → forge |

### Category: exploratory

Needs structured thinking before action.

| Pattern | Action |
|---------|--------|
| "brainstorm" / "explore idea" / "what should we build" | → brainstorm |
| "khám phá" / "thảo luận ý tưởng" / "brainstorm this" | → brainstorm |
| "thinking about" / "what if" / "explore" | → brainstorm (exploratory intent) |
| "discuss" / "thảo luận" / "think about" | → brainstorm (or elicit if structured reasoning needed) |
| "research" / "nghiên cứu" / "tìm hiểu" | Research inline, then suggest devise |
| "compare approaches" / "so sánh" | → elicit (Tree of Thoughts) |
| "analyze risk" / "đánh giá rủi ro" | → elicit (Pre-mortem) |

### Category: guidance

User seeks knowledge about Rune or recommendations.

| Pattern | Action |
|---------|--------|
| "help" / "giúp" / "what can you do" | Read rune-knowledge.md → show capability overview |
| "status" / "tình trạng" | Scan artifacts, report state |
| "what's next" / "tiếp theo làm gì" | Analyze current state → suggest next step |
| "how does X work" / "X là gì" | Read rune-knowledge.md → explain concept |
| "when to use X vs Y" / "khi nào dùng X" | Read skill-catalog.md → compare and recommend |
| "best practice" / "nên làm thế nào" | Read rune-knowledge.md → provide guidance |
| "troubleshoot" / "bị lỗi" / "failed" | Read rune-knowledge.md pitfalls → diagnose |
| "how to add mcp" / "mcp integration" / "setup untitledui" | Read rune-knowledge.md MCP section → guide setup |
| "tích hợp mcp" / "cách thêm mcp" / "untitledui là gì" | Read rune-knowledge.md MCP section → guide setup |

### Category: meta (legacy alias for guidance)

Same as guidance category — kept for backward compatibility.
