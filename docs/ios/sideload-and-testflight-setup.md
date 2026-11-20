# Hướng Dẫn Đóng Gói & Cài Đặt iOS `.ipa` Linh Hoạt (`0đ` Sideloadly / AltStore / SideStore → Ad-Hoc OTA / TestFlight Tùy Chọn)

Tài liệu chuẩn hóa quy trình build & cài **DR7-Studio DragonBall 2D** lên iPhone thật **không cần sở hữu máy Mac** và **KHÔNG khóa cứng vào TestFlight** (có thể linh hoạt đổi kênh phân phối bất cứ lúc nào):
- **Giai đoạn Test (`0đ`)**: GitHub Actions (`macos-latest`, có cache Godot tiết kiệm phút chạy) xuất `unsigned.ipa` + `altstore-source.json` → cài bằng **Sideloadly / AltStore / SideStore**, đồng thời lưu `base.ipa` tại `build/ios/base/dr7-studio-base.ipa` để `./loop.sh build-all` tự động đồng bộ **Web + APK + IPA** ngay trên Codespace Linux và hiển thị nút tải trực tiếp ở `localhost:8080`.
- **Giai đoạn Scale (Linh hoạt — không khóa cứng TestFlight)**: Cùng 1 workflow hỗ trợ cả **`signed_adhoc_ota`** (phân phối Ad-Hoc/OTA 100 UDID, không cần TestFlight/App Store) lẫn **`signed_appstore_testflight`** (tùy chọn upload TestFlight Internal/External hoặc App Store khi cần).

---

## Giai đoạn 1 — Test Native 60 FPS Trên iPhone (`0đ`, Không Cần Mac)

### Bước 1: Xuất file `unsigned.ipa` bằng GitHub Actions
1. Vào tab **Actions** trên GitHub → chọn workflow **`Build iOS IPA (Flexible Sideload / Ad-Hoc OTA / Optional TestFlight)`** ([build-ios-ipa.yml](../../.github/workflows/build-ios-ipa.yml)).
2. Bấm **Run workflow** với cấu hình:
   - `signing_mode`: **`unsigned_sideload`**
   - `publish_github_release`:
     - Chọn **`false`** nếu chỉ tải file `.ipa` từ Artifacts về máy tính cài bằng Sideloadly/AltStore.
     - Chọn **`true`** nếu muốn tự động tạo GitHub Release + file **`altstore-source.json`** có link HTTPS trực tiếp cho **SideStore / AltStore** tự nhận bản cập nhật!
3. Sau khi workflow chạy xong (~8–12 phút), tải artifact `dr7-studio-ios-unsigned_sideload-vX.Y.Z` gồm:
   - `dr7-studio-vX.Y.Z-unsigned.ipa`
   - `ipa-sha256.txt`
   - `altstore-source.json`

> **Lưu ý Entitlements cho Apple ID miễn phí**: Preset `[preset.2]` trong [export_presets.cfg](../../export_presets.cfg) đã tắt toàn bộ quyền hạn chế (`push_notifications=false`, `access_wifi=false`, `performance_gaming_tier=false`) để ký mượt 100% bằng Apple ID thường (`0đ`).

---

### Bước 2: Chọn 1 trong 3 công cụ cài lên iPhone

#### Cách 1A — Sideloadly *(Nhanh nhất trên Windows/Mac — 2 phút)*
1. Cài **Sideloadly** trên máy tính Windows + cài **iTunes** (bản tải từ apple.com, không dùng bản Microsoft Store) & **iCloud**.
2. Cắm cáp USB iPhone vào máy tính → chọn **Tin cậy (Trust)** trên iPhone.
3. Mở Sideloadly → kéo thả file `dr7-studio-vX.Y.Z-unsigned.ipa` vào → nhập Apple ID thường → bấm **Start**.
4. Trên iPhone: vào **Cài đặt → Cài đặt chung → Quản lý VPN & Thiết bị** → bấm **Tin cậy** chứng chỉ Apple ID của anh → mở game!
5. *(Hạn 7 ngày; có thể bật Wi-Fi Refresh trong Sideloadly để tự gia hạn khi cùng Wi-Fi với máy tính).*

#### Cách 1B — SideStore *(Khuyên dùng để test dài ngày — Tự gia hạn 7 ngày ngay trên iPhone KHÔNG cần máy tính)*
1. Cài **SideStore** lên iPhone lần đầu bằng máy tính Windows (theo hướng dẫn chính chủ `sidestore.io` + tạo file pairing).
2. Khi SideStore đã chạy trên iPhone, có 2 cách nạp DR7-Studio:
   - **Nạp thủ công**: Chép file `dr7-studio-vX.Y.Z-unsigned.ipa` vào ứng dụng **Tệp (Files)** trên iPhone → mở SideStore → tab **My Apps** → bấm **`+`** chọn file `.ipa`.
   - **Nạp tự động qua Source Feed (`altstore-source.json`)**: Nếu anh chạy workflow với `publish_github_release: true`, copy link raw/release của `altstore-source.json` → vào SideStore → **Sources → `+`** dán URL → từ các version sau chỉ cần bấm **Update** ngay trên iPhone!
3. Mỗi tuần, mở SideStore (bật VPN cục bộ WireGuard/StosVPN của SideStore) → bấm **Refresh All** để gia hạn thêm 7 ngày ngay trên điện thoại.

#### Cách 1C — AltStore Classic *(Qua AltServer trên PC)*
1. Cài **AltServer** trên Windows → cài **AltStore** lên iPhone.
2. Thêm `altstore-source.json` vào AltStore (hoặc bấm `+` chọn trực tiếp file `.ipa`). AltServer trên PC sẽ tự làm mới chứng chỉ 7 ngày qua Wi-Fi.

---

### Luồng chuẩn hóa 1 lệnh đồng bộ Localhost: Web + APK + IPA (`./loop.sh build-all`)
Sau khi tải **1 bản `base.ipa` nền** từ GitHub Actions đặt vào `build/ios/base/dr7-studio-base.ipa`, mỗi lần anh chốt bản mới để Human Test chỉ cần chạy duy nhất 1 lệnh trong Codespace:
```bash
./loop.sh build-all
```
Lệnh này tự động:
1. Xuất Godot Web (`build/web/index.html`)
2. Xuất Android APK (`build/android/dr7-studio-debug.apk`)
3. Repack `.pck` mới vào `build/ios/dr7-studio-unsigned.ipa` + `build/ios/altstore-source.json` trong ~15 giây (**0 phút macOS, 0 AI token**)
4. Cập nhật đồng bộ nút **📱 Tải APK Android** và **🍎 Tải IPA iOS** ngay trên `http://localhost:8080` kèm SHA-256!

---

## Giai đoạn 2 — Kênh Scale Linh Hoạt (`signed_adhoc_ota` HOẶC `signed_appstore_testflight`)

Không khóa cứng TestFlight: khi có tài khoản Apple Developer (`$99/năm`) hoặc kênh phân phối mới, workflow [build-ios-ipa.yml](../../.github/workflows/build-ios-ipa.yml) nhận 2 nhóm Secrets tách biệt:
- **Nhóm 1 (3 Secret ký `.ipa` — dùng cho cả Ad-Hoc OTA lẫn TestFlight/App Store)**: `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_PASSWORD`, `IOS_PROVISION_PROFILE_BASE64`.
- **Nhóm 2 (3 Secret CHỈ cần nếu bật `upload_testflight: true`)**: `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`.

| GitHub Secret | Cách lấy từ Apple Developer / App Store Connect |
| :--- | :--- |
| `IOS_DIST_CERT_P12_BASE64` | Chứng chỉ **Apple Distribution** xuất `.p12`, mã hóa Base64 (`base64 -w0 dist.p12`). |
| `IOS_DIST_CERT_PASSWORD` | Mật khẩu file `.p12`. |
| `IOS_PROVISION_PROFILE_BASE64` | File `.mobileprovision` tương ứng chế độ ký (**Ad-Hoc** cho `signed_adhoc_ota` hoặc **App Store Distribution** cho `signed_appstore_testflight`) cho Bundle ID `com.dr7studio.dragonball2d`, mã hóa Base64. |
| `ASC_API_KEY_ID` | Key ID tạo tại App Store Connect → Users & Access → Integrations → App Store Connect API (quyền `App Manager`). |
| `ASC_API_ISSUER_ID` | Issuer ID trong trang App Store Connect API. |
| `ASC_API_KEY_P8_BASE64` | Nội dung file `AuthKey_XXXXXX.p8` mã hóa Base64. |

Sau đó chạy lại **`Build iOS IPA (Flexible Sideload / Ad-Hoc OTA / Optional TestFlight)`** với một trong hai cấu hình:
- **Phân phối Ad-Hoc / OTA (không cần TestFlight):** `signing_mode`: **`signed_adhoc_ota`**, `upload_testflight`: **`false`**
- **Phân phối App Store / TestFlight:** `signing_mode`: **`signed_appstore_testflight`**, `upload_testflight`: **`true`** *(hoặc `false` nếu chỉ lấy file `.ipa` đã ký)*

Workflow sẽ tự động ký chuẩn **Apple Distribution** và đẩy thẳng lên **TestFlight**:
- **Internal Testing** (tối đa **100 tester** trong team): **Không qua duyệt**, có trên app TestFlight sau ~5–10 phút, hạn 90 ngày.
- **External Testing** (tối đa **10,000 tester** qua link public/email): Qua bước Beta App Review nhẹ (~24h), hạn 90 ngày.
