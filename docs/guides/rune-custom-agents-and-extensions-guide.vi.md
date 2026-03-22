# Hướng dẫn nâng cao Rune: Custom Agent và Mở rộng

Mở rộng pipeline review của Rune với agent theo dự án, model bên ngoài qua CLI, và tích hợp Forge Gaze.

Hướng dẫn liên quan:
- [Bắt đầu nhanh](rune-getting-started.vi.md)
- [Hướng dẫn cấu hình Talisman](rune-talisman-deep-dive-guide.vi.md)
- [Hướng dẫn review và audit](rune-code-review-and-audit-guide.vi.md)
- [Hướng dẫn xử lý sự cố và tối ưu](rune-troubleshooting-and-optimization-guide.vi.md)

## Đọc nhanh (2 phút)

- Bạn chỉ cần review mặc định: chưa cần đọc tài liệu này.
- Bạn có domain đặc thù (ví dụ fintech, y tế, ERP): nên tạo custom agent.
- Bạn muốn dùng model ngoài Claude qua CLI: xem mục CLI-backed Ashes.
- Làm theo thứ tự an toàn: viết agent file -> đăng ký trong `talisman.yml` -> test trên review nhỏ.
- Thuật ngữ tham khảo: [Thuật ngữ Rune (Tiếng Việt)](rune-glossary.vi.md).

---

## 1. Tổng quan kiến trúc

Pipeline review của Rune sử dụng **Ashes** — agent teammate hợp nhất, mỗi agent nhúng nhiều góc nhìn review. Bộ mặc định gồm 7 Ashes. Bạn có thể mở rộng bằng **custom Ashes** tham gia cùng vòng Roundtable Circle:

```
Ashes mặc định (7)  +  Custom Ashes (talisman.yml)  =  Tổng Ashes (tối đa max_ashes)
```

Custom Ashes tham gia vào:
- **Truthbinding** — bảo vệ prompt injection
- **Inscription** — hợp đồng output có cấu trúc
- **Dedup** — loại trùng finding theo prefix
- **Tổng hợp TOME** — báo cáo finding thống nhất
- **Xác minh Truthsight** — kiểm tra output (tuỳ chọn)

---

## 2. Tạo Custom Ash

### Bước 1: Viết file agent

Tạo file `.md` với YAML frontmatter. Đặt tại:
- `.claude/agents/my-reviewer.md` — cấp dự án (source: `local`)
- `~/.claude/agents/my-reviewer.md` — cấp user (source: `global`)

```yaml
---
name: domain-logic-reviewer
description: |
  Review tính toàn vẹn domain model, đúng đắn business rule,
  và patterns service layer. Dùng khi file domain/service/model thay đổi.
tools: Read, Grep, Glob
model: sonnet
---

Bạn là reviewer chuyên gia domain logic.

## Lĩnh vực tập trung

1. **Business rule correctness** — validate state transitions, invariants, guards
2. **Domain model integrity** — kiểm tra quan hệ entity, value objects, aggregate boundaries
3. **Service layer patterns** — verify separation of concerns

## Output Format

Dùng format finding từ inscription contract. Mỗi finding phải gồm:
- File path và line number
- Severity (P1/P2/P3)
- Evidence từ source code thực (Rune Trace)
- Confidence level (HIGH/MEDIUM/LOW)
```

### Bước 2: Đăng ký trong talisman.yml

```yaml
ashes:
  custom:
    - name: "domain-logic-reviewer"
      agent: "domain-logic-reviewer"
      source: local
      workflows: [review, audit]
      trigger:
        extensions: [".py", ".rb", ".go"]
        paths: ["src/domain/", "src/services/"]
      context_budget: 20
      finding_prefix: "DOM"
      required_sections:
        - "P1 (Critical)"
        - "P2 (High)"
        - "P3 (Medium)"
        - "Reviewer Assumptions"
        - "Self-Review Log"
```

### Bước 3: Thêm prefix vào dedup hierarchy

```yaml
settings:
  dedup_hierarchy:
    - SEC          # Ward Sentinel (cao nhất)
    - BACK         # Forge Warden
    - DOM          # Custom prefix — đặt theo độ ưu tiên
    - DOC          # Knowledge Keeper
    - QUAL         # Pattern Weaver
    - FRONT        # Glyph Scribe
    - CDX          # Codex Oracle (thấp nhất)
```

---

## 3. Cấu hình Trigger

### Trigger theo file (review/audit)

```yaml
trigger:
  extensions: [".py", ".ts"]       # Extension file
  paths: ["src/api/", "api/"]      # Prefix đường dẫn
  min_files: 5                     # Chỉ kích hoạt (summon) nếu ≥N file khớp
  always: true                     # Luôn kích hoạt (summon)
```

### Trigger theo topic (forge)

```yaml
trigger:
  topics: [api, contract, endpoints, rest, graphql]
```

---

## 4. Tích hợp Forge Gaze

Để custom Ash tham gia enrichment plan, thêm `forge` vào workflows:

```yaml
ashes:
  custom:
    - name: "api-contract-reviewer"
      agent: "api-contract-reviewer"
      source: local
      workflows: [review, audit, forge]    # "forge" bật Forge Gaze
      trigger:
        extensions: [".py", ".ts"]
        paths: ["src/api/"]
        topics: [api, contract, endpoints]
      forge:
        subsection: "API Contract Analysis"
        perspective: "API design, contract compatibility"
        budget: enrichment                  # enrichment (~5k tokens) | research (~15k tokens)
      finding_prefix: "API"
```

---

## 5. CLI-Backed Ashes (Model bên ngoài)

Dùng model không phải Claude làm review Ash qua CLI:

```yaml
ashes:
  custom:
    - name: "gemini-oracle"
      cli: "gemini"
      model: "gemini-2.5-pro"
      output_format: "json"
      finding_prefix: "GEM"
      timeout: 300
      workflows: [review, audit]
      trigger:
        always: true
      context_budget: 20
```

### Ràng buộc

- **Sub-cap**: Giới hạn bởi `settings.max_cli_ashes` (mặc định: 2). Codex Oracle KHÔNG tính vào.
- **Bảo mật**: Binary name phải khớp `CLI_BINARY_PATTERN`.
- **Chống hallucination**: Tất cả CLI Ashes có guard 4 bước.
- CLI binary phải được cài và xác thực riêng. Rune KHÔNG quản lý API key cho model bên ngoài.

---

## 6. Giải quyết Agent Source

| Source | Đường dẫn | Phù hợp cho |
|--------|----------|-------------|
| `local` | `.claude/agents/{name}.md` | Reviewer theo dự án |
| `global` | `~/.claude/agents/{name}.md` | Reviewer cá nhân dùng chung |
| `plugin` | `{plugin}:{category}:{agent}` | Agent cross-plugin |

---

## 7. Reviewer dạng Persona

Dùng agent built-in của Rune làm persona Ash:

```yaml
ashes:
  custom:
    - name: "senior-engineer"
      agent: "rune:review:senior-engineer-reviewer"
      source: plugin
      workflows: [review]
      finding_prefix: "SENIOR"
```

---

## 8. Tắt Ashes mặc định

Thay thế Ash built-in bằng custom:

```yaml
defaults:
  disable_ashes:
    - "knowledge-keeper"

ashes:
  custom:
    - name: "my-doc-reviewer"
      agent: "my-doc-reviewer"
      source: local
      workflows: [review, audit]
      finding_prefix: "MDOC"
```

---

## 9. Viết Prompt Agent hiệu quả

### Cấu trúc

```markdown
---
name: my-reviewer
description: |
  Mô tả agent làm GÌ và KHI NÀO dùng.
tools: Read, Grep, Glob
model: sonnet
---

# Vai trò (1-2 câu)

## Lĩnh vực tập trung (3-5 bullet)

## Quy trình review (từng bước)

## Anti-pattern cần phát hiện

## Format output
```

### Best practices

| Nên | Không nên |
|-----|----------|
| Cụ thể về cái cần tìm | Chỉ dẫn mơ hồ kiểu "review chất lượng" |
| Gồm ví dụ cụ thể | Để agent tự đoán bạn quan tâm gì |
| Chỉ rõ format output | Giả định agent biết format finding |
| Giữ dưới 500 dòng | Viết hướng dẫn quá dài |
| Dùng `tools: Read, Grep, Glob` (read-only) | Cho review agent quyền write |

---

## 10. Test Custom Ash

### 1. Chạy review với agent

```bash
/rune:appraise
```

### 2. Kiểm tra TOME output

Tìm finding prefix trong `tmp/reviews/{id}/TOME.md`:

```bash
grep "DOM-" tmp/reviews/*/TOME.md
```

### 3. Xác minh inscription compliance

Kiểm tra agent tạo đủ required sections trong `tmp/reviews/{id}/ash-outputs/`.

---

## 11. Ví dụ hoàn chỉnh: E-commerce Domain Reviewer

### File agent (`.claude/agents/ecommerce-reviewer.md`)

```yaml
---
name: ecommerce-reviewer
description: |
  Chuyên gia domain e-commerce. Review vòng đời order, xử lý thanh toán,
  quản lý kho, và logic giá. Phát hiện thiếu validation trong checkout,
  state transition sai, race condition trong cập nhật kho.
tools: Read, Grep, Glob
model: sonnet
---

Bạn là reviewer chuyên gia domain e-commerce.

## Lĩnh vực tập trung

1. **Vòng đời order** — state machine (pending → paid → shipped → delivered)
2. **Xử lý thanh toán** — idempotency, retry, hoàn tiền một phần
3. **Quản lý kho** — race conditions, overselling, đặt trước hàng
4. **Logic giá** — discount stacking, tính thuế, xử lý tiền tệ
5. **Checkout flow** — validation giỏ hàng, kiểm tra địa chỉ, phương thức thanh toán

## Anti-Patterns

- Thiếu idempotency key trên API thanh toán
- Kiểm tra kho ngoài transaction boundary
- Tính giá phía client không có server validation
- State transition không có guard conditions
- Thiếu rollback khi thanh toán thất bại một phần

## Evidence

Mọi finding phải bao gồm Rune Trace với đường dẫn file chính xác, số dòng, và code snippet.
```

### Đăng ký talisman

```yaml
ashes:
  custom:
    - name: "ecommerce-reviewer"
      agent: "ecommerce-reviewer"
      source: local
      workflows: [review, audit, forge]
      trigger:
        extensions: [".py", ".ts", ".rb"]
        paths: ["src/orders/", "src/payments/", "src/inventory/"]
        topics: [order, payment, inventory, pricing, checkout]
      forge:
        subsection: "E-commerce Domain Analysis"
        perspective: "order lifecycle, payment idempotency, inventory safety"
        budget: enrichment
      context_budget: 20
      finding_prefix: "ECOM"

settings:
  dedup_hierarchy:
    - SEC
    - BACK
    - ECOM
    - DOC
    - QUAL
    - FRONT
    - CDX
```

---

## 12. Giới hạn và ràng buộc

| Ràng buộc | Giá trị | Ghi chú |
|----------|---------|---------|
| Max tổng Ashes | `settings.max_ashes` (mặc định 9) | Gồm built-in + custom |
| Max CLI Ashes | `settings.max_cli_ashes` (mặc định 2) | Codex Oracle không tính |
| Context budget mỗi Ash | `context_budget` (mặc định 20 file) | Cao hơn = nhiều token hơn |
| Finding prefix | 2-5 ký tự viết hoa | Phải duy nhất |
| Agent prompt | < 500 dòng | Chuyển chi tiết sang file phụ |
| Cửa sổ dedup | 5 dòng | Finding trong 5 dòng bị dedup |
