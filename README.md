# AI Usage Monitor

A standalone macOS 14+ menu bar app that displays Claude Code and Codex usage. It uses SwiftUI, Foundation networking, and the local Codex CLI; no third-party runtime packages are required.

## Build and run

```sh
swift build
swift run
```

Create a local `.app` bundle with `./scripts/package-app.sh`.

## Credentials and data

Claude credentials are read in this order: `CLAUDE_CODE_OAUTH_TOKEN`, `~/.claude/.credentials.json`, then the `Claude Code-credentials` item in the macOS login Keychain. Access is read-only. Codex is queried through `codex app-server`; its auth files are not read directly. Snapshots and preferences are stored locally under `~/Library/Application Support/AIUsage/`; credentials are never cached or logged.

The default poll interval is five minutes. Failures preserve the previous successful snapshot and show its stale status. For authentication failures, sign in again with the relevant CLI, then refresh. For missing Codex data, ensure `codex` is installed and available in PATH.

The Claude OAuth usage endpoint and Codex app-server protocol are unofficial integration details and may change. HTTP 429 responses are surfaced and polling continues at the configured interval.

## References and licenses

Design and behavior references: [claude-usage-widget](https://github.com/bozdemir/claude-usage-widget) and [codex-usage-bar](https://github.com/CMMUU/codex-usage-bar), both distributed under MIT. No source code from either project is bundled here.
