# Rune MCP Integration Spec --- Hướng dẫn cho nhà phát triển

> Tích hợp các MCP tool bên thứ ba vào workflow Rune với cấu hình talisman khai báo.

## Tổng quan

Rune MCP Integration Framework thu hẹp khoảng cách giữa việc có sẵn MCP tool và việc sử dụng tool phù hợp với workflow. Khi bạn thêm một MCP server vào `.mcp.json`, Claude có quyền truy cập các tool --- nhưng các agent workflow của Rune (reviewer, worker, researcher) không biết _khi nào_ hay _cách_ sử dụng chúng. Một tool tìm kiếm thư viện component không có ích gì cho security reviewer; một tool sinh code lại phản tác dụng trong quá trình audit chỉ-đọc.

Framework giải quyết vấn đề này thông qua **cấu hình talisman khai báo**. Bạn khai báo các MCP tool, phân loại chúng, định nghĩa phase workflow nào nên kích hoạt chúng, và chỉ định điều kiện trigger (phần mở rộng file, đường dẫn, từ khoá). Tại thời điểm chạy, bộ giải quyết tích hợp đọc cấu hình này, đánh giá trigger theo ngữ cảnh hiện tại, và tiêm khối ngữ cảnh MCP có cấu trúc vào prompt agent phù hợp. Không cần thay đổi code plugin.

Hướng dẫn này đi qua ba cấp độ tích hợp, tham chiếu schema đầy đủ, logic đánh giá trigger, và một ví dụ hoàn chỉnh.

## 3 cấp độ tích hợp

### Level 1: Cơ bản (chỉ `.mcp.json`)

Ở cấp độ này, bạn đăng ký MCP server và các tool trở nên có sẵn cho Claude. Tuy nhiên, các agent workflow Rune không nhận được hướng dẫn nào về khi nào hay cách sử dụng chúng. Tool có thể được gọi không nhất quán --- hoặc không được gọi --- tuỳ thuộc vào cách agent diễn giải tác vụ.

**.mcp.json:**

```json
{
  "mcpServers": {
    "untitledui": {
      "type": "http",
      "url": "https://www.untitledui.com/react/api/mcp"
    }
  }
}
```

> **Lưu ý**: UntitledUI cung cấp MCP server HTTP chính thức tại `https://www.untitledui.com/react/api/mcp`.
> Xác thực: OAuth 2.1 với PKCE (đăng nhập tự động qua trình duyệt), biến môi trường `UNTITLEDUI_ACCESS_TOKEN`, hoặc không (chỉ component miễn phí).
> Để xác thực bằng API key, đặt `export UNTITLEDUI_ACCESS_TOKEN="your-api-key"` và thêm `"headers": { "Authorization": "Bearer ${UNTITLEDUI_ACCESS_TOKEN}" }`.
> MCP chính thức cung cấp 6 tool: `search_components`, `list_components`, `get_component`, `get_component_bundle`, `get_page_templates` (PRO), `get_page_template_files` (PRO).

**Bạn nhận được:** Tool xuất hiện trong danh sách tool của Claude. Agent _có thể_ gọi chúng nếu quyết định làm vậy.

**Bạn thiếu:** Không có định tuyến phase, không kích hoạt dựa trên trigger, không tiêm quy tắc, không có ngữ cảnh skill đi kèm. Agent có thể dùng tool tìm kiếm component trong quá trình review code (lãng phí token) hoặc bỏ qua chúng trong quá trình triển khai (bỏ lỡ cơ hội).

### Level 2: Talisman (`+ phần integrations`)

Thêm section `integrations.mcp_tools` vào `talisman.yml`. Điều này mang lại cho orchestrator của Rune ba khả năng quan trọng:

1. **Định tuyến phase** --- tool chỉ kích hoạt trong các phase workflow được chỉ định (devise, strive, forge, appraise, audit, arc)
2. **Điều kiện trigger** --- tool chỉ kích hoạt khi ngữ cảnh tác vụ khớp (phần mở rộng file, đường dẫn, từ khoá)
3. **Tiêm quy tắc** --- file quy tắc coding được tiêm vào prompt agent khi tích hợp đang hoạt động

**talisman.yml (cấp dự án `.rune/talisman.yml`):**

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

      skill_binding: "untitledui-mcp"

      rules: []

      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/components/", "src/pages/"]
        keywords: ["frontend", "ui", "component", "untitledui"]
        always: false
```

**Bạn nhận được:** Kích hoạt tool theo phase. Worker thấy "Use `search_components` to find UntitledUI components" trong prompt chỉ khi triển khai file `.tsx` trong `src/components/`. Reviewer không bao giờ thấy tool ghi nặng. Convention từ skill đi kèm được tiêm để đảm bảo sử dụng nhất quán.

### Level 3: Đầy đủ (`+ skill + rules + manifest`)

Cho tích hợp sâu, thêm skill đi kèm và metadata phát hiện. Điều này cung cấp tiêm kiến thức liên tục, tự động phát hiện, và tài liệu phong phú hơn.

**Cấu trúc thư mục:**

```
# Built-in Rune plugin skill (no project-level skill needed):
plugins/rune/skills/untitledui-mcp/
  SKILL.md                      # Builder-protocol skill with conventions
  references/
    agent-conventions.md        # UntitledUI code conventions (from AGENT.md)
    mcp-tools.md                # Detailed MCP tool documentation

# Optional project-level override:
.claude/
  skills/
    untitledui-builder/         # Custom project-specific conventions (overrides built-in)
      SKILL.md
  rules/
    untitledui-conventions.md   # Project-specific coding rules
  talisman.yml            # Integration config
.mcp.json                 # MCP server registration
```

**Cấu hình talisman.yml đầy đủ (bổ sung Level 3):**

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

      skill_binding: "untitledui-mcp"

      rules:
        - ".claude/rules/untitledui-button-icons.md"

      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["dashboard/src/", "admin/src/"]
        keywords: ["frontend", "ui", "component", "design"]
        always: false

      metadata:
        library_name: "UntitledUI PRO"
        component_count: 768
        version: "1.9.1"
        homepage: "https://untitledui.com"
        access_token_env: "UNTITLEDUI_ACCESS_TOKEN"
```

**Bạn nhận được:** Tất cả từ Level 2, cộng thêm: skill đi kèm được tự động tải khi tích hợp kích hoạt (cung cấp kiến thức component liên tục), metadata cho phép phát hiện qua `/rune:talisman audit`, và quy tắc đảm bảo pattern coding nhất quán trên tất cả agent.

## Hướng dẫn bắt đầu nhanh

Làm theo các bước sau để thêm tích hợp Level 2 cho bất kỳ MCP tool nào:

### Bước 1: Đăng ký MCP Server

Thêm MCP server vào `.mcp.json` (gốc dự án hoặc `~/.claude/.mcp.json` cho toàn cục):

```json
{
  "mcpServers": {
    "my-tool": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@my-org/mcp-server@1.0.0"]
    }
  }
}
```

### Bước 2: Thêm cấu hình tích hợp

Thêm `integrations.mcp_tools` vào `.rune/talisman.yml`:

```yaml
integrations:
  mcp_tools:
    my-tool:
      server_name: "my-tool"
      tools:
        - name: "my_tool_search"
          category: "search"
        - name: "my_tool_generate"
          category: "generate"
      phases:
        devise: true
        strive: true
        forge: false
        appraise: false
        audit: false
        arc: true
      trigger:
        extensions: [".ts", ".tsx"]
        paths: ["src/"]
        keywords: ["widget"]
        always: false
```

### Bước 3: Xác minh cấu hình

Chạy talisman audit để xác thực:

```
/rune:talisman audit
```

Audit kiểm tra:
- `server_name` khớp với một khoá trong `.mcp.json`
- Tất cả tên tool là định danh hợp lệ
- Danh mục thuộc tập được cho phép
- Ít nhất một phase được bật
- Trigger có ít nhất một điều kiện (hoặc `always: true`)
- File quy tắc tồn tại trên đĩa (nếu chỉ định)
- Skill `skill_binding` tồn tại (nếu chỉ định)

### Bước 4: Sử dụng trong bất kỳ workflow nào

Không cần thay đổi workflow. Chạy bất kỳ lệnh Rune nào và tool khớp sẽ tự kích hoạt:

```
/rune:strive "Build the dashboard settings page"
```

Nếu tác vụ chạm vào file `.tsx` trong `src/`, worker nhận khối ngữ cảnh MCP với hướng dẫn sử dụng tool.

## Tham chiếu Schema

### `integrations.mcp_tools.{namespace}`

Khoá namespace (ví dụ: `untitledui`) là một định danh logic. Nó nên khớp hoặc tương ứng chặt chẽ với khoá MCP server trong `.mcp.json`.

| Trường | Kiểu | Bắt buộc | Mô tả |
|--------|------|----------|-------|
| `server_name` | string | Có | Phải khớp với khoá trong `.mcp.json`. Xác thực server tồn tại khi audit. |
| `tools` | array | Có | Khai báo tool. Mỗi mục có `name` (string) và `category` (string). |
| `phases` | object | Có | Định tuyến phase workflow. Khoá: `devise`, `strive`, `forge`, `appraise`, `audit`, `arc`. Giá trị: boolean. |
| `skill_binding` | string | Không | Tên skill đi kèm. Phải tồn tại trong `.claude/skills/`. Tự động tải khi tích hợp kích hoạt. |
| `rules` | array | Không | Đường dẫn tới file quy tắc (tương đối với gốc dự án). Tiêm vào prompt agent khi hoạt động. |
| `trigger` | object | Có | Điều kiện kích hoạt. Xem Hệ thống Trigger bên dưới. |
| `metadata` | object | Không | Metadata phát hiện (tên thư viện, phiên bản, trang chủ). Chỉ mang tính thông tin. Mở rộng --- các khoá bổ sung được giữ nguyên nhưng không được bộ giải quyết sử dụng. |

### Trường Metadata

Các khoá metadata đã biết (tất cả tuỳ chọn):

| Khoá | Kiểu | Mô tả |
|------|------|-------|
| `library_name` | string | Tên thư viện dễ đọc (ví dụ: "UntitledUI PRO"). Dùng làm tên hiển thị trong prompt agent. |
| `component_count` | number | Tổng số component. Thông tin cho `/rune:talisman status`. |
| `version` | string | Phiên bản thư viện (ví dụ: "1.9.1"). Thông tin. |
| `homepage` | string | URL trang chủ thư viện. Thông tin. |

Các khoá bổ sung được cho phép và truyền qua trong đối tượng tích hợp, nhưng bộ giải quyết và trình xây dựng ngữ cảnh chỉ dùng `library_name` để hiển thị.

### Khai báo Tool

Mỗi mục trong mảng `tools` khai báo một MCP tool đơn lẻ với danh mục ngữ nghĩa:

```yaml
tools:
  - name: "search_components"    # Must match the MCP tool name exactly
    category: "search"           # Semantic category (see table below)
```

### Danh mục Tool

Danh mục cung cấp ý nghĩa ngữ nghĩa giúp agent hiểu mục đích tool mà không cần đọc tài liệu:

| Danh mục | Mục đích | Tool ví dụ |
|----------|----------|------------|
| `search` | Tìm/khám phá tài nguyên | `search_components`, `list_components`, `get_page_templates` |
| `details` | Lấy thông tin chi tiết về một tài nguyên cụ thể | `get_component`, `get_component_bundle`, `figma_inspect_node` |
| `compose` | Lên kế hoạch bố cục hoặc tổ hợp nhiều tài nguyên | `get_page_template_files` |
| `generate` | Sinh code hoặc artifact | `figma_to_react` |
| `suggest` | Gợi ý dựa trên AI | (tool tuỳ chỉnh) |
| `validate` | Kiểm tra, xác minh, hoặc lint tài nguyên | `storybook_validate` |

Danh mục ảnh hưởng đến cách tiêm prompt. Ví dụ, tool `search` nhận cụm từ "Use X to find...", trong khi tool `generate` nhận "Use X to produce...". Worker nhận tất cả danh mục hoạt động; reviewer chỉ nhận danh mục `search` và `details` (chỉ đọc).

### Hệ thống Trigger

Trigger xác định _khi nào_ tích hợp kích hoạt. Logic đánh giá như sau:

```
activation = (extension_match OR path_match OR keyword_match) AND phase_match
```

Nếu `always: true` được đặt, kiểm tra trigger bị bỏ qua --- chỉ định tuyến phase được áp dụng.

| Trường | Kiểu | Mặc định | Mô tả |
|--------|------|----------|-------|
| `extensions` | string[] | `[]` | Phần mở rộng file cần khớp (ví dụ: `[".tsx", ".ts"]`). So sánh với file thay đổi (review/audit) hoặc file tham chiếu tác vụ (strive/devise). |
| `paths` | string[] | `[]` | Tiền tố đường dẫn cần khớp (ví dụ: `["src/api/", "lib/"]`). Bất kỳ file thay đổi/tham chiếu nào dưới các đường dẫn này sẽ kích hoạt. |
| `keywords` | string[] | `[]` | Từ khoá mô tả tác vụ (ví dụ: `["frontend", "ui"]`). Khớp không phân biệt hoa thường với mô tả tác vụ hoặc nội dung plan của người dùng. |
| `always` | boolean | `false` | Ghi đè: bỏ qua tất cả kiểm tra trigger. Dùng cho tool nên luôn có sẵn trong các phase đã cấu hình. |

**Ví dụ đánh giá:**

```yaml
# Activates when ANY .tsx/.ts file is changed AND current phase is strive
trigger:
  extensions: [".tsx", ".ts"]
  always: false

# Activates when files in src/api/ are changed OR task mentions "api"
trigger:
  paths: ["src/api/"]
  keywords: ["api", "endpoint"]
  always: false

# Always active in configured phases (use sparingly --- wastes tokens if irrelevant)
trigger:
  always: true
```

### Định nghĩa Phase

Phase ánh xạ tới các lệnh workflow Rune. Mỗi phase có vai trò agent và nhu cầu tool khác nhau:

| Phase | Lệnh Rune | Vai trò Agent | Danh mục Tool thường dùng |
|-------|-----------|---------------|--------------------------|
| `devise` | `/rune:devise` | Nghiên cứu, lập kế hoạch | `search`, `details`, `suggest` | *Lưu ý: `changedFiles` trống trong giai đoạn lập kế hoạch. Chỉ trigger `keywords` và `always: true` kích hoạt trong devise. Dùng `keywords` cùng `extensions`/`paths` để kích hoạt devise.* |
| `strive` | `/rune:strive` | Triển khai | `search`, `details`, `compose`, `generate` |
| `forge` | `/rune:forge` | Làm giàu plan | `search`, `details`, `suggest` |
| `appraise` | `/rune:appraise` | Đánh giá code (chỉ đọc) | `search`, `details` |
| `audit` | `/rune:audit` | Phân tích toàn bộ codebase | `search`, `details`, `validate` |
| `arc` | `/rune:arc` | Pipeline đầy đủ | Kế thừa cài đặt theo phase |

**Phase `arc`:** Khi `arc: true`, tích hợp duy trì hoạt động trong toàn bộ pipeline arc. Mỗi sub-phase trong arc tuân theo cài đặt phase riêng. Ví dụ, nếu `strive: true` và `appraise: false`, tích hợp kích hoạt trong giai đoạn làm việc của arc nhưng vô hiệu trong giai đoạn đánh giá.

## Chi tiết tích hợp Workflow

### Cách `/rune:strive` sử dụng tích hợp

Trong workflow strive, orchestrator giải quyết tích hợp MCP tại thời điểm tiêm prompt worker:

1. **`resolveMCPIntegrations("strive", { changedFiles, taskDescription })`** --- đọc `integrations.mcp_tools`, lọc các mục có `phases.strive: true`
2. **`evaluateTriggers(trigger, context)`** --- cho mỗi tích hợp, kiểm tra điều kiện trigger theo phạm vi file và từ khoá mô tả tác vụ
3. **`buildMCPContextBlock(activeIntegrations)`** --- xây dựng khối prompt có cấu trúc liệt kê tool hoạt động theo danh mục, kèm hướng dẫn sử dụng
4. **Tiêm vào prompt worker** --- khối ngữ cảnh được nối vào system prompt của mỗi worker, cùng với nội dung skill liên kết và file quy tắc

Worker nhận hướng dẫn như:

```
## Available MCP Tools (UntitledUI)

**Search**: Use `search_components` to find components by natural language description.
**Browse**: Use `list_components` to browse components by category.
**Details**: Use `get_component` to install a component's full source code.
**Bundle**: Use `get_component_bundle` to install multiple components at once.

Conventions: React Aria Aria* prefix, semantic colors only, kebab-case files.
```

### Cách `/rune:devise` sử dụng tích hợp

Agent nghiên cứu (lore-scholar, practice-seeker) nhận ngữ cảnh MCP trong Phase 1C nghiên cứu bên ngoài. Bộ giải quyết tích hợp lọc các mục có `phases.devise: true` và tiêm tham chiếu tool vào prompt agent nghiên cứu. Điều này cho phép researcher khám phá component có sẵn, khả năng API, hoặc tài nguyên thiết kế trong giai đoạn lập kế hoạch.

### Cách `/rune:forge` sử dụng tích hợp

Agent làm giàu forge nhận ngữ cảnh MCP khi đào sâu các section plan. Nếu một section plan bao gồm triển khai frontend và trigger khớp, agent forge có thể dùng tool `search` và `details` để làm giàu plan với gợi ý component cụ thể, tham chiếu API, hoặc design pattern.

### Cách `/rune:arc` sử dụng tích hợp

Pipeline arc kế thừa cài đặt tích hợp qua tất cả sub-phase. Khi `arc: true`, orchestrator đánh giá trigger một lần khi bắt đầu pipeline và truyền tích hợp hoạt động qua mỗi phase. Cài đặt phase riêng (`strive`, `appraise`, v.v.) vẫn kiểm soát kích hoạt trong mỗi sub-phase arc --- `arc: true` không ghi đè `appraise: false`.

## Thực hành tốt nhất

- **Bắt đầu với Level 2, nâng cấp lên Level 3 khi cần.** Hầu hết tích hợp hoạt động tốt chỉ với cấu hình talisman. Chỉ thêm skill đi kèm khi agent cần kiến thức domain liên tục ngoài mô tả tool.

- **Dùng `appraise: false` cho tool ghi nặng.** Agent review trong Roundtable Circle hoạt động dưới `enforce-readonly.sh` (SEC-001). Tool sinh hoặc sửa code chỉ nên hoạt động trong phase `strive` và `forge`.

- **Khớp đường dẫn trigger với cấu trúc dự án thực tế.** Dùng tiền tố đường dẫn tương ứng với thư mục thực. Đường dẫn quá rộng (ví dụ: `["src/"]`) có thể kích hoạt tích hợp cho tác vụ không liên quan.

- **Giữ file quy tắc ngắn gọn.** File quy tắc tiêm qua `rules:` được nối vào prompt agent. **File quy tắc bị cắt ngắn tại 2000 ký tự** (ranh giới dòng gần nhất) khi tiêm vào prompt agent. Giữ chúng ngắn gọn và tập trung vào pattern ngăn lỗi phổ biến (ví dụ: "always use UntitledUI Button instead of raw HTML buttons"). Tối đa 5 file quy tắc mỗi tích hợp.

- **Dùng từ khoá trigger cụ thể thay vì chung chung.** Từ khoá như `"code"` hay `"build"` khớp quá nhiều tác vụ. Ưu tiên thuật ngữ chuyên biệt domain như `"dashboard"`, `"component-library"`, `"figma"`.

- **Đặt `arc: true` để kế thừa cài đặt qua toàn bộ pipeline.** Nếu tích hợp nên hoạt động trong quá trình thực thi arc, bật `arc: true` cùng với các phase cụ thể. Arc tuân theo cài đặt phase riêng cho lọc sub-phase.

- **Ghim phiên bản MCP server.** Trong `.mcp.json`, ghim phiên bản package (ví dụ: `@untitledui/mcp-server@1.9.1`) để tránh thay đổi phá vỡ. An toàn chuỗi cung ứng áp dụng cho MCP server giống như với dependency npm.

- **Một namespace mỗi server.** Mỗi khoá `mcp_tools` nên tương ứng với đúng một MCP server. Không kết hợp tool từ nhiều server dưới một namespace.

## Anti-Pattern

- **Không đặt `always: true` cho tool chuyên biệt.** Điều này ép tích hợp hoạt động trên mọi tác vụ trong các phase đã cấu hình, lãng phí token trên ngữ cảnh không liên quan. Dành `always: true` cho tool nền tảng dùng trong hầu hết mọi tác vụ (ví dụ: design system toàn công ty).

- **Không liên kết tool ghi nặng với phase `appraise`.** Reviewer hoạt động dưới chế độ chỉ-đọc nghiêm ngặt. Tool thuộc danh mục `generate`, `compose`, hoặc `validate` (có side effect) nên giới hạn trong `strive` và `forge`.

- **Không tạo quy tắc ghi đè hướng dẫn CLAUDE.md.** File quy tắc bổ sung hành vi agent --- chúng không nên mâu thuẫn với CLAUDE.md cấp dự án hoặc cấp plugin. Nếu có xung đột, CLAUDE.md được ưu tiên.

- **Không dùng danh mục tool chồng chéo.** Nếu một tool vừa tìm kiếm vừa sinh, chọn mục đích chính. Tool được phân loại `search` nhận khung prompt hướng đọc; phân loại sai tool `generate` thành `search` làm agent nhầm lẫn về side effect.

- **Không bỏ qua xác thực `server_name`.** Luôn chạy `/rune:talisman audit` sau khi thêm hoặc sửa tích hợp. Lỗi đánh máy trong `server_name` âm thầm vô hiệu tích hợp (không lỗi, tool không bao giờ kích hoạt).

- **Không thêm metadata mà không có server.** Trường `metadata` mang tính thông tin. Nó không thay thế cho MCP server hoạt động trong `.mcp.json`. Metadata không có `server_name` hợp lệ qua được audit nhưng không có giá trị runtime.

## Ví dụ: Tích hợp UntitledUI

Hướng dẫn hoàn chỉnh tích hợp UntitledUI --- một thư viện component với hơn 768 component có thể truy cập qua MCP server chính thức.

### 1. Đăng ký MCP Server

Thêm vào `.mcp.json` (gốc dự án):

```json
{
  "mcpServers": {
    "untitledui": {
      "type": "http",
      "url": "https://www.untitledui.com/react/api/mcp"
    }
  }
}
```

> **Tuỳ chọn xác thực**:
> - **OAuth 2.1 với PKCE** (khuyến nghị): Đăng nhập tự động qua trình duyệt, không cần API key
> - **API Key**: Đặt `export UNTITLEDUI_ACCESS_TOKEN="your-api-key"`, sau đó thêm `"headers": { "Authorization": "Bearer ${UNTITLEDUI_ACCESS_TOKEN}" }`
> - **Không xác thực**: Chỉ component miễn phí (base UI, một số application component)
>
> Biến môi trường `UNTITLEDUI_ACCESS_TOKEN` kích hoạt quyền PRO (tất cả component, template trang, tài nguyên chia sẻ).

### 2. Thêm tích hợp Talisman

Thêm vào `.rune/talisman.yml`:

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

      skill_binding: "untitledui-mcp"

      rules:
        - ".claude/rules/untitledui-button-icons.md"

      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["dashboard/src/", "admin/src/"]
        keywords: ["frontend", "ui", "component", "design"]
        always: false

      metadata:
        library_name: "UntitledUI PRO"
        component_count: 768
        version: "1.9.1"
        homepage: "https://untitledui.com"
        access_token_env: "UNTITLEDUI_ACCESS_TOKEN"
```

### 3. Skill đi kèm (Tích hợp sẵn)

Plugin Rune bao gồm skill `untitledui-mcp` tích hợp sẵn cung cấp:
- Convention code đầy đủ từ AGENT.md chính thức của UntitledUI (React Aria, Tailwind v4.1, màu ngữ nghĩa, file kebab-case, quy tắc icon)
- Tài liệu MCP tool với chiến lược tìm kiếm và pattern sử dụng
- Metadata builder protocol cho tích hợp pipeline tự động
- Workflow triển khai component (search → get → customize → validate)

Skill này được tự động tải khi `skill_binding: "untitledui-mcp"` được đặt trong cấu hình talisman. Không cần tạo skill cấp dự án.

> **Cho tuỳ chỉnh nâng cao**: Bạn vẫn có thể tạo skill cấp dự án `.claude/skills/untitledui-builder/SKILL.md` với convention riêng dự án. Skill cấp dự án được ưu tiên hơn skill plugin. Đặt `skill_binding: "untitledui-builder"` trong talisman để dùng skill tuỳ chỉnh thay thế.

### 4. Tạo file quy tắc (Tuỳ chọn)

Cho quy tắc coding riêng dự án, tạo `.claude/rules/untitledui-conventions.md`:

```markdown
# UntitledUI Project Rules

- Always use `<Button>` from UntitledUI instead of raw `<button>` elements
- Icons: use `iconLeading`/`iconTrailing` props, never pass as children
- Colors: use semantic classes (text-primary, bg-brand-solid) --- never raw Tailwind (text-gray-900)
- Files: kebab-case only (date-picker.tsx, not DatePicker.tsx)
- React Aria imports: always prefix with Aria* (import { Button as AriaButton })
```

### 5. Xác minh bằng Audit

```
/rune:talisman audit
```

Đầu ra mong đợi bao gồm xác thực:
- Server `untitledui` tìm thấy trong `.mcp.json`
- 6 tool được khai báo với danh mục hợp lệ
- `skill_binding` trỏ tới skill tích hợp sẵn `untitledui-mcp` (hoặc ghi đè dự án)
- Trigger có 4 điều kiện được cấu hình

### 6. Sử dụng trong Workflow

```
/rune:strive "Build the settings page with toggle switches and a save button"
```

Vì tác vụ đề cập "settings" và worker chạm vào file `.tsx`, tích hợp kích hoạt. Worker nhận khối ngữ cảnh MCP, kiến thức skill đi kèm, và quy tắc coding --- cho phép chúng tìm kiếm component toggle và button UntitledUI thay vì xây dựng từ đầu.

## Câu hỏi thường gặp

**H: Tôi có cần sửa file plugin Rune nào không?**
Đ: Không. Tích hợp hoàn toàn khai báo qua `talisman.yml` và `.mcp.json`. Không cần thay đổi skill, agent, hay hook plugin.

**H: Nếu MCP server không có trong `.mcp.json` thì sao?**
Đ: Tích hợp sẽ không kích hoạt. Trường `server_name` phải khớp với khoá trong `.mcp.json`. Đăng ký server trước, sau đó thêm cấu hình tích hợp. `/rune:talisman audit` sẽ đánh dấu server thiếu.

**H: Tôi có thể dùng nhiều tích hợp MCP đồng thời không?**
Đ: Có. Mỗi namespace dưới `mcp_tools` là độc lập. Tất cả tích hợp có trigger khớp ngữ cảnh hiện tại sẽ kích hoạt. Các khối ngữ cảnh được nối tiếp trong prompt agent.

**H: Làm sao tạm vô hiệu tích hợp?**
Đ: Đặt tất cả phase thành `false` hoặc xoá mục khỏi `talisman.yml`. Bạn cũng có thể đặt `trigger.always: false` và xoá tất cả điều kiện trigger --- nhưng đặt phase thành `false` gọn hơn.

**H: `arc: true` có ghi đè `appraise: false` không?**
Đ: Không. Cờ phase `arc` bật tích hợp cho pipeline arc tổng thể, nhưng cài đặt phase riêng vẫn kiểm soát kích hoạt sub-phase. Nếu `appraise: false`, tích hợp sẽ không kích hoạt trong sub-phase review của arc, ngay cả khi `arc: true`.

**H: Điều gì xảy ra nếu hai tích hợp khai báo cùng tên tool?**
Đ: Mỗi tích hợp có namespace riêng. Cùng tên tool có thể xuất hiện trong nhiều tích hợp (ví dụ: nếu hai server cung cấp tool `search`). Khối ngữ cảnh phân biệt chúng theo namespace.

**H: Tôi có thể ghi đè cài đặt tích hợp theo lần gọi không?**
Đ: Hiện tại chưa. Tích hợp được giải quyết từ cấu hình talisman khi bắt đầu workflow. Ghi đè theo lần gọi là cải tiến tiềm năng trong tương lai.

**H: Trigger tương tác với sub-phase arc như thế nào?**
Đ: Trigger được đánh giá một lần khi bắt đầu workflow theo ngữ cảnh ban đầu (file thay đổi, mô tả tác vụ). Chúng không được đánh giá lại theo từng sub-phase. Định tuyến phase kiểm soát kích hoạt sub-phase; trigger kiểm soát kích hoạt ban đầu.

**H: Đặt talisman.yml ở đâu?**
Đ: Cấu hình cấp dự án đặt trong `.rune/talisman.yml`. Cấu hình toàn cục (cấp người dùng) đặt trong `~/.rune/talisman.yml`. Cấu hình dự án được ưu tiên. Section `integrations` được merge: mục cấp dự án ghi đè mục toàn cục cùng khoá namespace.

**H: Chi phí token của tích hợp là bao nhiêu?**
Đ: Một tích hợp hoạt động thêm khoảng 100-300 token vào mỗi prompt agent (danh sách tool, danh mục, hướng dẫn sử dụng). File quy tắc thêm toàn bộ nội dung. Skill đi kèm thêm nội dung SKILL.md. Dùng trigger cụ thể để tránh kích hoạt tích hợp trên tác vụ không liên quan.

---

## Xử lý sự cố & hành vi lỗi

### Tích hợp không kích hoạt

| Triệu chứng | Nguyên nhân có thể | Cách sửa |
|-------------|---------------------|----------|
| Tích hợp không xuất hiện trong prompt agent | `server_name` không có trong `.mcp.json` | Đăng ký MCP server trong `.mcp.json` trước |
| Tích hợp bị bỏ qua cho một phase | Cờ phase đặt thành `false` hoặc thiếu | Đặt `phases.{phase}: true` trong cấu hình talisman |
| Trigger không khớp | Phần mở rộng file hoặc từ khoá không khớp ngữ cảnh | Kiểm tra `trigger.file_extensions` và `trigger.keywords` so với file thay đổi thực tế |
| `server_name` bị bỏ qua âm thầm | Định dạng không hợp lệ (chứa khoảng trắng, ký tự đặc biệt) | Chỉ dùng ký tự `[a-zA-Z0-9_-]` |
| `namespace` bị bỏ qua âm thầm | Định dạng không hợp lệ | Chỉ dùng ký tự `[a-z0-9_-]` (chữ thường) |

### Hành vi lỗi theo thành phần

| Thành phần | Chế độ lỗi | Hành vi |
|-----------|------------|---------|
| `readTalismanSection("integrations")` | Talisman không có sẵn hoặc lỗi parse | Trả về `null` → `resolveMCPIntegrations()` trả về `[]` (fail-open, không overhead) |
| `evaluateTriggers()` | Cấu hình trigger không đúng định dạng | Trả về `false` → tích hợp bị bỏ qua cho ngữ cảnh này |
| `buildMCPContextBlock()` | File quy tắc không tìm thấy | Lỗi nội tuyến: `[rule unavailable: path]` --- các quy tắc khác vẫn được xử lý |
| `buildMCPContextBlock()` | File quy tắc bị chặn (path traversal) | Lỗi nội tuyến: `[rule blocked: invalid path]` --- vi phạm bảo mật được ghi log |
| `loadMCPSkillBindings()` | Skill đi kèm chưa cài | Ghi cảnh báo --- tích hợp vẫn kích hoạt mà không có skill |
| MCP server không thể kết nối | Process server bị crash hoặc chưa khởi động | Tool được liệt kê trong prompt nhưng gọi thất bại lúc runtime --- không phải lỗi framework tích hợp |

### Lỗi xác thực

Chạy `/rune:talisman audit` để phát hiện lỗi cấu hình phổ biến:

- **Thiếu `server_name`**: Mỗi namespace phải có `server_name` khớp với khoá trong `.mcp.json`
- **Danh mục tool không hợp lệ**: Chỉ chấp nhận `search`, `details`, `compose`, `suggest`, `generate`, `validate`
- **Đường dẫn file quy tắc**: Phải là đường dẫn tương đối không có `..` traversal --- đường dẫn tuyệt đối và tham chiếu thư mục cha bị từ chối
- **Định dạng skill binding**: Phải khớp `[a-z0-9-]+` (kebab-case chữ thường)

### Danh sách kiểm tra Debug

1. Xác minh MCP server đã đăng ký: kiểm tra `.mcp.json` với khoá `server_name`
2. Xác minh cấu hình talisman: chạy `/rune:talisman audit` để xác thực schema
3. Kiểm tra định tuyến phase: đảm bảo phase workflow có `true` trong `phases`
4. Kiểm tra trigger: xác minh `file_extensions` hoặc `keywords` khớp ngữ cảnh
5. Kiểm tra prompt agent: tìm section `MCP TOOL INTEGRATIONS (Active)` trong đầu ra agent
