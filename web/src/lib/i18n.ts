import { currentRelease } from './downloads';

export type Lang = 'en' | 'vi';

export type ProviderItem = { name: string; color: string; source: string; detail: string };
export type FeatureItem = { title: string; detail: string };

export type Messages = {
  meta: { name: string; tagline: string; description: string };
  nav: {
    features: string;
    cliGuide: string;
    providers: string;
    privacy: string;
    install: string;
    releases: string;
    github: string;
    language: string;
  };
  hero: {
    badge: string;
    titleA: string;
    titleB: string;
    subtitle: string;
    download: string;
    viewReleases: string;
    viewSource: string;
    /** Use `{version}` placeholder. */
    versionNote: string;
    pillAria: string;
    cardTitle: string;
    cardAccount: string;
    cardStatus: string;
    mockNote: string;
  };
  providers: { eyebrow: string; title: string; subtitle: string; items: ProviderItem[] };
  features: { eyebrow: string; title: string; subtitle: string; items: FeatureItem[] };
  privacy: { eyebrow: string; title: string; subtitle: string; rows: string[][]; principles: string[] };
  install: {
    eyebrow: string;
    title: string;
    subtitle: string;
    requirements: string;
    steps: string[];
    commands: string[];
    binaries: string;
  };
  faq: { eyebrow: string; title: string; items: { q: string; a: string }[] };
  footer: { tagline: string; releases: string; source: string; issues: string; license: string };
  releasesPage: {
    eyebrow: string;
    title: string;
    subtitle: string;
    latest: string;
    downloadAsset: string;
    downloadTag: string;
    buildFromSource: string;
    buildCommand: string;
    empty: string;
  };
  notFound: { title: string; subtitle: string; home: string };
  lang: { en: string; vi: string; label: string };
  a11y: {
    skipToContent: string;
    primaryNav: string;
    pageScroll: string;
    toggleTheme: string;
    switchToLight: string;
    switchToDark: string;
  };
};

const en: Messages = {
  meta: {
    name: 'AI Usage Monitor',
    tagline: 'Every AI coding limit, in your menu bar.',
    description:
      'A native macOS menu bar app that tracks Claude Code, Codex, Cursor, Copilot and OpenCode usage quotas with reset countdowns.',
  },
  nav: {
    features: 'Features',
    cliGuide: 'CLI guide',
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
    versionNote: 'v{version} · macOS arm64',
    pillAria: 'Menu bar preview showing highest usage at 42 percent',
    cardTitle: 'OpenAI Codex',
    cardAccount: 'you@example.com · Plus',
    cardStatus: 'Connected',
    mockNote: 'Interface mock-up rendered in CSS',
  },
  providers: {
    eyebrow: 'Providers',
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
    eyebrow: 'Features',
    title: 'Features',
    subtitle: 'Small surface, thoughtful behavior.',
    items: [
      {
        title: 'Live menu bar',
        detail: 'A single status item can follow the selected provider, highest usage, or recognized foreground app. Icon-only, combined, per-provider, critical-only, and fixed-provider displays remain available.',
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
      {
        title: 'Light and dark themes',
        detail: 'The website follows your system appearance by default. Switch themes from the header and your choice is remembered for future visits.',
      },
      {
        title: 'Terminal and JSON',
        detail: 'Query cached quota or aggregate local Claude Code and Codex token logs from shell scripts, tmux, and Starship. JSON output has stable fields; quota queries never refresh providers.',
      },
    ],
  },
  privacy: {
    eyebrow: 'Privacy',
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
    eyebrow: 'Install',
    title: 'Install',
    subtitle: 'Build from source in under a minute.',
    requirements: 'Requires macOS 14+ and Swift 6. Sign in to each provider CLI first.',
    steps: ['Clone the repository', 'Build the app bundle', 'Open it and enable providers in Settings'],
    commands: [
      'git clone https://github.com/thienle99-dev/ai-usage.git',
      'cd ai-usage && ./scripts/package-app.sh',
      'open dist/"AI Usage Monitor.app"',
    ],
    binaries: 'Prefer binaries? Tagged releases attach a signed .app under Releases.',
  },
  faq: {
    eyebrow: 'FAQ',
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
    eyebrow: 'Changelog',
    title: 'Releases',
    subtitle: 'Version history and downloads.',
    latest: 'Latest',
    downloadAsset: 'Download .zip →',
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
  lang: { en: 'EN', vi: 'VI', label: 'Language' },
  a11y: {
    skipToContent: 'Skip to content',
    primaryNav: 'Primary navigation',
    pageScroll: 'Page scroll',
    toggleTheme: 'Toggle color theme',
    switchToLight: 'Switch to light theme',
    switchToDark: 'Switch to dark theme',
  },
};

const vi: Messages = {
  meta: {
    name: 'AI Usage Monitor',
    tagline: 'Mọi giới hạn AI coding, ngay trên menu bar.',
    description:
      'Ứng dụng menu bar macOS hiển thị quota Claude Code, Codex, Cursor, Copilot và OpenCode kèm đếm ngược reset.',
  },
  nav: {
    features: 'Tính năng',
    cliGuide: 'Hướng dẫn CLI',
    providers: 'Providers',
    privacy: 'Riêng tư',
    install: 'Cài đặt',
    releases: 'Releases',
    github: 'GitHub',
    language: 'Ngôn ngữ',
  },
  hero: {
    badge: 'macOS 14+ · SwiftUI thuần · Không Electron',
    titleA: 'Mọi giới hạn AI coding,',
    titleB: 'ngay trên menu bar.',
    subtitle:
      'Phần trăm usage trực tiếp, đếm ngược reset và cảnh báo ngưỡng cho các công cụ AI bạn đang trả tiền. Chỉ đọc — tái dùng đăng nhập CLI sẵn có, không bao giờ lưu token.',
    download: 'Tải về',
    viewReleases: 'Xem releases',
    viewSource: 'Mã nguồn',
    versionNote: 'v{version} · macOS arm64',
    pillAria: 'Xem trước menu bar hiển thị usage cao nhất 42 phần trăm',
    cardTitle: 'OpenAI Codex',
    cardAccount: 'you@example.com · Plus',
    cardStatus: 'Đã kết nối',
    mockNote: 'Minh họa giao diện bằng CSS',
  },
  providers: {
    eyebrow: 'Providers',
    title: 'Providers',
    subtitle: 'Một nơi theo dõi, mọi quota quan trọng. Mỗi tích hợp đọc đăng nhập bạn đã có.',
    items: [
      {
        name: 'Claude Code',
        color: 'claude',
        source: 'OAuth usage endpoint',
        detail: 'Session, weekly, scoped theo model và usage credits. Đọc CLAUDE_CODE_OAUTH_TOKEN, ~/.claude hoặc Keychain đăng nhập.',
      },
      {
        name: 'Codex',
        color: 'codex',
        source: 'App-server local (JSON-RPC)',
        detail: 'Rate limit 5 giờ và weekly kèm reset. Gọi Codex CLI bạn đã cài; hỗ trợ nhiều home, chuyển bằng 1 click.',
      },
      {
        name: 'Cursor',
        color: 'muted',
        source: 'Session app local, chỉ đọc',
        detail: 'Đọc session đã đăng nhập của Cursor.app từ database local mà không sửa gì. Cookie cursor.com dự phòng lưu trong Keychain.',
      },
      {
        name: 'Copilot',
        color: 'muted',
        source: 'GitHub device flow',
        detail: 'Kết nối tài khoản GitHub bằng device authorization. Token nằm trong Keychain, không nằm trong app.',
      },
      {
        name: 'OpenCode',
        color: 'muted',
        source: 'Dashboard session cookie',
        detail: 'Dán Cookie header dashboard một lần; chỉ auth cookie OpenCode được giữ trong Keychain.',
      },
    ],
  },
  features: {
    eyebrow: 'Tính năng',
    title: 'Tính năng',
    subtitle: 'Nhỏ gọn nhưng chỉn chu.',
    items: [
      {
        title: 'Menu bar trực tiếp',
        detail: 'Một status item có thể theo provider đang chọn, provider usage cao nhất hoặc app foreground được nhận diện. Settings vẫn có chế độ chỉ icon, tổng hợp, từng provider, critical-only và provider cố định.',
      },
      {
        title: 'Ngưỡng cảnh báo',
        detail: 'Đặt mức warning và critical. Cards, bars và menu bar chuyển từ màu provider sang hổ phách rồi đỏ.',
      },
      {
        title: 'Đếm ngược reset',
        detail: 'Mọi window đều hiện thời điểm reset — mặc định tương đối, hover để xem giờ chính xác.',
      },
      {
        title: 'Chuyển account Codex',
        detail: 'Đăng ký nhiều Codex home và chuyển home live từ Settings. Chỉ move folder, không đụng credentials.',
      },
      {
        title: 'Stale trung thực',
        detail: 'Lỗi thì giữ snapshot tốt gần nhất, ghi rõ stale kèm lỗi — không bao giờ im lặng hiện số 0.',
      },
      {
        title: 'Mở cùng máy',
        detail: 'Khởi động cùng macOS và refresh theo lịch bạn chọn: 1–15 phút hoặc chỉ thủ công.',
      },
      {
        title: 'Giao diện sáng và tối',
        detail: 'Website mặc định theo giao diện hệ thống. Bạn có thể đổi theme ở thanh đầu trang và lựa chọn sẽ được lưu cho lần truy cập sau.',
      },
      {
        title: 'Terminal và JSON',
        detail: 'Truy vấn quota cache hoặc tổng hợp log token Claude Code/Codex từ shell, tmux và Starship. JSON có field ổn định; lệnh quota không refresh provider.',
      },
    ],
  },
  privacy: {
    eyebrow: 'Riêng tư',
    title: 'Privacy',
    subtitle: 'Chỉ đọc từ thiết kế. Không gì rời khỏi máy bạn.',
    rows: [
      ['Claude Code', 'OAuth token từ env, ~/.claude hoặc Keychain đăng nhập. Chỉ đọc, không ghi, không cache.'],
      ['Codex', 'Giao thức app-server local. App không bao giờ mở file auth.'],
      ['Cursor', 'Database session local mở read-only. Cookie dự phòng nằm trong Keychain.'],
      ['Copilot', 'Token device-flow GitHub nằm trong Keychain.'],
      ['OpenCode', 'Session cookie dashboard nằm trong Keychain.'],
    ],
    principles: [
      'Không mật khẩu/token trong preferences, log, screenshot hay app bundle.',
      'Endpoint của provider không chính thức và có thể đổi — app xuống cấp thành trạng thái unavailable rõ ràng.',
      'Snapshot cache local tại ~/Library/Application Support/AIUsage; credentials không bao giờ cache.',
    ],
  },
  install: {
    eyebrow: 'Cài đặt',
    title: 'Install',
    subtitle: 'Build từ source chưa tới một phút.',
    requirements: 'Cần macOS 14+ và Swift 6. Đăng nhập từng provider CLI trước.',
    steps: ['Clone repository', 'Build app bundle', 'Mở app và bật providers trong Settings'],
    commands: [
      'git clone https://github.com/thienle99-dev/ai-usage.git',
      'cd ai-usage && ./scripts/package-app.sh',
      'open dist/"AI Usage Monitor.app"',
    ],
    binaries: 'Muốn bản build sẵn? Release có tag đính kèm .app tại trang Releases.',
  },
  faq: {
    eyebrow: 'FAQ',
    title: 'FAQ',
    items: [
      {
        q: 'App có lưu token của tôi không?',
        a: 'Không. App đọc đăng nhập CLI đã tạo sẵn, không giữ gì liên quan credentials trong preferences/log, không ghi ngược vào file provider (chuyển account Codex cũng chỉ move folder).',
      },
      {
        q: 'Sao dữ liệu bị đánh dấu stale?',
        a: 'Lần refresh lỗi — mạng, auth hết hạn, hoặc endpoint đổi. Snapshot tốt gần nhất vẫn hiện kèm tuổi và lỗi, kỳ refresh sau tự thử lại.',
      },
      {
        q: 'Chuyển account Codex thế nào?',
        a: 'Đăng ký mỗi Codex home một lần trong Settings → Providers → Codex homes, rồi bấm “Make active”. App swap folder vào ~/.codex và refresh.',
      },
      {
        q: 'Số liệu lệch với CLI. Vì sao?',
        a: 'Endpoint không chính thức và thay đổi. Window, scope và ngữ nghĩa reset có thể khác giữa góc nhìn OAuth/API và CLI. Payload lạ hiện unavailable chứ không đoán.',
      },
      {
        q: 'Hỗ trợ macOS nào?',
        a: 'macOS Sonoma (14) trở lên, cả Apple Silicon và Intel.',
      },
    ],
  },
  footer: {
    tagline: 'Tiện ích menu bar cho quota AI coding.',
    releases: 'Releases',
    source: 'Mã nguồn',
    issues: 'Issues',
    license:
      'Giấy phép MIT. Tham khảo thiết kế/tích hợp: claude-usage-widget của bozdemir và codex-usage-bar của CMMUU.',
  },
  releasesPage: {
    eyebrow: 'Nhật ký thay đổi',
    title: 'Releases',
    subtitle: 'Lịch sử phiên bản và tải về.',
    latest: 'Mới nhất',
    downloadAsset: 'Tải .zip →',
    downloadTag: 'Trang release',
    buildFromSource: 'Chưa có binary? Build từ source:',
    buildCommand: 'git clone https://github.com/thienle99-dev/ai-usage.git && cd ai-usage && ./scripts/package-app.sh',
    empty: 'Chưa có release nào. Binary sẽ xuất hiện từ release có tag đầu tiên.',
  },
  notFound: {
    title: 'Không tìm thấy trang',
    subtitle: 'Trang này không tồn tại.',
    home: 'Về trang chủ',
  },
  lang: { en: 'EN', vi: 'VI', label: 'Ngôn ngữ' },
  a11y: {
    skipToContent: 'Bỏ qua điều hướng, đến nội dung',
    primaryNav: 'Điều hướng chính',
    pageScroll: 'Tiến độ cuộn trang',
    toggleTheme: 'Đổi giao diện sáng tối',
    switchToLight: 'Chuyển sang giao diện sáng',
    switchToDark: 'Chuyển sang giao diện tối',
  },
};

export const messages: Record<Lang, Messages> = { en, vi };

export function isLang(value: string | null | undefined): value is Lang {
  return value === 'en' || value === 'vi';
}

/** Strip leading /vi locale prefix from a pathname. */
export function stripLangPrefix(pathname: string): string {
  if (pathname === '/vi' || pathname === '/vi/') return '/';
  if (pathname.startsWith('/vi/')) {
    const rest = pathname.slice(3);
    return rest.startsWith('/') ? rest : `/${rest}`;
  }
  return pathname || '/';
}

/** Resolve language from /vi path (static-friendly) or ?lang=. */
export function resolveLang(url: URL): Lang {
  const q = url.searchParams.get('lang');
  if (isLang(q)) return q;
  const path = url.pathname.replace(/\/+$/, '') || '/';
  if (path === '/vi' || path.startsWith('/vi/')) return 'vi';
  return 'en';
}

/** Locale-aware internal path. EN = `/…`, VI = `/vi/…`. */
export function withLang(path: string, lang: Lang): string {
  const hashIndex = path.indexOf('#');
  const hash = hashIndex >= 0 ? path.slice(hashIndex) : '';
  const withoutHash = hashIndex >= 0 ? path.slice(0, hashIndex) : path;
  const [rawPath, query = ''] = withoutHash.split('?');
  const clean = stripLangPrefix(rawPath || '/');
  const normalized = clean === '/' ? '/' : clean.replace(/\/+$/, '');
  const localized =
    lang === 'vi' ? (normalized === '/' ? '/vi/' : `/vi${normalized}`) : normalized === '/' ? '/' : normalized;
  const q = query ? `?${query}` : '';
  return `${localized}${q}${hash}`;
}

/** Path segment for `withBase` (no leading slash). */
export function langBasePath(path: string, lang: Lang): string {
  return withLang(path, lang).replace(/^\//, '');
}

/** Replace `{version}` placeholders with the pinned marketing release (e.g. 0.1.0). */
export function withVersion(text: string, version = currentRelease): string {
  return text.replaceAll('{version}', version);
}
