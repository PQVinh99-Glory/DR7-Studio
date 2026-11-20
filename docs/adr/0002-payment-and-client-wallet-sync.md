# ADR-0002: Kiến Trúc Liên Kết Thanh Toán Tự Động (In-Game Client + Website → Đồng Bộ Ví & Balo)

- **Trạng thái**: `PENDING` (Tạm hoãn — dự kiến tham khảo, chưa chốt chính thức; chờ hoàn thiện game core trước khi triển khai)
- **Ngày**: 2026-11-19
- **Phạm vi**: DR7-Studio (Godot 4 Mobile APK/iOS + Web + Website nạp tiền chính thức + Supabase PostgreSQL/Edge Functions + Cloudflare Workers/WAF)
- **Nguyên tắc cốt lõi**: **Server-Authoritative Ledger (Sổ cái phía máy chủ)** — Client KHÔNG BAO GIỜ tự cộng tiền/item; mọi giao dịch phải có **Idempotency Key**, xác thực chữ ký webhook/receipt phía server, ghi giao dịch nguyên tử (`ACID`) vào PostgreSQL và đẩy cập nhật về Game Client tự động.

---

## 1. Luồng Tổng Thể (2 Kênh Nạp → 1 Sổ Cái Trung Tâm)

```text
[Kênh A: Website Nạp Chính Thức]                 [Kênh B: In-Game Mobile Client]
 (PayPal / Stripe / Ví & Thẻ Quốc Tế —           (Google Play Billing / Apple IAP)
  KHÔNG dùng cổng thanh toán nội địa VN)
               │                                                │
               ▼                                                ▼
   Cloudflare Worker / WAF                         Godot Client gửi Purchase Token /
   (chặn bot, rate-limit, verify HMAC)             Receipt + JWT về Payment Endpoint
               │                                                │
               └───────────────────┬────────────────────────────┘
                                   ▼
                 Supabase Edge Function / Payment API
                 1. Verify chữ ký Webhook (PayPal / Stripe / International Wallet)
                    HOẶC Verify Receipt trực tiếp với Apple/Google API
                 2. Chống nạp trùng bằng UNIQUE(provider, provider_tx_id)
                 3. Gọi PostgreSQL RPC `credit_payment_order(...)` (ACID)
                    - Cập nhật `payment_orders.status = 'paid'`
                    - Ghi bút toán dương vào `wallet_ledger`
                    - Cộng số dư vào `player_wallets` (Vàng / Ngọc)
                    - Cộng gói vật phẩm vào `player_inventory` / `player_mail_rewards`
                                   │
                                   ▼
                 Đồng bộ tức thì về Game Client (2 lớp bảo vệ):
                 • Lớp 1 (Realtime <1s): Game Server / WebSocket (`wss://`) nhận
                   Postgres `LISTEN/NOTIFY` (hoặc HTTP internal webhook) → gửi gói
                   `WALLET_AND_INVENTORY_SYNC` trực tiếp tới session đang online.
                 • Lớp 2 (Fallback an toàn): Khi người chơi mở lại game / đổi khu /
                   mở Balo, Client gọi `GET /v1/player/wallet-sync` kèm `last_ledger_seq`
                   để đồng bộ bù 100%, không bao giờ mất hàng kể cả lúc rớt mạng.
```

---

## 2. Thiết Kế Bảng PostgreSQL trên Supabase (Zero-Drift & Chống Cộng Trùng)

| Bảng | Vai trò chính | Ràng buộc chống lỗi bắt buộc |
| :--- | :--- | :--- |
| `payment_products` | Danh mục gói nạp (SKU, giá `USD` / ngoại tệ quốc tế, số Ngọc/Vàng, bonus lần đầu, danh sách item). | Client chỉ gửi `product_id`, **server tự tra giá & phần thưởng** (chống sửa gói giá từ client). |
| `payment_orders` | Lịch sử đơn hàng (`order_id`, `user_id`, `channel`: `web_checkout`/`google_iap`/`apple_iap`, `status`: `pending`/`paid`/`failed`/`refunded`, `provider_tx_id`). | `UNIQUE(channel, provider_tx_id)` chặn webhook gửi lặp (replay attack / retry). |
| `wallet_ledger` | Sổ cái bất biến (Append-only) mọi biến động tiền (`delta_gems`, `delta_gold`, `balance_after`, `ref_order_id`, `created_at`). | Không `UPDATE`/`DELETE` dòng cũ; giúp kiểm toán/đối soát 100% khi khiếu nại. |
| `player_wallets` | Số dư hiện tại của người chơi (`user_id`, `gems`, `gold`, `ledger_seq`, `updated_at`). | Chỉ cập nhật trong cùng transaction với `wallet_ledger` (Row-Level Security: user chỉ `SELECT`, cấm `UPDATE` trực tiếp). |
| `player_inventory` | Vật phẩm/trang bị trong balo + hộp thư quà nạp (`player_mail_rewards`). | Hỗ trợ nạp khi nhân vật đang offline: quà vào hộp thư hoặc cộng thẳng balo kèm thông báo popup khi đăng nhập. |

---

## 3. Phân Tách Kênh Thanh Toán & Tuân Thủ Chính Sách Store

1. **Nạp trên Website chính thức (Web Top-Up Quốc Tế — Chốt Owner 2026-11-19: KHÔNG dùng cổng thanh toán tại Việt Nam)**:
   - Người chơi đăng nhập bằng đúng tài khoản **Supabase Auth đã xác thực Gmail 100%** (Google OAuth / Gmail verification — không cho tài khoản khách/chưa xác thực Gmail nạp tiền).
   - Tạo đơn hàng `pending` gắn `order_id` duy nhất.
   - Chỉ tích hợp **PayPal**, **Ví quốc tế** và **Stripe / Paddle (thẻ quốc tế)**; tuyệt đối **không** mở VietQR/ngân hàng/ví nội địa Việt Nam.
   - Khi thanh toán hoàn tất → cổng thanh toán quốc tế bắn Webhook HTTPS qua **Cloudflare WAF** → Edge Function xác thực chữ ký Webhook (PayPal/Stripe signature) + khớp đúng số tiền + mã đơn → ghi sổ cái & bắn sự kiện `WALLET_AND_INVENTORY_SYNC` vào Game Client trong **1–3 giây**.
2. **Nạp trực tiếp trong Game Client Mobile (Android Play & iOS App Store)**:
   - **Khi phát hành qua Google Play / Apple App Store**: Bắt buộc dùng **Google Play Billing** & **Apple StoreKit 2 (IAP)** cho vật phẩm số trong app (tuân thủ chính sách App Store / Google Play để tránh bị gỡ app). Godot 4 hỗ trợ plugin chính thức `GodotGooglePlayBilling` (Android) và `GodotAppleStoreKit` (iOS).
   - **Với bản APK ngoài store / test nội bộ**: Có thể mở luồng Web Checkout quốc tế (PayPal / Stripe) rồi tự động đồng bộ về game.
3. **Lưu ý tuân thủ quy định GeoIP trong `AGENTS.md` Điều 4**:
   - Tuân thủ chính sách tách vùng GeoIP (`2026-11-19`): **`JP`** chặn cứng 100% ở mọi lớp (web/store/tải về lẫn Client/Server); **`VN`** chặn ở trang tìm kiếm/tải về/web store nhưng **mở cho Game Client/Server**. Webhook PayPal/Stripe đến từ IP Mỹ/EU nên không xung đột với rule GeoIP (bảo vệ `/webhooks/payment/*` bằng xác thực chữ ký chính chủ PayPal/Stripe).

---

## 4. Lộ Trình Triển Khai 2 Pha (Khớp `ADR-0001` — `0đ` Test Trước, Hiện Trạng `PENDING`)

- **Pha 1 (`0đ` Test/Alpha — dùng Supabase Free + Cloudflare Workers Free)**:
  1. Tạo schema SQL migration (`payment_products`, `payment_orders`, `wallet_ledger`, `player_wallets`, `player_inventory`) + hàm RPC `credit_payment_order` trên Supabase CLI.
  2. Viết Cloudflare Worker + Supabase Edge Function nhận Webhook sandbox (PayPal Sandbox / Stripe Test) + endpoint `GET /v1/player/wallet-sync`.
  3. Nối Godot Client (`scenes/net/WebSocketTransport.gd` + `HTTPRequest`) nhận gói `WALLET_AND_INVENTORY_SYNC`, hiển thị toast `"Nhận +500 Ngọc / Item"` và cập nhật HUD/Balo tức thì.
- **Pha 2 (Thương mại hóa)**:
  - Bật Google Play Billing + Apple StoreKit 2 receipt verification + xử lý hoàn tiền/chargeback (`refunded` → thu hồi số dư hoặc khóa tài khoản gian lận) + dashboard đối soát hàng ngày.
