# Việc còn lại: quản lý nhiều tài khoản Claude Code và Codex

**Trạng thái triển khai:** Hoàn tất trong ứng dụng. Các luồng đăng nhập CLI, lưu tài khoản, chuyển tài khoản, lưu trữ credential, quota riêng theo tài khoản và cửa sổ Add Account đã được triển khai. Build và XCTest đã chạy thành công trong môi trường phát triển.

Tài liệu này ghi lại các bước kiểm chứng còn cần làm trên máy macOS có thể tương tác với cửa sổ và các CLI tương ứng. Đăng nhập thật phải do người dùng thực hiện trong ứng dụng.

## Kiểm chứng giao diện thủ công

- [ ] Mở popover menu bar, bấm nút `+` và xác nhận cửa sổ **Add Account** xuất hiện, kể cả khi popover đóng.
- [ ] Xác nhận cửa sổ có tiêu đề đơn, không có khoảng trống dọc thừa, chiều rộng khoảng 440 pt và chiều cao phù hợp với nội dung.
- [ ] Chuyển segmented picker giữa Claude Code và Codex; xác nhận trạng thái provider được giữ độc lập và picker bị khóa đúng lúc đăng nhập đang chạy.
- [ ] Chọn **Save current account** trên mỗi provider đã đăng nhập; xác nhận tài khoản được lưu mà không thay phiên đang dùng.
- [ ] Chọn **Sign in to another account** trên mỗi provider; hoàn tất CLI/browser flow, xác nhận tiến trình, nhập mã (nếu được yêu cầu), hủy và lỗi có thể thử lại.
- [ ] Đóng popover khi đăng nhập đang chạy; xác nhận cửa sổ Add Account và tiến trình vẫn hoạt động.
- [ ] Kiểm tra tài khoản lưu, lựa chọn hiện tại và chuyển A ↔ B sau khi khởi động lại ứng dụng.
- [ ] Dùng bàn phím để chuyển focus, chọn provider, kích hoạt hai hàng thao tác và hủy đăng nhập; xác nhận thứ tự focus và phím mặc định/hủy hoạt động tự nhiên.
- [ ] Kiểm tra Light và Dark appearance, VoiceOver labels, trạng thái hover và màu nhấn của Claude Code/Codex.
- [ ] Kiểm tra cửa sổ vẫn giữ macOS title bar và window controls.

## Kiểm chứng môi trường và provider

- [ ] Chạy trên máy có Claude Code và Codex CLI; xác nhận phiên Claude Code riêng dùng `CLAUDE_CONFIG_DIR` và phiên Codex riêng dùng `CODEX_HOME`/file credential riêng.
- [ ] Xác nhận đăng nhập thêm B trong khi A đang dùng không sửa credential/home đang hoạt động; sau đó chuyển A ↔ B cho từng provider.
- [ ] Kiểm tra CLI bị thiếu, Keychain từ chối, mã xác minh sai/hết hạn, token hết hạn và hủy trong lúc tiến trình đang chạy.
- [ ] Refresh quota cho nhiều tài khoản, chuyển tài khoản khi refresh đang chạy và xác nhận snapshot luôn gắn đúng provider/account ID.
- [ ] Xác nhận tài khoản hết phiên hoặc không có dữ liệu hiển thị trạng thái riêng, không dùng quota của tài khoản đang hoạt động làm dữ liệu thay thế.
- [ ] Khởi động lại ứng dụng trong lúc đăng nhập bị gián đoạn; xác nhận draft chưa hoàn tất có thể khôi phục hoặc dọn an toàn.
- [ ] Kiểm tra tiếng Anh và tiếng Việt trên cửa sổ, lỗi, tiến trình và accessibility labels.

## Tự động hóa hiện có

Các kiểm thử coordinator/store dùng process launcher giả và thư mục tạm; chúng kiểm tra các luồng logic mà không đăng nhập thật. Chạy lại trước khi thay đổi tiếp:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
git diff --check
```

Kiểm thử tự động không thay thế các bước tương tác giao diện và xác minh tài khoản thật ở trên. Antigravity, Claude Desktop và tự động chuyển tài khoản vẫn nằm ngoài phạm vi.
