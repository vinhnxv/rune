# Performance Profiling

Performance profiling during browser sessions using agent-browser.

## Network Timing (HAR Recording)

Capture full network activity in HAR 1.2 format:

```bash
agent-browser network har start
# ... navigate and interact ...
agent-browser network har stop perf-capture.har
```

Open the HAR file in Chrome DevTools (Network tab → Import HAR) or a HAR viewer.

## Page Load Metrics

Extract Web Vitals and navigation timing via JS eval:

```bash
agent-browser eval --stdin <<'EOF'
  const perf = performance.getEntriesByType('navigation')[0];
  JSON.stringify({
    domContentLoaded: perf.domContentLoadedEventEnd,
    load: perf.loadEventEnd,
    ttfb: perf.responseStart - perf.requestStart
  })
EOF
```

## Network Request Log

View all network requests with timing:

```bash
agent-browser network log
```

Output includes URL, method, status, timing, and transfer size for each request.

## Performance Budget Assertions

Combine HAR output with performance budgets in arc test assertions:

```bash
# Capture HAR
agent-browser network har start
agent-browser open https://app.example.com
agent-browser wait --load networkidle
agent-browser network har stop perf.har

# Assert TTFB < 500ms
agent-browser eval --stdin <<'EOF'
  const ttfb = performance.getEntriesByType('navigation')[0].responseStart;
  if (ttfb > 500) throw new Error(`TTFB too slow: ${ttfb}ms (budget: 500ms)`);
  `TTFB OK: ${ttfb}ms`
EOF
```

## Identifying Slow Pages

Use `network log` output to find:
- **Blocking requests** — requests that delay `domContentLoaded`
- **Large assets** — images, JS bundles, fonts over budget
- **Redirect chains** — multiple 301/302 hops adding latency
- **Third-party requests** — external scripts blocking render

## Arc Integration

During arc Phase 7.7, save HAR files to the standard output directory:

```
tmp/test/{timestamp}/network/
```

HAR filenames should include the route: `perf-login.har`, `perf-dashboard.har`.
