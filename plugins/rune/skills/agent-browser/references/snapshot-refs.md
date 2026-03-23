# Snapshot & Ref System Deep Dive

The `@e` ref system is the core interaction model for agent-browser. Understanding ref lifecycle is critical for reliable E2E testing.

## How Refs Work

When you run `snapshot -i`, agent-browser assigns compact references (`@e1`, `@e2`, etc.) to interactive elements (buttons, links, inputs, selects). This is dramatically more token-efficient than working with full DOM:

- **Compact snapshot**: ~200-400 tokens
- **Full DOM**: ~3000-5000 tokens

## Snapshot Command

```bash
agent-browser snapshot -i              # interactive only (default for AI agents)
agent-browser snapshot -i -d 2         # depth 2 (default)
agent-browser snapshot -i -d 3         # deeper — only when elements not found at d2
agent-browser snapshot -i -s "#form"   # scoped to CSS selector
agent-browser snapshot --json          # JSON output for assertions
```

**Depth guidance**:
- `-d 2` (default) — covers most pages. Start here.
- `-d 3` — use when target elements are nested deeper (e.g., complex forms, nested components)
- `-d 1` — use for simple pages with few interactive elements

## Using Refs for Interaction

```bash
agent-browser click @e3               # click button
agent-browser fill @e5 "text"         # fill input field
agent-browser select @e7 "option"     # select dropdown value
agent-browser hover @e2               # hover over element
agent-browser type @e5 "text" --submit # type and submit
agent-browser get text @e3            # read element text
agent-browser get attribute @e3 href  # read element attribute
agent-browser check visible @e3       # check if element is visible
```

## Ref Lifecycle and Invalidation (CRITICAL)

Refs are valid ONLY until the next navigation or DOM mutation. After ANY of these events, all refs are **STALE** — you must re-snapshot:

- Page navigation (`open`, `back`, `forward`, `reload`)
- Form submission
- SPA route change
- Dynamic content load (AJAX, WebSocket)
- Dialog open/close
- Tab switch

### The Fundamental Pattern

```
snapshot → interact → snapshot again → interact again
```

**Never** reuse refs across navigations or dynamic updates.

### Example: Login Flow

```bash
agent-browser open https://app.example.com/login
agent-browser snapshot -i                    # → @e1=email, @e2=password, @e3=submit
agent-browser fill @e1 "user@test.com"
agent-browser fill @e2 "password123"
agent-browser click @e3                      # triggers navigation
agent-browser wait --load networkidle
agent-browser snapshot -i                    # MUST re-snapshot — old refs are stale
# → @e1=dashboard-link, @e2=settings, ...   # new ref assignments
```

## Iframe Handling (v0.21+)

In v0.21+, snapshots automatically inline iframe content (one level deep):

- Refs assigned to iframe elements carry frame context
- `click @e5` works even if `@e5` is inside an iframe — no manual `frame switch` needed
- For deeper nesting (iframe within iframe): use `agent-browser frame list` + `agent-browser frame switch <id>`

```bash
agent-browser snapshot -i    # auto-includes iframe content
agent-browser click @e5      # works even if @e5 is in an iframe
```

## Scoped Snapshots

Reduce noise by scoping to a specific container:

```bash
# Only elements inside #checkout-form
agent-browser snapshot -i -s "#checkout-form"

# Only elements inside a modal
agent-browser snapshot -i -s "[role='dialog']"
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Ref not found" | Re-snapshot — element may have changed after interaction |
| "Element not visible" | Scroll first (`agent-browser scroll down`), then re-snapshot |
| "Too many elements" | Scope with `-s "#container"` or reduce depth to `-d 1` |
| "Wrong element clicked" | Check snapshot output — ref numbers change after every snapshot |
| "Stale refs after SPA navigation" | Always re-snapshot after any navigation or route change |
