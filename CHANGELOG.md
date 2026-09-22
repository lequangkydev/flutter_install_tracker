## 0.2.0

* **Sửa đếm install trên Firestore** — ⚠ cần publish lại rules (xem README):
  * Key dedupe đổi sang ANDROID_ID (method native mới `getAndroidId`).
    `androidInfo.id` của device_info_plus là Build.ID (tên bản firmware) —
    nhiều máy dùng chung 1 doc → `installCount` đếm thiếu nặng.
  * Bỏ transaction (cần quyền đọc mà rules trong README chặn → luôn fail;
    fail luôn khi offline). Thay bằng batch nguyên tử + marker chỉ-create
    `{collection}_devices/{androidId}` → server chặn đếm trùng trọn đời,
    chạy được offline; batch chưa được xác nhận (app bị kill khi offline)
    được gửi nốt ở launch sau.
* `install_source` không còn phụ thuộc Firestore — gate lại theo
  `fromCache=false`.
* `maxFull` trả `fromCache=true`: không còn ghi Firestore, bắn
  `install_source` hay ghi đè user property `install_network` mỗi launch.
* Gọi `initialize` nhiều lần (kể cả khi lần đầu chưa xong) → callback nào
  cũng được gọi; telemetry chỉ chạy 1 lần/process.
* Persist cache ghi key quyết định sau cùng → process chết giữa chừng không
  còn cache HIT với `network='unknown'`.

## 0.1.0

* Bản đầu: track nguồn cài qua Google Play Install Referrer (thay Adjust) →
  organic / google_ads / meta / tiktok / utm khác → quyết định full ads,
  cache quyết định sau lần đầu. Telemetry tuỳ chọn: Firebase Analytics +
  Firestore theo ngày.
