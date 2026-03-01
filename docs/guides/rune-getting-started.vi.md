# Bắt đầu với Rune

Chào mừng bạn đến với Rune! Hướng dẫn này sẽ giúp bạn bắt đầu sử dụng chỉ với ba lệnh đơn giản.

## Rune là gì?

Rune là plugin điều phối multi-agent cho [Claude Code](https://claude.ai/claude-code). Plugin này phối hợp các nhóm AI agent để lập kế hoạch, triển khai và review code — tất cả từ dòng lệnh.

**Bạn không cần học tất cả cùng lúc.** Hãy bắt đầu với ba lệnh và mở rộng dần.

## Cài đặt

```bash
/plugin marketplace add https://github.com/vinhnxv/rune-plugin
/plugin install rune
```

Khởi động lại Claude Code sau khi cài đặt.

## Thiết lập

### 1. Bật Agent Teams (Bắt buộc)

Rune sử dụng [Agent Teams](https://code.claude.com/docs/en/agent-teams) — nhiều AI agent làm việc cùng nhau, mỗi agent có context window riêng. Tính năng này phải được bật trước khi sử dụng.

Thêm cấu hình sau vào `.claude/settings.json` hoặc `.claude/settings.local.json` trong project của bạn:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### 2. Cho phép Claude Code đọc thư mục output của Rune (Khuyến nghị)

Rune tạo các file output (plans, reviews, artifacts tạm) trong các thư mục thường bị gitignore. Để Claude Code có thể đọc các file này, thêm `includedGitignorePatterns` vào cùng file settings:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "includedGitignorePatterns": [
    "plans/",
    "todos/",
    "tmp/",
    "reviews/",
    ".claude/arc/",
    ".claude/echoes/",
    ".claude/arc-batch-loop.local.md",
    ".claude/arc-phase-loop.local.md",
    ".claude/CLAUDE.local.md",
    ".claude/talisman.yml"
  ]
}
```

> **Đặt settings ở đâu:**
> - `.claude/settings.json` — cấp project, commit được (chia sẻ với team)
> - `.claude/settings.local.json` — cấp project, gitignored (cấu hình cá nhân)
>
> Dùng `settings.local.json` nếu bạn không muốn commit các settings này vào repository.

### 3. Cấu hình dự án (Tuỳ chọn)

Tạo file `talisman.yml` phù hợp với tech stack dự án:

```bash
/rune:talisman init
```

Lệnh này tự detect stack (Python, TypeScript, Rust, PHP, Go, v.v.) và tạo `.claude/talisman.yml` với ward commands, phân loại file, và cài đặt agent phù hợp. Bạn có thể bỏ qua bước này — Rune hoạt động tốt với cấu hình mặc định.

Xem [Hướng dẫn Talisman chi tiết](rune-talisman-deep-dive-guide.vi.md) cho tất cả tuỳ chọn.

### 4. Xác nhận

Sau khi lưu settings, khởi động lại Claude Code. Bạn sẽ có thể chạy `/rune:plan` và thấy các agent được tạo ra.

---

## Quy trình cơ bản: Plan → Work → Review

Quy trình làm việc hàng ngày với Rune gồm ba bước:

```
/rune:plan  →  /rune:work  →  /rune:review
  Lập kế hoạch    Triển khai     Review code
```

Chỉ vậy thôi. Ba lệnh cho công việc hàng ngày.

---

## Bước 1: Lập kế hoạch (`/rune:plan`)

Mô tả tính năng bạn muốn xây dựng. Rune sẽ nghiên cứu codebase và tạo kế hoạch chi tiết.

```bash
# Mô tả tính năng cần xây dựng
/rune:plan thêm xác thực người dùng với JWT

# Kế hoạch nhanh (nhanh hơn, ít chi tiết hơn)
/rune:plan --quick sửa lỗi phân trang tìm kiếm
```

**Điều gì xảy ra bên trong:**
1. Các AI agent brainstorm các phương án tiếp cận
2. Chúng nghiên cứu codebase — patterns hiện có, lịch sử git, dependencies
3. Kết quả được tổng hợp thành kế hoạch có cấu trúc với tasks và tiêu chí hoàn thành
4. Kế hoạch được review để đảm bảo đầy đủ

**Đầu ra:** File kế hoạch tại `plans/YYYY-MM-DD-{type}-{name}-plan.md`

**Thời gian:** 5-15 phút (đầy đủ) | 2-5 phút (nhanh)

### Mẹo
- Dùng `--quick` cho bug fix và task nhỏ
- Kế hoạch là file markdown — bạn có thể chỉnh sửa trước khi triển khai
- Kế hoạch bao gồm tiêu chí hoàn thành để bạn biết khi nào xong

---

## Bước 2: Triển khai (`/rune:work`)

Đưa kế hoạch cho Rune và nó sẽ triển khai bằng một nhóm AI workers.

```bash
# Triển khai một kế hoạch cụ thể
/rune:work plans/2026-02-25-feat-user-auth-plan.md

# Tự động tìm kế hoạch mới nhất
/rune:work
```

**Điều gì xảy ra bên trong:**
1. Kế hoạch được phân tích thành các task riêng lẻ
2. Các AI worker nhận task và triển khai độc lập
3. Quality gate chạy (linting, type check)
4. Code được commit khi tất cả task hoàn thành

**Thời gian:** 10-30 phút tùy kích thước kế hoạch

### Mẹo
- Chạy `/rune:work` không cần tham số — nó tự tìm kế hoạch mới nhất
- Dùng `--approve` nếu bạn muốn xem xét từng task trước khi triển khai
- Workers tạo thay đổi code thực trong repository của bạn

---

## Bước 3: Review code (`/rune:review`)

Sau khi triển khai, review code với nhiều AI reviewer chuyên biệt.

```bash
# Review các thay đổi hiện tại (git diff)
/rune:review

# Review sâu (kỹ hơn, mất nhiều thời gian hơn)
/rune:review --deep
```

**Điều gì xảy ra bên trong:**
1. Git diff của bạn được phân tích tự động
2. Tối đa 7 reviewer chuyên biệt kiểm tra code:
   - Lỗ hổng bảo mật
   - Bottleneck hiệu năng
   - Logic bug và edge case
   - Code patterns và tính nhất quán
   - Dead code và implementation chưa hoàn chỉnh
3. Findings được loại bỏ trùng lặp, sắp xếp ưu tiên và tổng hợp thành báo cáo

**Đầu ra:** Báo cáo review (TOME) tại `tmp/reviews/{id}/TOME.md`

**Thời gian:** 3-10 phút (tiêu chuẩn) | 5-15 phút (sâu)

### Sau review: Sửa lỗi

Nếu review phát hiện vấn đề, sửa tự động:

```bash
/rune:mend tmp/reviews/{id}/TOME.md
```

---

## Phiên làm việc đầu tiên

Đây là một session hoàn chỉnh:

```bash
# 1. Lập kế hoạch tính năng
/rune:plan thêm nút dark mode vào trang settings

# 2. Triển khai kế hoạch (tự tìm kế hoạch từ bước 1)
/rune:work

# 3. Review code đã triển khai
/rune:review

# 4. Sửa lỗi được phát hiện (nếu cần)
/rune:mend tmp/reviews/{id}/TOME.md
```

---

## Bảng tham chiếu nhanh

| Lệnh | Chức năng | Alias cho |
|-------|-----------|-----------|
| `/rune:plan` | Tạo kế hoạch triển khai | `/rune:devise` |
| `/rune:plan --quick` | Kế hoạch nhanh | `/rune:devise --quick` |
| `/rune:work` | Triển khai kế hoạch với AI workers | `/rune:strive` |
| `/rune:work --approve` | Triển khai với xác nhận từ người dùng | `/rune:strive --approve` |
| `/rune:review` | Review code đa agent | `/rune:appraise` |
| `/rune:review --deep` | Review nhiều đợt kỹ lưỡng | `/rune:appraise --deep` |
| `/rune:mend` | Tự động sửa findings | — |
| `/rune:test-browser` | Test E2E trình duyệt độc lập | — |
| `/rune:learn` | Trích xuất pattern từ session | — |
| `/rune:debug` | Debug song song đa giả thuyết | — |
| `/rune:rest` | Dọn dẹp file tạm | — |

## Flags phổ biến

| Flag | Dùng với | Tác dụng |
|------|---------|----------|
| `--quick` | `/rune:plan` | Lập kế hoạch nhanh (bỏ qua brainstorm và forge) |
| `--deep` | `/rune:review` | Review kỹ hơn (nhiều đợt) |
| `--approve` | `/rune:work` | Yêu cầu xác nhận trước mỗi task |
| `--dry-run` | `/rune:review` | Xem trước phạm vi review mà không chạy |
| `--worktree` | `/rune:work` | Sử dụng git worktree isolation (thử nghiệm) |
| `--smart-sort` | `/rune:arc-batch` | Buộc sắp xếp thông minh cho input |
| `--headed` | `/rune:test-browser` | Chạy test trình duyệt có hiển thị |

---

## `/rune:tarnished` — Lệnh thống nhất

Không nhớ nên dùng lệnh nào? `/rune:tarnished` là lệnh thông minh điều hướng yêu cầu của bạn đến workflow Rune phù hợp. Hỗ trợ cả tiếng Anh và tiếng Việt.

```bash
# Chỉ cần nói bạn muốn gì — tarnished tự chọn lệnh đúng
/rune:tarnished plan thêm xác thực người dùng
/rune:tarnished work
/rune:tarnished review
/rune:tarnished arc plans/my-plan.md

# Ghép nhiều bước với "rồi" / "sau đó" / "and" / "then"
/rune:tarnished review rồi sửa
/rune:tarnished plan rồi triển khai

# Ngôn ngữ tự nhiên cũng được
/rune:tarnished triển khai kế hoạch mới nhất
/rune:tarnished sửa lỗi từ review trước

# Hỏi hướng dẫn
/rune:tarnished help
/rune:tarnished tôi nên làm gì tiếp?
/rune:tarnished khi nào nên dùng audit vs review?
```

Khi chạy không có tham số, `/rune:tarnished` quét trạng thái project (plans, reviews, git changes) và đề xuất hành động tiếp theo hợp lý nhất.

| Từ khóa | Chuyển đến |
|---------|-----------|
| `plan` / `tạo plan` | `/rune:devise` |
| `work` / `triển khai` | `/rune:strive` |
| `review` / `kiểm tra` | `/rune:appraise` |
| `arc` | `/rune:arc` |
| `arc-batch` | `/rune:arc-batch` |
| `arc-issues` | `/rune:arc-issues` |
| `audit` / `đánh giá` | `/rune:audit` |
| `forge` | `/rune:forge` |
| `mend` / `sửa` | `/rune:mend` |
| `help` / `giúp` | Chế độ hướng dẫn |

---

## Tiến xa hơn

Khi đã quen với quy trình cơ bản, hãy khám phá các lệnh nâng cao:

| Khi bạn cần... | Dùng lệnh |
|----------------|-----------|
| Pipeline đầu-cuối (plan → work → review → ship) | `/rune:arc plans/...` |
| Audit toàn bộ codebase (không chỉ thay đổi) | `/rune:audit` |
| Bổ sung chi tiết cho kế hoạch | `/rune:forge plans/...` |
| Phân tích tác động thay đổi | `/rune:goldmask` |
| Suy luận có cấu trúc (phân tích trade-off, v.v.) | `/rune:elicit` |
| Review cross-model (Claude + Codex) | `/rune:codex-review` |
| Test E2E trình duyệt độc lập | `/rune:test-browser` |
| Debug song song đa giả thuyết | `/rune:debug` |
| Trích xuất bài học từ session | `/rune:learn` |
| Xử lý GitHub Issues tự động | `/rune:arc-issues --label "rune:ready"` |

### Các hướng dẫn liên quan

- [Hướng dẫn Arc và batch](rune-arc-and-batch-guide.vi.md) — Pipeline đầu-cuối
- [Hướng dẫn planning](rune-planning-and-plan-quality-guide.vi.md) — Lập kế hoạch nâng cao
- [Hướng dẫn review và audit](rune-code-review-and-audit-guide.vi.md) — Review chuyên sâu
- [Hướng dẫn thực thi](rune-work-execution-guide.vi.md) — Swarm workers
- [Hướng dẫn workflow nâng cao](rune-advanced-workflows-guide.vi.md) — Hierarchical plans, GitHub Issues, self-learning
- [Hướng dẫn agent và mở rộng](rune-custom-agents-and-extensions-guide.vi.md) — Custom reviewer và CLI-backed Ash
- [Hướng dẫn Talisman chi tiết](rune-talisman-deep-dive-guide.vi.md) — Tham chiếu cấu hình đầy đủ
- [Hướng dẫn xử lý sự cố](rune-troubleshooting-and-optimization-guide.vi.md) — Debug, tối ưu chi phí

---

## Câu hỏi thường gặp

**H: Tôi có bắt buộc phải dùng lệnh alias (`plan`/`work`/`review`) không?**
Không. Đây chỉ là lệnh tắt tiện lợi. `/rune:devise`, `/rune:strive`, và `/rune:appraise` hoạt động hoàn toàn giống nhau với cùng flags.

**H: Một session thông thường tốn bao nhiêu token?**
Một chu trình plan+work+review cho tính năng trung bình sử dụng khá nhiều token. Chúng tôi khuyến nghị Claude Max ($200/tháng) trở lên. Dùng `--dry-run` để xem trước phạm vi.

**H: Tôi có thể chỉnh sửa kế hoạch trước khi triển khai không?**
Có! Kế hoạch là file markdown trong `plans/`. Bạn thoải mái chỉnh sửa trước khi chạy `/rune:work`.

**H: Nếu review phát hiện quá nhiều vấn đề thì sao?**
Dùng `/rune:mend` để tự động sửa. Với false positive, bạn có thể bỏ qua các findings cụ thể.

**H: Tôi có cần bật Agent Teams không?**
Có, đây là yêu cầu bắt buộc. Xem phần [Thiết lập](#thiết-lập) ở trên để biết cách cấu hình.

**H: Tôi có thể test trình duyệt mà không cần chạy full arc pipeline không?**
Có! Dùng `/rune:test-browser` cho test E2E trình duyệt độc lập. Chạy quy trình 9 bước inline mà không cần agent teams.

**H: Làm thế nào để debug lỗi phức tạp với AI agent?**
Dùng `/rune:debug` — nó khởi tạo nhiều agent điều tra giả thuyết song song bằng phương pháp ACH (Analysis of Competing Hypotheses).

**H: Tôi có thể lấy ý kiến thứ hai từ model AI khác không?**
Có. `/rune:codex-review` chạy Claude và OpenAI Codex song song, kiểm tra chéo phát hiện, và hợp nhất các vấn đề đồng thuận thành TOME.

**H: Rune học được gì từ các session trước?**
Dùng `/rune:learn` để trích xuất pattern sửa lỗi CLI và phát hiện review lặp lại từ lịch sử session. Chúng được lưu vào Rune Echoes cho các session sau.

**H: Talisman shard resolver là gì?**
Từ v1.114.0, Rune tiền xử lý `talisman.yml` thành JSON shard theo namespace khi bắt đầu session, giảm 94% token. Hoạt động tự động — không cần cấu hình.
