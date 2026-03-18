# Rune Quick Cheat Sheet (Tiếng Việt)

Cheat sheet 1 trang để chọn đúng lệnh Rune theo tình huống.
Tài liệu giữ một số thuật ngữ English để tránh dịch máy móc: `workflow`, `phase`, `checkpoint`, `quality gate`.

Hướng dẫn liên quan:
- [Bắt đầu nhanh](rune-getting-started.vi.md)
- [Bảng tra lệnh](rune-command-reference.vi.md)
- [FAQ Rune](rune-faq.vi.md)

## Khởi động trong 60 giây

```bash
/plugin marketplace add https://github.com/vinhnxv/rune
/plugin install rune
```

Trong `.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Tùy chọn:

```bash
/rune:talisman init
```

---

## Chọn lệnh theo mục tiêu

| Bạn muốn làm gì? | Lệnh nên dùng |
|------------------|---------------|
| Biến ý tưởng thành kế hoạch | `/rune:plan` (`/rune:devise`) |
| Triển khai từ plan | `/rune:work` (`/rune:strive`) |
| Review phần code đang thay đổi | `/rune:review` (`/rune:appraise`) |
| Sửa findings từ review/audit | `/rune:mend tmp/reviews/{id}/TOME.md` hoặc `tmp/audit/{id}/TOME.md` |
| Audit toàn codebase | `/rune:audit` |
| Chạy full pipeline end-to-end | `/rune:arc plans/my-plan.md` |
| Chạy nhiều plan liên tiếp | `/rune:arc-batch plans/*.md` |
| Dùng ngôn ngữ tự nhiên để Rune tự điều hướng | `/rune:tarnished ...` |
| Dọn artifact tạm sau workflow | `/rune:rest` |
| Dừng workflow đang chạy | `/rune:cancel-*` phù hợp |

---

## 5 workflow copy-paste nhanh

### 1) Luồng cơ bản hằng ngày

```bash
/rune:plan thêm xác thực người dùng
/rune:work
/rune:review
```

### 2) Bug fix nhanh (tiết kiệm token)

```bash
/rune:plan --quick sửa lỗi phân trang
/rune:work
/rune:review
```

### 3) Review sâu và tự sửa

```bash
/rune:appraise --deep --auto-mend
```

### 4) Full pipeline từ plan tới PR

```bash
/rune:arc plans/2026-03-01-feat-x-plan.md
```

### 5) Chạy backlog theo nhãn issue

```bash
/rune:arc-issues --label "rune:ready"
```

---

## Flags hay dùng nhất

| Lệnh | Flag | Dùng khi |
|------|------|----------|
| `/rune:devise` | `--quick` | Kế hoạch ngắn, bug nhỏ |
| `/rune:strive` | `--approve` | Muốn duyệt từng task trước khi làm |
| `/rune:appraise` | `--deep` | Muốn review kỹ hơn |
| `/rune:audit` | `--incremental` | Audit codebase lớn theo batch |
| `/rune:arc` | `--resume` | Tiếp tục pipeline bị gián đoạn |
| `/rune:arc-batch` | `--dry-run` | Xem trước queue trước khi chạy thật |

---

## Đầu ra thường gặp nằm ở đâu?

| Loại output | Đường dẫn |
|-------------|-----------|
| Plan | `plans/YYYY-MM-DD-...-plan.md` |
| Review report (TOME) | `tmp/reviews/{id}/TOME.md` |
| Audit report (TOME) | `tmp/audit/{id}/TOME.md` |
| Arc checkpoint | `.rune/arc/{id}/checkpoint.json` |
| Echoes memory | `.rune/echoes/` |

---

## Lúc bị kẹt, chạy gì trước?

1. `arc` hoặc `arc-batch` bị ngắt: dùng `--resume`.
2. Plan bị stale: chạy lại `/rune:devise` hoặc dùng `--skip-freshness` có chủ đích.
3. Custom Ash không chạy: kiểm tra `trigger.extensions`, `trigger.paths`, `workflows`, `settings.max_ashes`.
4. Token quá cao: ưu tiên `plan -> work -> review` thay cho `arc`; giảm `--deep`; dùng `--quick`.
5. Muốn dọn workspace tạm: `/rune:rest`.

