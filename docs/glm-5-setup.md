# GLM-5 Coding Plan Setup Guide

> Use GLM-5 (Alibaba Cloud Coding Plan) with Rune Plugin via claude-code-router

## Table of Contents

- [English](#english)
- [Tiếng Việt](#tiếng-việt)

---

## English

### Overview

This guide helps you configure [GLM-5](https://www.alibabacloud.com/help/en/model-studio/coding-plan) from Alibaba Cloud Coding Plan to work with the Rune plugin using [claude-code-router](https://github.com/musistudio/claude-code-router).

### Prerequisites

- Node.js 18+ installed
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- Active Alibaba Cloud Coding Plan subscription

### Step 1: Subscribe to Coding Plan

1. Visit [Alibaba Cloud Coding Plan](https://www.alibabacloud.com/help/en/model-studio/coding-plan)
2. Choose a subscription tier:

   | Plan | Price | Models | Quotas |
   |------|-------|--------|--------|
   | **Lite** | $10/month | GLM-5, qwen3.5-plus, kimi-k2.5 | 1,200 req/5hrs, 9,000/week, 18,000/month |
   | **Pro** | $50/month | GLM-5, qwen3.5-plus, kimi-k2.5, qwen3-max | 6,000 req/5hrs, 45,000/week, 90,000/month |

3. Complete subscription and obtain your **Coding Plan API Key** (starts with `sk-sp-`)

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
ccr restart    # Restart after config changes
ccr stop       # Stop the daemon
ccr status     # Check router status
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

## Tiếng Việt

### Tổng quan

Hướng dẫn này giúp bạn cấu hình [GLM-5](https://www.alibabacloud.com/help/en/model-studio/coding-plan) từ Alibaba Cloud Coding Plan để sử dụng với Rune plugin thông qua [claude-code-router](https://github.com/musistudio/claude-code-router).

### Yêu cầu trước

- Đã cài đặt Node.js 18+
- Đã cài đặt Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- Đã đăng ký Alibaba Cloud Coding Plan

### Bước 1: Đăng ký Coding Plan

1. Truy cập [Alibaba Cloud Coding Plan](https://www.alibabacloud.com/help/en/model-studio/coding-plan)
2. Chọn gói đăng ký:

   | Gói | Giá | Models | Giới hạn |
   |-----|-----|--------|----------|
   | **Lite** | $10/tháng | GLM-5, qwen3.5-plus, kimi-k2.5 | 1,200 req/5hrs, 9,000/tuần, 18,000/tháng |
   | **Pro** | $50/tháng | GLM-5, qwen3.5-plus, kimi-k2.5, qwen3-max | 6,000 req/5hrs, 45,000/tuần, 90,000/tháng |

3. Hoàn tất đăng ký và lấy **Coding Plan API Key** (bắt đầu bằng `sk-sp-`)

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
ccr restart    # Khởi động lại sau khi thay đổi cấu hình
ccr stop       # Dừng daemon
ccr status     # Kiểm tra trạng thái router
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

## Quick Reference

| Item | Value |
|------|-------|
| API Key Prefix | `sk-sp-` |
| Base URL | `https://coding-intl.dashscope.aliyuncs.com/apps/anthropic/v1/messages` |
| Model Name | `glm-5` |
| Transformer | `Anthropic` |
| Config File | `~/.claude-code-router/config.json` |
| Start Command | `ccr start --daemon` |
| Code Command | `ccr code` |

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
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": 1,
    "CLAUDE_CODE_DISABLE_CRON": 0
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
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": 1,
    "CLAUDE_CODE_DISABLE_CRON": 0
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
├── .claude/                    # Default account
│   └── .claude-code-router/
│       └── config.json
├── .claude-ali/                # Alibaba Coding Plan
│   └── .claude-code-router/
│       └── config.json
└── .claude-work/               # Work account
    └── .claude-code-router/
        └── config.json
```

> **Note:** Each directory maintains its own settings, credentials, and conversation history. The `--dangerously-skip-permissions` flag skips permission prompts for a smoother experience.

---

## Related Links

- [Alibaba Cloud Coding Plan Documentation](https://www.alibabacloud.com/help/en/model-studio/coding-plan)
- [claude-code-router GitHub](https://github.com/musistudio/claude-code-router)
- [Rune Plugin Documentation](./README.md)
