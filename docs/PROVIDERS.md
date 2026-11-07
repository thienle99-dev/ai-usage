# Providers, accounts and refresh

Details moved from the README.

## Usage and refresh

The popover lists every enabled provider with a one-line summary and its usage windows, as returned by the provider. Percentages outside 0–100 or missing percentages are treated as unavailable; the app does not invent values. Providers with several saved accounts show them as rows you can switch between.

The menu bar item has four display modes in **Settings → Menu Bar**: icon only, combined usage (the default), a single chosen provider, or the provider of the active app. Active-app detection uses app identity only; when no provider app is recognized it falls back to the chosen provider and then the highest usage. A previously saved mode that no longer exists falls back to combined usage.

The packaged app includes a macOS 14+ WidgetKit widget in small and medium sizes. Add **AI Usage Quota** from the macOS widget gallery to the desktop or Notification Center. It shows cached data for enabled providers and updates when the app refreshes; the widget never calls provider APIs. The widget uses the first valid usage window returned by each provider in the app's standard provider order. The shared container uses `group.com.local.aiusage`; distribution signing must register this App Group and sign the host app and widget with the same team. The local packaging script uses ad-hoc signing.

Refresh choices are 1, 5, 10, or 15 minutes, plus Manual only. Manual only fetches once at app launch and waits for an explicit refresh afterward. The Refresh button fetches providers independently; if one fails, the other can still update. A prior successful snapshot stays visible and is marked stale after a failure. Preferences and snapshots are stored under `~/Library/Application Support/AIUsage/`.

## Credentials and data sources

Claude credentials are looked up read-only in this order: `CLAUDE_CODE_OAUTH_TOKEN`, `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`, then the macOS login Keychain entries `Claude Code-credentials` and `Claude Code`. The app calls Claude's OAuth usage endpoint and profile endpoint. It never writes CLI credentials or logs token values. Claude usage requests retry HTTP 429 responses at most twice when `Retry-After` provides a positive delay, with each delay bounded to 30 seconds.

Codex usage is read from the local `codex app-server` over JSON-RPC (`account/read` and `account/rateLimits/read`). The app discovers the executable in common install locations and `PATH`; it does not read Codex auth files directly. The process is bounded by a timeout.

Cursor usage uses Cursor's session-authenticated `GET https://cursor.com/api/usage-summary` and `/api/auth/me` endpoints, following CodexBar's current source strategy. By default, the app reads `cursorAuth/accessToken` from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` using SQLite read-only mode, validates the JWT identity/expiry, then forms the `WorkosCursorSessionToken` cookie expected by Cursor's web API. An optional manual `cursor.com` cookie header can be stored in Keychain. The usage-summary endpoint is undocumented and may change. It reports included plan usage percentages, Auto/API breakdowns, on-demand usage, and billing-cycle end when Cursor provides them. See [CodexBar's Cursor provider notes](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md).

OpenCode usage uses the authenticated `opencode.ai` dashboard server functions to discover a workspace and read its rolling five-hour and weekly subscription usage. Add a browser Cookie header in Settings; only `auth`, `__Host-auth`, and `__Host-console_session` values are kept, in macOS Keychain. OpenCode's dashboard API and cookies are undocumented and may change. OpenCode Go and pay-as-you-go spend are not included in this provider yet. See [CodexBar's OpenCode provider notes](research/CodexBar/docs/opencode.md).

Command Code usage reads the API key from `~/.commandcode/auth.json` (written by `cmd login`) and calls Command Code's billing and usage endpoints (`/alpha/whoami`, `/alpha/billing/credits`, `/alpha/billing/subscriptions`, `/alpha/usage/summary`). It shows the monthly credits used, the 5-hour and weekly limits, the request count for the current period, days until renewal, and the signed-in email and plan. The request count is best-effort and omitted if that endpoint fails.

Antigravity usage reads the Antigravity CLI (`agy`) session from the shared Keychain item `gemini` / `antigravity` or `~/.gemini/antigravity-cli/antigravity-oauth-token`, and calls the Code Assist quota endpoints. The account identity comes from the token's email, including the top-level `id_token_email` field written by the CLI. macOS asks for permission the first time AI Usage reads that Keychain item, because the CLI owns it; choose **Always Allow** to avoid repeated prompts.

These provider endpoints/protocols are compatibility-sensitive and may change. Re-authenticate with the relevant CLI when the provider reports an authentication error. If Codex is unavailable, confirm `codex` is installed and can start `app-server`. If Claude usage is unavailable, sign in with Claude Code and try Refresh.

## Multiple accounts

Use the add-account button in the popover (or **Add account…** in **Settings → Accounts**) to keep more than one login per provider. Saved credentials live in the macOS Keychain, not in preferences or logs.

- **Claude and Codex:** save the current login, or sign in to another account in an isolated session without replacing the active one. The sign-in runs the installed CLI in a temporary config folder and imports the result when it finishes.
- **Antigravity:** the CLI has no login command and uses a single shared Keychain item, so it cannot be isolated. **Sign in to another account** saves the current account, signs `agy` out, opens Terminal running `agy`, and imports the new account as soon as the session changes. If you cancel before finishing, `agy` stays signed out until you switch back to a saved account from the popover. **Open Antigravity** is the alternative: switch Google accounts in the Antigravity app, then save the signed-in account.

From the command line, add a Codex account without replacing the active one:

```sh
./scripts/ai-usage codex login
```

The command runs the installed Codex CLI interactively with a new `CODEX_HOME` under `~/.ai-usage/accounts/codex/`. A successful login registers that home for switching in the app. It requires `codex` on `PATH`; interrupted or failed attempts leave their new folder in place and do not register it.
