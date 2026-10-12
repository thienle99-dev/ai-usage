# AI Usage Monitor

A native macOS 14+ menu bar app for checking Claude Code, Codex, Cursor, and OpenCode usage. The app uses SwiftUI, Foundation networking, the macOS Keychain APIs, and the local Codex app-server protocol. It has no third-party runtime dependencies.

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

The packaged app includes a macOS 14+ WidgetKit widget in small and medium sizes. Add **AI Usage Quota** from the macOS widget gallery to the desktop or Notification Center. It shows cached data for enabled providers and updates when the app refreshes; the widget never calls provider APIs. The widget uses the first valid usage window returned by each provider in the app's standard provider order. The shared container uses `group.com.local.aiusage`; distribution signing must register this App Group and sign the host app and widget with the same team. The local packaging script uses ad-hoc signing.

Refresh choices are 1, 5, 10, or 15 minutes, plus Manual only. Manual only fetches once at app launch and waits for an explicit refresh afterward. The Refresh button fetches providers independently; if one fails, the other can still update. A prior successful snapshot stays visible and is marked stale after a failure. Preferences and snapshots are stored under `~/Library/Application Support/AIUsage/`.

## Credentials and data sources

Claude credentials are looked up read-only in this order: `CLAUDE_CODE_OAUTH_TOKEN`, `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`, then the macOS login Keychain entries `Claude Code-credentials` and `Claude Code`. The app calls Claude's OAuth usage endpoint and profile endpoint. It never writes CLI credentials or logs token values. Claude usage requests retry HTTP 429 responses at most twice when `Retry-After` provides a positive delay, with each delay bounded to 30 seconds.

Codex usage is read from the local `codex app-server` over JSON-RPC (`account/read` and `account/rateLimits/read`). The app discovers the executable in common install locations and `PATH`; it does not read Codex auth files directly. The process is bounded by a timeout.

Cursor usage uses Cursor's session-authenticated `GET https://cursor.com/api/usage-summary` and `/api/auth/me` endpoints, following CodexBar's current source strategy. By default, the app reads `cursorAuth/accessToken` from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` using SQLite read-only mode, validates the JWT identity/expiry, then forms the `WorkosCursorSessionToken` cookie expected by Cursor's web API. An optional manual `cursor.com` cookie header can be stored in Keychain. The usage-summary endpoint is undocumented and may change. It reports included plan usage percentages, Auto/API breakdowns, on-demand usage, and billing-cycle end when Cursor provides them. See [CodexBar's Cursor provider notes](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md).

OpenCode usage uses the authenticated `opencode.ai` dashboard server functions to discover a workspace and read its rolling five-hour and weekly subscription usage. Add a browser Cookie header in Settings; only `auth`, `__Host-auth`, and `__Host-console_session` values are kept, in macOS Keychain. OpenCode's dashboard API and cookies are undocumented and may change. OpenCode Go and pay-as-you-go spend are not included in this provider yet. See [CodexBar's OpenCode provider notes](research/CodexBar/docs/opencode.md).

These provider endpoints/protocols are compatibility-sensitive and may change. Re-authenticate with the relevant CLI when the provider reports an authentication error. If Codex is unavailable, confirm `codex` is installed and can start `app-server`. If Claude usage is unavailable, sign in with Claude Code and try Refresh.

## Quota-aware CLI preflight

Use the bundled wrapper before a large CLI task. It reads the last local usage snapshot and never refreshes quota or calls a model:

```sh
./scripts/ai-usage preflight --provider codex --estimated-tokens 6000
./scripts/ai-usage run --provider claude --estimated-tokens 6000 -- claude -p "Review this change"
```

Tasks estimated below 4,000 input tokens do not trigger a low-quota warning. For larger estimates, the wrapper compares the provider's most-used valid window with the warning threshold in Settings (70% by default). `run` asks for confirmation in an interactive terminal before launching the command; declining cancels it. If the snapshot is missing, older than 15 minutes, or marked with a local fetch error, the wrapper reports that quota could not be assessed and proceeds without a low-quota warning. Estimates are supplied by the caller; the wrapper does not inspect or store task prompts.

## CLI quota and JSON reports

Query quota cached by the app or generate a local token report from Claude Code and Codex logs:

```sh
./scripts/ai-usage quota --provider codex
./scripts/ai-usage quota --format json | jq '.providers[].windows[] | {label, used_percent, resets_at}'
./scripts/ai-usage report --group project --range 30d --format json
```

`quota` is read-only and uses the last app snapshot; it never refreshes providers or makes model requests. Omit `--provider` to print all supported providers, or pass a provider name/short name. Each provider includes a status, `stale` flag, account label, snapshot age and usage windows; each window has `used_percent`, `remaining_percent`, `resets_at` and detail when available. Missing percentages and dates are `null`/absent, never inferred. It exits with code `3` if the requested cache is unavailable. `report` scans local CLI logs only when invoked; `--group` accepts `day`, `provider`, `model`, `project` or `session`, and `--range` accepts `7d`, `30d` or `all`.

JSON uses stable snake_case field names and ISO 8601 timestamps. Report rows include input, output, cache and total tokens; `estimated_cost_usd` is `null` when no source estimate exists, and `cost_is_estimate` identifies local estimates. For tmux, a compact text query can be used directly in a status line:

```tmux
set -g status-right '#(./scripts/ai-usage quota --provider codex)'
```

For Starship, expose the same cached query as a custom module:

```toml
[custom.ai_usage]
command = "./scripts/ai-usage quota --provider codex"
format = "[$output]($style)"
style = "green"
```

Install the `scripts/ai-usage` wrapper on `PATH` or set `AI_USAGE_EXECUTABLE` to the packaged executable. The [website CLI guide](web/src/pages/cli.astro) includes the same examples and localized instructions.

## CLI status line

In **Settings → General → CLI Integration**, install the Claude Code status line to show quota from the last local snapshot. It reads no credentials and makes no network or model requests. AI Usage Monitor installs only when Claude Code has no existing `statusLine` configuration; removal is enabled only while the configured command still matches the app's ownership record. Claude Code may need to be restarted after changing the setting.

The same section can manage RTK hooks for Claude Code, Codex, and Gemini CLI when the RTK CLI is already installed. AI Usage Monitor does not install or update the RTK binary and offers removal only for integrations it recorded as app-managed. RTK compacts supported terminal command output; it does not reduce every model request or provider quota. The app does not enable RTK telemetry. To avoid removing existing hooks, the app leaves Gemini installations with pre-existing `BeforeTool` hooks for manual configuration.

## Context Mode for Claude Code

In **Settings → General → Claude Code Context Mode**, install the official Context Mode plugin from its Claude Code marketplace. Installation requires Claude Code v1.0.33+ and Node.js v22.5+; AI Usage Monitor does not install either prerequisite or bundle Context Mode source. It only removes a plugin and marketplace that it recorded as app-managed, and leaves an existing unmanaged installation untouched. Context Mode keeps local session and index data, and its `ctx_execute` tool runs code with Claude Code's filesystem permissions. AI Usage Monitor does not read Context Mode data or enable its settings automatically.

## Token and cost report

Open **Token & Cost Report…** from the dashboard layout menu to scan local Claude Code and Codex JSONL usage logs. The scan runs only when requested and reads token counts plus model, date, project folder, and session ID; it does not display or save message text. Reports can group by day, provider, model, project, or session. Claude Code's local `costUSD` is shown as an estimate, not billing data. Codex session logs do not provide billing cost here, so cost remains unavailable for Codex. Other providers expose quota but not per-request token usage to this app.

The formatter can also be used by compatible shell prompts and hooks:

```sh
./scripts/ai-usage statusline --provider Claude
```

Choose any supported provider name. Stale cached values are labeled `stale`; missing quota prints an unavailable message.

For Claude Code, the status line also reads session context and prompt-cache telemetry from the JSON input supplied by the CLI. Context warnings use the Settings threshold (80% by default); a cache miss is shown for three minutes with its reported cause when available. Prompt-cache telemetry requires Claude Code v2.1.251 or later; diagnosed miss causes require v2.1.260 or later. These warnings are local presentation only.

## Claude Code side pane

In **Settings → General → Claude Code Side Pane**, install the AI Usage pane managed by this app. It shows cached provider quotas, live Claude Code sessions, and background jobs. Quotas are read from the local snapshot; the pane does not fetch usage, read conversation transcripts, or make model requests. Claude Code v2.1.292 or later is required for installation. After installing or updating, start a new session or run `/reload-plugins`; use `/usage-pane` to reopen the pane. In narrower terminals Claude Code places panes above the prompt instead of in a right sidebar. Removal is limited to installations recorded as managed by AI Usage Monitor.

## Claude Code progress hand-off

Progress hand-off is off by default in **Settings → General → Progress hand-off**. After opting in, choose a live Claude Code session and prepare a preview. The app reads only the last text user request from the tail of that session's local JSONL transcript, Git status and staged/unstaged diff, plus explicit TODO/checklist lines from that request and added diff lines. The preview is shown before anything is passed to Claude. Untracked files are listed but not read, the diff is capped at 60,000 characters, and temporary hand-off files are removed when Terminal starts the new interactive session. The new session starts with the reviewed prompt in the selected project directory.

## Claude Code response modes

**Settings → General → Claude Code Response Modes** provides **Token Saver** and **Beginner Mode**, both off by default. With the AI Usage Monitor Claude Code plugin installed, enabled modes add short response preferences to each submitted prompt: Token Saver asks for concise answers without dropping important caveats; Beginner Mode asks for plain-language explanations of unfamiliar terms. The app makes no separate model request, but added prompt context can consume input tokens. Changes apply to the next prompt.

## Development notes

- [Technical research and architecture plan](docs/TECHNICAL_PLAN.md)
- [Feature comparison and roadmap against CodexBar](docs/FEATURE_COMPARISON.md)
- [Documentation index](docs/README.md)

## Reference projects and attribution

The implementation was informed by these MIT-licensed projects; no source code is bundled from them:

- [claude-usage-widget](https://github.com/bozdemir/claude-usage-widget) — usage presentation, Claude endpoint and credential source investigation.
- [codex-usage-bar](https://github.com/CMMUU/codex-usage-bar) — local Codex app-server integration pattern.
- [CodexBar](https://github.com/steipete/CodexBar) — feature comparison and roadmap reference.
