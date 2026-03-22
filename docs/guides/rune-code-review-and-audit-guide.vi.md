# Hướng dẫn Rune (Tiếng Việt): `/rune:appraise`, `/rune:audit` và `/rune:mend`

Hướng dẫn này bao gồm các workflow đảm bảo chất lượng của Rune:
- `/rune:appraise` — review code đa agent trên các file đã thay đổi.
- `/rune:audit` — audit toàn bộ codebase.
- `/rune:mend` — sửa lỗi song song từ kết quả review.

Các hướng dẫn liên quan:
- [Hướng dẫn arc và batch (arc/arc-batch)](rune-arc-and-batch-guide.vi.md)
- [Hướng dẫn planning (devise/forge/plan-review/inspect)](rune-planning-and-plan-quality-guide.vi.md)
- [Hướng dẫn thực thi (strive/goldmask)](rune-work-execution-guide.vi.md)

## Đọc nhanh (2 phút)

- Bạn vừa code xong trên branch: dùng `/rune:appraise`.
- Bạn muốn rà toàn bộ repo: dùng `/rune:audit`.
- Bạn có file TOME và muốn sửa nhanh: dùng `/rune:mend`.
- Nếu chưa rõ khác nhau giữa review và audit: bắt đầu với `appraise`, chỉ dùng `audit` khi cần phạm vi rộng.
- Thuật ngữ tham khảo: [Thuật ngữ Rune (Tiếng Việt)](rune-glossary.vi.md).

---

## 1. Chọn lệnh nhanh

| Tình huống | Lệnh khuyến nghị |
|---|---|
| Review các file đã thay đổi trên branch | `/rune:appraise` |
| Chỉ review file đã staged | `/rune:appraise --partial` |
| Review sâu đa sóng (3 wave, tối đa 18 Ash) | `/rune:appraise --deep` |
| Audit toàn bộ codebase | `/rune:audit` |
| Audit chỉ một số thư mục | `/rune:audit --dirs src,lib` |
| Audit tập trung vào bảo mật | `/rune:audit --focus security` |
| Audit incremental có lưu trạng thái | `/rune:audit --incremental` |
| Kiểm tra tuân thủ tùy chỉnh | `/rune:audit --prompt-file .claude/prompts/hipaa.md` |
| Sửa lỗi từ kết quả review | `/rune:mend tmp/reviews/{id}/TOME.md` |
| Review và tự động sửa trong một lệnh | `/rune:appraise --auto-mend` |
| Xem trước phạm vi mà không chạy agent | `/rune:appraise --dry-run` hoặc `/rune:audit --dry-run` |

---

## 2. Yêu cầu

### Bắt buộc
- Claude Code đã cài plugin Rune.
- Agent Teams đã bật (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).

### Khuyến nghị
- Git repository có thay đổi trên feature branch (cho appraise).
- Đủ token budget — mỗi workflow khởi tạo nhiều agent, mỗi agent có context window riêng.

### Tùy chọn
- `codex` CLI cho cross-model verification (Codex Oracle tham gia review).
- `.rune/talisman.yml` để tinh chỉnh timeout, Ash, và custom reviewer.

---

## 3. `/rune:appraise` — Review Code

### 3.1 Sử dụng cơ bản

```bash
/rune:appraise
```

Rune phát hiện file thay đổi trên branch, chọn reviewer phù hợp, và tạo TOME với các phát hiện được ưu tiên.

### 3.2 Các flag

| Flag | Tác dụng |
|---|---|
| `--deep` | Review sâu 3 wave: Ash chính → Ash điều tra → Ash phân tích (tối đa 18) |
| `--partial` | Chỉ review file đã staged (`git diff --cached`) |
| `--dry-run` | Hiển thị phạm vi và Ash được chọn mà không khởi tạo agent |
| `--max-agents <N>` | Giới hạn tổng Ash (1-8) |
| `--cycles <N>` | Chạy N lần review độc lập với TOME hợp nhất (1-5) |
| `--no-chunk` | Buộc review single-pass (tắt chunking) |
| `--chunk-size <N>` | Override ngưỡng auto-chunk (mặc định: 20 file) |
| `--no-converge` | Single pass mỗi chunk (tắt convergence loop) |
| `--no-lore` | Bỏ qua Lore Layer (phân tích git history) |
| `--scope-file <path>` | Override file thay đổi bằng JSON `{focus_files: [...]}` |
| `--auto-mend` | Tự động gọi `/rune:mend` nếu có P1/P2 |

### 3.3 Quy trình review

1. **Phát hiện phạm vi** — thu thập file thay đổi, phân loại theo extension.
2. **Lore Layer** — chấm điểm rủi ro file theo git history (churn, ownership).
3. **Rune Gaze** — chọn Ash phù hợp dựa trên loại file.
4. **Tạo team** — khởi tạo tất cả Ash song song, mỗi Ash có context window riêng.
5. **Review song song** — Ash viết phát hiện ra file (không viết vào chat).
6. **Tiền tổng hợp (Phase 5.0)** — nén output từng agent trước khi đưa vào Runebinder, giảm bão hòa context (v1.116.0+).
7. **Tổng hợp** — Runebinder loại bỏ trùng lặp, ưu tiên, tạo TOME.
8. **Xác minh trích dẫn (Phase 5.2)** — kiểm tra grep xác định các trích dẫn `file:line` trong TOME (v1.117.0+). Bắt trích dẫn ảo (file không tồn tại, dòng ngoài phạm vi). Đánh dấu `UNVERIFIED` hoặc `SUSPECT`.
9. **Truthsight** — kiểm tra bằng chứng P1 với source code.
10. **Dọn dẹp** — shutdown teammate, lưu echo, trình bày TOME.

### 3.4 Hiểu TOME

TOME chứa các phát hiện có cấu trúc với mức ưu tiên:

| Mức | Ý nghĩa | Hành động |
|---|---|---|
| **P1** | Nghiêm trọng — bảo mật, mất dữ liệu, crash | Phải sửa trước khi merge |
| **P2** | Quan trọng — lỗi logic, vấn đề hiệu năng | Nên sửa |
| **P3** | Tư vấn — style, cải thiện nhỏ | Có thể sửa |
| **Q** | Câu hỏi — cần làm rõ | Bị lọc bỏ trong mend |
| **N** | Nit — gợi ý nhỏ | Bị lọc bỏ trong mend |

**Tag trích dẫn (v1.117.0+):**

| Tag | Ý nghĩa | Hành vi mend |
|---|---|---|
| *(không có)* | Trích dẫn đã xác minh thành công | Sửa bình thường |
| **SUSPECT** | Trích dẫn xác minh một phần (pattern không khớp) | Thận trọng hơn |
| **UNVERIFIED** | Trích dẫn xác minh thất bại (file/dòng không tìm thấy) | Bị mend-fixer bỏ qua |

Output: `tmp/reviews/{id}/TOME.md`

### 3.5 Tương tác giữa các flag

- `--deep + --partial`: Hoạt động nhưng investigation Ash có thể cho ít kết quả. Có cảnh báo.
- `--deep + --cycles N`: Tốn nhiều token (N x 3 wave). Có cảnh báo.
- `--deep + --max-agents`: Max chỉ áp dụng cho Wave 1. Wave 2/3 không bị giới hạn.

---

## 4. `/rune:audit` — Audit Codebase

### 4.1 Sử dụng cơ bản

```bash
/rune:audit
```

Quét toàn bộ codebase (không chỉ file thay đổi) với phân tích sâu mặc định.

### 4.2 Các flag

| Flag | Tác dụng |
|---|---|
| `--focus <area>` | Giới hạn: `security`, `performance`, `quality`, `frontend`, `docs`, `backend`, `full` |
| `--deep` | Audit sâu đa wave (mặc định cho audit) |
| `--standard` | Override deep — audit standard single-wave |
| `--max-agents <N>` | Giới hạn tổng Ash (1-8) |
| `--dry-run` | Hiển thị phạm vi và thoát |
| `--no-lore` | Bỏ qua Lore Layer |
| `--dirs <path,...>` | Chỉ audit các thư mục này (phân cách bằng dấu phẩy) |
| `--exclude-dirs <path,...>` | Loại trừ các thư mục này |
| `--prompt <text>` | Tiêu chí kiểm tra tùy chỉnh inline |
| `--prompt-file <path>` | Tiêu chí từ file (ưu tiên hơn `--prompt`) |
| `--incremental` | Bật audit có trạng thái 3 tầng |
| `--resume` | Tiếp tục audit incremental bị gián đoạn |
| `--status` | Chỉ hiển thị dashboard coverage (không audit) |
| `--reset` | Xóa lịch sử, bắt đầu lại |
| `--tier <tier>` | Giới hạn incremental: `file`, `workflow`, `api`, `all` |

### 4.3 Giới hạn phạm vi thư mục

```bash
/rune:audit --dirs src,lib                         # Chỉ audit src/ và lib/
/rune:audit --exclude-dirs vendor,dist             # Loại trừ vendor/ và dist/
/rune:audit --dirs src --exclude-dirs src/generated # src/ trừ generated/
```

Giới hạn thư mục áp dụng từ phase đầu tiên — agent chỉ thấy file đã lọc.

### 4.4 Custom prompt

Thêm tiêu chí kiểm tra chuyên biệt cho reviewer:

```bash
/rune:audit --prompt "Flag tất cả SQL string interpolation trực tiếp là P1"
/rune:audit --prompt-file .claude/prompts/hipaa-audit.md
```

Các phát hiện tùy chỉnh được đánh dấu `source="custom"` trong TOME.

### 4.5 Audit incremental

Cho codebase lớn, audit có trạng thái theo dõi những gì đã review qua các session:

```bash
/rune:audit --incremental                # Lần đầu: ưu tiên theo rủi ro, audit một batch
/rune:audit --incremental                # Lần sau: bỏ qua file đã audit
/rune:audit --incremental --status       # Xem dashboard coverage (không chạy agent)
/rune:audit --incremental --resume       # Tiếp tục batch bị gián đoạn
/rune:audit --incremental --reset        # Xóa trạng thái, bắt đầu lại
```

Trạng thái incremental lưu tại `.rune/audit-state/` và tồn tại qua các session.

### 4.6 Khác biệt so với appraise

| Khía cạnh | `/rune:appraise` | `/rune:audit` |
|---|---|---|
| Phạm vi | Chỉ file thay đổi | Toàn bộ codebase |
| Cần git | Có (cần diff) | Không (dùng file scan) |
| Độ sâu mặc định | Standard | Deep |
| Timeout | 10 phút | 15 phút |
| Use case | Review PR | Kiểm tra sức khỏe codebase |

---

## 5. `/rune:mend` — Sửa lỗi phát hiện

### 5.1 Sử dụng cơ bản

```bash
/rune:mend tmp/reviews/{id}/TOME.md
```

Phân tích phát hiện từ TOME và gửi fixer song song để sửa.

### 5.2 Quy trình mend

1. **Phân tích TOME** — trích xuất phát hiện, lọc bỏ Q/N, loại bỏ trùng lặp.
2. **Goldmask discovery** — đọc dữ liệu rủi ro sẵn có (nếu có).
3. **Lập kế hoạch** — nhóm phát hiện theo file, xác định số fixer (tối đa 5).
4. **Khởi tạo fixer** — agent mend-fixer bị giới hạn tool (không có Bash, TeamCreate).
5. **Giám sát** — theo dõi tiến độ, phát hiện fixer bị kẹt (cảnh báo 5 phút, tự giải phóng 10 phút).
6. **Ward check** — chạy quality gate một lần sau khi tất cả fixer hoàn thành.
7. **Cross-file mend** — sửa phát hiện SKIPPED có dependency cross-file (tối đa 5).
8. **Doc-consistency** — sửa drift giữa file source-of-truth và target.
9. **Báo cáo** — tạo `tmp/mend/{id}/resolution-report.md`.

### 5.3 Các trạng thái kết quả

| Trạng thái | Ý nghĩa |
|---|---|
| **FIXED** | Đã sửa bởi fixer |
| **FIXED_CROSS_FILE** | Đã sửa trong cross-file mend pass |
| **FALSE_POSITIVE** | Fixer xác định phát hiện không phải lỗi thật |
| **FAILED** | Đã thử sửa nhưng không áp dụng được |
| **SKIPPED** | Không xử lý (ưu tiên thấp hoặc phức tạp) |
| **CONSISTENCY_FIX** | Đã sửa drift doc/config |

Phát hiện có prefix SEC- (bảo mật) không thể đánh dấu FALSE_POSITIVE bởi fixer — cần xác nhận của người dùng.

---

## 6. Kết hợp workflow

### Review rồi sửa

```bash
/rune:appraise
# Kiểm tra TOME, sau đó sửa:
/rune:mend tmp/reviews/{id}/TOME.md
```

Hoặc dùng flag tích hợp:

```bash
/rune:appraise --auto-mend
```

### Audit rồi sửa

```bash
/rune:audit --focus security
/rune:mend tmp/audit/{id}/TOME.md
```

### Chu trình đầy đủ trong arc

### Review cross-model

Cho các thay đổi quan trọng, lấy ý kiến thứ hai từ model độc lập:

```bash
/rune:codex-review
```

Chạy Claude và OpenAI Codex reviewer song song, kiểm tra chéo phát hiện, và hợp nhất vấn đề đồng thuận thành TOME thống nhất. Cần cài `codex` CLI.

### Chu trình đầy đủ trong arc

`/rune:arc` chạy review → mend → verify-mend tự động trong pipeline 29 phase. Dùng appraise/mend riêng khi bạn muốn review có mục tiêu mà không cần full pipeline.

---

## 7. Use Case

### 7.1 Review PR trước khi merge

```bash
/rune:appraise
```

Review tiêu chuẩn cho branch diff. Phù hợp cho hầu hết PR.

### 7.2 Review sâu cho thay đổi rủi ro cao

```bash
/rune:appraise --deep --auto-mend
```

Review 3 wave bắt được vấn đề tinh vi. Auto-mend tiết kiệm bước thủ công.

### 7.3 Audit bảo mật trước release

```bash
/rune:audit --focus security --dirs src
```

Quét bảo mật tập trung cho source code (loại trừ test, docs, config).

### 7.4 Audit tuân thủ với rule tùy chỉnh

```bash
/rune:audit --prompt-file .claude/prompts/hipaa-audit.md --dirs backend
```

Thêm tiêu chí chuyên biệt cho môi trường regulated.

### 7.5 Audit incremental cho codebase lớn

```bash
/rune:audit --incremental          # Batch đầu tiên
/rune:audit --incremental          # Batch tiếp (bỏ qua file đã cover)
/rune:audit --incremental --status # Kiểm tra tiến độ coverage
```

Phân bổ công việc audit qua nhiều session mà không quét lại file đã review.

---

## 8. Xử lý sự cố

| Triệu chứng | Nguyên nhân | Hành động |
|---|---|---|
| "Concurrent review running" | Session review trước đang chạy | `/rune:cancel-review` rồi thử lại |
| Không có file để review | Không có thay đổi trên branch | Đảm bảo có uncommitted changes trên feature branch |
| Ash timeout (>5 phút) | File set lớn hoặc code phức tạp | Rune tiếp tục với kết quả partial. Kiểm tra TOME cho coverage gaps |
| TOME ít phát hiện | Phạm vi quá hẹp hoặc code tốt | Kiểm tra `--dry-run` xem file mong đợi có trong scope không |
| Mend fixer bị kẹt | Cross-file dependency phức tạp | Tự giải phóng sau 10 phút. Kiểm tra resolution report cho SKIPPED |
| Ward check thất bại sau mend | Fix gây regression | Mend bisect để tìm fix gây lỗi, đánh dấu NEEDS_REVIEW |
| "No TOME found" khi mend | Chưa chạy review/audit | Chạy `/rune:appraise` hoặc `/rune:audit` trước |
| Incremental audit bị kẹt | Lock bị session chết giữ | Lock tự recovery (kiểm tra PID). Nếu vẫn kẹt, `--reset` |
| TOME có nhiều finding UNVERIFIED | Trích dẫn ảo trong code reference | Phase 5.2 đã bắt trích dẫn sai. Kiểm tra xem path file có thay đổi không |
| Tiền tổng hợp bị skip | Chỉ có 1 agent hoặc output quá ngắn | Phase 5.0 chỉ kích hoạt khi nhiều agent tạo output đáng kể |

---

## 9. Tham chiếu lệnh nhanh

```bash
# Review code
/rune:appraise                                     # Review tiêu chuẩn
/rune:appraise --deep                              # Review sâu 3 wave
/rune:appraise --partial                           # Chỉ file đã staged
/rune:appraise --deep --auto-mend                  # Review sâu + tự sửa
/rune:appraise --dry-run                           # Xem trước phạm vi

# Audit codebase
/rune:audit                                        # Audit sâu toàn bộ
/rune:audit --standard                             # Độ sâu standard
/rune:audit --focus security                       # Tập trung bảo mật
/rune:audit --dirs src --exclude-dirs src/generated # Giới hạn thư mục
/rune:audit --prompt "Flag SQL injection là P1"    # Tiêu chí tùy chỉnh
/rune:audit --incremental                          # Audit có trạng thái
/rune:audit --incremental --status                 # Dashboard coverage

# Sửa phát hiện
/rune:mend tmp/reviews/{id}/TOME.md                # Sửa kết quả review
/rune:mend tmp/audit/{id}/TOME.md                  # Sửa kết quả audit

# Review cross-model
/rune:codex-review                                 # Claude + Codex song song

# Hủy
/rune:cancel-review
/rune:cancel-audit
/rune:cancel-codex-review
```
