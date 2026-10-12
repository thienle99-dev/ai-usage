# Research Folder Guidelines

## Purpose

This folder contains reference repositories and provider research used to inform the AI Usage Monitor. The application itself lives in the parent repository under `../Sources/AIUsage/`.

## Using References

- Before implementing or changing a provider, read the matching document in `CodexBar/docs/` when available (for example, `CodexBar/docs/antigravity.md` or `CodexBar/docs/grok.md`).
- For the `usage` reference, start with `usage/README.md` and relevant material in `usage/docs/`; then inspect the narrow provider implementation and its tests.
- Check whether the reference describes current behavior or a historical/internal API. Confirm assumptions against the app's current design and available upstream documentation.
- Prefer focused file and symbol searches. Avoid dumping entire repositories when a provider-specific doc, implementation, or test answers the question.

## Reference Repository Safety

- Treat `CodexBar/` and `usage/` as research inputs, not locations for application changes. Make product changes in the parent repository unless the user explicitly asks to modify a reference checkout.
- Check each reference repository's `git status` before any requested edits, and keep its history and working tree separate from the parent project.
- Review the relevant repository license before adapting source code. Preserve required notices and do not copy implementation code without confirming the license permits the intended use.
- Never copy real credentials, tokens, local account data, or secrets from research fixtures into the app.

## Reporting Findings

When using a reference, name the specific document or source file and note material limitations, such as undocumented endpoints, version-specific credential formats, or potentially stale quota schemas.
