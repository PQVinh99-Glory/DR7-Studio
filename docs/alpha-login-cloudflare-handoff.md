# Bàn giao triển khai alpha DR7-Studio v0.16.0

Tài liệu này là kế hoạch cho phiên sau. Phạm vi gồm hai lỗi gameplay, login hai tài khoản test, splash và loading Godot, website tải bản test qua Wrangler, cùng kiểm tra kết nối client–server. Việc ký IPA được Owner hoãn. K70E sẽ được Owner cài APK trực tiếp. ADB không phải điều kiện nghiệm thu.

## 1. Làm rõ báo cáo trước

### Mana của tướng Drum

Probe nói về **tướng Drum do người chơi điều khiển trong Field Mode**. Boss Drum có đường AI riêng. Trường hợp dùng orb sau khi đánh xong vẫn có thể hoạt động đúng như Owner đã test. Probe đi vào nhánh khác:

1. Tướng đang chơi một clip hành động và có 100 Mana.
2. Bấm `power_up` trong lúc clip chưa xong. Arena nhận chiêu vào hàng chờ và Field Combat trừ 100 Mana.
3. Bấm `teleport` trước khi hàng chờ được lấy ra. Ô duy nhất `_arena_queued_action` bị ghi đè.
4. Probe thấy Mana về 0, chiêu chờ biến mất và không có orb.

Điểm đọc mã: [Arena xử lý chiêu](../scenes/ArenaSandbox.gd#L465), [Field Combat xử lý Mana](../scenes/runtime/FieldCombatManager.gd#L887), [hook bắn đạn](../scenes/runtime/FieldCombatManager.gd#L800). Bản sửa phải giữ trường hợp đánh đủ Mana rồi bấm orb bình thường. Ưu tiên trừ Mana đúng một lần khi clip `power_up` thực sự bắt đầu, kiểm lại Mana và mục tiêu lúc lấy lệnh. Nếu lệnh bị ghi đè trước đó thì không trừ. Giữ chính sách của các chiêu khác và AI boss. Bổ sung regression bấm orb lúc rảnh, bấm khi đang đánh rồi chờ bắn, bị teleport ghi đè, và lặp input.

### Skill chéo và địa hình

Skill chéo **chạm vách hoặc đất thì dừng** là hành vi đúng. Lỗi báo cáo là đường chéo **đã đi qua phần rắn nhưng hàm trả về không va chạm**. Probe trên bậc đầu của Rocky Plateau từ `(3000, 853)` tới `(2500, 811)` trả `false`, dù điểm `(2847.5, 840.19)` nằm dưới mặt sàn tại X đó và đoạn con tới điểm này trả `true`. Kiểm tra hiện tại lấy bốn điểm mẫu nên bỏ lọt phần giao ngắn giữa hai mẫu. [Logic địa hình](../scenes/ArenaSandbox.gd#L1496)

Giữ khả năng quái **theo dõi mục tiêu**. Đạn homing được đổi hướng theo tướng, nhưng vẫn dừng nếu đường bay thực tế chạm địa hình, theo Điều 7.8. Nếu Owner muốn một chiêu cụ thể xuyên vách, chốt ngoại lệ theo ID chiêu trước khi sửa. Dùng giao cắt liên tục với mặt vách và các đoạn mặt sàn từ `arena-stage.json`, kiểm cả hai hướng, đường sượt cạnh, đường bay trên vách và đạn homing đổi hướng. Giữ quy tắc Chilopoda hiện tại, dưới 50 px dùng `power_up`, từ 50 px trở lên độn thổ áp sát trong vùng aggro.

## 2. Phân đợt triển khai

Trước khi sửa, chạy `./loop.sh status`, đọc `state.json` và `lerning.md`, kiểm tra backup đã được Owner yêu cầu và xác minh ref trên remote. Tại thời điểm lập kế hoạch, `.env` là file chưa được Git theo dõi và chưa có quy tắc ignore. Bảo vệ `.env` ở Git và danh sách đóng gói trước khi staging. Stage theo danh sách file và kiểm diff staged trước commit. Loại cả ảnh tham chiếu ở root và sidecar import khỏi gói build. Sau mỗi đợt, chạy `./loop.sh test` và đọc log thực tế. Chỉ chuyển đợt sau khi gate của đợt hiện tại đạt.

| Đợt | Việc thực hiện | Điều kiện qua |
|---|---|---|
| 1 | Sửa hàng chờ/Mana và giao cắt địa hình theo mục 1. | Regression của hai lỗi qua và giữ hành vi orb, boss, Chilopoda hiện có. |
| 2 | Thêm login Godot, splash, loading và luồng session. Có thể chạy với dịch vụ auth/WSS test cục bộ trong đợt này. | Đăng nhập hợp lệ, sai mật khẩu, mất mạng, retry và logout đều đúng. Build alpha không vào Arena khi chưa có hồ sơ và khu hợp lệ. |
| 3 | Sửa đồng bộ khu, chạy Godot Headless cho hai client, cấu hình môi trường staging qua Cloudflare khi có origin. | Hai client thật đăng nhập, thấy nhau, gửi input, nhận snapshot, đổi khu, ngắt và kết nối lại. Không công nhận mock là server headless. |
| 4 | Website tải bản test, đóng gói, đối chiếu nguồn và tải thực từ staging. | Website tải đúng file, hash khớp, kiểm quyền truy cập và geo theo chính sách. K70E được Owner cài trực tiếp. IPA ghi rõ unsigned và chờ ký. |

## 3. Login, hồ sơ tướng và kết nối

- Hai tên đăng nhập đã chốt là `vinhadmin` và `thaiadmin`. Mật khẩu của hai tài khoản đã được cập nhật trong `.env` cục bộ theo yêu cầu mới nhất của Owner. Cặp mật khẩu đã được trao đổi trong chat và chỉ dùng cho mock cục bộ. Trước khi mở staging qua Internet, tạo hai mật khẩu test mới đạt chính sách của Supabase và bàn giao qua kênh bí mật. Không ghi mật khẩu vào tài liệu, log, repo, build, JavaScript hay metadata deploy. [Supabase Password security](https://supabase.com/docs/guides/auth/password-security)
- Tắt đăng ký công khai trên môi trường test. Provision đúng hai user bằng tác vụ quản trị phía server. Nếu dùng Supabase email/password, ánh xạ username tới email định danh phía server, dùng password auth của Supabase, giữ quyền tối thiểu và giới hạn thử đăng nhập. Supabase có cơ chế tạo hai tài khoản test đã xác nhận ở phía quản trị nếu cần đăng nhập trước khi triển khai luồng xác minh email. Ghi rõ đây là ngoại lệ staging theo hai user ID và gỡ khi kết thúc test. Giữ quy tắc Gmail production. [Supabase password auth](https://supabase.com/docs/guides/auth/passwords) · [Supabase admin createUser](https://supabase.com/docs/reference/javascript/auth-admin-createuser)
- `.env` có biến cấu hình Cloudflare và Supabase. Phiên lập kế hoạch chỉ kiểm tên biến, chưa xác minh quyền token, tài khoản, zone, billing hay endpoint. Ánh xạ tên biến theo tài liệu Wrangler khi triển khai. Khóa quản trị Supabase, mật khẩu DB và mật khẩu test dùng secret phía server. Client chỉ nhận URL, khóa công khai được phép, cùng token phiên riêng của user sau đăng nhập.
- Giữ Godot 4 GDScript, Compatibility và `NetworkTransport` theo Pha 1. Hiện `project.godot` mở thẳng `ArenaSandbox.tscn`, còn `_setup_network_client_stub()` chỉ khởi tạo transport/sync. Thêm scene điều phối startup và trạng thái **Login → xác thực → tải hồ sơ → kết nối WSS → server xác nhận phiên và khu → vào Arena**. Giữ đường vào Human Test theo cơ chế dành riêng cho dev và kiểm tra để bản alpha phát cho tester không đi qua đường này.
- Cho server xác thực JWT và quyết định profile/tướng xuất hiện. Dữ liệu cấu hình gồm user ID, `character_id`, map, khu và spawn được phép. Kiểm `character_id` trong roster và dùng mặc định staging đã ghi rõ nếu tài khoản chưa cấu hình. Hiện Arena Field Mode có nhánh spawn Drum cố định. Điều chỉnh entry point để nhận dữ liệu hồ sơ mà vẫn giữ luồng Sân Tập. Chốt tướng từng tài khoản với Owner khi có yêu cầu cụ thể.
- Đổi khu chỉ commit khi server xác nhận. Snapshot kiểm schema, map/khu và tick trước khi áp dụng. Phân biệt socket mở, xác thực và sẵn sàng chơi. Engine server quyết định kết quả thay vì tin vị trí hoặc sát thương do client khai. Với hai client, xác minh cả hai nhìn thấy nhau và trạng thái không lùi tick khi reconnect. [Arena](../scenes/ArenaSandbox.gd) · [WebSocketTransport](../scenes/net/WebSocketTransport.gd) · [ZoneClientSync](../scenes/net/ZoneClientSync.gd)

## 4. UI Godot và tài nguyên

| Hạng mục | Thiết kế và điều kiện nghiệm thu |
|---|---|
| Login | Dùng `image.png` (600×338) làm tham chiếu bố cục. Dựng panel mới viền bạc, phần nền kính mờ vẫn thấy cảnh phía sau, hai ô tên đăng nhập/mật khẩu và nút Đăng nhập. Dùng `image copy.png` (734×413) làm nền, scale đồng nhất theo chế độ cover, giữ nguồn và tránh dải đen. Bàn phím mềm không che nút, mật khẩu được che, hiển thị trạng thái gửi và lỗi có thể thử lại. Dùng safe area và kiểm trên K70E, iPad và Web. |
| Splash | Dùng `assets/app_icon/android_adaptive_fg_432.png` (432×432) theo yêu cầu Owner. Đối chiếu video cold-start của bản hiện tại để ghi lại thời lượng và nhịp xuất hiện. `application/boot_splash/image` hỗ trợ PNG tĩnh. Dùng PNG làm splash nền tảng và một scene Godot mỏng để mô phỏng fade/scale theo video thực tế nếu cần chuyển động. Tránh lặp logo giữa splash hệ điều hành và scene. Ảnh logo đã có, không cần sinh lại asset. |
| Loading | Dùng bảy frame 1–7 sao từ atlas [Dragon Balls](../assets/items/dragon_balls/godot/dragon_balls.tres), đặt giữa safe area. Làm sáng tuần tự **1 → 2 → … → 7 → 1**. Với kết nối, loop đến khi server xác nhận phiên và nhận snapshot đầu. Dùng cùng component cho tác vụ bất đồng bộ khác, kết thúc theo tín hiệu thành công/thất bại của tác vụ đó. Hiện lỗi và nút thử lại khi hết thời gian chờ. Bảy viên là bảy số sao, thời lượng sáng mỗi viên là tham số điều chỉnh khi review UI. |

Nạp ảnh nền và vật liệu blur một lần. Kiểm chi phí blur trên Compatibility và dùng lớp kính mờ giả lập nhẹ nếu blur thật làm suy giảm hiệu năng. Chuyển các asset được dùng sang đường dẫn trong `assets/...` theo quy ước dự án. Giữ nguyên file tham chiếu gốc. [Godot ProjectSettings](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html) · [Godot Web splash](https://docs.godotengine.org/en/4.7/tutorials/platform/web/customizing_html5_shell.html)

## 5. Website Wrangler và máy chủ test 0đ

- **Website tải bản test:** Deploy trang gọn bằng Workers + Static Assets qua Wrangler. Hiển thị bản build, hai nút tải APK/IPA, kích thước, SHA‑256 và trạng thái unsigned của IPA. Giữ trang staging theo phạm vi truy cập được Owner duyệt. Giữ đúng chính sách JP/VN trong `AGENTS.md` cho từng hostname và route, gồm đường tải thực tế và origin. Nếu dải IP của Owner thuộc vùng bị chặn tải, dùng kênh bàn giao nội bộ đã duyệt hoặc chốt riêng ngoại lệ staging với Owner trước khi đổi chính sách.
- **Lưu binary:** Workers Static Assets giới hạn **25 MiB mỗi file**. Build đang có APK **51.509.712 B**, IPA **48.357.174 B**, Web WASM **39.514.754 B**. Đề xuất R2 Standard bucket riêng tư và serve qua route tải của Worker để dùng chung kiểm tra quyền truy cập và geo. Giữ manifest theo build, đẩy artifact trước khi chuyển liên kết sang build mới. Đo và kiểm quota R2 trước deploy. Chỉ sử dụng trong phần miễn phí đã xác minh và dừng triển khai nếu tài khoản yêu cầu bật trả phí ngoài phạm vi Owner duyệt. [Giới hạn Workers](https://developers.cloudflare.com/workers/platform/limits/#static-assets) · [Giá và quota R2](https://developers.cloudflare.com/r2/pricing/)
- **Server test:** Wrangler triển khai Worker và cấu hình Cloudflare. Workers Free không cung cấp VPS để chạy binary Godot Headless. Cloudflare Containers yêu cầu Workers Paid. Để bám kiến trúc Pha 1 và ngân sách 0đ, chạy Godot Headless trên máy/dev host Owner có quyền sử dụng, đưa WSS qua lớp Cloudflare với origin staging đã xác minh. Nếu chưa có host, test Godot Headless local với hai client trước và báo riêng phần WSS qua Internet còn thiếu. Workers/Durable Objects Free chỉ là lựa chọn cho smoke test kết nối nếu Owner đồng ý dùng đầu giả lập riêng. [Giá Cloudflare Containers](https://developers.cloudflare.com/containers/platform/pricing/) · [Durable Objects](https://developers.cloudflare.com/durable-objects/) · [ADR Pha 1](adr/0001-architecture-and-scale-roadmap.md)

## 6. Bằng chứng bàn giao cuối

- Ghi commit nguồn, phiên bản, kết quả từng lượt test và đường dẫn staging. Đối chiếu `arena-stage.json`, device profiles, atlas, mã game và SHA‑256 các gói. Sau khi có link thật, tải lại mỗi file và so SHA với manifest.
- Smoke test Web Godot thật, APK trên K70E do Owner cài trực tiếp, và ghi rõ tình trạng IPA unsigned. Đo thời gian từ khởi động tới login, kết nối vào khu, reconnect và frame time trong combat trên K70E. Nghiệm thu iOS trên thiết bị thật khi có bộ ký và thiết bị.
- Bảng trạng thái QA phải ghi riêng từng mục đã chạy, bỏ qua hoặc còn chờ. Thêm kết quả vào `state.json` bằng `./loop.sh log-task`. Chỉ cập nhật `lerning.md` sau khi fix có bằng chứng kiểm thử. Phiên lập kế hoạch này chưa thay đổi code, chưa triển khai Cloudflare và chưa cấp tài khoản test.
