# AI Usage Monitor

A native macOS 14+ menu bar app for checking Claude Code, Codex, and Cursor usage. The app uses SwiftUI, Foundation networking, the macOS Keychain APIs, and the local Codex app-server protocol. It has no third-party runtime dependencies.

## Build and run

Requires macOS 14+ and Swift 6 with the macOS SDK.

```sh
swift build
swift run
```

Create a runnable `.app` bundle:

```sh
./scripts/package-app.sh
open "dist/AI Usage Monitor.app"
```

The app is an agent-style menu bar app, so it has no Dock icon. Open Settings from the popover gear button. Settings include General, Appearance, Providers, and About tabs.

## Usage and refresh

The popover shows provider cards with the usage windows actually returned by the provider. Percentages outside 0–100 or missing percentages are treated as unavailable; the app does not invent values. The menu bar's combined percentage is the highest valid utilization among enabled providers. Other modes are icon only, provider-specific values, or a warning for any enabled window at/above the critical threshold.

Refresh choices are 1, 5, 10, or 15 minutes, plus Manual only. Manual only fetches once at app launch and waits for an explicit refresh afterward. The Refresh button fetches providers independently; if one fails, the other can still update. A prior successful snapshot stays visible and is marked stale after a failure. Preferences and snapshots are stored under `~/Library/Application Support/AIUsage/`.

## Credentials and data sources

Claude credentials are looked up read-only in this order: `CLAUDE_CODE_OAUTH_TOKEN`, `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`, then the macOS login Keychain entries `Claude Code-credentials` and `Claude Code`. The app calls Claude's OAuth usage endpoint and profile endpoint. It never writes CLI credentials or logs token values. Claude usage requests retry HTTP 429 responses at most twice when `Retry-After` provides a positive delay, with each delay bounded to 30 seconds.

Codex usage is read from the local `codex app-server` over JSON-RPC (`account/read` and `account/rateLimits/read`). The app discovers the executable in common install locations and `PATH`; it does not read Codex auth files directly. The process is bounded by a timeout.

Cursor usage uses Cursor's session-authenticated `GET https://cursor.com/api/usage-summary` and `/api/auth/me` endpoints, following CodexBar's current source strategy. By default, the app reads `cursorAuth/accessToken` from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` using SQLite read-only mode, validates the JWT identity/expiry, then forms the `WorkosCursorSessionToken` cookie expected by Cursor's web API. An optional manual `cursor.com` cookie header can be stored in Keychain. The usage-summary endpoint is undocumented and may change. It reports included plan usage percentages, Auto/API breakdowns, on-demand usage, and billing-cycle end when Cursor provides them. See [CodexBar's Cursor provider notes](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md).

These provider endpoints/protocols are compatibility-sensitive and may change. Re-authenticate with the relevant CLI when the provider reports an authentication error. If Codex is unavailable, confirm `codex` is installed and can start `app-server`. If Claude usage is unavailable, sign in with Claude Code and try Refresh.

## Development notes

- [Technical research and architecture plan](docs/TECHNICAL_PLAN.md)
- [Feature comparison and roadmap against CodexBar](docs/FEATURE_COMPARISON.md)
- [Documentation index](docs/README.md)

## Reference projects and attribution

The implementation was informed by these MIT-licensed projects; no source code is bundled from them:

- [claude-usage-widget](https://github.com/bozdemir/claude-usage-widget) — usage presentation, Claude endpoint and credential source investigation.
- [codex-usage-bar](https://github.com/CMMUU/codex-usage-bar) — local Codex app-server integration pattern.
- [CodexBar](https://github.com/steipete/CodexBar) — feature comparison and roadmap reference.
