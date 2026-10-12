# Checklist tính năng tham khảo từ `usage`

Danh sách này ghi lại các tính năng đáng cân nhắc đưa vào AI Usage Monitor, dựa trên [`usage/README.md`](usage/README.md) và [`docs/FEATURE_COMPARISON.md`](../docs/FEATURE_COMPARISON.md). Đây là checklist tham khảo, không khẳng định các tính năng chưa đánh dấu đã được triển khai.

## Quota và thông báo

- [x] **Auto-start phiên 5 giờ:** gửi prompt nhỏ sau khi phát hiện quota reset. Hiện hỗ trợ Claude Code, Codex và Antigravity; mặc định tắt. Xem `Sources/AIUsage/UsageWindowAutoStarter.swift`.
- [x] **Thông báo quota/reset:** thông báo hệ thống khi quota sắp hết, chạm giới hạn hoặc được khôi phục; cần chống gửi lặp theo provider và cửa sổ quota. Đã làm: `Sources/AIUsage/QuotaNotifier.swift` (policy warning/critical/restored + episode chống lặp theo provider/window, hysteresis 5 điểm khi recover), toggle off-by-default trong Settings, deliver qua `UNUserNotificationCenter`. Xem `testQuotaPolicy*`, `testQuotaNotifications*`.
- [x] **Cảnh báo sự cố dịch vụ:** kiểm tra feed status công khai mỗi 5 phút cho provider đang bật; hiển thị incident riêng với lỗi fetch quota cục bộ và link về status page. Đã làm trong `Sources/AIUsage/ServiceStatus.swift`, `UsageStore.swift`, usage card và Settings. Nguồn: OpenAI, Claude, Cursor, GitHub Copilot, Google Cloud cho Gemini/Antigravity và RSS xAI cho Grok. OpenCode, Windsurf, Cline và Roo chưa có feed được nối.
- [x] **Quota-aware mode:** `scripts/ai-usage run` bọc lệnh CLI và hỏi xác nhận trước tác vụ lớn khi quota gần ngưỡng cảnh báo; `preflight` chỉ đọc snapshot local, không refresh quota và không gửi model request. Ước lượng token do người dùng truyền; thiếu/stale snapshot thì báo chưa đánh giá được. Hướng dẫn trong README.

## Tích hợp CLI và phiên làm việc

- [x] **Status line / hook:** Settings có thể cài/gỡ status line Claude Code do app quản lý; formatter CLI chỉ đọc snapshot local, không gọi API hay model. Không ghi đè status line tùy chỉnh; chỉ gỡ cấu hình còn khớp ownership record. CLI khác có thể gọi `scripts/ai-usage statusline --provider <name>` nếu hỗ trợ formatter hook.
- [x] **RTK command filtering:** Settings quản lý hook RTK cho Claude Code, Codex và Gemini CLI khi RTK binary đã được cài. Tách ownership theo agent, không cài/nâng cấp binary hay bật telemetry; từ chối Gemini nếu đã có BeforeTool hook để tránh ảnh hưởng hook khác. RTK rút gọn output lệnh tương thích, không thay đổi quota provider.
- [x] **Context Mode cho Claude Code:** Settings cài/gỡ plugin Context Mode chính thức qua Claude Code marketplace; yêu cầu Claude Code 1.0.33+ và Node.js 22.5+. Chỉ gỡ plugin/marketplace do app quản lý; không bundling mã nguồn, đọc session/index DB, hay tự bật cấu hình plugin. `ctx_execute` chạy với quyền filesystem của Claude Code.
- [x] **Context và prompt-cache warnings:** Claude Code status line đọc context percentage và prompt-cache miss/cause trực tiếp từ JSON hook; ngưỡng context và hai cảnh báo bật/tắt riêng trong Settings. Không đọc transcript hay gửi request. Prompt-cache telemetry cần Claude Code v2.1.251+.
- [x] **Side pane cho Claude Code:** pane riêng cho Claude Code hiển thị quota từ snapshot local, các phiên đang chạy và background jobs/agents. Cài/gỡ plugin local do app quản lý trong Settings; không đọc transcript, gọi API quota hay gửi model request. Dùng `/usage-pane` để mở lại; cần Claude Code v2.1.292+ để cài đặt.
- [x] **Progress hand-off:** Settings có opt-in riêng, mặc định tắt. Khi người dùng chủ động tạo preview, app chỉ đọc yêu cầu text gần nhất từ tối đa 1 MiB cuối transcript của phiên Claude Code đang chạy, Git status/diff và TODO/checklist mới nhất; hiển thị đầy đủ prompt trước khi xác nhận mở phiên mới trong Terminal. Không gửi/ghi lại dữ liệu ở bước preview; untracked file chỉ hiện tên, không đọc nội dung. Giới hạn diff 60.000 ký tự.
- [x] **Token Saver / Beginner Mode:** hai tuỳ chọn Claude Code trong Settings, mặc định tắt; plugin thêm chỉ dẫn ngắn vào context của từng prompt để trả lời súc tích hoặc giải thích thuật ngữ. Chỉ hoạt động khi cài plugin AI Usage Monitor; không gọi model riêng, phần context bổ sung vẫn có thể dùng input tokens.

## Lịch sử, báo cáo và giao diện

- [ ] **Lịch sử usage và burndown:** lưu snapshot theo thời gian để xem xu hướng và dự đoán quota cạn; phân biệt dữ liệu đo được với ước tính.
- [x] **Báo cáo token/chi phí:** cửa sổ báo cáo quét metadata token từ Claude Code/Codex JSONL theo yêu cầu; nhóm theo ngày, provider, model, project hoặc session. Claude `costUSD` được ghi rõ là ước tính local, không phải billing; Codex và provider không có token telemetry không được gán chi phí giả.
- [ ] **Xuất báo cáo offline:** HTML, CSV hoặc ảnh; hỗ trợ ẩn tên project nếu có dữ liệu nhạy cảm.
- [x] **Tuỳ biến dashboard:** kéo thả thứ tự thẻ provider trong Overview, chọn Dark Minimal/Slate/Violet ở Appearance; thứ tự và theme được lưu qua lần khởi động lại.
- [x] **Widget hệ thống:** WidgetKit trên macOS 14+, kích thước nhỏ/vừa, hiển thị quota cache của các provider đang bật; widget chỉ đọc App Group snapshot, không tự gọi API.

## Tự động hoá và vận hành

- [x] **CLI và JSON output:** `scripts/ai-usage quota` đọc snapshot cache, `report` tổng hợp log local theo nhóm/range; cả hai hỗ trợ text và JSON ổn định để tích hợp shell, tmux, Starship và script. Không refresh quota hay gọi model.
- [x] **Kiểm tra token-waste:** `scripts/ai-usage waste` đọc log Claude Code khi người dùng gọi rõ; tìm Read lặp và tool output lớn, không ước lượng token/chi phí. Giới hạn 7/30 ngày, 10.000 entry thư mục, 500 candidate, tối đa 100 file mới nhất trong số đó, 2 MiB/file, 64 MiB tổng, 1 MiB/line; không xuất hoặc lưu path, command, session ID hay nội dung log.
- [ ] **Localization và cập nhật ứng dụng:** bổ sung ngôn ngữ, cơ chế cập nhật, ký/notarize và quy trình phát hành hoàn chỉnh.

## Nguyên tắc đánh giá

- Xác minh từng tính năng trong `usage/README.md`, tài liệu liên quan và implementation trước khi port; README có thể mô tả tính năng thử nghiệm hoặc phụ thuộc phiên bản.
- Ưu tiên tính năng hoạt động độc lập với provider; ghi rõ provider, nguồn dữ liệu, quyền cần thiết và giới hạn khi API/CLI thay đổi.
- Không đọc log, cookie hoặc credential cho tính năng mới nếu chưa có use case rõ ràng và giải thích quyền riêng tư trong UI/tài liệu.
