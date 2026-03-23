# Authentication Patterns

Agent-browser supports multiple authentication approaches for E2E testing. Choose based on your scenario.

## Decision Matrix

| Scenario | Recommended Approach | Why |
|----------|---------------------|-----|
| Local dev, quick test | Import from browser | Fastest — reuse existing login |
| CI/CD pipeline | State files | Reproducible, no manual steps |
| Multi-user testing | Persistent profiles | Isolated per-user state |
| OAuth/SSO flows | Headed + state save | OAuth requires user interaction once |
| Arc test phase | Session persistence | Session reuse saves 3-8s/route |

## 1. Import from Running Chrome

Connect to an already-authenticated Chrome instance and save its state.

```bash
# Launch Chrome with debug port
google-chrome --remote-debugging-port=9222

# Connect and save state
agent-browser --auto-connect state save auth-state.json
```

## 2. Persistent Profiles

Browser profiles persist cookies, localStorage, and session data across runs.

```bash
agent-browser --profile staging-user open https://staging.example.com
# Profile data saved automatically — next run with same profile reuses auth
```

## 3. Session Persistence

Named sessions maintain browser state within a session lifetime.

```bash
agent-browser --session-name arc-e2e open https://app.example.com/login
agent-browser fill @e3 "user@test.com" && agent-browser fill @e4 "password" && agent-browser click @e5
# Session persists — next open reuses auth state
```

**Rune convention**: Arc test phase uses `--session-name arc-e2e-{timestamp}`.

## 4. Basic Login Flow

Direct form fill for simple username/password authentication.

```bash
agent-browser open https://app.example.com/login
agent-browser snapshot -i
agent-browser fill @e1 "username" && agent-browser fill @e2 "password"
agent-browser click @e3 && agent-browser wait --load networkidle
```

## 5. State Save/Restore

JSON export for reproducible CI/CD authentication.

```bash
# Save (once, after manual login)
agent-browser state save auth.json

# Restore (in every CI run)
agent-browser state restore auth.json
```

**Security**: State files contain credentials — add to `.gitignore`.

## 6. OAuth/SSO Flows

OAuth requires manual user interaction. Use headed mode to complete the flow once, then save state.

```bash
agent-browser --headed open https://app.example.com/auth/google
# User manually completes OAuth flow in browser window
agent-browser state save oauth-state.json
```

For `/rune:test-browser`, see [human-gates.md](../../test-browser/references/human-gates.md) for OAuth gate handling.

## 7. Two-Factor Authentication

Headed mode allows manual 2FA entry during automated flows.

```bash
agent-browser --headed open https://app.example.com/login
# Script fills credentials, pauses for manual 2FA entry
agent-browser fill @e1 "user@test.com" && agent-browser fill @e2 "password"
agent-browser click @e3
# Wait for user to complete 2FA manually
agent-browser wait --selector "#dashboard" --timeout 60s
agent-browser state save post-2fa-state.json
```

## 8. HTTP Basic Auth

Embed credentials in the URL.

```bash
agent-browser open "https://user:pass@example.com/admin"
```

## 9. Cookie-Based Auth

Direct cookie injection for token-based auth.

```bash
agent-browser cookie set session_token "abc123" --domain example.com --httponly --secure
agent-browser open https://example.com/dashboard
```

## 10. Token Refresh Handling

Bash wrapper for rotating tokens.

```bash
TOKEN=$(curl -s https://auth.example.com/token -d 'grant_type=client_credentials' | jq -r '.access_token')
agent-browser cookie set access_token "$TOKEN" --domain example.com
agent-browser open https://example.com/api-dashboard
```

## Rune-Specific Notes

- Arc test phase uses `--session-name arc-e2e-{timestamp}` convention
- State files should be `.gitignore`d (contain credentials)
- `/rune:test-browser` has human gate handling for OAuth flows
- Auth vault profiles are stored in the OS keychain or encrypted file — not exported to env vars or logs
