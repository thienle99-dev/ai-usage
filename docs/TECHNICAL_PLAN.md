# Technical research and implementation plan

**Status:** Implemented in this directory; live provider verification still depends on a machine with the corresponding CLI accounts signed in.

## Repository and references

The workspace has the independent `ai-usage/` Swift package and a separate `dbplus/` application. The two usage-widget reference repositories were not cloned into this workspace, so their public source and documentation were reviewed instead:

- `claude-usage-widget` (PySide6): the README and source describe `claude_usage/collector.py`, credential lookup, `/api/oauth/usage`, polling, and a compact progress/reset presentation. Its runtime uses PySide6 and certifi; none of those dependencies are used by this app.
- `codex-usage-bar` (SwiftUI): its README and `Sources/CodexUsageCore` describe launching the local `codex app-server`, then querying account and rate limits over JSON-RPC. It avoids directly reading Codex auth material.

Both references are MIT licensed. This project uses them for behavior and design guidance, not copied source.

## Retrieval and compatibility findings

### Claude Code

The app reads existing Claude OAuth credentials without writing them: environment variable, CLI credentials file (respecting `CLAUDE_CONFIG_DIR`), then login Keychain. `ClaudeProvider` calls `/api/oauth/usage` and `/api/oauth/profile`. Usage parsing accepts recognized session/weekly limits, scoped windows, and usage credits, while preserving provider values and rejecting percentages outside 0–100 for display. A bounded retry policy honors positive `Retry-After` values for HTTP 429, with at most two retries and a 30-second per-delay cap. Profile data is cached in memory to avoid repeat profile calls.

The OAuth endpoints and payload fields are undocumented compatibility points. A successful CLI `/usage` screen may use locally available accounting information that is absent from, or named differently in, the OAuth response. Unknown response windows remain unavailable rather than being interpreted as zero.

### Codex

The app discovers `codex` in common locations and `PATH`, starts `app-server`, and uses JSON-RPC `account/read` and `account/rateLimits/read`. It selects rate-limit windows from provider duration metadata, and reads account/plan information only when returned. Process startup and response waiting are bounded. No Codex token or auth file is opened by this integration.

The local app-server protocol is not a stable public usage API; method names, startup behavior, and response shapes can change across Codex releases. The adapter is isolated in `Providers.swift` so protocol changes do not reach SwiftUI views.

## UI patterns and architecture

The Claude reference's compact provider hierarchy, progress bars, reset labels, and subdued status copy informed the reusable SwiftUI usage cards. This native app uses `MenuBarExtra`, a 380-point scrollable popover, provider filter, refresh/settings actions, semantic appearance-aware colors, and a native tabbed Settings window. macOS System Appearance is the default, with Light and Dark overrides.

Normalized `UsageSnapshot` and `UsageWindow` models separate provider parsing from presentation. `UsageProvider` adapters are independent. `UsageStore` coordinates concurrent refreshes, keeps successful snapshots on failures, records per-provider status, persists snapshots/preferences, and schedules supported intervals. Manual only performs the initial startup fetch and later refreshes only on user action. Tests inject HTTP and Codex data sources to cover retry/status mapping, failure independence, stale data, and single-flight behavior.

## Sources

- [claude-usage-widget README and source](https://github.com/bozdemir/claude-usage-widget)
- [codex-usage-bar README and source](https://github.com/CMMUU/codex-usage-bar)
