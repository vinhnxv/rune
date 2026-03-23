# Agent-Browser Full Command Reference

Complete CLI reference for `agent-browser` v0.21+. Ported from upstream [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) with Rune-specific adaptations.

**Rule**: All commands are Bash-only — NEVER use Chrome MCP tools (`mcp__*chrome*`).

## Navigation

```bash
agent-browser open <url> [--timeout 30s] [--wait-until networkidle]
agent-browser back
agent-browser forward
agent-browser reload
```

## Snapshot

```bash
agent-browser snapshot [-i] [-d <depth>] [-s <selector>] [--json]
```

- `-i` — interactive elements only (default for AI agents — 60-80% context reduction)
- `-d 2` — depth 2 (default). Only escalate to `-d 3` when elements not found
- `-s "#form"` — scope to CSS selector (reduces noise)
- `--json` — JSON output for programmatic assertions

## Interactions

```bash
agent-browser click @e<n>
agent-browser fill @e<n> "value"
agent-browser type @e<n> "text" [--submit] [--delay 100]
agent-browser press "Enter"
agent-browser hover @e<n>
agent-browser check @e<n>       # checkbox toggle
agent-browser select @e<n> "value"
agent-browser scroll [up|down|left|right] [amount]
agent-browser drag @e<n> @e<m>
agent-browser upload @e<n> /path/to/file
```

## Get Information

```bash
agent-browser get text @e<n>
agent-browser get attribute @e<n> href
agent-browser get value @e<n>
```

## Check State

```bash
agent-browser check visible @e<n>
agent-browser check enabled @e<n>
agent-browser check checked @e<n>
```

## Screenshots / PDF

```bash
agent-browser screenshot [filename] [--full-page] [--annotate]
agent-browser pdf [filename]
```

- `--annotate` — overlay `@e` ref labels and bounding boxes (v0.12.0+)
- `--full-page` — capture entire scrollable page
- `AGENT_BROWSER_ANNOTATE=1` — env var equivalent of `--annotate`

## Video Recording

```bash
agent-browser record start
agent-browser record stop [filename]
```

Output format: WebM (VP8/VP9). See [video-recording.md](video-recording.md) for details.

**Rune convention**: Save to `tmp/test/{timestamp}/videos/` during arc Phase 7.7.

## Wait

```bash
agent-browser wait --load networkidle
agent-browser wait --selector "#element" [--timeout 10s]
agent-browser wait <ms>
```

Prefer `--load networkidle` over fixed waits. Use `--selector` for dynamic content.

## Mouse Control

```bash
agent-browser mouse move <x> <y>
agent-browser mouse click [<x> <y>]
agent-browser mouse dblclick [<x> <y>]
```

## Semantic Locators

```bash
agent-browser find role/<role> ["name"]
agent-browser find text "content"
agent-browser find label "text"
agent-browser find testid "id"
```

Semantic locators return `@e` refs. Prefer over raw CSS selectors for accessibility.

## Browser Settings

```bash
agent-browser set viewport <width> <height> [--scale <factor>]
agent-browser set device "<device-name>"
agent-browser set darkmode [on|off]
```

- `--scale 2` — retina resolution (v0.21+)
- Device names: `"iPhone 15"`, `"iPad Pro"`, `"Pixel 7"`, etc.

## Cookies / Storage

```bash
agent-browser cookie get [name]
agent-browser cookie set <name> <value> [--domain] [--path] [--httponly] [--secure]
agent-browser cookie clear [--domain]
agent-browser storage get <key>
agent-browser storage set <key> <value>
agent-browser storage clear
```

## Network

```bash
agent-browser network har start
agent-browser network har stop [filename]
agent-browser network intercept <url-pattern> [--status] [--body] [--headers]
agent-browser network block <url-pattern>
agent-browser network log
```

- HAR output: HAR 1.2 format — open in Chrome DevTools Network tab
- **Rune convention**: Save HAR to `tmp/test/{timestamp}/network/` during arc Phase 7.7

## Tabs / Windows

```bash
agent-browser tab list
agent-browser tab switch <id>
agent-browser tab close [<id>]
agent-browser tab new [<url>]
```

## Frames (v0.21+)

```bash
agent-browser frame list
agent-browser frame switch <id>
```

In v0.21+, iframe content is auto-inlined in snapshots. Refs inside iframes work directly — `click @e5` works even if `@e5` is inside an iframe. Manual `frame switch` only needed for deeply nested iframes.

## Dialogs

```bash
agent-browser dialog accept [text]
agent-browser dialog dismiss
```

## JavaScript

```bash
agent-browser eval "expression"
agent-browser eval --stdin <<'EOF'
  multiline code
EOF
agent-browser eval -b "expression"   # browser context (no Node.js wrapping)
```

Use `--stdin` for complex JS to avoid shell escaping issues.

## Clipboard (v0.21+)

```bash
agent-browser clipboard read
agent-browser clipboard write "text"
```

## State Management

```bash
agent-browser state save <filename>
agent-browser state restore <filename>
```

Exports/imports cookies, localStorage, and sessionStorage. See [authentication.md](authentication.md) for auth-specific patterns.

## Session Management

```bash
agent-browser --session-name <name> open <url>    # create/reuse persistent session
agent-browser session list                         # list active sessions
agent-browser close                                # release current session
```

**Rune convention**: Use `arc-e2e-{timestamp}` naming. See [session-management.md](session-management.md).

## Global Options

```bash
--session-name <name>    # persistent session
--profile <name>         # persistent browser profile
--timeout <duration>     # default timeout
--headed                 # show browser window
--auto-connect           # connect to running Chrome
--engine <name>          # browser engine: chrome (default), lightpanda
```

## Debugging

```bash
agent-browser console               # JS console output
agent-browser errors                 # JS errors
agent-browser network log            # network request log
```

## Diffing (v0.13.0+)

```bash
agent-browser diff snapshot                    # compare DOM snapshots (before vs. after)
agent-browser diff screenshot baseline.png     # pixel diff against saved screenshot
agent-browser diff url <url1> <url2>           # diff two URLs side-by-side
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `AGENT_BROWSER_ANNOTATE=1` | Auto-annotate screenshots |
| `AGENT_BROWSER_ALLOWED_DOMAINS=...` | Domain allowlist (comma-separated) |
| `AGENT_BROWSER_CONTENT_BOUNDARIES=..` | DOM scope restriction (CSS selector) |
| `AGENT_BROWSER_ENGINE=lightpanda` | Browser engine override |
| `AGENT_BROWSER_HEADED=1` | Headed mode override |
| `AGENT_BROWSER_VIDEO_FORMAT=webm` | Video output format |
| `HTTP_PROXY` / `HTTPS_PROXY` | Proxy configuration |
| `NO_PROXY` | Proxy bypass list |
