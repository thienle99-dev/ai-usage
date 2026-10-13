# Checklist tính năng tham khảo từ CodexBar

Danh sách này ghi lại tính năng của [CodexBar](CodexBar/README.md) có thể cân nhắc cho AI Usage Monitor. Đối chiếu implementation và giới hạn hiện tại trong [`docs/codexbar-research.md`](../docs/codexbar-research.md) và [`docs/FEATURE_COMPARISON.md`](../docs/FEATURE_COMPARISON.md). Đánh dấu `[x]` nghĩa là app hiện có năng lực tương ứng ở mức cơ bản, không nhất thiết tương đương toàn bộ CodexBar.

## Hiển thị và làm mới quota

- [x] **Menu bar và popover:** hiển thị trạng thái tổng hợp, thẻ quota theo provider, phần trăm và thời gian reset.
- [x] **Chọn cách hiển thị:** icon-only, phần trăm tổng hợp, từng provider hoặc provider vượt ngưỡng; có thể ẩn provider.
- [x] **Làm mới định kỳ/thủ công và cache stale:** các chu kỳ cố định cùng Manual; giữ snapshot cũ khi refresh lỗi.
- [x] **Layout card và điều hướng provider:** Overview/Detail có layout lưu riêng và chế độ dùng chung.
- [ ] **Layout menu bar tuỳ biến:** chọn token hiển thị, thứ tự, xuống dòng và override theo provider.
- [ ] **Gộp icon và chuyển provider:** một status item có switcher, chọn nguồn theo provider hiện tại, mức sử dụng cao nhất hoặc app đang chạy.
- [ ] **Adaptive refresh:** điều chỉnh chu kỳ theo lần mở menu, hoạt động và trạng thái tiết kiệm năng lượng.
- [ ] **Status/incidents:** poll status page, hiển thị độ mới của incident và badge trên menu bar; phân biệt với lỗi truy vấn quota.
- [ ] **Reset notifications:** thông báo reset/ngưỡng quota, mặc định tắt và chống lặp theo provider/account/window.

## Provider, độ tin cậy và dữ liệu

- [ ] **Chuỗi nguồn/fallback cho provider:** khai báo strategy theo thứ tự, timeout và điều kiện chuyển fallback thay vì gom vào một adapter.
- [ ] **Credential refresh có kiểm soát:** cooldown sau lỗi Keychain hoặc `invalid_grant`, backoff hợp lý và không lặp prompt xác thực.
- [ ] **Bảo vệ reset bất thường:** giữ reset timestamp đáng tin gần nhất khi provider trả về reset weekly không hợp lý.
- [ ] **Extra/scoped quota windows:** ánh xạ quota model-scoped, extra credits và rate limit pools khi API cung cấp.
- [x] **Nhiều tài khoản/workspace (Codex):** chọn Codex home đã đăng ký, hiển thị account/plan và phân biệt home trùng identity; giữ quota cache riêng theo home. Các provider khác hiện dùng một credential/session và chưa có account switcher riêng.
- [ ] **Status/usage history:** lưu snapshot có retention để xem biểu đồ và quota burndown.
- [ ] **Cost theo model/session/project:** đọc log cục bộ với giới hạn tài nguyên và khử đếm trùng; phân biệt spend ghi nhận với hoá đơn thực tế.
- [ ] **Dashboard bổ sung opt-in:** lấy review, breakdown hoặc credits history từ web khi provider không có API tương đương.

## Bề mặt sản phẩm và tự động hoá

- [ ] **WidgetKit:** widget quota và lịch sử qua snapshot gọn trong App Group.
- [ ] **CLI:** lệnh đọc usage dạng text/JSON, kiểm tra quota bằng exit code, refresh và các lệnh cost/config cần thiết.
- [ ] **Config import/export:** cấu hình có version, ghi file an toàn; giữ secrets trong Keychain và chỉ export preferences được phép.
- [ ] **Provider plugin/strategy system:** thêm provider mà không phải mở rộng enum trung tâm cho mọi trường hợp.
- [ ] **Localization, updater và phát hành:** bản dịch, Sparkle/appcast, signing/notarization và checklist release.
- [ ] **Nền tảng khác:** CLI hoặc desktop Linux chỉ xem xét sau khi xác định nhu cầu và chia sẻ được data model an toàn.

## Nguyên tắc port từ reference

- Xác minh hành vi trong source và test của CodexBar; README và danh sách provider có thể đổi theo phiên bản.
- Ưu tiên độ tin cậy của provider hiện có, rồi đến thông báo/lịch sử; chỉ mở rộng bề mặt như widget hoặc CLI khi có use case rõ.
- Dùng CodexBar làm tài liệu tham khảo, không sao chép code trước khi kiểm tra license và yêu cầu giữ attribution.
- Với dữ liệu cost, browser session, credential hoặc log cục bộ, mô tả nguồn, quyền truy cập, retention và giới hạn ngay trong thiết kế.
