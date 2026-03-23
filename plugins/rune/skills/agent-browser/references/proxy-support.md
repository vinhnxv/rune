# Proxy Support

Proxy configuration for corporate and CI environments.

## Environment Variable Proxy

```bash
HTTP_PROXY=http://proxy:8080 agent-browser open <url>
HTTPS_PROXY=http://proxy:8080 agent-browser open <url>
NO_PROXY=localhost,127.0.0.1 agent-browser open <url>
```

## Authenticated Proxy

```bash
HTTP_PROXY=http://user:pass@proxy:8080 agent-browser open <url>
```

## SOCKS5 Proxy

```bash
ALL_PROXY=socks5://proxy:1080 agent-browser open <url>
```

## Combined Configuration

```bash
HTTP_PROXY=http://proxy:8080 \
HTTPS_PROXY=http://proxy:8080 \
NO_PROXY=localhost,127.0.0.1,.internal.corp \
agent-browser open https://staging.example.com
```

## CI/CD Patterns

### GitHub Actions

```yaml
- name: E2E Tests
  env:
    HTTP_PROXY: ${{ vars.HTTP_PROXY }}
    HTTPS_PROXY: ${{ vars.HTTPS_PROXY }}
  run: agent-browser open https://staging.example.com
```

### GitLab CI

```yaml
e2e-tests:
  variables:
    HTTP_PROXY: http://proxy.corp:8080
  script:
    - agent-browser open https://staging.example.com
```

### Docker

```bash
docker run -e HTTP_PROXY=http://proxy:8080 \
  agent-browser open https://staging.example.com
```

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|---------|
| Connection refused | Wrong proxy address/port | Verify proxy is running: `curl -x http://proxy:8080 https://example.com` |
| SSL certificate errors | Proxy uses custom CA cert | Set `NODE_EXTRA_CA_CERTS=/path/to/ca.pem` |
| Timeout on HTTPS | Proxy doesn't support CONNECT | Use `HTTPS_PROXY` with a CONNECT-capable proxy |
| Auth required | Proxy needs credentials | Use `http://user:pass@proxy:8080` format |
| Localhost bypassed | `NO_PROXY` includes localhost | Remove localhost from `NO_PROXY` if testing via proxy |
