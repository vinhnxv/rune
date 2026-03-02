# Hướng Dẫn Planning Rune (Tiếng Việt): Lập Plan, Forge, Review Plan, Inspect

Tài liệu này hướng dẫn cách tạo và kiểm định plan chất lượng cao trước khi triển khai.

Các lệnh được bao phủ:
- `/rune:devise`
- `/rune:forge`
- `/rune:plan-review`
- `/rune:inspect`

## Đọc nhanh (2 phút)

- Bạn chưa có plan: bắt đầu bằng `/rune:devise`.
- Bạn đã có plan nhưng muốn làm sâu hơn: dùng `/rune:forge`.
- Bạn muốn kiểm tra code mẫu trong plan: dùng `/rune:plan-review`.
- Bạn muốn so plan với code đã triển khai: dùng `/rune:inspect`.
- Thuật ngữ tham khảo: [Thuật ngữ Rune (Tiếng Việt)](rune-glossary.vi.md).

---

## 1. Bản Đồ Lệnh Planning

| Lệnh | Mục tiêu chính | Đầu ra thường gặp |
|---|---|---|
| `/rune:devise` | Tạo plan có cấu trúc từ yêu cầu | `plans/YYYY-MM-DD-{type}-{name}-plan.md` |
| `/rune:forge` | Làm sâu plan hiện có bằng agent chuyên môn | Cập nhật ngay trên plan đó |
| `/rune:plan-review` | Review code sample trong plan về correctness/security/pattern | `tmp/inspect/{id}/VERDICT.md` |
| `/rune:inspect` | So sánh plan-vs-implementation hoặc inspect plan (`--mode plan`) | `tmp/inspect/{id}/VERDICT.md` |

---

## 2. Vòng Đời Planning Khuyến Nghị

### Trình tự chuẩn

1. Tạo plan nền.
2. Enrich plan bằng forge.
3. Review chất lượng plan.
4. Review code sample trong plan.
5. Chốt plan rồi chạy arc.

```bash
/rune:devise
/rune:forge plans/2026-02-24-feat-my-feature-plan.md
/rune:plan-review plans/2026-02-24-feat-my-feature-plan.md
/rune:arc plans/2026-02-24-feat-my-feature-plan.md
```

### Trình tự nhanh (khi thiếu thời gian)

```bash
/rune:devise --quick
/rune:plan-review plans/2026-02-24-feat-my-feature-plan.md
/rune:arc plans/2026-02-24-feat-my-feature-plan.md --no-forge
```

Chỉ dùng khi yêu cầu đã rõ và rủi ro thấp.

---

## 3. Cách Tạo Plan File Đúng Chuẩn

## 3.1 Vị trí và tên file

Đặt plan trong `plans/`.
Dùng pattern tên chuẩn:

```text
plans/YYYY-MM-DD-{type}-{feature-name}-plan.md
```

Ví dụ:

```text
plans/2026-02-24-feat-user-auth-plan.md
```

## 3.2 Frontmatter contract

### Nhóm field tối thiểu nên có
- `title`
- `type` (`feat` | `fix` | `refactor`)
- `date`
- `estimated_effort`
- `status`

### Nhóm field chất lượng cao nên có
- `git_sha`
- `branch`
- `non_goals`
- `tags`
- `affects`

### Mẫu frontmatter

```yaml
---
title: "feat: Add user authentication with rate limiting"
type: feat
date: 2026-02-24
status: draft
estimated_effort: M
complexity: Medium
risk: Medium
affects:
  - backend/auth/service.py
  - backend/auth/routes.py
  - tests/auth/test_auth_flow.py
tags: [auth, security, rate-limit]
non_goals:
  - "No OAuth providers in this iteration"
git_sha: "a1b2c3d4"
branch: "feat/auth-v1"
session_budget:
  max_concurrent_agents: 5
---
```

## 3.3 Cấu trúc thân plan (standard)

Các section khuyến nghị:
- `# Title`
- `## Overview`
- `## Problem Statement`
- `## Proposed Solution`
- `## Technical Approach`
- `## Acceptance Criteria`
- `## Non-Goals`
- `## Success Criteria`
- `## Dependencies & Risks`
- `## References`

## 3.4 Format Acceptance Criteria

Dùng checkbox để hỗ trợ verification/completion tracking.

~~~markdown
## Acceptance Criteria

- [ ] API endpoint trả về đúng schema
- [ ] Auth failure trả đúng status code
- [ ] Unit + integration tests cover main flow và error flow
~~~

## 3.5 Plan Section Convention (bắt buộc khi có pseudocode)

Với section có pseudocode/code block, đặt contract header trước code:
- `**Inputs**:`
- `**Outputs**:`
- `**Preconditions**:`
- `**Error handling**:`

Nếu pseudocode có `Bash(...)`, `Error handling` là bắt buộc.

## 3.6 Lỗi thường gặp cần tránh

- Thiếu checkbox acceptance criteria.
- Có TODO/FIXME trong phần mô tả.
- Link heading nội bộ bị hỏng.
- Path file không an toàn/không hợp lệ.
- Tham chiếu file đã xóa nhưng không ghi chú xử lý.
- Pseudocode không có Inputs/Outputs.

---

## 4. `/rune:devise` — Tạo Plan Ban Đầu

## 4.1 Cách dùng chuẩn

```bash
/rune:devise
```

Nó thực hiện:
- Brainstorm (mặc định, có thể auto-skip nếu yêu cầu rõ)
- Nghiên cứu đa agent
- Synthesize thành plan
- Shatter assessment (khi phù hợp)
- Forge + review phase (trừ khi skip)

Output pattern:

```text
plans/YYYY-MM-DD-{type}-{feature}-plan.md
```

## 4.2 Các flag hay dùng

```bash
/rune:devise --quick
/rune:devise --no-forge
/rune:devise --no-brainstorm
/rune:devise --exhaustive
```

Gợi ý dùng:
- `--quick`: thiếu thời gian, yêu cầu đã rõ.
- `--no-forge`: sẽ forge thủ công ở bước sau.
- `--exhaustive`: tính năng rủi ro cao/nhiều quyết định kiến trúc.

---

## 5. `/rune:forge` — Làm Sâu Plan

## 5.1 Cách dùng chuẩn

```bash
/rune:forge plans/2026-02-24-feat-user-auth-plan.md
```

Auto-detect plan mới nhất:

```bash
/rune:forge
```

Enrich sâu hơn:

```bash
/rune:forge plans/2026-02-24-feat-user-auth-plan.md --exhaustive
```

Bỏ lore layer khi cần:

```bash
/rune:forge plans/2026-02-24-feat-user-auth-plan.md --no-lore
```

## 5.2 Lưu ý thực tế

- Forge chỉnh trực tiếp plan file (làm sâu section).
- Forge không viết code implementation.
- Forge hiện chưa có `--dry-run`.

---

## 6. Review Plan Trước Khi Code

## 6.1 `/rune:plan-review` (khuyến nghị)

Dùng khi plan có code sample/pseudocode và bạn muốn check correctness/security/pattern.

```bash
/rune:plan-review plans/2026-02-24-feat-user-auth-plan.md
/rune:plan-review --focus security plans/2026-02-24-feat-user-auth-plan.md
/rune:plan-review --dry-run plans/2026-02-24-feat-user-auth-plan.md
```

`/rune:plan-review` là wrapper mỏng của inspect plan mode.

## 6.2 `/rune:inspect --mode plan` (đường tương đương)

```bash
/rune:inspect --mode plan plans/2026-02-24-feat-user-auth-plan.md
/rune:inspect --mode plan --focus performance plans/2026-02-24-feat-user-auth-plan.md
```

Dùng cách này nếu bạn muốn điều khiển trực tiếp flag của inspect.

---

## 7. `/rune:inspect` — So Plan Với Implementation

Sau khi bắt đầu code (hoặc sau một vòng arc), chạy audit mức độ khớp plan-vs-implementation:

```bash
/rune:inspect plans/2026-02-24-feat-user-auth-plan.md
/rune:inspect --focus security plans/2026-02-24-feat-user-auth-plan.md
/rune:inspect --fix plans/2026-02-24-feat-user-auth-plan.md
```

Flag hữu ích:
- `--focus <dimension>`
- `--max-agents <1-4>`
- `--threshold <0-100>`
- `--fix`
- `--dry-run`

Artifact kết quả:

```text
tmp/inspect/{id}/VERDICT.md
```

---

## 8. Quality Gate Nên Chạy Trước `/rune:arc`

Nên kiểm tra theo thứ tự:

1. Plan có frontmatter đầy đủ.
2. Acceptance criteria đo được và test được.
3. Pseudocode section có contract header.
4. Forge đã enrich (nếu cần).
5. Plan review xong và đã xử lý concern lớn.

Sau đó chạy:

```bash
/rune:arc plans/2026-02-24-feat-user-auth-plan.md
```

---

## 9. Mẹo Planning: Greenfield vs Brownfield

### Greenfield
- Nên dùng `devise` đầy đủ + `forge --exhaustive` để khám phá solution space.
- Ghi non-goals rõ để tránh tràn phạm vi.
- Review sớm các giả định kiến trúc bằng plan-review.

### Brownfield
- Ghi cụ thể file ảnh hưởng trong `affects`.
- Nghiêm ngặt phần risk/rollback trong plan.
- Chạy `plan-review --focus security` và `inspect --focus failure-modes` trước khi ship.

---

## 10. Troubleshooting

| Vấn đề | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| Plan review yếu/chung chung | Plan thiếu acceptance criteria/contract rõ ràng | Viết lại section với tiêu chí kiểm thử được + Inputs/Outputs rõ |
| Forge enrich chưa sâu | Section trong plan quá mơ hồ | Đặt heading rõ hơn, thêm file reference cụ thể |
| Inspect trả gap quá rộng | Requirement extraction bị mơ hồ | Viết requirement thành statement kiểm chứng được |
| Arc cảnh báo verification gate | Plan vẫn còn lỗi chất lượng | Sửa plan, chạy lại plan-review rồi mới rerun arc |

---

## 11. Skeleton Plan Tối Thiểu (Viết Tay)

~~~markdown
---
title: "feat: <feature>"
type: feat
date: YYYY-MM-DD
status: draft
estimated_effort: M
git_sha: "<short-sha>"
branch: "<branch-name>"
---

# <Feature Title>

## Overview

## Problem Statement

## Proposed Solution

## Technical Approach

### <Sub-problem>
**Inputs**:
**Outputs**:
**Preconditions**:
**Error handling**:

```text
pseudocode here
```

## Acceptance Criteria
- [ ] ...
- [ ] ...

## Non-Goals
- ...

## Success Criteria
- ...

## Dependencies & Risks
- ...

## References
- ...
~~~
