# Releasing AI Usage Monitor

## Versioning

SemVer (`vX.Y.Z`). No tags exist yet — the first tagged release bootstraps
both the website Releases page and the Download links.

## Publish a release

```sh
# 1. Build the bundle
./scripts/package-app.sh

# 2. Zip it (keep the exact asset name; the website links the tag page)
cd dist
zip -r "AI-Usage-Monitor-vX.Y.Z-macos-arm64.zip" "AI Usage Monitor.app"
cd ..

# 3. Tag and publish with notes
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z dist/AI-Usage-Monitor-vX.Y.Z-macos-arm64.zip \
  --title "vX.Y.Z" --notes-file <notes-file>

# 4. Add the website entry
#    web/src/content/releases/vX.Y.Z.md (version, date, highlights + highlightsVi)
#    Push to main — Vercel redeploys and /releases updates.
```

## Checklist

- `swift build` and `swift test` green on a clean checkout.
- `./scripts/package-app.sh` produces a working `.app` on macOS 14+ (Apple Silicon and Intel if claimed).
- Release notes mention provider endpoint assumptions that changed, if any.
- Website entry added with both English highlights and Vietnamese highlights when available.
- Verify the Download flow from a Vercel preview deployment before merging to `main`.
