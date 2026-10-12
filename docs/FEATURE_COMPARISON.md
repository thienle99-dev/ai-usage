# Đối chiếu tính năng với CodexBar

**Ngày đối chiếu:** 2026-10-12  
**Ứng dụng:** AI Usage Monitor trong repo này  
**Tham khảo:** [steipete/CodexBar](https://github.com/steipete/CodexBar), chủ yếu là README và mục Providers/Features trên nhánh `main`.

CodexBar là ứng dụng trưởng thành với nhiều provider, nguồn xác thực và bề mặt sử dụng. AI Usage Monitor hiện tập trung vào Claude Code, Codex và Cursor. Bảng dưới đây đối chiếu tính năng dựa trên code đang có, không coi tính năng chỉ được nhắc trong README là đã hoàn tất.

## Đã có trong AI Usage Monitor

| Nhóm | Tính năng hiện có | Tình trạng |
|---|---|---|
| Ứng dụng macOS | SwiftUI `MenuBarExtra`, popover, cửa sổ Settings, quit | Có trong code |
| Provider | Claude Code OAuth, Codex CLI app-server, Cursor web usage API | Có adapter cho ba provider; Cursor dùng local Cursor.app auth hoặc cookie |
| Claude auth | Đọc `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR/.credentials.json` hoặc Keychain | Chỉ đọc; không lưu hoặc ghi token |
| Tài khoản Claude | Lấy email/tên và plan từ `/api/oauth/profile`, cache trong RAM theo token tối đa 6 giờ | Hiển thị dưới usage giống dòng account của Codex; nếu profile API không trả email/tên thì bỏ trống |
| Claude usage | Gọi `GET /api/oauth/usage`, parser hỗ trợ các trường legacy, `limits[]` (`session`, `weekly_all`, `weekly_scoped`) và Usage credits | Gửi OAuth beta header; retry tối đa 2 lần khi gặp HTTP 429 và tôn trọng `Retry-After` (tối đa 30 giây). Live quota windows chưa xác nhận |
| Codex usage | Tìm Codex CLI ở một số đường dẫn và gọi `account/read`, `account/rateLimits/read` qua JSON-RPC | Có timeout và parser cho response lồng nhau; live success chưa xác nhận |
| Cursor usage | `GET /api/usage-summary` và `/api/auth/me` qua session Cursor | Hiển thị Plan, Auto/Composer, API model và on-demand fields khi response có; nguồn endpoint không tài liệu công khai và có thể đổi |
| Hiển thị usage | Progress bar, phần trăm, tên window, thời gian reset tương đối | Hiện có khi provider trả dữ liệu nhận diện được |
| Làm mới | Nút refresh và chu kỳ 1, 5, 10, 15 phút hoặc Manual only; mặc định 5 phút | Có. Manual only vẫn fetch một lần khi app khởi động, sau đó chỉ fetch theo thao tác người dùng |
| Lỗi và cache | Giữ snapshot thành công gần nhất, hiển thị stale/error; lưu snapshot cục bộ | Có; không có lịch sử chuỗi snapshot |
| Tuỳ chỉnh | Ẩn/hiện provider, ngưỡng cảnh báo và nghiêm trọng, giao diện sáng/tối/hệ thống, bốn chế độ menu bar, launch at login | Có trong Settings |
| Phát triển | Swift Package Manager, parser/provider/store tests, script tạo `.app`, README và technical plan | Có; live provider calls và UI appearance cần xác nhận trên máy đã đăng nhập |

## Khác biệt so với CodexBar

| Nhóm | CodexBar có | AI Usage Monitor hiện thiếu |
|---|---|---|
| Số lượng provider | Nhiều provider cho coding plans, API billing, credits và gateways; danh sách cụ thể thay đổi theo phiên bản | Claude Code, Codex và Cursor; các provider khác mới có điều hướng |
| Nguồn dữ liệu / xác thực | Tuỳ provider: CLI, OAuth, API key, browser cookie, local app/config hoặc dashboard | Claude Code OAuth, local Codex app-server, Cursor.app local auth hoặc cookie nhập thủ công |
| Tùy biến menu bar | Icon provider, nhãn, bars/percent, reset style, chọn usage cao nhất, gộp nhiều provider, xếp layout | Có icon only, phần trăm cao nhất, provider-specific hoặc critical-only; chưa có sắp xếp provider/layout tùy chỉnh |
| Usage history | Lưu mẫu theo thời gian, biểu đồ và quota burndown cho provider hỗ trợ | Chỉ snapshot mới nhất và cache stale |
| Spend / cost | Ước tính và báo cáo chi phí theo provider, model, session/project và thời gian; mức hỗ trợ tuỳ nguồn | Chỉ hiển thị Claude Usage credits (đã dùng / giới hạn) nếu API trả về; không có lịch sử chi phí, model/session breakdown hoặc thống kê token |
| Dashboard bổ sung | Codex có thể bổ sung dữ liệu web như code review, breakdown và credits history | Không có nguồn dashboard hoặc số liệu bổ sung |
| Widgets | WidgetKit cho provider được hỗ trợ | Không có widget |
| Cảnh báo | Thông báo theo quota/session và sự kiện reset | Có màu theo ngưỡng trong popover; không có notification hoặc sự kiện reset |
| Trạng thái dịch vụ | Poll trạng thái provider, incident badge trên menu/icon | Chỉ báo lỗi của lần refresh cục bộ; không poll status page |
| CLI và tự động hoá | CLI `codexbar` cho cấu hình, provider và một số cost commands | Không có CLI riêng |
| Cấu hình | Cấu hình provider, API keys và tuỳ chọn có thể quản lý bằng CLI/config file | Preferences cơ bản lưu trong UserDefaults; không có import/export hay cấu hình CLI |
| Trải nghiệm sản phẩm | Localization nhiều ngôn ngữ, launch-at-login, updater, tài liệu cài đặt/phát hành và cấu hình chi tiết | Có launch-at-login cơ bản và script app bundle; chưa có localization, updater, signing/notarization hay quy trình phát hành hoàn chỉnh |
| An toàn / quyền riêng tư | Tài liệu hoá rõ nguồn đọc, quyền macOS và hành vi theo từng provider | Có nguyên tắc read-only và không lưu token trong README; chưa có trang quyền riêng tư/permission matrix chi tiết |

CodexBar mô tả các nhóm này trong [README](https://github.com/steipete/CodexBar#readme), cùng [tài liệu Providers](https://github.com/steipete/CodexBar/blob/main/docs/providers.md), [Configuration](https://github.com/steipete/CodexBar/blob/main/docs/configuration.md), [Widgets](https://github.com/steipete/CodexBar/blob/main/docs/widgets.md), [CLI](https://github.com/steipete/CodexBar/blob/main/docs/cli.md), và [Refresh loop](https://github.com/steipete/CodexBar/blob/main/docs/refresh-loop.md). Repo CodexBar được cập nhật thường xuyên nên danh sách provider và khả năng có thể đổi.

## Roadmap gợi ý

### P0 — Làm vững hai provider hiện tại

1. Xác nhận live Claude và Codex hoạt động trên máy thật; bổ sung fixture từ response đã ẩn dữ liệu nhạy cảm khi gặp kiểu payload mới. Không ghi token hay toàn bộ response vào log.
2. Với Claude, kiểm tra các trường hợp window null, model-scoped limits và reset timestamp; thông báo rõ khi account/plan không có window usage.
3. Với Codex, kiểm tra discovery của CLI/binary đi kèm ChatGPT app, response theo ID, account chưa đăng nhập, nhiều rate-limit pools và lựa chọn weekly theo duration.
4. Tách network/process client khỏi parser và inject dependency để kiểm thử timeout, auth failure, 429, response lỗi và lỗi độc lập giữa hai provider.
5. Cải thiện UX trạng thái đầu tiên: loading, chưa đăng nhập, không tìm thấy CLI, chưa có dữ liệu, stale kèm lần cập nhật thành công gần nhất.

### P1 — Lịch sử, menu bar và cảnh báo

1. Lưu lịch sử usage với retention giới hạn; thêm biểu đồ và quota burn-down.
2. Cho chọn layout menu bar: icon, provider, phần trăm, usage cao nhất, reset countdown; cho chỉnh thứ tự và gộp provider.
3. Thêm thông báo ngưỡng quota và tuỳ chọn cảnh báo gần reset; có snooze/disable để tránh thông báo quá thường xuyên.
4. Làm phần Settings thành các mục rõ ràng: Providers, Display, Notifications, Data/Privacy và About.

### P2 — Mở rộng dữ liệu và cách sử dụng

1. Thêm WidgetKit sau khi model snapshot/cache ổn định.
2. Thêm usage/cost theo model và session cho nguồn có thể đọc an toàn; phân biệt rõ số liệu API thực tế với ước tính từ log.
3. Thiết kế provider interface/config trước khi thêm provider mới; ưu tiên provider có API/CLI/local source ổn định.
4. Thêm CLI cho xem trạng thái, refresh và cấu hình provider.
5. Thêm localization, launch-at-login, updater, signing/notarization và hướng dẫn phát hành.

## Phụ lục A — Đã có (chi tiết, tại thời điểm đối chiếu)

| Nhóm | Chi tiết (kèm symbol/file trong repo này) |
|---|---|
| Provider enum | 9 cases (`codex, claude, cursor, copilot, gemini, windsurf, cline, roo, openCode`), `supported = [.codex, .claude, .cursor]`; mỗi case có `displayName/shortName/menuBarAbbreviation/systemImage` (`Models.swift`) |
| Claude adapter | `ClaudeProvider` inject `HTTPDataLoading`; token env → `CLAUDE_CONFIG_DIR/.credentials.json` → Keychain; `GET /api/oauth/usage` + beta `oauth-2025-04-20`; retry 429 tối đa 2 lần, tôn trọng `Retry-After` (cap 30s, `ClaudeRetryPolicy`); profile `/api/oauth/profile` cache RAM 6h theo fingerprint SHA256 (`Providers.swift`) |
| Codex adapter | `CodexProvider` inject `CodexAppServerDataSource`; discovery CLI nhiều đường dẫn + PATH; JSON-RPC `initialize` → `account/read` → `account/rateLimits/read`, timeout bounded, parse response lồng nhau, chọn weekly theo duration (`Providers.swift`) |
| Cursor adapter | Đọc read-only SQLite `Cursor/.../state.vscdb` (`CursorAppAuthStore`, cần `Sources/CSQLite3`), validate JWT expiry + userID, bọc `WorkosCursorSessionToken`; hoặc cookie thủ công trong Keychain; `GET /api/usage-summary` + `/api/auth/me` (`Providers.swift`) |
| Models | `UsageSnapshot` (`windows/account/lastSuccess/error/status`), `UsageWindow` (`label/utilization/resetsAt/detail`); `validUtilization` lọc giá trị ngoài 0–100 khỏi hiển thị/tổng hợp; `ProviderStatus` 5 trạng thái + map từ `ProviderFailure` (gồm cả `.network`) (`Models.swift`) |
| Store | Refresh đồng thời theo provider (task group), single-flight (bỏ qua provider đang refresh), `refresh(provider:)` riêng lẻ; lỗi giữ snapshot cũ + gán `status`; cache JSON local; `schedule()` theo `RefreshPolicy` 1/5/10/15 phút + Manual (manual vẫn fetch 1 lần lúc khởi động) (`UsageStore.swift`) |
| Menu bar | `MenuBarStatusView`: icon `chart.bar.fill` (hoặc `exclamationmark.triangle.fill` khi critical), text monospaced theo `MenuBarDisplayMode`: iconOnly / combinedUsage (%) / providerSpecific (`C 3% · A 5%`) / criticalProviderOnly; accessibility label + tooltip (`AIUsageApp.swift`) |
| Popover | `UsagePopover`: cards theo provider (progress bar, %, reset tương đối, account, stale/error), footer refresh/settings/quit; `ProviderIconNavigationView` điều hướng provider (mới) |
| Settings | Cửa sổ Settings riêng (680×500), sections Providers / Display / Thresholds / Status / About; appearance System/Light/Dark (`colorSchemeOverride`, `Theme.swift`); warning < critical tự kẹp; launch at login qua `SMAppService` |
| Tests | `ParserTests` (Claude/Codex/Cursor parsers) + `ProviderAndStoreTests` (inject HTTP/Codex sources: retry 429, status mapping, failure independence, stale, single-flight) |
| Tooling | SPM, `scripts/package-app.sh`, README + `TECHNICAL_PLAN.md` + file đối chiếu này |

## Phụ lục B — Còn thiếu (từ source CodexBar, kèm file gốc)

Chi tiết kiến trúc và thứ tự gợi ý ở [codexbar-research.md](codexbar-research.md).
`research/CodexBar/` = repo CodexBar.

### Menu bar & icon

| CodexBar có (source) | App này thiếu |
|---|---|
| Cached template image 18×18 cho text-only, `attributedTitle` cho stale/emoji/multiline; loading giới hạn FPS + trần thời gian (`docs/ui.md`) | Icon/text render trực tiếp bằng SwiftUI, chưa có render path tối ưu hay loading guard |
| Dim icon khi stale, incident overlay trên icon (`docs/ui.md`, `ProviderStatusFetcher`) | Chưa dim khi stale; chỉ màu ngưỡng trong popover |
| Color-by-provider opt-in + gate tương phản, về monochrome khi menu mở/stale (`docs/ui.md`, `docs/provider-palette.md`) | Chưa có |
| Merge Icons + switcher; nguồn gộp Current/Highest/Frontmost (`StatusItemController+SwitcherViews.swift`, `FrontmostProviderMonitor.swift`) | Chỉ 1 item Highest/combined; chưa gộp/chuyển provider |
| Token layout editor kéo-thả 1–2 dòng + per-provider override (`MenuBarLayout.swift` 218 symbols, `MenuBarLayoutEditor.swift`, `MenuBarLayoutRenderer.swift`) | 4 mode cố định, chưa tùy biến token/thứ tự |
| Pace token `+11%/-8%`, `Color Pace Indicator`, reset style countdown/absolute (`docs/ui.md`) | Chưa có pace; reset chỉ tương đối trong popover |
| Ổn định vị trí (autosave identity, giữ Cmd-drag, xóa item khi quit), chẩn đoán `CODEXBAR_STATUS_ITEM_DIAGNOSTICS=1` | Chưa có |

### Claude

| CodexBar có (source) | App này thiếu |
|---|---|
| Keychain gates/cooldowns/ACL repair, probe non-interactive trước (`ClaudeOAuthKeychain*Gate*.swift`, `ClaudeOAuthDirectKeychainReadConsent.swift`) | Đọc Keychain trực tiếp, chưa cooldown/chính sách prompt |
| Tự refresh `POST /v1/oauth/token`, `invalid_grant` chặn tới khi fingerprint đổi, 401 backoff mũ 6h (`ClaudeOAuthRefreshFailureGate.swift`, `ClaudeTokenRefresher` tương đương) | Nhờ Claude Code refresh, chưa tự refresh/backoff dài |
| Web cookies opt-in Safari→Chrome→Firefox + Manual header (`docs/claude.md#Web API`) | Chưa có nguồn web |
| CLI PTY fallback `/usage` parse frame (`ClaudeStatusProbe.swift`, `ClaudeCLISession.swift`, watchdog helper) | Chưa có |
| Admin API spend Today/7d/30d + chart (`ClaudeAdminAPIUsageFetcher.swift`) | Chưa có spend |
| Multi-account `tokenAccounts` + `claude-swap` (`ClaudeSwap/`, `StatusItemController+ClaudeSwapMenu.swift`) | Đơn account |
| Scoped-weekly mapper, Extra usage/Cloud credits/Reset credits, burndown Plan Usage (`ClaudeScopedWeeklyLimitMapper.swift`, `ClaudeRateLimitResetCredits.swift`) | Parser cơ bản session/weekly/credits |

### Codex

| CodexBar có (source) | App này thiếu |
|---|---|
| Chuỗi Auto PAT → OAuth → CLI RPC; OAuth trực tiếp `wham/usage` + JWT freshness, CLI sở hữu refresh (`CodexOAuthUsageFetcher.swift`, `CodexTokenRefresher.swift`, `docs/codex-oauth.md`) | Chỉ CLI RPC |
| Weekly-reset publication gate (giữ last-trusted khi reset khả nghi) (`docs/codex.md`, `codex-weekly-reset-publication`) | Tin timestamp server ngay |
| `additional_rate_limits[]` → extra windows ẩn/hiện (`CodexAdditionalRateLimitMapper.swift`) | Chưa map extra windows |
| Dashboard web opt-in: review/breakdown/credits history (`CodexWebDashboardStrategy.swift`) | Chưa có |
| Managed accounts, profile homes, System promotion (`ManagedCodexAccountCredentialResolver.swift`, `CodexAccountPromotion*.swift`) | Đơn home |
| Cost scan local JSONL + SQLite caps + burndown (`docs/codex.md`, `RemoteCodexCostFetcher.swift`) | Chưa có |

### Refresh, status, history, nền tảng

| CodexBar có (source) | App này thiếu |
|---|---|
| Adaptive refresh pure (`AdaptiveRefreshPolicyCore`: menu-recency 2m/5m/15m/30m + LowPower/thermal) + agent-aware opt-in có consent (`docs/refresh-loop.md`, `docs/predictive-refresh-policy.md`, replay −49,7% refresh) | Timer cố định theo `RefreshPolicy` |
| Menu-open refresh (mặc định chỉ provider thiếu/lỗi), không retry ngay sau batch lỗi | Chưa có |
| Statuspage.io + Google incidents poll, incident badge menu/icon (`ProviderStatusFetcher`, `docs/status.md`) | Chỉ lỗi refresh cục bộ |
| Lịch sử snapshot retention + burndown + local cost ledger (JSONL/SQLite) + kỷ luật honesty (recorded ≠ bill) (`BurnDownWidgetProvider.swift`, `docs/cost-*.md`) | Chỉ snapshot mới nhất + cache stale |
| 8 loại WidgetKit qua app-group JSON (`Sources/CodexBarWidget/`, `docs/widgets.md`) | Chưa có widget |
| CLI `usage/cost/cards/dashboard/serve/guard/hooks/sessions` + exit codes scripting (`Sources/CodexBarCLI/`, `docs/cli.md`) | Chưa có CLI |
| Reset/quota notification off-default + dedupe, credential-expiry episodes, confetti (`SessionQuotaNotifications.swift`, `AppNotifications.swift`) | Chưa có notification |
| `config.json` 0600 versioned + quản lý bằng CLI, preferences export/import, CloudKit opt-in, secrets tách Keychain (`docs/configuration.md`) | Mọi preferences trong UserDefaults |
| i18n 23 ngôn ngữ + RTL, Sparkle updater + appcast, sign/notarize scripts, release checklist (`Scripts/`, `docs/RELEASING.md`, `docs/sparkle.md`) | Chưa có |
| Provider plugin system + authoring guide (`ProviderFetchStrategy` ~119 impl, `ScriptFetchStrategy.swift`, `docs/provider.md`, `docs/plugins.md`) | Thêm provider = sửa enum + adapter thủ công |
| Tích hợp Linux/Qt, Omarchy, Waybar/GNOME/KDE, ESP32 desk display, Stream Deck qua `serve` (README Related) | Chỉ macOS app |
| Suite test sharded + SwiftFormat/SwiftLint gates (`AGENTS.md`, `Makefile`) | XCTest cơ bản |

## Tiêu chí chọn phạm vi

- Ưu tiên làm provider hiện tại ổn định trước khi tăng số lượng provider.
- Mỗi provider cần ghi rõ nguồn dữ liệu, kiểu credential, quyền cần thiết, độ tin cậy và phương án khi API thay đổi.
- Không đọc browser cookie hoặc credential của provider mới nếu chưa có use case rõ ràng và giải thích quyền truy cập trong UI/tài liệu.
- Tách tiện ích có thể dùng độc lập (history, notifications, menu bar layouts) khỏi tích hợp provider để roadmap có thể chia thành release nhỏ.
