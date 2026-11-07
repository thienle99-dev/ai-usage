# CLI and integrations

Details moved from the README.

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
./scripts/ai-usage waste --range 7d --format json
```

`quota` is read-only and uses the last app snapshot; it never refreshes providers or makes model requests. Omit `--provider` to print all supported providers, or pass a provider name/short name. Each provider includes a status, `stale` flag, account label, snapshot age and usage windows; each window has `used_percent`, `remaining_percent`, `resets_at` and detail when available. Missing percentages and dates are `null`/absent, never inferred. It exits with code `3` if the requested cache is unavailable. `report` scans local CLI logs only when invoked; `--group` accepts `day`, `provider`, `model`, `project` or `session`, and `--range` accepts `7d`, `30d` or `all`.

JSON uses stable snake_case field names and ISO 8601 timestamps. Report rows include input, output, cache and total tokens; `estimated_cost_usd` is `null` when no source estimate exists, and `cost_is_estimate` identifies local estimates.

`waste` is a review-only signal scanner for Claude Code logs. It counts repeated `Read` calls for the same file in a session and tool results larger than 20 KiB; it reports repeated/large output bytes, never inferred token counts or cost. It runs only when explicitly invoked and examines up to 10,000 directory entries and 500 candidate files, selects up to 100 newest among those, then reads at most the last 2 MiB per file, 64 MiB total and 1 MiB per JSONL line, within a 7- or 30-day event window. JSON coverage indicates when discovery hit its cap. File paths, commands, session IDs and log contents are not returned or saved; transient hashes are used to group repeats. It does not currently analyze Codex logs. For tmux, a compact text query can be used directly in a status line:

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

Open **Token & Cost Report…** from the popover menu to scan local Claude Code and Codex JSONL usage logs. The scan runs only when requested and reads token counts plus model, date, project folder, and session ID; it does not display or save message text. Reports can group by day, provider, model, project, or session. Claude Code's local `costUSD` is shown as an estimate, not billing data. Codex session logs do not provide billing cost here, so cost remains unavailable for Codex. Other providers expose quota but not per-request token usage to this app.

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
