# Đối chiếu tính năng với Pitboard

**Ngày đối chiếu:** 2026-11-07  
**Phạm vi:** AI Usage trong repo này so với Pitboard, dựa trên code hiện có và tài liệu Pitboard công khai.

## Đã có trong AI Usage

- Thêm và lưu nhiều tài khoản Claude Code/Codex, rồi chuyển giữa chúng.
- Hiển thị quota theo provider và tài khoản; trạng thái lỗi hoặc hết phiên được giữ riêng.
- Giữ lựa chọn tài khoản sau khi khởi động lại.
- Có widget và thông báo quota.
- Có CLI truy vấn quota/báo cáo, nhưng CLI này chưa quản lý vòng đời tài khoản như CLI Pitboard.

Pitboard cũng hỗ trợ thêm/chuyển nhiều tài khoản Claude Code và Codex, và hiển thị quota của từng tài khoản. Xem [kiến trúc Pitboard](https://github.com/datlechin/pitboard/blob/main/ARCHITECTURE.md).

## Khác biệt còn lại

| Tính năng Pitboard | Tình trạng trong AI Usage |
|---|---|
| Tự động chuyển Claude Code khi quota chạm ngưỡng; có tùy chọn trong app và lệnh `pitboard watch` | Chưa có. Tự động chuyển đã được xác định ngoài phạm vi của kế hoạch hiện tại. |
| Đổi tên và gỡ tài khoản | Chưa có trong luồng quản lý Claude Code/Codex hiện tại; giao diện hỗ trợ thêm, xem và kích hoạt tài khoản. |
| Cửa sổ web riêng cho từng tài khoản tại `claude.ai` hoặc `chatgpt.com` | Chưa có. |
| CLI quản lý tài khoản như thêm, chuyển, gỡ, kiểm tra và phục hồi | Chưa có CLI tương đương. CLI hiện tại tập trung vào truy vấn quota và báo cáo. |
| Chẩn đoán và nhật ký thao tác tài khoản để hỗ trợ khôi phục | Chưa có giao diện chẩn đoán/hoạt động tương đương Pitboard. |
| Warm-up Claude Code sau khi quota reset | Chưa có. |
| Ứng dụng Windows và Linux | Repo hiện tại là ứng dụng macOS. |
| Quản lý tài khoản Claude Desktop trên macOS | Ngoài phạm vi kế hoạch hiện tại. |

Pitboard mô tả tự chuyển, CLI, cửa sổ tài khoản và các khả năng khác trong [CHANGELOG](https://github.com/datlechin/pitboard/blob/main/CHANGELOG.md) và [ARCHITECTURE](https://github.com/datlechin/pitboard/blob/main/ARCHITECTURE.md). Danh sách này là đối chiếu tính năng, không khẳng định hai ứng dụng có cùng mục tiêu hoặc kiến trúc.

## Ưu tiên nếu muốn thu hẹp khoảng cách

1. Thêm đổi tên và gỡ tài khoản, kèm xác nhận và xử lý credential an toàn.
2. Bổ sung chẩn đoán trạng thái tài khoản và lịch sử thao tác để người dùng tự phục hồi khi có lỗi.
3. Mở rộng CLI từ truy vấn quota sang thao tác quản lý tài khoản, nếu cần tự động hóa.
4. Chỉ xem xét tự chuyển Claude Code, Claude Desktop, warm-up, hoặc nền tảng khác khi phạm vi sản phẩm thay đổi.

Tự chuyển tài khoản, Claude Desktop và việc đọc dữ liệu Pitboard hiện không nằm trong phạm vi đã chốt.
