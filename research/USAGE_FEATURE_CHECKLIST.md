# Checklist tính năng tham khảo từ `usage`

Danh sách này ghi lại các tính năng đáng cân nhắc đưa vào AI Usage Monitor, dựa trên [`usage/README.md`](usage/README.md) và [`docs/FEATURE_COMPARISON.md`](../docs/FEATURE_COMPARISON.md). Đây là checklist tham khảo, không khẳng định các tính năng chưa đánh dấu đã được triển khai.

## Quota và thông báo

- [x] **Auto-start phiên 5 giờ:** gửi prompt nhỏ sau khi phát hiện quota reset. Hiện hỗ trợ Claude Code, Codex và Antigravity; mặc định tắt. Xem `Sources/AIUsage/UsageWindowAutoStarter.swift`.
- [ ] **Thông báo quota/reset:** thông báo hệ thống khi quota sắp hết, chạm giới hạn hoặc được khôi phục; cần chống gửi lặp theo provider và cửa sổ quota.
- [ ] **Cảnh báo sự cố dịch vụ:** lấy trạng thái từ status page công khai và báo sự cố riêng với lỗi fetch cục bộ.
- [ ] **Quota-aware mode:** cảnh báo trước tác vụ lớn khi quota thấp. Cần tích hợp riêng với CLI; không biến refresh quota thành model request.

## Tích hợp CLI và phiên làm việc

- [ ] **Status line / hook:** hiển thị quota trong Claude Code, Codex hoặc CLI có hook phù hợp; chỉ cài/gỡ thành phần do app quản lý.
- [ ] **Context và prompt-cache warnings:** cảnh báo context gần đầy hoặc cache miss. Phụ thuộc vào telemetry của từng CLI.
- [ ] **Side pane cho Claude Code:** xem quota, hội thoại và background jobs trong terminal. Đây là tính năng riêng cho Claude Code.
- [ ] **Progress hand-off:** chuyển yêu cầu gần nhất, thay đổi chưa commit và TODO sang phiên Claude Code mới; cần opt-in và đánh giá kỹ dữ liệu đọc từ log.
- [ ] **Token Saver / Beginner Mode:** tuỳ chọn điều chỉnh câu trả lời hoặc giải thích thuật ngữ; các chế độ gọi model có thể tiêu tốn quota.

## Lịch sử, báo cáo và giao diện

- [ ] **Lịch sử usage và burndown:** lưu snapshot theo thời gian để xem xu hướng và dự đoán quota cạn; phân biệt dữ liệu đo được với ước tính.
- [ ] **Báo cáo token/chi phí:** tổng hợp theo ngày, provider, model, project hoặc session; chỉ báo chi phí ước tính khi nguồn không phải dữ liệu billing thực.
- [ ] **Xuất báo cáo offline:** HTML, CSV hoặc ảnh; hỗ trợ ẩn tên project nếu có dữ liệu nhạy cảm.
- [ ] **Tuỳ biến dashboard:** kéo thả thứ tự thẻ, thêm theme và giữ lựa chọn sau khi khởi động lại.
- [ ] **Widget hệ thống:** hiển thị quota tóm tắt bên ngoài menu bar; cần chốt phạm vi macOS trước khi triển khai.

## Tự động hoá và vận hành

- [ ] **CLI và JSON output:** truy vấn quota hoặc báo cáo qua terminal để tích hợp với shell, tmux, Starship và script.
- [ ] **Kiểm tra token-waste:** phân tích log cục bộ để phát hiện đọc file lặp hoặc output dư thừa; cần giới hạn dữ liệu và quyền truy cập rõ ràng.
- [ ] **Localization và cập nhật ứng dụng:** bổ sung ngôn ngữ, cơ chế cập nhật, ký/notarize và quy trình phát hành hoàn chỉnh.

## Nguyên tắc đánh giá

- Xác minh từng tính năng trong `usage/README.md`, tài liệu liên quan và implementation trước khi port; README có thể mô tả tính năng thử nghiệm hoặc phụ thuộc phiên bản.
- Ưu tiên tính năng hoạt động độc lập với provider; ghi rõ provider, nguồn dữ liệu, quyền cần thiết và giới hạn khi API/CLI thay đổi.
- Không đọc log, cookie hoặc credential cho tính năng mới nếu chưa có use case rõ ràng và giải thích quyền riêng tư trong UI/tài liệu.
