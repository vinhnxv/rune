# Hướng Dẫn Người Dùng Rune (Tiếng Việt): `/rune:arc` và `/rune:arc-batch`

Tài liệu này hướng dẫn cách vận hành hai workflow delivery chính của Rune:
- `/rune:arc` cho một plan end-to-end.
- `/rune:arc-batch` cho nhiều plan chạy tuần tự.

Trọng tâm là an toàn vận hành, khả năng khôi phục, và các kịch bản triển khai thực tế.

Tài liệu liên quan:
- [Hướng dẫn planning Rune (devise/forge/plan-review/inspect)](rune-planning-and-plan-quality-guide.vi.md)

## Đọc nhanh (2 phút)

- Dùng `/rune:arc` khi bạn có **1 plan** cần chạy trọn pipeline.
- Dùng `/rune:arc-batch` khi bạn có **nhiều plan** cần chạy lần lượt.
- Nếu pipeline bị ngắt, ưu tiên `--resume` trước khi chạy mới.
- Nếu chưa quen thuật ngữ, xem [Thuật ngữ Rune (Tiếng Việt)](rune-glossary.vi.md).

---

## 1. Chọn Lệnh Nhanh

| Tình huống | Lệnh khuyến nghị |
|---|---|
| Triển khai một plan với đầy đủ quality gate | `/rune:arc plans/my-plan.md` |
| Chạy nhiều plan tuần tự | `/rune:arc-batch plans/*.md` |
| Cần tiếp tục sau khi gián đoạn | `/rune:arc ... --resume` hoặc `/rune:arc-batch --resume` |
| Muốn tạo PR nhưng không auto-merge | Thêm `--no-merge` |

---

## 2. Điều Kiện Tiên Quyết

### Bắt buộc
- Claude Code đã cài Rune plugin.
- Agent Teams đã bật.
- Có plan markdown hợp lệ trong repo.

### Khuyến nghị
- Cài và đăng nhập `gh` CLI nếu muốn tự động tạo PR/merge.
- Chạy từ branch sạch (nếu bắt đầu từ `main`, Rune có thể tự tạo feature branch).
- Dự trù token đủ lớn cho workflow multi-agent.

### Tùy chọn
- `codex` CLI cho các pha cross-model.
- `.rune/talisman.yml` để chỉnh timeout, bot review, merge behavior, test policy.

---

## 3. Quy Tắc Path Plan và Chất Lượng Plan

### An toàn path plan
Path plan nên:
- Là path tương đối.
- Không là symlink.
- Không chứa `..` (path traversal).
- Chỉ dùng ký tự an toàn (`a-zA-Z0-9._-/`).

### Chất lượng plan
Để arc ổn định hơn:
- Có acceptance criteria dạng checkbox (`- [ ]`).
- File reference còn đúng.
- Có `git_sha` trong frontmatter để freshness scoring chính xác.

---

## 4. `/rune:arc` Theo Từng Bước

### 4.1 Khởi chạy arc

```bash
/rune:arc plans/my-plan.md
```

### 4.2 Các flag arc thường dùng

| Flag | Tác dụng |
|---|---|
| `--resume` | Tiếp tục từ checkpoint |
| `--no-forge` | Bỏ qua enrich plan |
| `--skip-freshness` | Bỏ qua freshness gate |
| `--approve` | Yêu cầu duyệt thủ công từng work task |
| `--confirm` | Tạm dừng khi plan review là all-CONCERN |
| `--no-test` | Bỏ qua phase test |
| `--no-pr` | Không tạo PR |
| `--no-merge` | Không auto-merge |
| `--draft` | Tạo PR dạng draft |
| `--bot-review` | Bật bắt buộc bot review phases |
| `--no-bot-review` | Tắt bắt buộc bot review phases |

### 4.3 Arc kiểm tra gì trước khi implement
Arc pre-flight sẽ kiểm tra:
- Có arc session khác đang chạy hay không.
- Path plan có an toàn không.
- Trạng thái branch và chiến lược tạo branch.
- Độ mới plan (trừ khi bạn skip).

### 4.4 Arc chạy những gì
Arc chạy pipeline theo phase, gồm:
- Plan readiness: Forge, Plan Review, Plan Refinement, Verification, Semantic Verification, Design Extraction, Task Decomposition.
- Implementation quality: Work, Design Verification, Gap Analysis, Codex Gap Analysis, Gap Remediation, Goldmask Verification.
- Convergence: Code Review (--deep), Goldmask Correlation, Mend, Verify Mend, Design Iteration loop.
- Delivery: Test (3 tầng: unit/integration/E2E), Test Coverage Critique, Pre-Ship Validation, Release Quality Check, Ship, Bot Review Wait, PR Comment Resolution, Merge.

> **Lưu ý (v1.120.2+):** Arc pipeline hiện có 29 phase (tăng từ 23), thêm Design Extraction, Design Prototype, Design Verification, Design Iteration, UX Verification, và Pre-Ship Validation.

### 4.5 Theo dõi state ở đâu
- Checkpoint: `.rune/arc/{arc-id}/checkpoint.json`
- Artifact/report: `tmp/arc/{arc-id}/`

### 4.6 Cơ chế resume
`--resume` sẽ kiểm tra checkpoint schema và hash artifact. Nếu artifact mất hoặc bị sửa, phase tương ứng bị hạ để chạy lại an toàn.

---

## 5. `/rune:arc-batch` Theo Từng Bước

### 5.1 Khởi chạy batch

```bash
/rune:arc-batch plans/*.md
```

Biến thể queue file:

```bash
/rune:arc-batch batch-queue.txt
```

### 5.2 Các flag batch thường dùng

| Flag | Tác dụng |
|---|---|
| `--dry-run` | Chỉ xem queue, không chạy |
| `--no-merge` | Giữ PR mở, không auto-merge |
| `--resume` | Chạy tiếp các plan pending |
| `--no-shard-sort` | Giữ nguyên thứ tự input |
| `--smart-sort` | Buộc sắp xếp thông minh cho mọi loại input (v1.117.0+) |

### 5.3 Batch pre-flight
Rune kiểm tra từng plan:
- File có tồn tại.
- Có phải symlink không (bị từ chối).
- Có traversal không (bị từ chối).
- File có rỗng không.
- Path có nằm trong allowlist ký tự không.
- Có trùng lặp plan không.

### 5.4 Cơ chế loop của batch
Batch dùng stop-hook loop (không dùng subprocess polling):
- Chạy plan đầu tiên.
- Mỗi lần stop event, hook cập nhật tiến độ và bơm prompt cho plan tiếp theo.
- Lặp tới khi hết plan pending.

Lưu ý quan trọng:
- Arc nội bộ trong batch được gọi kèm `--skip-freshness`.
- Sắp xếp thông minh (v1.117.0+) là **opt-in** — input glob sẽ hỏi 3 lựa chọn: Smart / Alphabetical / As-discovered. Queue file giữ nguyên thứ tự người dùng.

### 5.4.1 Chế độ sắp xếp thông minh

| Chế độ | Hành vi | Cấu hình |
|---|---|---|
| `ask` (mặc định) | Hỏi người dùng chọn thứ tự cho glob input | `arc.batch.smart_ordering.mode: "ask"` |
| `auto` | Luôn áp dụng sắp xếp thông minh | `arc.batch.smart_ordering.mode: "auto"` |
| `off` | Không sắp xếp thông minh | `arc.batch.smart_ordering.mode: "off"` |

### 5.5 File state của batch
- Loop state: `.rune/arc-batch-loop.local.md`
- Progress ledger: `tmp/arc-batch/batch-progress.json`
- Summary từng lượt (nếu bật): `tmp/arc-batch/summaries/iteration-{N}.md`

### 5.6 Resume và cancel
Chạy tiếp queue pending:

```bash
/rune:arc-batch --resume
```

Dừng lượt kế tiếp:

```bash
/rune:cancel-arc-batch
```

Dừng luôn arc đang chạy:

```bash
/rune:cancel-arc
```

---

## 6. Trường Hợp Đặc Biệt và Lưu Ý Vận Hành

### Kết quả freshness của arc
- `PASS`: chạy tiếp.
- `WARN`: cảnh báo nhưng chạy tiếp.
- `STALE`: hỏi lựa chọn (re-plan, xem drift, override, abort).

### Plan review ra all-CONCERN
- Mặc định: ghi warning và chạy tiếp sau khi tạo concern context.
- Nếu dùng `--confirm`: bắt buộc quyết định rõ từ người dùng.

### Hành vi pre-ship validator
Pre-ship có thể ra WARN/BLOCK để tăng visibility, nhưng trong workflow arc chuẩn nó được thiết kế không chặn pipeline.

### Điều kiện ship/merge bị skip
Thường do:
- Thiếu/chưa auth `gh`.
- Không có commit để push.
- Tắt auto PR/auto merge bằng flag/config.
- Context branch không hợp lệ.

### Bot review mặc định là opt-in
Các pha bot wait/comment resolution chỉ chạy khi bật bằng talisman hoặc CLI flag.

### Phạm vi resume của batch
`/rune:arc-batch --resume` chỉ chạy các plan đang `pending`.

---

## 7. Use Cases: Greenfield và Brownfield

### 7.1 Use Case Greenfield

#### Trường hợp A: Xây tính năng mới từ đầu (single PR)
Khi dùng:
- Bạn đang xây capability mới, ít phụ thuộc legacy.

Flow khuyến nghị:
1. Chuẩn bị plan.
2. Chạy full arc.

```bash
/rune:arc plans/2026-02-24-feat-notifications-plan.md
```

Vì sao hợp lý:
- Full pipeline bao phủ từ kiến trúc tới implement, review, remediation, test và ship.

Kiểm soát rủi ro:
- Dùng `--draft` nếu muốn mở PR sớm.
- Dùng `--no-merge` nếu cần người duyệt trước khi merge.

#### Trường hợp B: Sprint launch greenfield (nhiều plan độc lập)
Khi dùng:
- Có nhiều plan độc lập, cần throughput cao.

Flow khuyến nghị:
1. Dry-run queue.
2. Chạy batch không auto-merge.
3. Merge thủ công sau review.

```bash
/rune:arc-batch plans/launch/*.md --dry-run
/rune:arc-batch plans/launch/*.md --no-merge
```

Vì sao hợp lý:
- Tự động hóa tuần tự giảm vận hành tay, vẫn giữ trace rõ từng plan/PR.

Kiểm soát rủi ro:
- Giữ plan nhỏ, ít phụ thuộc chéo.
- Dùng `/rune:arc-batch --resume` nếu bị gián đoạn.

#### Trường hợp C: Rollout hệ thống mới theo shard
Khi dùng:
- Initiative greenfield lớn được tách shard plan.

Flow khuyến nghị:
- Chuẩn bị shard plan và chạy batch (mặc định có shard sorting).

```bash
/rune:arc-batch plans/shards/*.md
```

Kiểm soát rủi ro:
- Giữ metadata shard nhất quán.
- Chỉ tắt shard sort khi có chủ đích giữ thứ tự thủ công.

### 7.2 Use Case Brownfield

#### Trường hợp D: Refactor module legacy có blast radius cao
Khi dùng:
- Module cũ nhiều ràng buộc ngầm và coupling phức tạp.

Flow khuyến nghị:
1. Phân tích trước (tùy chọn) bằng `/rune:goldmask`, `/rune:inspect`.
2. Chạy arc với kiểm soát thủ công chặt.

```bash
/rune:goldmask
/rune:arc plans/refactor-auth-legacy-plan.md --approve --no-merge --confirm --bot-review
```

Vì sao hợp lý:
- Goldmask + convergence của arc giúp phát hiện regression/rủi ro còn sót trước khi merge.

Kiểm soát rủi ro:
- Giữ `--no-merge` bắt buộc.
- Bật approve cho từng task implementation.

#### Trường hợp E: Hotfix brownfield ở vùng nhạy cảm production
Khi dùng:
- Cần sửa nhanh nhưng vẫn phải giữ guardrail chất lượng.

Flow khuyến nghị:

```bash
/rune:arc plans/hotfix-payment-timeout-plan.md --no-forge --confirm --no-merge
```

Vì sao hợp lý:
- Bỏ forge để giảm thời gian; vẫn giữ review/mend/test/convergence để hạn chế rủi ro.

Kiểm soát rủi ro:
- Tránh `--skip-freshness` trừ khi cực kỳ khẩn cấp và đã xác nhận plan đúng.
- Duy trì merge gate thủ công.

#### Trường hợp F: Modernization backlog trên codebase legacy
Khi dùng:
- Có nhiều plan cleanup/refactor dạng brownfield.

Flow khuyến nghị:

```bash
/rune:arc-batch plans/modernization/*.md --dry-run
/rune:arc-batch plans/modernization/*.md --no-merge
```

Hướng dẫn vận hành:
- Review từng PR trước merge.
- Nếu gián đoạn, resume queue pending:

```bash
/rune:arc-batch --resume
```

---

## 8. Troubleshooting Nhanh

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| Arc không khởi chạy | Có arc session khác đang active | `/rune:cancel-arc` hoặc chờ |
| Ship bị skip | Thiếu/chưa auth `gh`, hoặc ship bị tắt | Auth `gh` và kiểm tra config |
| Batch dừng sau 1 plan | State loop bị xóa/cancel | Kiểm tra file state + progress |
| Resume không chạy gì | Không còn plan `pending` | Kiểm tra `tmp/arc-batch/batch-progress.json` |
| Plan bị từ chối ở pre-flight | Path/file không an toàn | Sửa path/file rồi chạy lại |
| Design phase bị skip | Không có Figma URL trong plan | Bình thường — design phase chỉ chạy khi `design_sync.enabled` và có URL Figma |
| Stop hook timeout | Arc phase vượt ngưỡng staleness | Ngưỡng hiện là 90 phút (phase) / 150 phút (batch) từ v1.125.1 |
| Worker bị loop vô hạn | maxTurns quá cao | Đã sửa trong v1.119.0 — worker có maxTurns=60 với runtime budget enforcement |

---

## 9. Command Reference (Ngắn)

```bash
# Arc
/rune:arc plans/my-plan.md
/rune:arc plans/my-plan.md --resume --no-merge

# Arc batch
/rune:arc-batch plans/*.md --dry-run
/rune:arc-batch plans/*.md --no-merge
/rune:arc-batch --resume

# Cancel
/rune:cancel-arc
/rune:cancel-arc-batch

# Arc batch với sắp xếp thông minh
/rune:arc-batch plans/*.md --smart-sort          # Buộc sắp xếp thông minh
```
