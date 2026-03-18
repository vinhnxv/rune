# FAQ Rune (Tiếng Việt)

Câu hỏi thường gặp cho người dùng Rune, ưu tiên trả lời ngắn và thực dụng.
Tài liệu giữ một số thuật ngữ English (`workflow`, `phase`, `checkpoint`, `quality gate`) để dễ đối chiếu kỹ thuật.

Hướng dẫn liên quan:
- [Quick Cheat Sheet](rune-quick-cheat-sheet.vi.md)
- [Bắt đầu nhanh](rune-getting-started.vi.md)
- [Bảng tra lệnh](rune-command-reference.vi.md)
- [Hướng dẫn xử lý sự cố](rune-troubleshooting-and-optimization-guide.vi.md)

## Bắt đầu và lệnh cơ bản

### 1) `/rune:plan` khác gì `/rune:devise`?
`/rune:plan` là alias cho `/rune:devise`, dành cho người mới.

### 2) `/rune:work` khác gì `/rune:strive`?
`/rune:work` là alias cho `/rune:strive`, cùng chức năng triển khai từ plan.

### 3) `/rune:review` khác gì `/rune:appraise`?
`/rune:review` là alias cho `/rune:appraise`, cùng engine review.

### 4) Khi nào nên dùng `/rune:audit` thay vì `/rune:review`?
- Dùng `review` khi bạn muốn kiểm tra `git diff` hiện tại.
- Dùng `audit` khi muốn quét sâu rộng hơn trong codebase.

### 5) Khi nào dùng `/rune:arc`?
Khi bạn muốn pipeline end-to-end tự động (plan -> work -> review -> mend -> test -> ship/merge).
Nếu muốn nhanh và tiết kiệm token hơn, dùng chuỗi thủ công: `/rune:plan -> /rune:work -> /rune:review`.

## Vận hành workflow

### 6) Arc bị ngắt giữa chừng thì làm gì?
Tiếp tục bằng:

```bash
/rune:arc plans/my-plan.md --resume
```

### 7) Arc-batch bị gián đoạn thì sao?
Tiếp tục bằng:

```bash
/rune:arc-batch --resume
```

### 8) Làm sao dừng workflow đang chạy?
Dùng nhóm lệnh `cancel` phù hợp:
- `/rune:cancel-arc`
- `/rune:cancel-arc-batch`
- `/rune:cancel-review`
- `/rune:cancel-audit`

### 9) `/rune:tarnished` là gì?
Là entrypoint thống nhất, nhận ngôn ngữ tự nhiên và route sang workflow phù hợp.

Ví dụ:

```bash
/rune:tarnished review and fix
/rune:tarnished plan then work
```

## Cấu hình và độ chính xác

### 10) Có bắt buộc dùng `talisman.yml` không?
Không bắt buộc, nhưng nên dùng để tùy chỉnh theo stack dự án.

### 11) Nên chạy `talisman init`, `audit`, `update` khi nào?
- `init`: tạo cấu hình mới.
- `audit`: kiểm tra thiếu/lỗi thời.
- `update`: thêm section còn thiếu vào file hiện có.

### 12) Vì sao plan bị chặn do stale?
Freshness gate phát hiện plan cũ so với `HEAD` hiện tại.
Giải pháp:
1. Tạo lại plan bằng `/rune:devise`.
2. Hoặc dùng `--skip-freshness` khi bạn chủ động chấp nhận rủi ro.

### 13) Custom Ash không chạy, kiểm tra gì trước?
1. `trigger.extensions` có khớp file đổi không.
2. `trigger.paths` có khớp path không.
3. `workflows` có chứa workflow hiện tại không.
4. `settings.max_ashes` có quá thấp không.

## Chi phí và tối ưu

### 14) Vì sao Rune tốn token?
Vì Rune chạy multi-agent, mỗi agent có context window riêng.
Đổi lại là độ phủ và chất lượng review/implementation cao hơn.

### 15) Muốn giảm token thì nên làm gì?
1. Ưu tiên `/rune:plan --quick` cho task nhỏ.
2. Dùng `/rune:review` thay vì `--deep` khi không cần quá kỹ.
3. Chạy workflow tách bước thay vì luôn dùng `/rune:arc`.

### 16) Lúc nào nên dùng `/rune:rest`?
Khi muốn dọn artifacts trong `tmp/` từ workflow đã hoàn thành.
Lệnh này giữ trạng thái active workflow và giữ `.rune/echoes/`.

## Output và sửa lỗi

### 17) TOME nằm ở đâu?
- Review: `tmp/reviews/{id}/TOME.md`
- Audit: `tmp/audit/{id}/TOME.md`

### 18) Sửa findings từ TOME thế nào?

```bash
/rune:mend tmp/reviews/{id}/TOME.md
```

hoặc

```bash
/rune:mend tmp/audit/{id}/TOME.md
```

### 19) Mend sửa sai thì xử lý sao?
1. Đảm bảo `ward_commands` đủ lint/typecheck/test.
2. Review lại finding confidence thấp.
3. Bật `goldmask.mend.inject_context` để fix có risk context.

### 20) Muốn xem tài liệu giải pháp thực chiến ở đâu?
Xem khu Remembrance:
- [Remembrance (English)](../solutions/README.md)
- [Remembrance (Tiếng Việt)](../solutions/README.vi.md)

