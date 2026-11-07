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
  };
  providers: { eyebrow: string; title: string; subtitle: string; items: ProviderItem[] };
  features: { eyebrow: string; title: string; subtitle: string; items: FeatureItem[] };
  showcase: {
    eyebrow: string;
    title: string;
    subtitle: string;
    popoverAlt: string;
    accountAlt: string;
    accountTitle: string;
    accountDetail: string;
    sampleNote: string;
  };
  privacy: { eyebrow: string; title: string; subtitle: string; rows: string[][]; principles: string[] };
  install: {
    eyebrow: string;
    title: string;
    subtitle: string;
    requirements: string;
    steps: string[];
    commands: string[];
    binaries: string;
    autoUpdateTitle: string;
    autoUpdate: string;
    firstLaunch: string;
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
      'A native macOS menu bar app that tracks Claude Code, Codex, Cursor, Antigravity, Command Code and more, with multiple accounts and reset countdowns.',
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
      'Live usage percentages, reset countdowns and threshold alerts for the AI coding tools you already pay for. It reuses your existing CLI logins, supports several accounts per provider, and keeps credentials in Keychain.',
    download: 'Download',
    viewReleases: 'See releases',
    viewSource: 'Source code',
    versionNote: 'v{version} · macOS arm64',
  },
  providers: {
    eyebrow: 'Providers',
    title: 'Providers',
    subtitle: 'Nine providers, one popover. Each integration reuses the login you already have.',
    items: [
      { name: 'Claude Code', color: 'claude', source: 'OAuth usage endpoint', detail: 'Session, weekly and model-scoped windows plus usage credits. Multiple accounts with isolated sign-in.' },
      { name: 'Codex', color: 'codex', source: 'Local app-server (JSON-RPC)', detail: '5-hour and weekly limits with resets. Runs the Codex CLI you installed; add accounts without replacing the active one.' },
      { name: 'Cursor', color: 'muted', source: 'Local app session, read-only', detail: 'Plan usage, Auto/API breakdown and billing-cycle end from Cursor.app’s signed-in session. Optional cookie fallback.' },
      { name: 'Antigravity', color: 'muted', source: 'Antigravity CLI session', detail: 'Per-account quota windows from the agy session. Add another Google account straight from the app.' },
      { name: 'Command Code', color: 'muted', source: 'Command Code API', detail: 'Monthly credits, 5-hour and weekly limits, request count, days to renew, plus your email and plan.' },
      { name: 'Copilot', color: 'muted', source: 'GitHub device flow', detail: 'Connect GitHub with device authorization. The token lives in Keychain.' },
      { name: 'Gemini', color: 'muted', source: 'Gemini CLI login', detail: 'Quota from the Gemini CLI login you already created.' },
      { name: 'Grok', color: 'muted', source: 'Local session', detail: 'Usage from your existing Grok sign-in, read-only.' },
      { name: 'OpenCode', color: 'muted', source: 'Dashboard session cookie', detail: 'Paste a dashboard Cookie header once; only OpenCode auth cookies are kept in Keychain.' },
    ],
  },
  features: {
    eyebrow: 'Features',
    title: 'Features',
    subtitle: 'Small surface, thoughtful behavior.',
    items: [
      { title: 'Liquid Glass popover', detail: 'A compact popover that uses the macOS 26 Liquid Glass material and falls back to a standard blur on earlier versions.' },
      { title: 'Multiple accounts', detail: 'Keep several Claude, Codex and Antigravity logins side by side and switch from the popover. Credentials stay in Keychain.' },
      { title: 'Live menu bar', detail: 'Four modes: icon only, combined usage, a single provider, or the provider of the app you are using.' },
      { title: 'Warning thresholds', detail: 'Set warning and critical percentages. Bars and the menu bar shift from provider color to amber to red.' },
      { title: 'Reset countdowns', detail: 'Every window shows when it resets, relative by default with the exact time one hover away.' },
      { title: 'Honest stale states', detail: 'Failures keep your last good snapshot, clearly labeled stale with the error. Never a silent zero.' },
      { title: 'Launch at login', detail: 'Starts with your Mac and refreshes every 1 to 15 minutes, or only when you ask.' },
      { title: 'Terminal and JSON', detail: 'Query cached quota or aggregate local Claude Code and Codex token logs from shell scripts, tmux and Starship. Quota queries never refresh providers.' },
      { title: 'English and Tiếng Việt', detail: 'The app and this site switch between English and Vietnamese, and follow your light or dark appearance.' },
    ],
  },
  showcase: {
    eyebrow: 'Accounts',
    title: 'One popover, every account',
    subtitle: 'Add a second login without signing out of the first.',
    popoverAlt: 'AI Usage popover listing Codex, Claude Code, Cursor, Google Antigravity and Command Code usage',
    accountAlt: 'Add Account window for Antigravity with save, sign in and open actions',
    accountTitle: 'Sign in to another Antigravity account',
    accountDetail: 'The app saves the current account, signs the CLI out, opens Terminal running agy, and imports the new account as soon as you finish. Switch back any time from the popover.',
    sampleNote: 'Screenshots use sample data.',
  },
  privacy: {
    eyebrow: 'Privacy',
    title: 'Privacy',
    subtitle: 'Read-only where possible. Nothing leaves your Mac except the provider requests themselves.',
    rows: [
      ['Claude Code', 'OAuth token from env, ~/.claude or the login Keychain. Read, never logged or cached.'],
      ['Codex', 'Local app-server protocol. Auth files are never opened by the app.'],
      ['Cursor', 'Local session database opened read-only. Optional cookie lives in Keychain.'],
      ['Antigravity', 'agy session read from its Keychain item or token file. macOS asks once; choose Always Allow.'],
      ['Command Code', 'API key read from ~/.commandcode/auth.json and sent only to api.commandcode.ai.'],
      ['Copilot', 'GitHub device-flow token in Keychain.'],
      ['OpenCode', 'Dashboard session cookies in Keychain.'],
      ['Saved accounts', 'Extra accounts are stored in the macOS Keychain, never in preferences or logs.'],
    ],
    principles: [
      'No passwords or tokens in preferences, logs, screenshots or the app bundle.',
      'Provider endpoints are unofficial and may change. The app degrades to clear unavailable states.',
      'Snapshots are cached locally under ~/Library/Application Support/AIUsage; credentials are never cached.',
    ],
  },
  install: {
    eyebrow: 'Install',
    title: 'Install',
    subtitle: 'Choose Homebrew, a shell installer, or a disk image.',
    requirements: 'Requires macOS 14 or later. Homebrew and the shell installer currently support Apple silicon.',
    steps: ['Install the latest release with Homebrew:', 'Or install from Terminal:', 'Or install manually from a disk image:'],
    commands: [
      'brew tap thienle99-dev/ai-usage https://github.com/thienle99-dev/ai-usage\nbrew install --cask thienle99-dev/ai-usage/ai-usage-monitor',
      'curl -fsSL https://raw.githubusercontent.com/thienle99-dev/ai-usage/main/install.sh | sh',
      'Download the latest DMG from the button above or Releases, then drag AI Usage Monitor to Applications.',
    ],
    binaries: 'If macOS blocks the first launch, Control-click the app, choose Open, then confirm.',
    autoUpdateTitle: 'Automatic updates',
    autoUpdate: 'Sparkle checks for updates automatically and prompts you when one is available. You can also check in Settings → About → Updates.',
    firstLaunch: 'Updates are downloaded from the project release feed and installed after you confirm.',
  },
  faq: {
    eyebrow: 'FAQ',
    title: 'FAQ',
    items: [
      { q: 'Does it store my tokens?', a: 'It reads the logins your CLIs already created and keeps nothing credential-like in preferences or logs. Accounts you add are kept in the macOS Keychain.' },
      { q: 'How do I add a second account?', a: 'Use the + button in the popover. Claude Code and Codex sign in to an isolated session. For Antigravity, “Sign in to another account” saves the current one, opens Terminal with agy, and imports the new account when you finish.' },
      { q: 'Why does macOS ask about “gemini” in my keychain?', a: 'The Antigravity CLI owns that Keychain item, so macOS asks before AI Usage reads it. Enter your login password and choose Always Allow.' },
      { q: 'Why is my data marked stale?', a: 'A refresh failed: network, expired auth, or a changed endpoint. The last good snapshot stays visible with its age and the error, and the next scheduled refresh retries.' },
      { q: 'The numbers disagree with my CLI. Why?', a: 'Provider endpoints are unofficial and evolve. Windows, scopes and reset semantics can differ between the API view and the CLI view. Unknown payloads show as unavailable rather than guessed.' },
      { q: 'Which macOS versions work?', a: 'macOS 14 and later. The popover uses Liquid Glass on macOS 26 and a standard blur earlier. Releases are built for Apple silicon.' },
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
      'Ứng dụng menu bar macOS hiển thị quota Claude Code, Codex, Cursor, Antigravity, Command Code và nhiều hơn, hỗ trợ nhiều account và đếm ngược reset.',
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
      'Phần trăm usage trực tiếp, đếm ngược reset và cảnh báo ngưỡng cho các công cụ AI bạn đang trả tiền. Tái dùng đăng nhập CLI sẵn có, hỗ trợ nhiều account cho mỗi provider và giữ credentials trong Keychain.',
    download: 'Tải về',
    viewReleases: 'Xem releases',
    viewSource: 'Mã nguồn',
    versionNote: 'v{version} · macOS arm64',
  },
  providers: {
    eyebrow: 'Providers',
    title: 'Providers',
    subtitle: 'Chín provider, một popover. Mỗi tích hợp tái dùng đăng nhập bạn đã có.',
    items: [
      { name: 'Claude Code', color: 'claude', source: 'OAuth usage endpoint', detail: 'Cửa sổ session, weekly và theo model cùng usage credits. Nhiều account, đăng nhập tách biệt.' },
      { name: 'Codex', color: 'codex', source: 'App-server local (JSON-RPC)', detail: 'Giới hạn 5 giờ và weekly kèm reset. Chạy Codex CLI bạn đã cài; thêm account mà không thay account đang dùng.' },
      { name: 'Cursor', color: 'muted', source: 'Session app local, chỉ đọc', detail: 'Plan usage, Auto/API và ngày hết chu kỳ từ session đã đăng nhập của Cursor.app. Có cookie dự phòng.' },
      { name: 'Antigravity', color: 'muted', source: 'Session Antigravity CLI', detail: 'Quota theo account từ session agy. Thêm tài khoản Google khác ngay trong app.' },
      { name: 'Command Code', color: 'muted', source: 'Command Code API', detail: 'Credits hàng tháng, giới hạn 5 giờ và weekly, số request, ngày gia hạn, kèm email và plan.' },
      { name: 'Copilot', color: 'muted', source: 'GitHub device flow', detail: 'Kết nối GitHub bằng device authorization. Token nằm trong Keychain.' },
      { name: 'Gemini', color: 'muted', source: 'Đăng nhập Gemini CLI', detail: 'Quota từ đăng nhập Gemini CLI bạn đã tạo.' },
      { name: 'Grok', color: 'muted', source: 'Session local', detail: 'Usage từ đăng nhập Grok sẵn có, chỉ đọc.' },
      { name: 'OpenCode', color: 'muted', source: 'Session cookie dashboard', detail: 'Dán Cookie header dashboard một lần; chỉ auth cookie OpenCode được giữ trong Keychain.' },
    ],
  },
  features: {
    eyebrow: 'Tính năng',
    title: 'Tính năng',
    subtitle: 'Giao diện nhỏ gọn, hành vi cẩn trọng.',
    items: [
      { title: 'Popover Liquid Glass', detail: 'Popover gọn dùng chất liệu Liquid Glass của macOS 26, tự quay về blur tiêu chuẩn trên bản cũ hơn.' },
      { title: 'Nhiều account', detail: 'Giữ nhiều đăng nhập Claude, Codex và Antigravity cạnh nhau, chuyển ngay trong popover. Credentials nằm trong Keychain.' },
      { title: 'Menu bar trực tiếp', detail: 'Bốn chế độ: chỉ icon, usage gộp, một provider, hoặc provider của app bạn đang dùng.' },
      { title: 'Ngưỡng cảnh báo', detail: 'Đặt phần trăm cảnh báo và nghiêm trọng. Thanh usage và menu bar đổi từ màu provider sang vàng rồi đỏ.' },
      { title: 'Đếm ngược reset', detail: 'Mỗi cửa sổ cho biết khi nào reset, mặc định là tương đối, rê chuột để xem giờ chính xác.' },
      { title: 'Trạng thái cũ minh bạch', detail: 'Khi lỗi, snapshot tốt gần nhất vẫn hiển thị và được gắn nhãn stale kèm lỗi. Không bao giờ hiện số 0 âm thầm.' },
      { title: 'Mở khi đăng nhập', detail: 'Khởi động cùng máy và refresh mỗi 1 đến 15 phút, hoặc chỉ khi bạn yêu cầu.' },
      { title: 'Terminal và JSON', detail: 'Truy vấn quota cache hoặc tổng hợp log token Claude Code/Codex từ shell, tmux và Starship. Lệnh quota không refresh provider.' },
      { title: 'Tiếng Anh và Tiếng Việt', detail: 'App và website chuyển giữa tiếng Anh và tiếng Việt, theo giao diện sáng hoặc tối của bạn.' },
    ],
  },
  showcase: {
    eyebrow: 'Tài khoản',
    title: 'Một popover, mọi account',
    subtitle: 'Thêm đăng nhập thứ hai mà không cần đăng xuất tài khoản đầu.',
    popoverAlt: 'Popover AI Usage liệt kê usage của Codex, Claude Code, Cursor, Google Antigravity và Command Code',
    accountAlt: 'Cửa sổ Add Account của Antigravity với các hành động lưu, đăng nhập và mở app',
    accountTitle: 'Đăng nhập tài khoản Antigravity khác',
    accountDetail: 'App lưu account hiện tại, đăng xuất CLI, mở Terminal chạy agy rồi tự nhập account mới ngay khi bạn đăng nhập xong. Có thể chuyển lại bất cứ lúc nào từ popover.',
    sampleNote: 'Ảnh chụp dùng dữ liệu mẫu.',
  },
  privacy: {
    eyebrow: 'Riêng tư',
    title: 'Riêng tư',
    subtitle: 'Chỉ đọc khi có thể. Không gì rời khỏi máy ngoài các request tới provider.',
    rows: [
      ['Claude Code', 'OAuth token từ env, ~/.claude hoặc Keychain đăng nhập. Chỉ đọc, không log, không cache.'],
      ['Codex', 'Giao thức app-server local. App không bao giờ mở file auth.'],
      ['Cursor', 'Database session local mở read-only. Cookie dự phòng nằm trong Keychain.'],
      ['Antigravity', 'Session agy đọc từ Keychain item hoặc file token. macOS hỏi một lần; chọn Always Allow.'],
      ['Command Code', 'API key đọc từ ~/.commandcode/auth.json và chỉ gửi tới api.commandcode.ai.'],
      ['Copilot', 'Token device-flow GitHub nằm trong Keychain.'],
      ['OpenCode', 'Session cookie dashboard nằm trong Keychain.'],
      ['Account đã lưu', 'Account thêm vào được lưu trong Keychain macOS, không nằm trong preferences hay log.'],
    ],
    principles: [
      'Không có mật khẩu hay token trong preferences, log, ảnh chụp hoặc app bundle.',
      'Endpoint của provider không chính thức và có thể đổi. App hạ cấp thành trạng thái unavailable rõ ràng.',
      'Snapshot cache local tại ~/Library/Application Support/AIUsage; credentials không bao giờ được cache.',
    ],
  },
  install: {
    eyebrow: 'Cài đặt',
    title: 'Install',
    subtitle: 'Chọn Homebrew, script cài đặt hoặc file DMG.',
    requirements: 'Yêu cầu macOS 14 trở lên. Homebrew và script hiện hỗ trợ Apple silicon.',
    steps: ['Cài bản mới nhất bằng Homebrew:', 'Hoặc cài từ Terminal:', 'Hoặc cài thủ công từ file DMG:'],
    commands: [
      'brew tap thienle99-dev/ai-usage https://github.com/thienle99-dev/ai-usage\nbrew install --cask thienle99-dev/ai-usage/ai-usage-monitor',
      'curl -fsSL https://raw.githubusercontent.com/thienle99-dev/ai-usage/main/install.sh | sh',
      'Tải DMG mới nhất bằng nút phía trên hoặc tại Releases, sau đó kéo AI Usage Monitor vào Applications.',
    ],
    binaries: 'Nếu macOS chặn lần mở đầu, Control-click ứng dụng, chọn Open rồi xác nhận.',
    autoUpdateTitle: 'Tự động cập nhật',
    autoUpdate: 'Sparkle tự kiểm tra bản cập nhật và thông báo khi có bản mới. Bạn cũng có thể kiểm tra trong Settings → About → Updates.',
    firstLaunch: 'Bản cập nhật được tải từ release feed của dự án và cài sau khi bạn xác nhận.',
  },
  faq: {
    eyebrow: 'FAQ',
    title: 'FAQ',
    items: [
      { q: 'App có lưu token của tôi không?', a: 'App đọc các đăng nhập CLI đã tạo sẵn và không giữ gì liên quan credentials trong preferences hay log. Account bạn thêm vào được lưu trong Keychain macOS.' },
      { q: 'Thêm account thứ hai thế nào?', a: 'Dùng nút + trong popover. Claude Code và Codex đăng nhập trong session tách biệt. Với Antigravity, “Sign in to another account” lưu account hiện tại, mở Terminal chạy agy và nhập account mới khi bạn xong.' },
      { q: 'Sao macOS hỏi về “gemini” trong keychain?', a: 'Antigravity CLI sở hữu Keychain item đó nên macOS hỏi trước khi AI Usage đọc. Nhập mật khẩu đăng nhập và chọn Always Allow.' },
      { q: 'Sao dữ liệu bị đánh dấu stale?', a: 'Một lần refresh thất bại: mạng, auth hết hạn hoặc endpoint đã đổi. Snapshot tốt gần nhất vẫn hiển thị kèm tuổi và lỗi, lần refresh theo lịch tiếp theo sẽ thử lại.' },
      { q: 'Số liệu khác với CLI của tôi. Vì sao?', a: 'Endpoint của provider không chính thức và thay đổi. Cửa sổ, phạm vi và cách reset có thể khác giữa góc nhìn API và CLI. Payload lạ hiển thị là unavailable thay vì đoán.' },
      { q: 'macOS nào dùng được?', a: 'macOS 14 trở lên. Popover dùng Liquid Glass trên macOS 26 và blur tiêu chuẩn ở bản cũ hơn. Bản release build cho Apple silicon.' },
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
