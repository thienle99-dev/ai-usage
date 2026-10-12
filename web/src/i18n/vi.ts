import type { Dict } from './en';

export const vi: Dict = {
  meta: {
    name: 'AI Usage Monitor',
    tagline: 'Mọi giới hạn AI coding, ngay trên menu bar.',
    description:
      'Ứng dụng menu bar macOS hiển thị quota Claude Code, Codex, Cursor, Copilot và OpenCode kèm đếm ngược reset.',
  },
  nav: {
    features: 'Tính năng',
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
    pillAria: 'Xem trước menu bar hiển thị usage cao nhất 42 phần trăm',
    cardTitle: 'OpenAI Codex',
    cardAccount: 'you@example.com · Plus',
    cardStatus: 'Đã kết nối',
    mockNote: 'Minh họa giao diện bằng CSS',
  },
  providers: {
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
    title: 'Tính năng',
    subtitle: 'Nhỏ gọn nhưng chỉn chu.',
    items: [
      {
        title: 'Menu bar trực tiếp',
        detail: 'Bốn chế độ hiển thị: chỉ icon, usage cao nhất, từng provider, hoặc chỉ critical. Chữ số monospaced nên số không nhảy.',
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
    ],
  },
  privacy: {
    title: 'Riêng tư',
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
    title: 'Cài đặt',
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
    title: 'Releases',
    subtitle: 'Lịch sử phiên bản và tải về.',
    latest: 'Mới nhất',
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
};
