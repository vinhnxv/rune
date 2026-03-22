# Rune UI Builder Protocol --- Hướng dẫn cho nhà phát triển

Tích hợp bất kỳ thư viện component MCP nào (UntitledUI, shadcn/ui, tuỳ chỉnh) vào pipeline workflow của Rune với khả năng phát hiện tự động, định tuyến theo phase, và tiêm conventions.

Các hướng dẫn liên quan:
- [MCP Integration Spec](mcp-integration-spec.vi.md)
- [Talisman chi tiết](rune-talisman-deep-dive-guide.vi.md)
- [Agent và extension tuỳ chỉnh](rune-custom-agents-and-extensions-guide.vi.md)
- [Xử lý sự cố và tối ưu hoá](rune-troubleshooting-and-optimization-guide.vi.md)

---

## 1. UI Builder Protocol là gì?

UI Builder Protocol là một lớp trừu tượng có thể mở rộng, cho phép bất kỳ hệ sinh thái thư viện component nào (UntitledUI, shadcn/ui, MCP tuỳ chỉnh) đăng ký khả năng của mình và đưa các workflow có cấu trúc vào các phase pipeline của Rune.

### Khoảng trống mà protocol giải quyết

Nếu không có protocol, đầu ra `figma-to-react` của Rune được coi là bản triển khai cuối cùng:

```
TRƯỚC:   Figma → figma_to_react (~50-60% khớp) → worker áp dụng nguyên trạng → sửa thủ công
         (Rune tạo từ đầu, bỏ qua thư viện component)

SAU:     Figma → figma_to_react (~50-60%) → phân tích ý định → tìm trong thư viện MCP
                → khớp component thực → bố cục tổng hợp → Code (~85-95%)
         (worker import component thực từ thư viện qua MCP)
```

### Protocol KHÔNG phải là

- **Không phải một section talisman mới** --- nó mở rộng `integrations.mcp_tools` và frontmatter `builder-protocol` của skill
- **Không phải một trình xây dựng UI** --- Rune điều phối các builder bên ngoài (UntitledUI MCP, shadcn registry)
- **Không phải một thư viện component** --- Rune không đi kèm thư viện component
- **Không phải thay đổi phá vỡ** --- khi không phát hiện builder nào, pipeline hoạt động giống hệt như trước

### Hệ thống hai phần

Protocol gồm hai phần bổ sung cho nhau:

| Phần | Vị trí | Chức năng |
|------|--------|-----------|
| `integrations.mcp_tools` (talisman) | `.rune/talisman.yml` | Định tuyến tool, kiểm soát phase, điều kiện trigger |
| `builder-protocol` frontmatter (skill) | `skills/{name}/SKILL.md` | Ánh xạ capability, file conventions, hướng dẫn workflow |

Trường `skill_binding` trong talisman liên kết hai phần này với nhau. Cùng nhau chúng tạo thành một **Builder Profile** --- được giải quyết tại thời điểm chạy bởi `discoverUIBuilder()`.

---

## 2. Tạo Builder Skill (Ví dụ tối thiểu)

Một builder skill là một skill Rune tiêu chuẩn với hai bổ sung: frontmatter `builder-protocol` khai báo các capability, và một file tham chiếu `conventions`.

### Builder Skill tối thiểu

```
.claude/
  skills/
    my-builder/
      SKILL.md
      references/
        conventions.md
```

**`.claude/skills/my-builder/SKILL.md`:**

```yaml
---
name: my-builder
description: |
  My component library MCP integration for Rune workflows.
  Provides MCP tools for searching and installing components.
  Use when agents build UI with my-library components.
  Trigger keywords: my-library, component library.
user-invocable: false
disable-model-invocation: false
builder-protocol:
  library: my_library            # Must match design-system-discovery output
  mcp_server: my-library         # Must match .mcp.json server key
  capabilities:
    search: my_search_tool       # MCP tool name for natural-language search
    list: my_list_tool           # MCP tool name for browsing by category
    details: my_get_tool         # MCP tool name for getting component source
    bundle: my_bundle_tool       # MCP tool name for batch install (optional)
  conventions: references/conventions.md  # Path relative to skill dir
---

# My Library MCP Integration

Background knowledge for Rune agents working with my-library components.

## MCP Tools

### `my_search_tool`
Search for components by natural language description.

### `my_get_tool`
Install a component's full source code.

## Core Conventions

1. Always import from `@my-org/my-library`
2. Use the design token scale — never raw CSS values
3. ...
```

**`.claude/skills/my-builder/references/conventions.md`:**

```markdown
# My Library Conventions

- Import: `import { Button } from "@my-org/my-library"`
- Tokens: use `--color-brand-500`, never `#3B82F6`
- Files: kebab-case only (my-component.tsx)
```

### Liên kết Skill trong Talisman

Thêm vào `.rune/talisman.yml`:

```yaml
integrations:
  mcp_tools:
    my-library:
      server_name: "my-library"
      tools:
        - name: "my_search_tool"
          category: "search"
        - name: "my_list_tool"
          category: "search"
        - name: "my_get_tool"
          category: "details"
        - name: "my_bundle_tool"
          category: "details"
      phases:
        devise: true
        strive: true
        forge: true
        appraise: false
        audit: false
        arc: true
      skill_binding: "my-builder"       # Links to your builder skill
      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/components/"]
        keywords: ["ui", "component", "my-library"]
        always: false
```

---

## 3. Builder Frontmatter Contract

Khối YAML `builder-protocol` là phần cốt lõi của protocol. Nó khai báo skill là gì và có thể làm gì.

### Schema

```yaml
builder-protocol:
  library: string           # BẮT BUỘC. Định danh design system từ design-system-discovery.
  mcp_server: string        # BẮT BUỘC. Khoá MCP server — phải khớp với khoá trong .mcp.json.
  capabilities:             # BẮT BUỘC. Ánh xạ capability ngữ nghĩa tới tên tool MCP.
    search: string          # Tool tìm kiếm component bằng ngôn ngữ tự nhiên (BẮT BUỘC)
    list: string            # Tool duyệt component theo danh mục (BẮT BUỘC)
    details: string         # Tool lấy mã nguồn của một component (BẮT BUỘC)
    bundle: string          # Tool cài đặt hàng loạt nhiều component (TUỲ CHỌN)
    templates: string       # Tool duyệt template trang (TUỲ CHỌN, thường là PRO)
    template_files: string  # Tool cài đặt toàn bộ template trang (TUỲ CHỌN, thường là PRO)
  conventions: string       # BẮT BUỘC. Đường dẫn tới file conventions, tương đối với thư mục skill.
```

### Giá trị `library`

Trường `library` phải khớp với định danh do `discoverDesignSystem()` trả về. Các giá trị đã biết:

| Thư viện | Giá trị `library` |
|----------|-------------------|
| UntitledUI | `untitled_ui` |
| shadcn/ui | `shadcn_ui` |
| Radix UI | `radix_ui` |
| Tuỳ chỉnh/Không xác định | `custom` |

Với thư viện tuỳ chỉnh/không xác định, dùng `custom`. Protocol sẽ khớp qua heuristic của MCP server.

### `capabilities` bắt buộc và tuỳ chọn

| Capability | Bắt buộc | Mục đích |
|------------|----------|----------|
| `search` | CÓ | Tìm kiếm component bằng ngôn ngữ tự nhiên --- dùng bởi devise và design-sync Phase 1.5 |
| `list` | KHÔNG | Duyệt component theo danh mục --- dùng bởi workflow duyệt của strive worker |
| `details` | CÓ | Lấy mã nguồn component --- dùng bởi triển khai strive và design-sync Phase 2 |
| `bundle` | KHÔNG | Cài đặt hàng loạt nhiều component --- dùng bởi design-sync Phase 2 |
| `templates` | KHÔNG | Template trang/màn hình --- dùng bởi design-sync Phase 1.5 |
| `template_files` | KHÔNG | File tài nguyên template --- dùng bởi design-sync Phase 2 cài đặt toàn bộ trang |

**Builder khả dụng tối thiểu**: chỉ cần `search` + `details`. Protocol suy giảm một cách nhẹ nhàng --- bỏ qua `bundle`, `templates`, và `template_files` sẽ vô hiệu hoá các tối ưu pipeline tương ứng nhưng không phá vỡ tích hợp.

---

## 4. Tham chiếu giao diện Capability

### `search` --- Tìm kiếm Component bằng ngôn ngữ tự nhiên

Tool chính để tìm component. Worker gọi tool này trước khi xây dựng từ đầu.

**Hành vi mong đợi**: nhận chuỗi truy vấn bằng ngôn ngữ tự nhiên, trả về danh sách component được xếp hạng với tên và mô tả.

**Mẫu sử dụng trong worker**:
```
1. search(query) → matches
2. IF matches found AND score > threshold → proceed to details
3. IF no match → build from scratch using conventions
```

### `list` --- Duyệt theo danh mục

Dùng khi worker cần khám phá những gì có sẵn mà không có truy vấn cụ thể.

**Hành vi mong đợi**: nhận bộ lọc danh mục tuỳ chọn, trả về danh sách component phân trang.

**Khi nào dùng**: triển khai toàn trang khi worker cần khảo sát các khối xây dựng có sẵn.

### `details` --- Cài đặt mã nguồn Component

Tool cài đặt. Worker gọi tool này để lấy toàn bộ mã nguồn của component.

**Hành vi mong đợi**: nhận tên/định danh component, trả về mã nguồn + import + dependency.

**Khi gặp lỗi xác thực (component PRO)**: Rune chuyển sang triển khai Tailwind theo hướng dẫn conventions.

### `bundle` --- Cài đặt Component hàng loạt

Phiên bản hàng loạt của `details`. Giảm số lượt gọi MCP cho triển khai cấp trang.

**Hành vi mong đợi**: nhận mảng tên component, trả về toàn bộ mã nguồn trong một lần gọi.

**Khi nào dùng**: design-sync Phase 2 khi cần nhiều component cho một phần trang.

### `templates` --- Duyệt template trang

Liệt kê các template toàn trang có sẵn. Thường là tính năng cấp PRO.

**Hành vi mong đợi**: trả về danh sách định danh và mô tả template.

**Khi nào dùng**: design-sync Phase 1.5 --- kiểm tra trước khi khớp component đơn lẻ (khớp cấp trang hiệu quả hơn ghép component riêng lẻ).

### `template_files` --- Cài đặt toàn bộ template trang

Cài đặt template trang hoàn chỉnh với tất cả file component.

**Hành vi mong đợi**: nhận định danh template, trả về tất cả file cần thiết cho trang.

**Khi nào dùng**: design-sync Phase 2 khi tìm thấy template trang khớp với độ tin cậy cao trong Phase 1.5.

---

## 5. Định dạng file Conventions

File conventions là kho kiến thức cho worker. Nó được:
- Tiêm vào prompt của worker khi builder đang hoạt động (cắt ngắn tại 2000 ký tự theo ranh giới dòng)
- Tải bởi design-system-compliance-reviewer làm quy tắc đánh giá bổ sung
- Dùng làm hướng dẫn dự phòng khi truy xuất component thất bại (cổng PRO, lỗi mạng)

### Cấu trúc khuyến nghị

```markdown
# [Library Name] Conventions

## Critical Rules

1. **Import pattern**: Always import from `@org/package`
   ```typescript
   import { Button } from "@org/package"
   ```

2. **File naming**: kebab-case only
   ```
   my-component.tsx    // correct
   MyComponent.tsx     // wrong
   ```

3. **Color tokens**: use semantic tokens, not raw values
   ```
   bg-brand-500       // correct
   bg-blue-500        // wrong (raw Tailwind)
   ```

## Anti-Patterns

- Do NOT mix library components with custom HTML for the same UI primitive
- Do NOT override tokens with inline styles
- Do NOT import component styles — use the token system

## Fallback Strategy

If component retrieval fails:
1. Use the library's base primitives (Button, Input, etc.) with token styles
2. Build with Tailwind + token classes only
3. Never use raw CSS values
```

### Giới hạn kích thước

**Giữ file conventions dưới ~150 dòng.** Bộ tiêm cắt ngắn tại 2000 ký tự (ranh giới dòng gần nhất). Đặt các quy tắc quan trọng lên đầu. Chuyển tài liệu API chi tiết sang file tham chiếu riêng và tải theo yêu cầu.

---

## 6. Kiểm tra tích hợp Builder

### Bước 1: Xác thực Frontmatter

```bash
# Read your skill's frontmatter
cat .claude/skills/my-builder/SKILL.md | head -30
```

Kiểm tra `builder-protocol` có `library`, `mcp_server`, `capabilities.search`, `capabilities.details`, và `conventions`.

### Bước 2: Xác thực cấu hình Talisman

```
/rune:talisman audit
```

Audit kiểm tra:
- `server_name` khớp với một khoá trong `.mcp.json`
- `skill_binding` trỏ tới một skill đã cài đặt
- Ít nhất một cờ `phases` là `true`
- Trigger có ít nhất một điều kiện

**Kiểm tra đồng bộ builder skill** (kiểm tra lệch 3 thành phần): `/rune:talisman audit` cũng xác thực rằng ba thành phần protocol đang đồng bộ:
1. Mọi `skill_binding` trong talisman tham chiếu tới một skill đã cài đặt trong `.claude/skills/` hoặc plugin
2. Mỗi skill được tham chiếu có frontmatter `builder-protocol:`
3. Đường dẫn `conventions:` trong frontmatter đó tồn tại tương đối với thư mục gốc của skill

Nếu bất kỳ thành phần nào trong ba thành phần trên không đồng bộ, audit phát ra cảnh báo thay vì thất bại âm thầm tại thời điểm chạy.

### Bước 3: Xác minh MCP Server

```bash
claude mcp list
```

Xác nhận server của bạn xuất hiện và trạng thái là đã kết nối.

### Bước 4: Chạy Design System Discovery

Dùng `/rune:devise` trên một tác vụ nhỏ có tham chiếu tới thư viện component. Kiểm tra frontmatter của plan xem có section `ui_builder` không:

```yaml
ui_builder:
  builder_skill: my-builder
  builder_mcp: my-library
  conventions: references/conventions.md
  capabilities:
    search: my_search_tool
    details: my_get_tool
    bundle: my_bundle_tool
```

Nếu section này có mặt, tự động phát hiện đã thành công.

### Bước 5: Chạy Worker Task

```
/rune:strive "Add a settings page with form fields"
```

Trong đầu ra worker, tìm:

```
## Available MCP Tools (My Library)

**Search**: Use `my_search_tool` to find components by description.
**Details**: Use `my_get_tool` to install a component's full source code.

Conventions: kebab-case files, @org/package imports, semantic tokens.
```

Nếu khối này xuất hiện trong ngữ cảnh worker, tích hợp đang hoạt động.

### Bước 6: Kiểm tra Compliance Reviewer

Chạy `/rune:appraise` trên một file sử dụng thư viện của bạn. Compliance reviewer sẽ phát ra các phát hiện `DSYS-BLD-*` nếu phát hiện vi phạm convention.

---

## 7. Ví dụ

### Ví dụ A: UntitledUI (Tích hợp sẵn)

UntitledUI là bản triển khai tham chiếu. Rune đi kèm skill `untitledui-mcp` tích hợp sẵn --- không cần tạo skill ở cấp dự án.

**Thiết lập:**
```bash
# Free + OAuth (recommended — auto-handles login flow):
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp

# PRO with API key (set UNTITLEDUI_ACCESS_TOKEN in your shell profile):
export UNTITLEDUI_ACCESS_TOKEN="your-api-key-here"
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp \
  --header "Authorization: Bearer $UNTITLEDUI_ACCESS_TOKEN"
```

> **Các cấp truy cập**: Khi `UNTITLEDUI_ACCESS_TOKEN` được đặt, agent có quyền PRO (tất cả component,
> template trang, tài nguyên chia sẻ). Nếu không, agent dùng cấp miễn phí hoặc chuyển sang Tailwind + conventions.

**Cấu hình talisman (`.rune/talisman.yml`):**
```yaml
integrations:
  mcp_tools:
    untitledui:
      server_name: "untitledui"
      tools:
        - name: "search_components"
          category: "search"
        - name: "list_components"
          category: "search"
        - name: "get_component"
          category: "details"
        - name: "get_component_bundle"
          category: "details"
        - name: "get_page_templates"
          category: "search"
        - name: "get_page_template_files"
          category: "details"
      phases:
        devise: true
        strive: true
        forge: true
        appraise: false
        audit: false
        arc: true
      skill_binding: "untitledui-mcp"    # Built-in plugin skill
      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/components/", "src/pages/"]
        keywords: ["frontend", "ui", "component", "design", "untitledui"]
        always: false
      metadata:
        library_name: "UntitledUI"
        homepage: "https://www.untitledui.com"
        access_token_env: "UNTITLEDUI_ACCESS_TOKEN"
```

Skill `untitledui-mcp` tích hợp sẵn cung cấp:
- 6 định nghĩa MCP tool với chiến lược tìm kiếm
- Convention React Aria (tiền tố import Aria*)
- Quy tắc màu ngữ nghĩa Tailwind v4.1
- Quy ước đặt tên file kebab-case
- Yêu cầu thuộc tính data-icon
- Xử lý dự phòng Free/PRO

> **Ghi đè cấp dự án**: tạo `.claude/skills/untitledui-builder/SKILL.md` với convention riêng cho dự án và đặt `skill_binding: "untitledui-builder"`. Skill cấp dự án được ưu tiên hơn skill plugin.

---

### Ví dụ B: shadcn/ui

shadcn/ui không cung cấp MCP server HTTP chính thức. Nếu có MCP cộng đồng hoặc MCP registry `21st.dev`, hãy đăng ký và tạo builder skill cấp dự án.

**`.mcp.json`:**
```json
{
  "mcpServers": {
    "shadcn": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@your-org/shadcn-mcp@1.0.0"]
    }
  }
}
```

**`.claude/skills/shadcn-builder/SKILL.md`:**
```yaml
---
name: shadcn-builder
description: |
  shadcn/ui component library integration for Rune workflows.
  Provides tools for browsing and installing shadcn/ui components.
  Use when agents build UI with shadcn/ui components.
  Trigger keywords: shadcn, shadcn/ui, radix, @shadcn.
user-invocable: false
builder-protocol:
  library: shadcn_ui
  mcp_server: shadcn
  capabilities:
    search: shadcn_search
    list: shadcn_list
    details: shadcn_install
    bundle: shadcn_install_many
  conventions: references/conventions.md
---

# shadcn/ui Integration

Background knowledge for Rune agents working with shadcn/ui.

## Component Model

shadcn/ui components are installed into your project — they are owned code, not a dependency.
Install via the CLI or MCP tool, then modify freely.

## Core Conventions

1. Import from local path: `import { Button } from "@/components/ui/button"`
2. Use `cn()` for conditional classes
3. Tailwind CSS v3/v4 variable-based tokens (`--background`, `--foreground`)
4. Never import directly from `@radix-ui/*` — use the shadcn wrapper
```

**`.claude/skills/shadcn-builder/references/conventions.md`:**
```markdown
# shadcn/ui Conventions

## Imports
- Always: `import { Button } from "@/components/ui/button"`
- Never: `import * as RadixDialog from "@radix-ui/react-dialog"`

## Styling
- Use `cn()` utility for conditional classes: `cn("base-class", { "active": isActive })`
- CSS variables: `bg-background`, `text-foreground`, `border-border`
- Never raw Tailwind color values: `bg-gray-100` → use `bg-muted`

## File Structure
- Components live in `src/components/ui/` after install
- Custom variants go in the same file, not a separate file
```

**Cấu hình talisman:**
```yaml
integrations:
  mcp_tools:
    shadcn:
      server_name: "shadcn"
      tools:
        - name: "shadcn_search"
          category: "search"
        - name: "shadcn_list"
          category: "search"
        - name: "shadcn_install"
          category: "details"
        - name: "shadcn_install_many"
          category: "details"
      phases:
        devise: true
        strive: true
        forge: false
        appraise: false
        audit: false
        arc: true
      skill_binding: "shadcn-builder"
      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/", "app/"]
        keywords: ["shadcn", "ui", "component", "radix"]
        always: false
```

---

### Ví dụ C: Thư viện component nội bộ tuỳ chỉnh

Cho một design system nội bộ công ty với MCP server riêng:

**`.mcp.json`:**
```json
{
  "mcpServers": {
    "acme-design": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@acme/design-system-mcp@2.1.0"]
    }
  }
}
```

**`.claude/skills/acme-builder/SKILL.md`:**
```yaml
---
name: acme-builder
description: |
  ACME company design system MCP integration.
  Provides search and install for ACME components (800+ components, 3 tiers).
  Use when agents build UI with ACME Design System components.
  Trigger keywords: acme, acme-ds, design-system, acme component.
user-invocable: false
builder-protocol:
  library: custom
  mcp_server: acme-design
  capabilities:
    search: acme_search_components
    list: acme_list_category
    details: acme_get_component
    bundle: acme_get_bundle
  conventions: references/conventions.md
---

# ACME Design System Integration

...conventions and workflow instructions...
```

> **Lưu ý về `library: custom`**: Khi `library` là `custom` hoặc không xác định, `discoverUIBuilder()` không thể khớp chỉ qua đầu ra `discoverDesignSystem()`. Thay vào đó, nó quét `.mcp.json` tìm server có tên tool giống thư viện component (heuristic: tool chứa `search`, `get_component`, hoặc `install`). Đảm bảo tên tool của server có ít nhất một trong các pattern này, hoặc đặt `always: true` trong trigger để ép kích hoạt.

---

## 8. Xử lý sự cố

### Builder không được phát hiện

| Triệu chứng | Nguyên nhân có thể | Cách sửa |
|-------------|---------------------|----------|
| Không có section `ui_builder` trong frontmatter plan | `discoverUIBuilder()` trả về null | Kiểm tra MCP server đã đăng ký + skill có frontmatter `builder-protocol` |
| Worker không đề cập component thư viện | Builder phát hiện nhưng trigger không kích hoạt | Kiểm tra `trigger.extensions`, `trigger.paths`, `trigger.keywords` |
| `skill_binding` không trỏ tới gì | Skill chưa cài hoặc sai tên | Xác minh skill tồn tại trong `.claude/skills/` hoặc plugin; kiểm tra chính tả `skill_binding` |
| `library: custom` không tự động phát hiện | Không khớp heuristic trên tên tool | Đặt `trigger.always: true` hoặc thêm `search`/`get_component` vào tên tool |

### Worker bỏ qua builder MCP

Worker thấy khối ngữ cảnh MCP nhưng chuyển sang Tailwind chung:

1. Kiểm tra tool `capabilities.search` có gọi được không: MCP server có phản hồi không?
2. Kiểm tra cổng PRO: worker chuyển dự phòng khi `get_component` trả về lỗi xác thực
3. Kiểm tra file conventions: worker có thể hiểu sai API nếu conventions không chính xác

```bash
# Verify MCP server is connected
claude mcp list

# Check if talisman resolves the integration
/rune:talisman status
```

### Vi phạm convention trong đánh giá

`design-system-compliance-reviewer` tạo phát hiện `DSYS-BLD-*` chỉ khi:
1. Builder đang hoạt động (phát hiện builder profile)
2. Reviewer tải file conventions từ `builder-protocol.conventions`
3. File thay đổi nằm trong phạm vi đánh giá

Nếu thiếu phát hiện `DSYS-BLD-*` khi mong đợi:
- Xác minh đường dẫn `builder-protocol.conventions` chính xác (tương đối với thư mục skill)
- Kiểm tra file conventions dưới 2000 ký tự hoặc quy tắc quan trọng nằm trong 150 dòng đầu
- Xác minh file đang đánh giá khớp với extension/đường dẫn trigger

### Convention không được áp dụng (Thất bại âm thầm)

Nếu convention builder không được tiêm vào ngữ cảnh worker mặc dù builder đã phát hiện:

**Nguyên nhân gốc:**

| Nguyên nhân | Triệu chứng |
|-------------|-------------|
| `skill_binding` trỏ tới skill không tồn tại | Builder phát hiện nhưng khối convention vắng mặt trong prompt worker |
| Skill tồn tại nhưng thiếu frontmatter `builder-protocol:` | `discoverUIBuilder()` tìm thấy skill nhưng không đọc được capability |
| Đường dẫn `conventions:` sai | Builder hoạt động, không có văn bản convention trong ngữ cảnh worker |

**Quan trọng**: `conventions:` là tương đối với **thư mục skill**, không phải gốc repo. `.claude/skills/my-builder/references/conventions.md` → đặt `conventions: references/conventions.md`, không phải `.claude/skills/my-builder/references/conventions.md`.

**Các bước debug:**

```bash
# 1. Verify the skill exists
ls .claude/skills/{skill_name}/

# 2. Verify builder-protocol frontmatter is present
grep -n "builder-protocol:" .claude/skills/{skill_name}/SKILL.md

# 3. Verify the conventions file path (relative to skill dir)
ls .claude/skills/{skill_name}/references/{path}
```

Sau đó chạy `/rune:talisman audit` --- nó sẽ đánh dấu skill thiếu và đường dẫn conventions bị hỏng.

### Lưu ý chuyển đổi TrueDigital

Nếu bạn có skill cấp dự án (`untitledui-builder`, `frontend-figma-sync`, `frontend-workflow`) từ thiết lập trước phiên bản 1.133.0, chúng tiếp tục hoạt động như ghi đè cấp dự án --- skill cấp dự án được ưu tiên hơn skill plugin. Bạn có thể:

1. **Giữ nguyên** --- chúng ghi đè skill plugin tích hợp sẵn với các tuỳ chỉnh của bạn
2. **Chuyển đổi dần** --- chuyển convention vào pattern skill tích hợp sẵn và xoá ghi đè dự án khi đã hấp thụ xong

Để dùng skill dự án làm builder, đặt `skill_binding` trong talisman thành tên skill dự án:
```yaml
skill_binding: "untitledui-builder"   # uses .claude/skills/untitledui-builder/ (project override)
# vs.
skill_binding: "untitledui-mcp"       # uses plugins/rune/skills/untitledui-mcp/ (built-in)
```

---

## 9. Nâng cấp từ MCP Integration Level 2

Level 2 (cấu hình `integrations.mcp_tools` trong talisman) đã xử lý định tuyến tool và kiểm soát phase. UI Builder Protocol bổ sung khả năng Level 3 phía trên.

### Level 2 mang lại cho bạn

- Kích hoạt tool theo phase (tool chỉ hoạt động trong các phase đã cấu hình)
- Điều kiện trigger (chỉ kích hoạt khi ngữ cảnh khớp)
- Danh mục tool (worker hiểu mục đích tool)
- Tiêm file quy tắc (quy tắc coding riêng dự án)

### Level 3 bổ sung thêm (UI Builder Protocol)

- Tự động phát hiện `discoverUIBuilder()` từ design-system-discovery
- Frontmatter `builder-protocol` được đọc bởi pipeline design-sync
- Phase 1.5 Component Match trong design-sync (mã tham chiếu → tìm kiếm component thư viện)
- Section `ui_builder` trong frontmatter plan (capability có sẵn cho tất cả phase)
- Phát hiện `DSYS-BLD-*` từ compliance reviewer

### Lộ trình nâng cấp

**Trước (chỉ Level 2):**
```yaml
integrations:
  mcp_tools:
    untitledui:
      server_name: "untitledui"
      tools: [...]
      phases: [...]
      skill_binding: "untitledui-builder"   # project skill without builder-protocol
      trigger: [...]
```

**Sau (Level 3 / Builder Protocol):**

1. Thêm frontmatter `builder-protocol` vào skill:
```yaml
# In .claude/skills/untitledui-builder/SKILL.md frontmatter:
builder-protocol:
  library: untitled_ui
  mcp_server: untitledui
  capabilities:
    search: search_components
    list: list_components
    details: get_component
    bundle: get_component_bundle
    templates: get_page_templates
    template_files: get_page_template_files
  conventions: references/agent-conventions.md
```

2. Tạo/cập nhật file tham chiếu conventions tại `references/agent-conventions.md`

3. Chạy `/rune:talisman audit` để xác thực

Không cần thay đổi cấu hình talisman --- `skill_binding` đã liên kết skill của bạn. Khi skill có frontmatter `builder-protocol`, `discoverUIBuilder()` tự động nhận diện.

### Cách khác: Chuyển sang Skill tích hợp sẵn

Nếu bạn dùng UntitledUI và không cần tuỳ chỉnh riêng dự án, chuyển sang skill plugin tích hợp sẵn `untitledui-mcp`:

```yaml
# Change skill_binding in talisman:
skill_binding: "untitledui-mcp"    # was: "untitledui-builder"
```

Skill tích hợp sẵn có hỗ trợ `builder-protocol` đầy đủ và được cập nhật theo convention AGENT.md chính thức của UntitledUI.

---

## Tham chiếu nhanh

### Builder Protocol Frontmatter (đầy đủ)

```yaml
builder-protocol:
  library: untitled_ui             # design-system identifier
  mcp_server: untitledui           # .mcp.json server key
  capabilities:
    search: search_components      # natural language search
    list: list_components          # category browse
    details: get_component         # single component install
    bundle: get_component_bundle   # batch install (optional)
    templates: get_page_templates  # page templates (optional)
    template_files: get_page_template_files  # template install (optional)
  conventions: references/agent-conventions.md
```

### Các điểm tích hợp Pipeline

| Phase | Điều gì xảy ra khi builder hoạt động |
|-------|--------------------------------------|
| `/rune:devise` Phase 0.5 | `discoverUIBuilder()` tìm builder skill và capability |
| `/rune:devise` Phase 2 | Frontmatter plan nhận section `ui_builder` + section "Component Strategy" trong plan |
| `/rune:strive` Phase 1.5 | Worker được tiêm khối workflow builder + convention |
| `/rune:design-sync` Phase 1.5 | Component Match: mã tham chiếu → tìm trong thư viện → VSM được chú thích |
| `/rune:design-sync` Phase 2 | Worker import component thực từ thư viện qua VSM được chú thích |
| `/rune:appraise` | Compliance reviewer tải convention, tạo phát hiện `DSYS-BLD-*` |
| `/rune:arc` | Tất cả các bước trên, xuyên suốt các phase pipeline |

### Giá trị Library đã biết

| Thư viện | `library` | Skill tích hợp sẵn mặc định |
|----------|----------|------------------------------|
| UntitledUI | `untitled_ui` | `untitledui-mcp` (plugin tích hợp sẵn) |
| shadcn/ui | `shadcn_ui` | Không có (tạo skill cấp dự án) |
| Radix UI | `radix_ui` | Không có (tạo skill cấp dự án) |
| Tuỳ chỉnh | `custom` | Không có (tạo skill cấp dự án) |
