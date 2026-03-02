# Thuật ngữ Rune (Tiếng Việt)

Bảng thuật ngữ ngắn gọn để đọc tài liệu Rune dễ hơn.
Tài liệu Rune giữ nguyên một số thuật ngữ English để dễ trao đổi kỹ thuật và tránh dịch máy móc.

## Thuật ngữ cốt lõi

| Thuật ngữ | Nghĩa đơn giản |
|-----------|----------------|
| `plan` | Bản kế hoạch triển khai (file markdown trong `plans/`) |
| `workflow` | Chuỗi bước của một tác vụ (ví dụ: `devise`, `strive`, `appraise`) |
| `phase` | Bước con bên trong workflow lớn (đặc biệt là `arc`) |
| `gate` / `quality gate` | Bước kiểm tra chất lượng, có thể chặn tiến trình khi fail |
| `artifact` | File đầu ra tạo trong quá trình chạy workflow |
| `checkpoint` | Trạng thái lưu giữa chừng để `--resume` tiếp tục |
| `resume` | Chạy tiếp từ checkpoint thay vì chạy lại từ đầu |
| `Ash` | Agent chuyên trách trong hệ thống Rune |
| `Roundtable Circle` | Cơ chế phối hợp nhiều reviewer song song |
| `TOME` | Báo cáo findings tổng hợp sau review/audit |
| `finding` | Vấn đề được phát hiện (thường có mức P1/P2/P3) |
| `mend` | Workflow sửa lỗi dựa trên findings |
| `ward command` | Lệnh kiểm tra chất lượng như lint/test/typecheck |
| `dedup` | Loại bỏ finding trùng nhau giữa nhiều agent |
| `Echoes` | Bộ nhớ bền vững của Rune cho bài học/quy ước dự án |
| `Remembrance` | Tài liệu kiến thức đã được nâng cấp từ Echoes |
| `summon` / `kích hoạt` | Rune gọi một agent/team vào đúng workflow hoặc phase |
| `Forge Gaze` | Cơ chế ghép agent phù hợp theo chủ đề plan |
| `blast radius` | Phạm vi ảnh hưởng của thay đổi |
| `dry-run` | Xem trước phạm vi/lộ trình, không chạy agent thật |
| `worktree` | Bản sao tách biệt của repo để giảm xung đột khi chạy song song |

## Mức độ ưu tiên finding

| Mức | Ý nghĩa |
|-----|---------|
| `P1` | Nghiêm trọng, cần xử lý ngay |
| `P2` | Quan trọng, nên xử lý sớm |
| `P3` | Trung bình/thấp, có thể xử lý sau |

## Lộ trình tối thiểu cho người mới

1. `/rune:plan`
2. `/rune:work`
3. `/rune:review`
4. Nếu có TOME: `/rune:mend tmp/reviews/{id}/TOME.md`
