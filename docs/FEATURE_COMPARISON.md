# Đối chiếu tính năng với CodexBar

**Ngày đối chiếu:** 2026-10-12  
**Ứng dụng:** AI Usage Monitor trong repo này  
**Tham khảo:** [steipete/CodexBar](https://github.com/steipete/CodexBar), chủ yếu là README và mục Providers/Features trên nhánh `main`.

CodexBar là ứng dụng trưởng thành với nhiều provider, nguồn xác thực và bề mặt sử dụng. AI Usage Monitor hiện tập trung vào Claude Code và Codex. Bảng dưới đây đối chiếu tính năng dựa trên code đang có, không coi tính năng chỉ được nhắc trong README là đã hoàn tất.

## Đã có trong AI Usage Monitor

| Nhóm | Tính năng hiện có | Tình trạng |
|---|---|---|
| Ứng dụng macOS | SwiftUI `MenuBarExtra`, popover, cửa sổ Settings, quit | Có trong code |
| Provider | Claude Code OAuth và Codex CLI app-server | Có adapter cho hai provider |
| Claude auth | Đọc `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR/.credentials.json` hoặc Keychain | Chỉ đọc; không lưu hoặc ghi token |
| Tài khoản Claude | Lấy email/tên và plan từ `/api/oauth/profile`, cache trong RAM theo token tối đa 6 giờ | Hiển thị dưới usage giống dòng account của Codex; nếu profile API không trả email/tên thì bỏ trống |
| Claude usage | Gọi `GET /api/oauth/usage`, parser hỗ trợ các trường legacy, `limits[]` (`session`, `weekly_all`, `weekly_scoped`) và Usage credits | Gửi OAuth beta header; retry tối đa 2 lần khi gặp HTTP 429 và tôn trọng `Retry-After` (tối đa 30 giây). Live quota windows chưa xác nhận |
| Codex usage | Tìm Codex CLI ở một số đường dẫn và gọi `account/read`, `account/rateLimits/read` qua JSON-RPC | Có timeout và parser cho response lồng nhau; live success chưa xác nhận |
| Hiển thị usage | Progress bar, phần trăm, tên window, thời gian reset tương đối | Hiện có khi provider trả dữ liệu nhận diện được |
| Làm mới | Làm mới bằng nút và chu kỳ cài đặt, mặc định 5 phút | Chu kỳ chọn được: 1, 5, 15 hoặc 30 phút |
| Lỗi và cache | Giữ snapshot thành công gần nhất, hiển thị stale/error; lưu snapshot cục bộ | Có; không có lịch sử chuỗi snapshot |
| Tuỳ chỉnh | Ẩn/hiện provider, ngưỡng cảnh báo và nghiêm trọng, giao diện sáng/tối/hệ thống, nhãn menu bar | Có trong Settings |
| Phát triển | Swift Package Manager, parser tests, script tạo `.app`, README | Có; test hiện tập trung vào parser và status HTTP |

## Khác biệt so với CodexBar

| Nhóm | CodexBar có | AI Usage Monitor hiện thiếu |
|---|---|---|
| Số lượng provider | Nhiều provider cho coding plans, API billing, credits và gateways; danh sách cụ thể thay đổi theo phiên bản | Chỉ Claude Code và Codex |
| Nguồn dữ liệu / xác thực | Tuỳ provider: CLI, OAuth, API key, browser cookie, local app/config hoặc dashboard | Chỉ OAuth credential Claude Code và local Codex app-server |
| Tùy biến menu bar | Icon provider, nhãn, bars/percent, reset style, chọn usage cao nhất, gộp nhiều provider, xếp layout | Chỉ phần trăm cao nhất hoặc chữ “AI Usage” |
| Usage history | Lưu mẫu theo thời gian, biểu đồ và quota burndown cho provider hỗ trợ | Chỉ snapshot mới nhất và cache stale |
| Spend / cost | Ước tính và báo cáo chi phí theo provider, model, session/project và thời gian; mức hỗ trợ tuỳ nguồn | Chỉ hiển thị Claude Usage credits (đã dùng / giới hạn) nếu API trả về; không có lịch sử chi phí, model/session breakdown hoặc thống kê token |
| Dashboard bổ sung | Codex có thể bổ sung dữ liệu web như code review, breakdown và credits history | Không có nguồn dashboard hoặc số liệu bổ sung |
| Widgets | WidgetKit cho provider được hỗ trợ | Không có widget |
| Cảnh báo | Thông báo theo quota/session và sự kiện reset | Có màu theo ngưỡng trong popover; không có notification hoặc sự kiện reset |
| Trạng thái dịch vụ | Poll trạng thái provider, incident badge trên menu/icon | Chỉ báo lỗi của lần refresh cục bộ; không poll status page |
| CLI và tự động hoá | CLI `codexbar` cho cấu hình, provider và một số cost commands | Không có CLI riêng |
| Cấu hình | Cấu hình provider, API keys và tuỳ chọn có thể quản lý bằng CLI/config file | Preferences cơ bản lưu trong UserDefaults; không có import/export hay cấu hình CLI |
| Trải nghiệm sản phẩm | Localization nhiều ngôn ngữ, launch-at-login, updater, tài liệu cài đặt/phát hành và cấu hình chi tiết | Chưa có localization, launch-at-login, updater hay quy trình phát hành hoàn chỉnh |
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

## Tiêu chí chọn phạm vi

- Ưu tiên làm provider hiện tại ổn định trước khi tăng số lượng provider.
- Mỗi provider cần ghi rõ nguồn dữ liệu, kiểu credential, quyền cần thiết, độ tin cậy và phương án khi API thay đổi.
- Không đọc browser cookie hoặc credential của provider mới nếu chưa có use case rõ ràng và giải thích quyền truy cập trong UI/tài liệu.
- Tách tiện ích có thể dùng độc lập (history, notifications, menu bar layouts) khỏi tích hợp provider để roadmap có thể chia thành release nhỏ.
