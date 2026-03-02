# Bảng tra lệnh Rune (Tiếng Việt)

Mục lục lệnh thực dụng cho người dùng Rune.

Đã đối chiếu với repository vào **ngày 1 tháng 3 năm 2026**:
- đặc tả lệnh trong `plugins/rune/commands/*.md`
- workflow skill trong `plugins/rune/skills/*/SKILL.md`

Hướng dẫn liên quan:
- [Bắt đầu nhanh](rune-getting-started.vi.md)
- [Hướng dẫn arc và batch](rune-arc-and-batch-guide.vi.md)
- [Hướng dẫn planning](rune-planning-and-plan-quality-guide.vi.md)
- [Hướng dẫn review và audit](rune-code-review-and-audit-guide.vi.md)
- [Hướng dẫn thực thi](rune-work-execution-guide.vi.md)
- [Hướng dẫn workflow nâng cao](rune-advanced-workflows-guide.vi.md)

## Cách dùng tài liệu này

- Bạn không cần đọc toàn bộ.
- Chỉ cần tìm đúng mục theo tình huống hiện tại:
  - Muốn bắt đầu nhanh: xem `Nhóm alias cho người mới`.
  - Muốn làm đúng workflow: xem `Nhóm lệnh workflow cốt lõi`.
  - Muốn dừng workflow đang chạy: xem `Nhóm lệnh hủy workflow`.
- Nếu thuật ngữ chưa rõ: xem [Thuật ngữ Rune (Tiếng Việt)](rune-glossary.vi.md).

---

## 1. Chọn lệnh nhanh nhất

| Nếu bạn muốn... | Chạy lệnh |
|-----------------|-----------|
| Diễn đạt tự nhiên, để Rune tự điều hướng | `/rune:tarnished` |
| Lập kế hoạch công việc mới | `/rune:plan` (alias của `/rune:devise`) |
| Triển khai từ plan | `/rune:work` (alias của `/rune:strive`) |
| Review code đang thay đổi | `/rune:review` (alias của `/rune:appraise`) |
| Chạy end-to-end pipeline | `/rune:arc plans/...` |

---

## 2. Nhóm alias cho người mới

| Lệnh | Lệnh gốc | Mục đích |
|------|----------|----------|
| `/rune:plan` | `/rune:devise` | Điểm vào planning cho người mới |
| `/rune:work` | `/rune:strive` | Điểm vào triển khai cho người mới |
| `/rune:review` | `/rune:appraise` | Điểm vào review cho người mới |

---

## 3. Nhóm lệnh workflow cốt lõi

| Lệnh | Mục đích | Flag hay dùng |
|------|----------|---------------|
| `/rune:devise` | Pipeline planning đa agent | `--quick`, `--no-brainstorm`, `--no-forge`, `--exhaustive` |
| `/rune:forge` | Làm sâu plan hiện có | `--exhaustive` |
| `/rune:plan-review` | Review code block trong plan (`inspect --mode plan`) | `--focus`, `--dry-run` |
| `/rune:strive` | Thực thi task từ plan bằng workers | `--approve`, `--worktree` |
| `/rune:goldmask` | Phân tích tác động/rủi ro trước hoặc sau thay đổi | `--mode quick|deep` |
| `/rune:appraise` | Review đa agent cho git diff hiện tại | `--deep`, `--dry-run`, `--max-agents` |
| `/rune:audit` | Audit toàn bộ codebase | `--focus`, `--incremental`, `--deep`, `--dry-run` |
| `/rune:mend` | Sửa finding từ TOME | `--all`, `--max-fixers` |
| `/rune:inspect` | Audit độ khớp giữa plan và implementation | `--focus`, `--mode plan`, `--fix`, `--dry-run` |
| `/rune:arc` | Pipeline đầy đủ từ plan tới ship/merge | `--resume`, `--no-forge`, `--approve`, `--no-pr`, `--no-merge` |

---

## 4. Nhóm lệnh nâng cao và batch

| Lệnh | Mục đích | Flag hay dùng |
|------|----------|---------------|
| `/rune:arc-batch` | Chạy arc tuần tự cho nhiều plan | `--resume`, `--dry-run`, `--no-merge`, `--smart-sort` |
| `/rune:arc-hierarchy` | Thực thi decomposition plan cha/con | `--resume`, `--dry-run` |
| `/rune:arc-issues` | Chạy batch arc theo GitHub Issues | `--label`, `--all`, `--resume`, `--cleanup-labels` |
| `/rune:echoes` | Quản lý memory bền vững và tài liệu Remembrance | `show`, `init`, `prune`, `remember`, `promote`, `remembrance`, `migrate` |
| `/rune:learn` | Trích xuất pattern tái sử dụng từ session vào Echoes | không bắt buộc flag |
| `/rune:test-browser` | Kiểm tra E2E browser độc lập | `[PR#]`, `--headed`, `--max-routes` |
| `/rune:debug` | Debug song song theo ACH | mô tả lỗi/vấn đề |

---

## 5. Nhóm utility

| Lệnh | Mục đích |
|------|----------|
| `/rune:tarnished` | Router thống nhất theo ngôn ngữ tự nhiên |
| `/rune:talisman` | Cấu hình và audit `talisman.yml` (`init`, `audit`, `update`, `guide`, `status`) |
| `/rune:elicit` | Chọn phương pháp suy luận có cấu trúc |
| `/rune:file-todos` | Quản lý todo file-based theo session |
| `/rune:rest` | Dọn artifact workflow đã hoàn thành trong `tmp/` |

---

## 6. Nhóm lệnh hủy workflow

| Lệnh | Dừng workflow nào |
|------|-------------------|
| `/rune:cancel-review` | Review đang chạy |
| `/rune:cancel-codex-review` | Codex-review đang chạy |
| `/rune:cancel-audit` | Audit đang chạy |
| `/rune:cancel-arc` | Arc pipeline đang chạy |
| `/rune:cancel-arc-batch` | Arc-batch loop đang chạy |
| `/rune:cancel-arc-hierarchy` | Arc-hierarchy loop đang chạy |
| `/rune:cancel-arc-issues` | Arc-issues loop đang chạy |

---

## 7. Lộ trình gợi ý

| Tình huống | Chuỗi lệnh |
|------------|------------|
| Người mới | `/rune:plan` -> `/rune:work` -> `/rune:review` |
| Triển khai có kiểm soát cao | `/rune:devise` -> `/rune:plan-review` -> `/rune:strive --approve` -> `/rune:appraise` |
| Giao hàng tự động end-to-end | `/rune:arc plans/...` |
| Tự động hóa backlog | `/rune:arc-issues --label "rune:ready"` |
| Học sau session | `/rune:learn` -> `/rune:echoes show` |

---

## 8. Ghi chú độ chính xác

- Tài liệu này chủ động tránh hard-code các con số nội bộ dễ thay đổi (ví dụ tổng số section talisman).
- Dùng `/rune:talisman status` để lấy trạng thái cấu hình thực tế của dự án hiện tại.
