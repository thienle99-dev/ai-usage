# Repository Guidelines

## Project Structure

- `Sources/AIUsage/` contains the Swift 6 macOS menu bar app, provider integrations, models, and SwiftUI views.
- `Sources/CSQLite3/` defines the system SQLite module used for read-only Cursor session access.
- `Tests/AIUsageTests/` contains XCTest parser, provider, and store tests.
- `docs/` contains design and architecture notes. `research/` holds reference projects and provider research; do not treat reference code as app source.
- `scripts/package-app.sh` creates the distributable app bundle under `dist/`.

Before changing a provider, read its matching `research/CodexBar/docs/<provider>.md` when present, plus relevant docs and tests in `research/usage/` when applicable. Treat these as research references: verify assumptions against the current app and provider behavior before implementing them.

## Build and Development

Requires macOS 14 or later and Swift 6 with the macOS SDK.

```sh
swift build                 # Compile the app
swift test                  # Run the XCTest suite
swift run                   # Launch the menu bar app
./scripts/package-app.sh    # Build a distributable .app in dist/
```

Provider changes should keep network and credential access inside provider implementations, return normalized `UsageSnapshot` data, and avoid storing secrets in preferences or logs. Use fixtures and injected loaders for deterministic provider tests.

## Coding Style

Follow Swift conventions: four-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for properties and functions. Name integrations `<Name>Provider`; keep parsing helpers focused and testable. Use SwiftUI and platform APIs already present in the package, and avoid adding runtime dependencies without a clear need. No formatter or linter is currently configured.

## Testing

Tests use XCTest. Name test methods `test` plus the behavior being checked, such as `testCursorProviderUsesInjectedSessionAndUsageSummary`. Put provider and store behavior in `ProviderAndStoreTests.swift`; put shared data parsing checks in `ParserTests.swift`. Run `swift test` before submitting changes that affect app behavior.

## Commits and Pull Requests

Recent commits use short imperative subjects (for example, `Add Gemini provider for Code Assist quota tracking`). Keep commits focused and describe the user-visible change. Pull requests should summarize behavior, mention relevant tests, link related issues when available, and include screenshots for visible UI changes.

## Security and Configuration

Read provider credentials from their intended secure or local source. Keep Keychain values and OAuth tokens out of source control, fixtures, screenshots, and diagnostic output. Provider endpoints can change; document compatibility assumptions and preserve graceful unavailable or authentication-required states.
