export const en = {
  meta: {
    name: 'AI Usage Monitor',
    tagline: 'Every AI coding limit, in your menu bar.',
    description:
      'A native macOS menu bar app that tracks Claude Code, Codex, Cursor, Copilot and OpenCode usage quotas with reset countdowns.',
  },
  nav: {
    features: 'Features',
    providers: 'Providers',
    privacy: 'Privacy',
    install: 'Install',
    releases: 'Releases',
    github: 'GitHub',
    language: 'Language',
  },
  hero: {
    badge: 'macOS 14+ · Native SwiftUI · No Electron',
    titleA: 'Every AI coding limit,',
    titleB: 'in your menu bar.',
    subtitle:
      'Live usage percentages, reset countdowns and threshold alerts for the AI coding tools you already pay for. Read-only by design — it reuses your existing CLI logins and never stores a token.',
    download: 'Download',
    viewReleases: 'See releases',
    viewSource: 'Source code',
    pillAria: 'Menu bar preview showing highest usage at 42 percent',
    cardTitle: 'OpenAI Codex',
    cardAccount: 'you@example.com · Plus',
    cardStatus: 'Connected',
    mockNote: 'Interface mock-up rendered in CSS',
  },
  providers: {
    title: 'Providers',
    subtitle: 'One monitor, every quota that matters. Each integration reads the login you already have.',
    items: [
      {
        name: 'Claude Code',
        color: 'claude',
        source: 'OAuth usage endpoint',
        detail: 'Session, weekly and model-scoped windows plus usage credits. Reads CLAUDE_CODE_OAUTH_TOKEN, ~/.claude credentials or the login Keychain item.',
      },
      {
        name: 'Codex',
        color: 'codex',
        source: 'Local app-server (JSON-RPC)',
        detail: '5-hour and weekly rate limits with resets. Spawns the Codex CLI you installed; supports multiple homes with one-click folder-swap switching.',
      },
      {
        name: 'Cursor',
        color: 'muted',
        source: 'Local app session, read-only',
        detail: 'Reads Cursor.app’s signed-in session from its local database without modifying it. Optional cursor.com cookie fallback in Keychain.',
      },
      {
        name: 'Copilot',
        color: 'muted',
        source: 'GitHub device flow',
        detail: 'Connect your GitHub account with device authorization. The token lives in Keychain, never in the app.',
      },
      {
        name: 'OpenCode',
        color: 'muted',
        source: 'Dashboard session cookie',
        detail: 'Paste a dashboard Cookie header once; only OpenCode auth cookies are kept in Keychain.',
      },
    ],
  },
  features: {
    title: 'Features',
    subtitle: 'Small surface, thoughtful behavior.',
    items: [
      {
        title: 'Live menu bar',
        detail: 'Four display modes: icon only, combined highest usage, per-provider, or critical-only. Monospaced digits so the number never jitters.',
      },
      {
        title: 'Warning thresholds',
        detail: 'Set warning and critical percentages. Cards, bars and the menu bar shift from provider color to amber to red.',
      },
      {
        title: 'Reset countdowns',
        detail: 'Every window shows when it resets — relative by default with the exact time one hover away.',
      },
      {
        title: 'Codex account switching',
        detail: 'Register multiple Codex homes and swap the live one from Settings. Only folders move; credentials are never touched.',
      },
      {
        title: 'Honest stale states',
        detail: 'Failures keep your last good snapshot, clearly labeled stale with the error — never a silent zero.',
      },
      {
        title: 'Launch at login',
        detail: 'Starts with your Mac and refreshes on a schedule you choose: 1 to 15 minutes, or manual only.',
      },
    ],
  },
  privacy: {
    title: 'Privacy',
    subtitle: 'Read-only by design. Nothing leaves your Mac.',
    rows: [
      ['Claude Code', 'OAuth token from env, ~/.claude, or login Keychain. Read, never written or cached.'],
      ['Codex', 'Local app-server protocol. Auth files are never opened by the app.'],
      ['Cursor', 'Local session database opened read-only. Optional cookie lives in Keychain.'],
      ['Copilot', 'GitHub device-flow token in Keychain.'],
      ['OpenCode', 'Dashboard session cookies in Keychain.'],
    ],
    principles: [
      'No passwords or tokens in preferences, logs, screenshots or the app bundle.',
      'Provider endpoints are unofficial and may change — the app degrades to clear unavailable states.',
      'Snapshots cached locally under ~/Library/Application Support/AIUsage; credentials never cached.',
    ],
  },
  install: {
    title: 'Install',
    subtitle: 'Build from source in under a minute.',
    requirements: 'Requires macOS 14+ and Swift 6. Sign in to each provider CLI first.',
    steps: [
      'Clone the repository',
      'Build the app bundle',
      'Open it and enable providers in Settings',
    ],
    commands: [
      'git clone https://github.com/thienle99-dev/ai-usage.git',
      'cd ai-usage && ./scripts/package-app.sh',
      'open dist/"AI Usage Monitor.app"',
    ],
    binaries: 'Prefer binaries? Tagged releases attach a signed .app under Releases.',
  },
  faq: {
    title: 'FAQ',
    items: [
      {
        q: 'Does it store my tokens?',
        a: 'No. It reads the logins your CLIs already created, keeps nothing credential-like in preferences or logs, and never writes back to provider files (Codex account switching only moves folders).',
      },
      {
        q: 'Why is my data marked stale?',
        a: 'A refresh failed — network, expired auth, or a changed endpoint. The last good snapshot stays visible with its age and the error, and the next scheduled refresh retries automatically.',
      },
      {
        q: 'How do I switch Codex accounts?',
        a: 'Register each Codex home folder once in Settings → Providers → Codex homes, then press “Make active”. The app swaps the folders into ~/.codex and refreshes.',
      },
      {
        q: 'The numbers disagree with my CLI. Why?',
        a: 'Provider endpoints are unofficial and evolve. Usage windows, scopes and reset semantics can differ between the OAuth/API view and the CLI view. Unknown payloads show as unavailable rather than guessed.',
      },
      {
        q: 'Which macOS versions work?',
        a: 'macOS Sonoma (14) and later, Apple Silicon and Intel.',
      },
    ],
  },
  footer: {
    tagline: 'A native menu bar utility for AI coding quotas.',
    releases: 'Releases',
    source: 'Source',
    issues: 'Issues',
    license:
      'MIT licensed. Design and integration references: claude-usage-widget by bozdemir and codex-usage-bar by CMMUU.',
  },
  releasesPage: {
    title: 'Releases',
    subtitle: 'Version history and downloads.',
    latest: 'Latest',
    downloadTag: 'Release page',
    buildFromSource: 'No binary attached yet? Build from source:',
    buildCommand: 'git clone https://github.com/thienle99-dev/ai-usage.git && cd ai-usage && ./scripts/package-app.sh',
    empty: 'No releases published yet. Binaries appear here starting with the first tagged release.',
  },
  notFound: {
    title: 'Page not found',
    subtitle: 'That page doesn’t exist.',
    home: 'Back to home',
  },
};

export type Dict = typeof en;
export type Lang = 'en' | 'vi';
