# flutter_install_tracker

Track nguồn cài đặt app qua **Google Play Install Referrer** (thay Adjust) và
quyết định chế độ **full ads**:

| Nguồn cài | network | isFullAds |
|---|---|---|
| Organic (search/browse Play) | `organic` | **false** |
| Google Ads (gclid/gbraid/wbraid) | `google_ads` | true |
| Meta (fbclid / facebook / instagram) | `meta` | true |
| TikTok (ttclid) | `tiktok` | true |
| utm_source khác | `<utm_source>` | true |
| Không đọc được / rỗng / không nhận diện | `null` / `empty` / `unattributed` | theo config |

Kèm telemetry (optional): Firebase Analytics events + Firestore document
theo ngày cho từng install.

## Cài đặt

```yaml
dependencies:
  flutter_install_tracker:
    git:
      url: git@github.com:lequangkydev/flutter_install_tracker.git
      ref: main
```

Native tự đăng ký qua plugin registry — **không cần sửa
MainApplication/MainActivity/gradle** (hoạt động cả với engine pre-warm).

## Dùng

Gọi 1 lần lúc khởi động, **sau `Firebase.initializeApp()`** (nếu bật
telemetry) và sau khi load Remote Config (nếu options lấy từ đó):

```dart
await InstallTracker.initialize(
  options: RemoteConfigManager.instance.installTrackerOptions,
  telemetry: InstallTrackerTelemetryConfig(flavor: F.appFlavor.name),
  // Ép kết quả khi build test: --dart-define=FULL_ADS=true/false
  fullAdsOverride: const bool.hasEnvironment('FULL_ADS')
      ? const bool.fromEnvironment('FULL_ADS')
      : null,
  onResolved: (attribution, isFullAds) {
    Global.instance.isFullAds = isFullAds;
    // sync native / save network / v.v. tuỳ app
  },
);
```

- Quyết định **cache sau lần resolve đầu** → các launch sau trả trong vài ms,
  không flap. Native cache raw referrer (Play chỉ giữ ~90 ngày).
- Test lại từ đầu: `adb shell pm clear <package>`.
- Log console: lọc từ khóa `InstallTracker`.

## Options (map với Remote Config key, vd `install_tracker_config`)

```json
{"maxFull":false,"useNull":true,"useEmpty":true,"useUnAttributed":true,"organicKeywords":["organic"]}
```

- `maxFull` — kill-switch: mọi user full ads (không cache, tắt là hết hiệu
  lực). Callback `fromCache=true` → telemetry không tính là install mới
- `useNull` / `useEmpty` / `useUnAttributed` — referrer null / rỗng / không
  nhận diện → coi là full ads? (default true — an toàn doanh thu)
- `organicKeywords` — keyword trong `utm_medium` được coi là organic

Parse: `InstallTrackerOptions.fromJson(jsonDecode(rawJson))`.

## Telemetry

**Analytics** (mọi app dùng chung Firebase project của chính nó):
- `install_source` — 1 lần ở lần resolve thật (`fromCache=false`): network,
  is_full_ads, referrer. Không phụ thuộc Firestore.
- `install_tracker_timing` — mọi launch: total_ms, referrer_fetch_ms
- user property `install_network` — segment GA4 theo nguồn cài

**Firestore** (1 batch/máy trọn đời, key = ANDROID_ID):
```
install_tracker_logs/{yyyy-MM-dd}          ← installCount tổng theo ngày
  └─ installs/{androidId}                  ← network, isFullAds, duration, device, version...
install_tracker_logs_devices/{androidId}   ← marker dedupe (chỉ create)
```
Ngày tính theo UTC+7 (đổi qua `dayUtcOffset`).

Máy đã được đếm (clear data, cài lại) → marker đã tồn tại → rules từ chối
**cả batch** → `installCount` không +1 trùng. Batch không cần quyền đọc và
chạy được offline (SDK tự gửi khi có mạng, kể cả khi app bị kill trước đó).

Cần tạo Firestore database + publish rules:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /install_tracker_logs/{date} {
      allow create, update: if true;
      allow read, delete: if false;
      match /installs/{deviceId} {
        // update: giữ cho các bản app cũ còn đang chạy
        allow create, update: if true;
        allow read, delete: if false;
      }
    }
    // Marker dedupe: CHỈ create — ghi lại = update → bị từ chối.
    match /install_tracker_logs_devices/{deviceId} {
      allow create: if true;
      allow read, update, delete: if false;
    }
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

Đổi `firestoreCollection` thì đổi cả 2 tên trong rules: `<tên>` và
`<tên>_devices`.

> **Nâng cấp từ 0.1.x:** publish lại rules (thêm block
> `install_tracker_logs_devices`) **trước** khi phát hành app. Thiếu block
> này mọi batch bị từ chối → Firestore không ghi được gì (Analytics không
> ảnh hưởng). Số liệu Firestore từ 0.1.x không tin được: doc `installs/`
> cũ keyed theo Build.ID (tên bản firmware, nhiều máy trùng nhau) chứ không
> phải ID máy.

Tắt bớt: `InstallTrackerTelemetryConfig(firestoreEnabled: false)` hoặc bỏ
hẳn param `telemetry`.

## Test attribution trước khi chạy tiền thật

Đẩy build lên Internal Testing, cài qua link Play có gắn referrer:

```
https://play.google.com/store/apps/details?id=<PKG>&referrer=gclid%3Dtest123
```

→ mở app: `network=google_ads, isFullAds=true`. Cài thẳng từ Play search →
`organic, false`.
