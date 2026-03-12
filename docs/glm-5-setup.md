# GLM-5 Coding Plan Setup Guide

> Use GLM-5 (Alibaba Cloud Coding Plan or Z.AI) with Rune Plugin

## Table of Contents

- [English](#english)
  - [Option A: Alibaba Cloud Coding Plan](#option-a-alibaba-cloud-coding-plan)
  - [Option B: Z.AI GLM Coding Plan (Recommended)](#option-b-zai-glm-coding-plan-recommended)
- [Tiếng Việt](#tiếng-việt)
  - [Phương án A: Alibaba Cloud Coding Plan](#phương-án-a-alibaba-cloud-coding-plan)
  - [Phương án B: Z.AI GLM Coding Plan (Khuyên dùng)](#phương-án-b-zai-glm-coding-plan-khuyên-dùng)

---

## English

### Overview

This guide helps you configure GLM-5 from Chinese providers to work with the Rune plugin.

**Why consider this option?**

- 💰 **Budget-friendly** — If you can't afford expensive models like Claude Max ($200/month), this offers a cost-effective alternative starting at $10/month
- 🧪 **Test Agent Teams** — Great for testing Rune's agent teams features at lower cost (Claude Pro $20/month is not enough for heavy agent usage)
- ⚠️ **Trade-offs** — Consider potential security and data collection implications when using models from Chinese providers. Use for non-sensitive projects.

> **Disclaimer:** This is NOT an official endorsement. Evaluate your own security requirements before use.

---

## Option A: Alibaba Cloud Coding Plan

Uses [claude-code-router](https://github.com/musistudio/claude-code-router) to route Claude Code requests through Alibaba's GLM-5.

### Prerequisites

- Node.js 18+ installed
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- Active Alibaba Cloud Coding Plan subscription

### Step 1: Subscribe to Coding Plan

1. Visit [Alibaba Cloud Coding Plan](https://www.alibabacloud.com/help/en/model-studio/coding-plan)
2. Choose a subscription tier:

   | Plan | Price | Quotas |
   |------|-------|--------|
   | **Lite** | $10/month | 1,200 req/5hrs, 9,000/week, 18,000/month |
   | **Pro** | $50/month | 6,000 req/5hrs, 45,000/week, 90,000/month |

3. **Available Models:**

   | Model | Notes |
   |-------|-------|
   | `glm-5` | **Recommended for coding** - Stable speed, good reasoning |
   | `glm-4.7` | Alternative GLM version |
   | `qwen3.5-plus` | General purpose |
   | `qwen3-max` | Pro plan only, advanced tasks |
   | `qwen3-coder-plus` | Code optimization |
   | `kimi-k2.5` | Long context |
   | `MiniMax-M2.5` | Alternative model |

4. Complete subscription and obtain your **Coding Plan API Key** (starts with `sk-sp-`)

> **Tip:** A simple task consumes ~5-10 invocations, complex tasks can use 10-30+ invocations. **Recommended:** Use `glm-5` for coding — stable speed and solid reasoning.

### Step 2: Install claude-code-router

```bash
npm install -g @musistudio/claude-code-router
```

### Step 3: Configure the Router

Create or edit `~/.claude-code-router/config.json`:

```json
{
  "LOG": true,
  "LOG_LEVEL": "debug",
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "API_TIMEOUT_MS": "600000",
  "Providers": [
    {
      "name": "Alibaba Cloud",
      "api_base_url": "https://coding-intl.dashscope.aliyuncs.com/apps/anthropic/v1/messages",
      "api_key": "${ALIBABA_CODING_PLAN_API_KEY}",
      "models": ["glm-5"],
      "transformer": {
        "use": ["Anthropic"],
        "glm-5": {
          "use": ["Anthropic"]
        }
      }
    }
  ],
  "Router": {
    "default": "Alibaba Cloud,glm-5",
    "background": "Alibaba Cloud,glm-5",
    "think": "Alibaba Cloud,glm-5",
    "longContext": "Alibaba Cloud,glm-5",
    "longContextThreshold": 60000
  }
}
```

> **Note:** Use `coding-intl.dashscope.aliyuncs.com` (international endpoint) and the `/apps/anthropic/v1/messages` path for Anthropic-compatible API.

### Step 4: Set Environment Variable

Add your API key to your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
export ALIBABA_CODING_PLAN_API_KEY="sk-sp-your-api-key-here"
```

Reload your shell:

```bash
source ~/.zshrc  # or ~/.bashrc
```

### Step 5: Start the Router

Start the router in daemon mode:

```bash
ccr start --daemon
```

> **Tip:** If `ccr start --daemon` fails, use this alias as an alternative:
> ```bash
> # Add to ~/.zshrc or ~/.bashrc
> alias ccrd='ccr start --daemon &'
>
> # Then run
> ccrd
> ```

Or start Claude Code directly with the router:

```bash
ccr code
```

Other useful commands:

```bash
ccr model      # Interactive model selector
ccr ui         # Web-based configuration interface
ccr preset     # Manage configuration presets
ccr activate   # Output environment variables for shell
ccr restart    # Restart after config changes
ccr stop       # Stop the daemon
ccr status     # Check router status
```

### Logs & Debugging

```bash
# Server logs
~/.claude-code-router/logs/ccr-*.log

# Application logs
~/.claude-code-router/claude-code-router.log
```

### Usage with Rune Plugin

Once configured, all Rune commands will automatically route through GLM-5:

```bash
# Example Rune commands
/rune:appraise    # Code review
/rune:devise      # Planning
/rune:strive      # Implementation
```

### Important Notes

- **Personal use only** - Coding Plan subscriptions are for individual use
- **No automated scripts** - Use only in interactive coding tools (Claude Code, OpenClaw)
- **Use correct endpoint** - Always use `coding.dashscope.aliyuncs.com`, NOT the general Model Studio endpoint
- **Non-refundable** - Subscriptions cannot be refunded

### Troubleshooting

| Issue | Solution |
|-------|----------|
| `ccr: command not found` | Ensure npm global bin is in PATH: `npm config get prefix` |
| `401 Unauthorized` | Verify API key starts with `sk-sp-` and is correctly set |
| `Model not found` | Check model name matches: `glm-5` (lowercase) |
| Connection timeout | Check network/proxy settings, verify `api_base_url` |

---

## Option B: Z.AI GLM Coding Plan (Recommended)

> **Why Z.AI over Alibaba?** Simpler setup (no router needed), direct Anthropic-compatible API, less prone to getting stuck during execution.

### Step 1: Subscribe

1. Visit [Z.AI GLM Coding Plan](https://z.ai/subscribe)
2. Subscribe (plans from $10/month)
3. Get your API key from [z.ai/manage-apikey/apikey-list](https://z.ai/manage-apikey/apikey-list)

### Step 2: Configure Claude Code

Edit `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "your_zai_api_key",
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "ANTHROPIC_MODEL": "GLM-4.7",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "GLM-4.7",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "GLM-4.7",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "GLM-4.5-Air",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": 1
  }
}
```

### Step 3: Done!

No router setup needed. Just run:

```bash
claude
```

### Available Models

| Model | Best For |
|-------|----------|
| `GLM-4.7` | **Recommended** — Default for Opus/Sonnet tasks |
| `GLM-5` | Latest model — Good for coding |
| `GLM-4.5-Air` | Fast, lightweight — Default for Haiku tasks |
| `GLM-4.6V` | Vision tasks |

### Automated Setup (Optional)

```bash
# macOS/Linux
curl -O "https://cdn.bigmodel.cn/install/claude_code_zai_env.sh" && bash ./claude_code_zai_env.sh

# Or use the helper
npx @z_ai/codinghelper
```

### Troubleshooting

| Issue | Solution |
|-------|----------|
| Config not taking effect | Close all Claude Code windows and reopen |
| JSON errors | Validate with online JSON validator |
| Version issues | Run `claude update` to upgrade |

> **Docs:** [docs.z.ai/devpack/tool/claude](https://docs.z.ai/devpack/tool/claude)

### ⚠️ Important: Agent Teams Compatibility

**Current limitation:** Agent teams (teammates) in Claude Code do not work well with direct custom model configuration. Even when `ANTHROPIC_MODEL` is set, teammates may still call Claude Opus or Sonnet instead of your custom model.

**Recommended solution:** Use **claude-code-router** (Option A) for agent teams support. The router intercepts all API calls, ensuring teammates use your configured model.

| Setup Method | Agent Teams Support | Notes |
|--------------|---------------------|-------|
| Direct env config (Z.AI) | ⚠️ Partial | Teammates may ignore custom model |
| claude-code-router (Alibaba) | ✅ Works | Router enforces model for all calls |

> This is a known limitation that will likely be improved in future Claude Code updates.

---

## Tiếng Việt

### Tổng quan

Hướng dẫn này giúp bạn cấu hình [GLM-5](https://www.alibabacloud.com/help/en/model-studio/coding-plan) từ Alibaba Cloud Coding Plan để sử dụng với Rune plugin thông qua [claude-code-router](https://github.com/musistudio/claude-code-router).

**Tại sao nên cân nhắc phương án này?**

- 💰 **Tiết kiệm chi phí** — Nếu bạn không đủ tiền mua các model đắt tiền như Claude Max ($200/tháng), đây là giải pháp thay thế với giá từ $10/tháng
- 🧪 **Test Agent Teams** — Phù hợp để test tính năng agent teams của Rune với chi phí thấp hơn (Claude Pro $20/tháng không đủ cho việc dùng agent nhiều)
- ⚠️ **Đánh đổi** — Cân nhắc các vấn đề tiềm ẩn về bảo mật và thu thập dữ liệu khi dùng model từ nhà cung cấp Trung Quốc. Nên dùng cho các dự án không nhạy cảm.

> **Lưu ý:** Đây KHÔNG phải là khuyến nghị chính thức. Hãy tự đánh giá yêu cầu bảo mật của bạn trước khi sử dụng.

### Yêu cầu trước

- Đã cài đặt Node.js 18+
- Đã cài đặt Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- Đã đăng ký Alibaba Cloud Coding Plan

### Bước 1: Đăng ký Coding Plan

1. Truy cập [Alibaba Cloud Coding Plan](https://www.alibabacloud.com/help/en/model-studio/coding-plan)
2. Chọn gói đăng ký:

   | Gói | Giá | Giới hạn |
   |-----|-----|----------|
   | **Lite** | $10/tháng | 1,200 req/5hrs, 9,000/tuần, 18,000/tháng |
   | **Pro** | $50/tháng | 6,000 req/5hrs, 45,000/tuần, 90,000/tháng |

3. **Các Model có sẵn:**

   | Model | Ghi chú |
   |-------|---------|
   | `glm-5` | **Khuyên dùng cho coding** - Tốc độ ổn định, reasoning tốt |
   | `glm-4.7` | Phiên bản GLM khác |
   | `qwen3.5-plus` | Tổng quát |
   | `qwen3-max` | Chỉ gói Pro, tác vụ nâng cao |
   | `qwen3-coder-plus` | Tối ưu cho code |
   | `kimi-k2.5` | Context dài |
   | `MiniMax-M2.5` | Model thay thế |

4. Hoàn tất đăng ký và lấy **Coding Plan API Key** (bắt đầu bằng `sk-sp-`)

> **Mẹo:** Một tác vụ đơn giản tốn ~5-10 lượt gọi, tác vụ phức tạp có thể tốn 10-30+ lượt. **Khuyên dùng:** `glm-5` cho coding — tốc độ ổn định và reasoning tốt.

---

## Mẹo Workflow từ Author

**Cách tiếp cận hybrid để tiết kiệm chi phí:**

| Tác vụ | Model Khuyên Dùng | Lý Do |
|--------|-------------------|-------|
| Planning (`/rune:devise`, `/rune:forge`, plan review) | Claude Opus | Reasoning tốt hơn cho planning phức tạp |
| Execution (`/rune:strive`, `/rune:arc`) | `glm-5` qua `claude-ali` | Tiết kiệm chi phí khi chạy task |
| Testing, test-browser, agent browser | `glm-5` qua `claude-ali` | Hiệu suất ổn định cho tác vụ tự động |

**Workflow:**
1. Dùng **Claude Opus** để tạo plan files (`/rune:devise`, `/rune:forge`)
2. Chuyển sang **`claude-ali` với `glm-5`** để thực thi plan:
   - `/rune:strive plans/xxx.md` — Thực thi plan đơn
   - `/rune:arc plans/xxx.md` — Full pipeline (forge → work → review → mend → test)
   - `/rune:arc-batch plans/*.md` — Thực thi nhiều plan cùng lúc
3. Tiết kiệm đáng kể chi phí mà vẫn giữ được chất lượng

> Cách tiếp cận hybrid này cho bạn tốt nhất của cả hai: chất lượng planning niveau Opus với chi phí thực thi thấp hơn nhiều.

### Mẹo để có kết quả tốt hơn với GLM-5

| Vấn đề | Giải pháp |
|--------|-----------|
| Chậm hơn Claude | Đánh đổi chấp nhận được cho chi phí thấp — lên kế hoạch phù hợp |
| Trả lời bằng tiếng Trung | Viết plan file bằng tiếng Trung để hiểu tốt hơn |
| Lệch khỏi plan | Dùng plan tiếng Trung để bám sát hơn |

**Mẹo ngôn ngữ:** Các model Trung Quốc như `glm-5` thường hoạt động tốt hơn với input tiếng Trung. Nếu bạn biết tiếng Trung:

1. **Phương án A:** Viết plan file trực tiếp bằng tiếng Trung
2. **Phương án B:** Dùng Claude Sonnet để dịch plan tiếng Anh sang tiếng Trung trước khi thực thi:

   ```bash
   # Dịch plan sang tiếng Trung với Claude Sonnet
   claude "Dịch plan này sang tiếng Trung để GLM-5 hiểu tốt hơn: $(cat plans/my-plan.md)" > plans/my-plan-zh.md

   # Thực thi với plan tiếng Trung
   claude-ali
   /rune:strive plans/my-plan-zh.md
   ```

> Nhiều developer phản hồi rằng các model Trung Quốc bám sát plan tiếng Trung hơn và cho kết quả tốt hơn so với plan tiếng Anh.

### Bước 2: Cài đặt claude-code-router

```bash
npm install -g @musistudio/claude-code-router
```

### Bước 3: Cấu hình Router

Tạo hoặc chỉnh sửa file `~/.claude-code-router/config.json`:

```json
{
  "LOG": true,
  "LOG_LEVEL": "debug",
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "API_TIMEOUT_MS": "600000",
  "Providers": [
    {
      "name": "Alibaba Cloud",
      "api_base_url": "https://coding-intl.dashscope.aliyuncs.com/apps/anthropic/v1/messages",
      "api_key": "${ALIBABA_CODING_PLAN_API_KEY}",
      "models": ["glm-5"],
      "transformer": {
        "use": ["Anthropic"],
        "glm-5": {
          "use": ["Anthropic"]
        }
      }
    }
  ],
  "Router": {
    "default": "Alibaba Cloud,glm-5",
    "background": "Alibaba Cloud,glm-5",
    "think": "Alibaba Cloud,glm-5",
    "longContext": "Alibaba Cloud,glm-5",
    "longContextThreshold": 60000
  }
}
```

> **Lưu ý:** Sử dụng `coding-intl.dashscope.aliyuncs.com` (endpoint quốc tế) và đường dẫn `/apps/anthropic/v1/messages` cho API tương thích Anthropic.

### Bước 4: Thiết lập biến môi trường

Thêm API key vào file cấu hình shell (`~/.zshrc` hoặc `~/.bashrc`):

```bash
export ALIBABA_CODING_PLAN_API_KEY="sk-sp-api-key-của-bạn"
```

Tải lại shell:

```bash
source ~/.zshrc  # hoặc ~/.bashrc
```

### Bước 5: Khởi động Router

Khởi động router ở chế độ daemon:

```bash
ccr start --daemon
```

> **Mẹo:** Nếu `ccr start --daemon` bị lỗi, dùng alias sau thay thế:
> ```bash
> # Thêm vào ~/.zshrc hoặc ~/.bashrc
> alias ccrd='ccr start --daemon &'
>
> # Sau đó chạy
> ccrd
> ```

Hoặc khởi động Claude Code trực tiếp với router:

```bash
ccr code
```

Các lệnh hữu ích khác:

```bash
ccr model      # Bộ chọn model tương tác
ccr ui         # Giao diện cấu hình web
ccr preset     # Quản lý preset cấu hình
ccr activate   # Xuất biến môi trường cho shell
ccr restart    # Khởi động lại sau khi thay đổi cấu hình
ccr stop       # Dừng daemon
ccr status     # Kiểm tra trạng thái router
```

### Logs & Debug

```bash
# Server logs
~/.claude-code-router/logs/ccr-*.log

# Application logs
~/.claude-code-router/claude-code-router.log
```

### Sử dụng với Rune Plugin

Sau khi cấu hình, tất cả lệnh Rune sẽ tự động chạy qua GLM-5:

```bash
# Ví dụ các lệnh Rune
/rune:appraise    # Review code
/rune:devise      # Lập kế hoạch
/rune:strive      # Triển khai
```

### Lưu ý quan trọng

- **Chỉ sử dụng cá nhân** - Gói Coding Plan chỉ dành cho một người
- **Không dùng cho script tự động** - Chỉ sử dụng trong công cụ coding tương tác (Claude Code, OpenClaw)
- **Sử dụng đúng endpoint** - Luôn dùng `coding.dashscope.aliyuncs.com`, KHÔNG phải endpoint Model Studio thông thường
- **Không hoàn tiền** - Gói đăng ký không được hoàn tiền

### Khắc phục sự cố

| Vấn đề | Giải pháp |
|--------|-----------|
| `ccr: command not found` | Kiểm tra PATH có chứa npm global bin: `npm config get prefix` |
| `401 Unauthorized` | Xác minh API key bắt đầu bằng `sk-sp-` và đã được thiết lập đúng |
| `Model not found` | Kiểm tra tên model: `glm-5` (chữ thường) |
| Timeout kết nối | Kiểm tra mạng/proxy, xác minh `api_base_url` |

---

## Phương án B: Z.AI GLM Coding Plan (Khuyên dùng)

> **Tại sao chọn Z.AI thay Alibaba?** Cài đặt đơn giản hơn (không cần router), API tương thích Anthropic trực tiếp, ít bị stuck khi chạy hơn.

### Bước 1: Đăng ký

1. Truy cập [Z.AI GLM Coding Plan](https://z.ai/subscribe)
2. Đăng ký (từ $10/tháng)
3. Lấy API key tại [z.ai/manage-apikey/apikey-list](https://z.ai/manage-apikey/apikey-list)

### Bước 2: Cấu hình Claude Code

Chỉnh sửa `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "your_zai_api_key",
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "ANTHROPIC_MODEL": "GLM-4.7",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "GLM-4.7",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "GLM-4.7",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "GLM-4.5-Air",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": 1
  }
}
```

### Bước 3: Xong!

Không cần setup router. Chỉ cần chạy:

```bash
claude
```

### Các Model có sẵn

| Model | Dùng cho |
|-------|----------|
| `GLM-4.7` | **Khuyên dùng** — Mặc định cho task Opus/Sonnet |
| `GLM-5` | Model mới nhất — Tốt cho coding |
| `GLM-4.5-Air` | Nhanh, nhẹ — Mặc định cho task Haiku |
| `GLM-4.6V` | Vision tasks |

### Cài đặt tự động (Tùy chọn)

```bash
# macOS/Linux
curl -O "https://cdn.bigmodel.cn/install/claude_code_zai_env.sh" && bash ./claude_code_zai_env.sh

# Hoặc dùng helper
npx @z_ai/codinghelper
```

### Khắc phục sự cố

| Vấn đề | Giải pháp |
|--------|-----------|
| Config không có tác dụng | Đóng tất cả cửa sổ Claude Code và mở lại |
| Lỗi JSON | Kiểm tra với JSON validator online |
| Lỗi version | Chạy `claude update` để nâng cấp |

> **Docs:** [docs.z.ai/devpack/tool/claude](https://docs.z.ai/devpack/tool/claude)

### ⚠️ Quan trọng: Khả năng tương thích Agent Teams

**Hạn chế hiện tại:** Agent teams (teammates) trong Claude Code không hoạt động tốt với cấu hình model tùy chỉnh trực tiếp. Ngay cả khi `ANTHROPIC_MODEL` đã được set, teammates vẫn có thể gọi Claude Opus hoặc Sonnet thay vì model tùy chỉnh của bạn.

**Giải pháp khuyên dùng:** Dùng **claude-code-router** (Phương án A) để hỗ trợ agent teams. Router sẽ chặn tất cả API calls, đảm bảo teammates sử dụng model đã cấu hình.

| Phương án Setup | Hỗ trợ Agent Teams | Ghi chú |
|-----------------|-------------------|---------|
| Direct env config (Z.AI) | ⚠️ Một phần | Teammates có thể bỏ qua model tùy chỉnh |
| claude-code-router (Alibaba) | ✅ Hoạt động | Router ép model cho tất cả calls |

> Đây là hạn chế đã biết và có thể sẽ được cải thiện trong các bản cập nhật Claude Code tương lai.

---

## Quick Reference

### Essential Settings

| Item | Value |
|------|-------|
| API Key Prefix | `sk-sp-` |
| Base URL | `https://coding-intl.dashscope.aliyuncs.com/apps/anthropic/v1/messages` |
| Transformer | `Anthropic` |
| Config File | `~/.claude-code-router/config.json` |
| Start Command | `ccr start --daemon` |
| Code Command | `ccr code` |

### Available Models

| Model | Plan | Best For |
|-------|------|----------|
| `glm-5` | Lite/Pro | **Recommended for coding** - Stable speed, good reasoning |
| `glm-4.7` | Lite/Pro | Alternative GLM |
| `qwen3.5-plus` | Lite/Pro | General purpose |
| `qwen3-max` | Pro only | Advanced tasks |
| `qwen3-coder-plus` | Lite/Pro | Code optimization |
| `kimi-k2.5` | Lite/Pro | Long context |
| `MiniMax-M2.5` | Lite/Pro | Alternative |

> **Recommendation:** Use `glm-5` for coding tasks — it offers stable speed and solid reasoning capabilities for day-to-day development work.

---

## Author's Workflow Tip

**Hybrid approach for cost efficiency:**

| Task | Recommended Model | Why |
|------|-------------------|-----|
| Planning (`/rune:devise`, `/rune:forge`, plan review) | Claude Opus | Better reasoning for complex planning |
| Execution (`/rune:strive`, `/rune:arc`) | `glm-5` via `claude-ali` | Cost-effective for running tasks |
| Testing, test-browser, agent browser | `glm-5` via `claude-ali` | Stable performance for automated tasks |

**Workflow:**
1. Use **Claude Opus** to create plan files (`/rune:devise`, `/rune:forge`)
2. Switch to **`claude-ali` with `glm-5`** to execute the plan:
   - `/rune:strive plans/xxx.md` — Single plan execution
   - `/rune:arc plans/xxx.md` — Full pipeline (forge → work → review → mend → test)
   - `/rune:arc-batch plans/*.md` — Batch execution of multiple plans
3. Significant cost savings while maintaining quality

> This hybrid approach gives you the best of both worlds: Opus-level planning quality at a fraction of the execution cost.

### Tips for Better Results with GLM-5

| Issue | Solution |
|-------|----------|
| Slower than Claude | Expected trade-off for lower cost — plan accordingly |
| Returns Chinese responses | Write plan files in Chinese for better comprehension |
| Deviates from plan | Use Chinese plans for tighter adherence |

**Language tip:** Chinese models like `glm-5` often perform better with Chinese language input. If you know Chinese:

1. **Option A:** Write plan files directly in Chinese
2. **Option B:** Use Claude Sonnet to translate English plans to Chinese before execution:

   ```bash
   # Translate plan to Chinese with Claude Sonnet
   claude "Translate this plan to Chinese for better GLM-5 comprehension: $(cat plans/my-plan.md)" > plans/my-plan-zh.md

   # Execute with Chinese plan
   claude-ali
   /rune:strive plans/my-plan-zh.md
   ```

> Many developers report that Chinese models follow Chinese plans more closely and produce better results compared to English plans.

### Multi-Model Config Example

```json
{
  "Providers": [
    {
      "name": "Alibaba Cloud",
      "api_base_url": "https://coding-intl.dashscope.aliyuncs.com/apps/anthropic/v1/messages",
      "api_key": "${ALIBABA_CODING_PLAN_API_KEY}",
      "models": ["glm-5", "qwen3.5-plus", "qwen3-coder-plus", "kimi-k2.5"],
      "transformer": {
        "use": ["Anthropic"]
      }
    }
  ],
  "Router": {
    "default": "Alibaba Cloud,qwen3.5-plus",
    "background": "Alibaba Cloud,glm-5",
    "think": "Alibaba Cloud,qwen3.5-plus",
    "longContext": "Alibaba Cloud,kimi-k2.5"
  }
}
```

---

## Multiple Claude Code Accounts Setup

If you want to use multiple Claude Code accounts (e.g., work + personal), create separate directories:

### Quick Setup Script

```bash
# 1. Create new Claude Code directory
mkdir -p ~/.claude-ali

# 2. Skip onboarding/setup
echo '{"hasCompletedProjectOnboarding": true}' > ~/.claude-ali/.claude.json

# 3. Configure Claude Code to use router
cat << 'EOF' > ~/.claude-ali/settings.json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "anykey",
    "ANTHROPIC_BASE_URL": "http://localhost:3456",
    "ANTHROPIC_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": 1
  }
}
EOF

# 4. Router config (shared at HOME level)
vim ~/.claude-code-router/config.json
```

### Manual Setup

```bash
# 1. Create new directory
mkdir -p ~/.claude-ali

# 2. Skip onboarding/setup
echo '{"hasCompletedProjectOnboarding": true}' > ~/.claude-ali/.claude.json

# 3. Configure Claude Code to use router
vim ~/.claude-ali/settings.json
```

**`~/.claude-ali/settings.json`:**
```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "anykey",
    "ANTHROPIC_BASE_URL": "http://localhost:3456",
    "ANTHROPIC_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": 1
  }
}
```

> **Note:** Router config is at `~/.claude-code-router/config.json` (shared, HOME level), not inside `~/.claude-ali/`

### Shell Aliases for Multiple Accounts

Add to `~/.zshrc` or `~/.bashrc`:

```bash
# Alibaba GLM-5 account
alias claude-ali="CLAUDE_CONFIG_DIR=~/.claude-ali claude --dangerously-skip-permissions"

# Work account
alias claude-work="CLAUDE_CONFIG_DIR=~/.claude-work claude --dangerously-skip-permissions"

# Personal account
alias claude-personal="CLAUDE_CONFIG_DIR=~/.claude-personal claude --dangerously-skip-permissions"
```

Then reload your shell:

```bash
source ~/.zshrc  # or ~/.bashrc
```

Now simply run:

```bash
claude-ali      # Start Claude Code with Alibaba account
claude-work     # Start Claude Code with work account
claude-personal # Start Claude Code with personal account
```

### Directory Structure for Multiple Accounts

```
~/
├── .claude-code-router/        # SHARED router config
│   └── config.json             # Single config for all accounts
│
├── .claude/                    # Default account
│   ├── .claude.json            # Onboarding status
│   └── settings.json           # Routes to router via env vars
│
├── .claude-ali/                # Alibaba Coding Plan
│   ├── .claude.json
│   └── settings.json           # Routes to router via env vars
│
└── .claude-work/               # Work account
    ├── .claude.json
    └── settings.json           # Routes to router via env vars
```

> **Note:** Router config (`~/.claude-code-router/config.json`) is **SHARED** across all accounts. Each account's `settings.json` points to the router via `ANTHROPIC_BASE_URL`. The `--dangerously-skip-permissions` flag skips permission prompts for a smoother experience.

---

## Related Links

- [Z.AI GLM Coding Plan](https://z.ai/subscribe)
- [Z.AI Claude Code Setup Docs](https://docs.z.ai/devpack/tool/claude)
- [Alibaba Cloud Coding Plan Documentation](https://www.alibabacloud.com/help/en/model-studio/coding-plan)
- [claude-code-router GitHub](https://github.com/musistudio/claude-code-router)
- [Rune Plugin Documentation](./README.md)
