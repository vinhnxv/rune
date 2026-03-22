# Hướng dẫn nâng cao Rune: Cấu hình Talisman chi tiết

Nắm vững mọi tuỳ chỉnh trong `talisman.yml` để điều chỉnh workflow đa agent của Rune theo dự án.

Hướng dẫn liên quan:
- [Bắt đầu nhanh](rune-getting-started.vi.md)
- [Hướng dẫn arc và batch](rune-arc-and-batch-guide.vi.md)
- [Hướng dẫn planning](rune-planning-and-plan-quality-guide.vi.md)
- [Hướng dẫn review và audit](rune-code-review-and-audit-guide.vi.md)
- [Hướng dẫn custom agent và mở rộng](rune-custom-agents-and-extensions-guide.vi.md)
- [Hướng dẫn xử lý sự cố và tối ưu](rune-troubleshooting-and-optimization-guide.vi.md)

## Đọc nhanh (2 phút)

- Bạn mới dùng Rune: chỉ cần chạy `/rune:talisman init` là đủ cho bước đầu.
- Khi workflow chạy không như mong đợi: dùng `/rune:talisman audit` trước khi sửa tay.
- Chỉ sửa các khóa bạn hiểu rõ, thay đổi nhỏ rồi kiểm tra lại.
- Nếu chưa rõ thuật ngữ cấu hình: xem [Thuật ngữ Rune (Tiếng Việt)](rune-glossary.vi.md).

---

## Thiết lập nhanh: `/rune:talisman` (v1.103.0+)

Cách nhanh nhất để có talisman cấu hình đúng là dùng skill `/rune:talisman`:

```bash
# Tạo talisman.yml mới cho dự án (tự detect stack)
/rune:talisman init

# Kiểm tra talisman hiện tại có thiếu/lỗi thời không
/rune:talisman audit

# Thêm các section thiếu vào talisman hiện tại
/rune:talisman update

# Tìm hiểu về từng section cấu hình
/rune:talisman guide codex
/rune:talisman guide arc
/rune:talisman guide review

# Xem tổng quan tình trạng talisman
/rune:talisman status

# Tách thành 3 file companion (theo đối tượng sử dụng)
/rune:talisman split

# Gộp các file companion lại thành một talisman.yml
/rune:talisman merge
```

Subcommand `init` tự detect stack dự án (Python, TypeScript, Rust, PHP, Go, v.v.) và tạo talisman với `ward_commands`, `backend_extensions`, và `dedup_hierarchy` phù hợp.

### Split / Merge — Bố cục file Companion

Khi `talisman.yml` lớn lên, bạn có thể tách thành **3 file companion** theo đối tượng sử dụng:

| File | Chứa | Ai chỉnh sửa |
|------|------|---------------|
| `.rune/talisman.yml` | Config runtime chính (rune-gaze, review, work, arc, testing, v.v.) | Hầu hết người dùng |
| `.rune/talisman.ashes.yml` | Định nghĩa agent tùy chỉnh (ashes, user_agents, extra_agent_dirs) | Tác giả agent |
| `.rune/talisman.integrations.yml` | Công cụ bên ngoài (codex, elicitation, echoes, evidence, v.v.) | Power users |

```bash
# Tách talisman.yml thành 3 file
/rune:talisman split

# Gộp các file companion lại thành một
/rune:talisman merge
```

**Cách hoạt động:**
- Split dùng **xử lý text theo dòng** (không parse YAML) — comments, khoảng trắng, và thứ tự được giữ nguyên
- Xác minh shard đảm bảo resolver tạo JSON giống hệt trước và sau khi split
- Rollback khi thất bại: nếu xác minh lỗi, file gốc được khôi phục và companions bị xóa
- `split → merge` tương đương ngữ nghĩa; `merge → split → merge` idempotent

**Khi nào nên dùng split:**
- Talisman.yml lớn (100+ dòng) nơi các thành viên khác nhau chỉnh sửa các phần khác nhau
- Tách agent registry (ashes) khỏi config chính để giảm merge conflict
- Giữ config tích hợp bên ngoài riêng biệt để dễ audit

Resolver (`talisman-resolve.sh`) tự động gộp tất cả companion files trước khi tạo JSON shards — không cần thay đổi workflow.

---

## 1. Thứ tự ưu tiên cấu hình

Talisman tuân theo **chuỗi ưu tiên 3 lớp** (cao nhất thắng):

| Ưu tiên | Vị trí | Phạm vi |
|---------|--------|---------|
| 1 (cao nhất) | `.rune/talisman.yml` | Cấp dự án |
| 2 | `~/.rune/talisman.yml` | Cấp user toàn cục |
| 3 | Plugin defaults | Mặc định (7 Ashes) |

Đối với arc flags, có thêm một lớp: **CLI flags luôn ghi đè talisman**.

```
CLI flags  >  .rune/talisman.yml  >  ~/.rune/talisman.yml  >  hardcoded defaults
```

**Mẹo**: Dùng talisman cấp dự án cho cài đặt team. Dùng talisman toàn cục cho sở thích cá nhân.

---

## 2. Phân loại file: `rune-gaze`

Rune Gaze phân loại file thay đổi thành các danh mục quyết định Ash nào được kích hoạt (summon).

```yaml
rune-gaze:
  backend_extensions:
    - .py
    - .go
    - .rs

  frontend_extensions:
    - .tsx
    - .ts
    - .jsx

  # Glob patterns bỏ qua hoàn toàn — không bao giờ review
  skip_patterns:
    - "**/migrations/**"
    - "**/*.generated.ts"
    - "**/vendor/**"

  # File luôn được review bất kể extension
  always_review:
    - "CLAUDE.md"
    - ".claude/**/*.md"
```

### Khi nào cần tuỳ chỉnh

| Tình huống | Cần thay đổi gì |
|-----------|-----------------|
| Monorepo: Go backend + React frontend | `backend_extensions: [.go]`, `frontend_extensions: [.tsx, .ts]` |
| Code auto-generated không muốn review | Thêm vào `skip_patterns` |
| File config quan trọng phải luôn review | Thêm vào `always_review` |

---

## 3. Cài đặt Review

### 3.1 Diff-Scope Engine

Engine diff-scope cho Ashes biết chính xác dòng nào thay đổi:

```yaml
review:
  diff_scope:
    enabled: true
    expansion: 8            # Dòng context mỗi bên hunk (0-50)
    tag_pre_existing: true  # Gắn tag "pre-existing" cho issue ở code không đổi
    fix_pre_existing_p1: true  # Luôn fix P1 pre-existing (security)
```

### 3.2 Vòng lặp hội tụ

```yaml
review:
  convergence:
    smart_scoring: true
    convergence_threshold: 0.7

  # Arc convergence (vòng Phase 6 → 7 → 7.5)
  arc_convergence_tier_override: null   # null = tự detect, hoặc ép: light/standard/thorough
  arc_convergence_max_cycles: null      # Hard cap (1-5)
  arc_convergence_improvement_ratio: 0.5  # Finding phải giảm 50%
```

### Hành vi theo tier

| Tier | Max cycles | Min cycles | Phù hợp cho |
|------|-----------|-----------|-------------|
| LIGHT | 2 | 1 | Thay đổi nhỏ, PR ít rủi ro |
| STANDARD | 3 | 2 | Feature thông thường |
| THOROUGH | 5 | 2 | Thay đổi rủi ro cao, code bảo mật |

### 3.3 Enforcement Asymmetry

Mức độ nghiêm ngặt thay đổi theo ngữ cảnh (file mới vs sửa, shared vs isolated):

```yaml
review:
  enforcement_asymmetry:
    enabled: true
    security_always_strict: true
    new_file_threshold: 0.30
    high_risk_paths:
      - "core/**"
      - "shared/**"
```

---

## 4. Cài đặt Work

```yaml
work:
  ward_commands:
    - "npm run lint"
    - "npm run typecheck"
    - "npm test"
  max_workers: 3
  commit_format: "rune: {subject} [ward-checked]"
  branch_prefix: "rune/work"
  co_authors:
    - "Claude <noreply@anthropic.com>"
```

### Ward commands theo loại dự án

| Loại dự án | Ward commands |
|-----------|--------------|
| Node.js/TypeScript | `["npm run lint", "npm run typecheck", "npm test"]` |
| Python | `["ruff check .", "mypy .", "pytest --tb=short"]` |
| Rust | `["cargo clippy", "cargo test"]` |
| Go | `["go vet ./...", "go test ./..."]` |

---

## 5. Cấu hình Arc Pipeline

### 5.1 Flag mặc định

```yaml
arc:
  defaults:
    no_forge: false
    approve: false
    skip_freshness: false
    confirm: false
```

### 5.2 Cài đặt Ship (tạo PR)

```yaml
arc:
  ship:
    auto_pr: true
    auto_merge: false
    merge_strategy: "squash"
    draft: false
    labels: ["rune"]
    rebase_before_merge: true
```

### 5.3 Tích hợp bot review

```yaml
arc:
  ship:
    bot_review:
      enabled: true
      timeout_ms: 900000
      hallucination_check: true
      known_bots:
        - "coderabbitai[bot]"
        - "gemini-code-assist[bot]"
```

### 5.4 Timeout theo phase

```yaml
arc:
  timeouts:
    forge: 900000          # 15 phút
    work: 2100000          # 35 phút
    code_review: 900000    # 15 phút
    mend: 1380000          # 23 phút
    test: 900000           # 15 phút
```

---

## 6. Forge Gaze

```yaml
forge:
  threshold: 0.30          # Ngưỡng điểm (thấp = nhiều agent hơn)
  max_per_section: 3       # Agent tối đa mỗi section
  max_total_agents: 8      # Tổng agent tối đa
  stack_affinity_bonus: 0.2
```

| Chế độ | Threshold | Max/section | Dùng khi |
|--------|-----------|-------------|----------|
| Mặc định | 0.30 | 3 | Feature thường ngày |
| `--exhaustive` | 0.15 | 5 | Feature phức tạp |
| Tiết kiệm | 0.50 | 2 | Plan nhanh, ít rủi ro |

---

## 7. Goldmask Impact Analysis

```yaml
goldmask:
  enabled: true

  forge:
    enabled: true            # Risk scoring trong forge

  mend:
    enabled: true
    inject_context: true     # Risk context trong fixer prompts
    quick_check: true        # Check sau mend

  devise:
    depth: "enhanced"        # basic (2 agents) | enhanced (6) | full (8)
```

| Depth | Agents | Chi phí | Phù hợp cho |
|-------|--------|---------|-------------|
| `basic` | 2 | Thấp | Plan nhanh, feature nhỏ |
| `enhanced` | 6 | Trung bình | Feature thông thường (mặc định) |
| `full` | 8 | Cao | Thay đổi rủi ro cao |

---

## 8. Testing

```yaml
testing:
  enabled: true
  tiers:
    unit:
      enabled: true
      timeout_ms: 300000
      coverage: true
    integration:
      enabled: true
      timeout_ms: 300000
    e2e:
      enabled: true
      base_url: "http://localhost:3000"
      max_routes: 3
  service:
    startup_command: null
    health_endpoint: null
```

---

## 9. Audit

```yaml
audit:
  deep:
    enabled: true
    ashes:
      - rot-seeker
      - strand-tracer
      - decree-auditor
      - fringe-watcher
    dimensions:
      - truth-seeker       # Correctness
      - ruin-watcher       # Failure modes
      - breach-hunter      # Security-deep
      - ember-seer         # Performance
  always_deep: false
```

### Audit tăng dần cho codebase lớn

```yaml
audit:
  incremental:
    enabled: true
    batch_size: 30
    coverage_target: 0.80
    staleness_window_days: 90
```

---

## 10. Echoes (Bộ nhớ Agent)

```yaml
echoes:
  version_controlled: false
  fts_enabled: true
```

Tuỳ chọn nâng cao (opt-in):

| Tính năng | Key | Mặc định | Mục đích |
|----------|-----|---------|---------|
| Semantic groups | `semantic_groups.expansion_enabled` | false | Nhóm entry liên quan |
| Query decomposition | `decomposition.enabled` | false | Tìm kiếm đa facet |
| Haiku reranking | `reranking.enabled` | false | Re-scoring ngữ nghĩa |

---

## 11. Codex Oracle (Xác minh đa model)

```yaml
codex:
  disabled: false              # Kill switch
  model: "gpt-5.3-codex"
  reasoning: "xhigh"          # xhigh | high | medium | low
  timeout: 600                 # Timeout ngoài (giây)
  stream_idle_timeout: 540     # Timeout idle trong

  # QUAN TRỌNG: bao gồm "arc" để Codex chạy trong các phase arc (v1.87.0+)
  workflows: [review, audit, plan, forge, work, mend, goldmask, inspect, arc]

  # 17 điểm xác minh inline (v1.51.0+, mở rộng v1.87.0+)
  diff_verification:
    enabled: true              # So khớp findings P1/P2 với diff hunks
  test_coverage_critique:
    enabled: true              # Phát hiện gaps coverage test
  section_validation:
    enabled: true              # Kiểm tra coverage section plan
  task_decomposition:
    enabled: true              # Kiểm tra độ chi tiết task
```

---

## 12. Biến môi trường Platform

Đặt trong `.claude/settings.json` (không phải talisman):

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "BASH_DEFAULT_TIMEOUT_MS": "600000",
    "BASH_MAX_TIMEOUT_MS": "3600000"
  }
}
```

| Biến | Mặc định | Khuyến nghị | Lý do |
|------|---------|-------------|-------|
| `BASH_DEFAULT_TIMEOUT_MS` | 120,000 | 600,000 | Ward checks thường vượt 2 phút |
| `BASH_MAX_TIMEOUT_MS` | 120,000 | 3,600,000 | Cap timeout cho mỗi lệnh |
| `MCP_TIMEOUT` | 10,000 | 30,000 | MCP server khởi động chậm |

---

## 13. Công thức theo loại dự án

### Node.js/TypeScript

```yaml
version: 1
rune-gaze:
  backend_extensions: [.ts]
  frontend_extensions: [.tsx, .jsx]
  skip_patterns: ["**/dist/**", "**/*.d.ts"]

work:
  ward_commands: ["npm run lint", "npm run typecheck", "npm test -- --passWithNoTests"]

testing:
  tiers:
    e2e:
      base_url: "http://localhost:3000"
  service:
    startup_command: "npm run dev"
```

### Python/FastAPI

```yaml
version: 1
rune-gaze:
  backend_extensions: [.py]
  skip_patterns: ["**/__pycache__/**", "**/migrations/**"]

work:
  ward_commands: ["ruff check .", "mypy . --ignore-missing-imports", "pytest --tb=short -q"]

testing:
  service:
    startup_command: "uvicorn app.main:app --port 8000"
    health_endpoint: "/health"
```

---

## 14. Mend

```yaml
mend:
  cross_file_batch_size: 3    # Tối đa file mỗi batch cho cross-file mend (1-10)
  todos_per_fixer: 5          # Tối đa file-todos mỗi fixer wave
```

---

## 15. File Todos (Schema v2, v1.101.0+)

Tất cả todos đều session-scoped và bắt buộc. Các key sau đã bị **xoá** trong v1.101.0:
- `file_todos.enabled` — todos luôn bật
- `file_todos.dir` — todos nằm trong `tmp/{workflow}/{id}/todos/`
- `file_todos.auto_generate.work` — work todos luôn được tạo

Schema hiện tại:

```yaml
file_todos:
  triage:
    auto_approve_p1: false
  manifest:
    auto_build: true
    dedup_on_build: false
    dedup_threshold: 0.70
  history:
    enabled: true
```

---

## 16. Quản lý Context

### Context Monitor

```yaml
context_monitor:
  enabled: true
  warning_threshold: 0.4          # Cảnh báo khi còn 40% context
  critical_threshold: 0.25        # Hard deny khi còn 25%
```

### Context Weaving

```yaml
context_weaving:
  glyph_budget: 300               # Tối đa chữ mỗi message agent
  offload_threshold: 500          # Dòng trên ngưỡng này → offload ra file
  rot_detection: true             # Detect context stale
```

---

## 17. Tham khảo nhanh: Tất cả key cấp cao nhất

| Key | Mục đích | Mặc định |
|-----|---------|---------|
| `version` | Phiên bản config | `1` |
| `rune-gaze` | Phân loại file | Tự detect |
| `ashes` | Custom Ash | Không có |
| `settings` | Giới hạn (max_ashes, dedup) | 7 Ashes |
| `defaults` | Tắt built-in Ash | Không tắt |
| `audit` | Deep/incremental audit | Deep enabled |
| `forge` | Ngưỡng Forge Gaze | 0.30 |
| `plan` | Verification patterns, freshness | Enabled |
| `arc` | Pipeline defaults, ship, timeouts | Xem từng key |
| `review` | Diff-scope, convergence, chunking | Tất cả enabled |
| `work` | Ward commands, workers, branch | 3 workers |
| `testing` | Test 3 tầng | Tất cả bật |
| `goldmask` | Impact analysis theo workflow | Tất cả enabled |
| `codex` | Cross-model verification (17 điểm) | Tự detect |
| `elicitation` | Structured reasoning | Enabled |
| `echoes` | Bộ nhớ agent | FTS enabled |
| `mend` | Giải quyết finding song song | 3 batch, 5/fixer |
| `file_todos` | File-based todo (schema v2) | Bắt buộc |
| `horizon` | Đánh giá chiến lược | Enabled |
| `context_monitor` | Giám sát context budget | 40% warn, 25% deny |
| `context_weaving` | Glyph budget và offload | 300 từ budget |
| `inner_flame` | Self-review protocol | Enabled |
| `doubt_seer` | Verification chất lượng | Tắt (opt-in) |

> **Mẹo**: Dùng `/rune:talisman audit` để so sánh config dự án với template mới nhất và tìm key thiếu.

Xem [`talisman.example.yml`](../../plugins/rune/talisman.example.yml) để có schema đầy đủ.
