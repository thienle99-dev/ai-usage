# AI Usage Monitor — Website

Astro static site for the product landing page and releases. Ships to Vercel.

## Develop

```sh
cd web
npm install
npm run dev      # http://localhost:4321
npm run build    # static output in web/dist/
npm run preview  # serve the build locally
```

Requires Node 22.12+.

## Structure

Shares the dbplus site language: Tailwind v4 + dark-first theme (`src/styles/global.css`),
Bricolage Grotesque / Figtree / IBM Plex Mono, `SiteHeader` / `SiteFooter` /
`LangSwitcher`, `ScrollProgress` + `ScrollReveal`, `lib/i18n.ts` (`Messages` type +
`withLang` helpers), `lib/paths.ts` (`withBase`), `lib/downloads.ts` (pinned
`currentRelease` + asset URLs). Brand accents are teal/sand from
`Sources/AIUsage/Theme.swift` instead of dbplus blue.

- `src/pages/index.astro` — English landing (`/`)
- `src/pages/vi/index.astro` — Vietnamese landing (`/vi/`)
- `src/pages/releases.astro`, `src/pages/vi/releases.astro` — changelog + downloads
- `src/pages/404.astro`, `src/pages/vi/404.astro`
- `src/lib/i18n.ts` — all copy as `messages: Record<Lang, Messages>`; the build
  fails on EN/VI shape drift
- `src/content/releases/*.md` — one file per version (`version`, `date`,
  `highlights`, optional `highlightsVi`)
- `src/layouts/Base.astro` — shell, fonts, OG tags, skip link
- `src/components/` — `Hero.astro` (CSS interface mock-up), `Sections.astro`
  (providers/features/privacy/install/FAQ)

## Add a release

1. Add `src/content/releases/vX.Y.Z.md` with `version`, `date`, `highlights` (+ `highlightsVi` when translated).
2. Publish the GitHub release with attached binaries (see `docs/RELEASING.md`) — the page links each version to its tag.
3. `npm run build` to verify, push; Vercel deploys automatically.

## Deploy (Vercel)

- Import `github.com/thienle99-dev/ai-usage`, framework preset **Astro**.
- Root Directory: `web`. Build command `npm run build` (default). No env vars needed.
- Every push gets a preview deployment; `main` updates production.
