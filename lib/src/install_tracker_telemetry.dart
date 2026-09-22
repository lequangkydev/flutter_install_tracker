import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model/install_attribution.dart';

/// Cấu hình telemetry — truyền vào [InstallTracker.initialize]. Null = tắt.
class InstallTrackerTelemetryConfig {
  const InstallTrackerTelemetryConfig({
    this.analyticsEnabled = true,
    this.firestoreEnabled = true,
    this.firestoreCollection = 'install_tracker_logs',
    this.dayUtcOffset = const Duration(hours: 7),
    this.flavor,
    this.extraFields = const {},
  });

  /// Log event `install_tracker_timing` (mọi launch) + `install_source`
  /// (lần đầu) + user property `install_network` lên Firebase Analytics.
  final bool analyticsEnabled;

  /// Ghi document chi tiết lên Firestore (chỉ lần resolve đầu tiên).
  /// Yêu cầu app đã tạo Firestore database + publish rules cho
  /// [firestoreCollection] và [firestoreDevicesCollection] (xem README).
  final bool firestoreEnabled;

  /// Collection gốc trên Firestore.
  final String firestoreCollection;

  /// Collection marker dedupe trọn đời — `{firestoreCollection}_devices`.
  String get firestoreDevicesCollection => '${firestoreCollection}_devices';

  /// Múi giờ dùng để tính doc id ngày ('2026-08-17'). Mặc định UTC+7 (VN)
  /// để "ngày 17" trên console khớp ngày ops đang xem, bất kể timezone máy.
  final Duration dayUtcOffset;

  /// Flavor app (vd 'prod'/'dev') — ghi kèm doc Firestore.
  final String? flavor;

  /// Field tuỳ ý thêm vào doc Firestore (vd app-specific meta).
  final Map<String, Object?> extraFields;
}

/// Telemetry cho InstallSourceTracker — trả lời "tracker mất bao lâu, cho
/// user nào, ra kết quả gì":
///
/// 1. **Firebase Analytics** (`install_tracker_timing`): log MỌI lần launch
///    — nhẹ, miễn phí, xem aggregate (median/p95 duration) trên console /
///    BigQuery. Kèm `install_source` event (lần resolve thật) + user property
///    `install_network` (mọi launch) để segment GA4 theo nguồn cài. Analytics
///    tự queue khi offline → KHÔNG phụ thuộc Firestore.
/// 2. **Firestore** — cấu trúc THEO NGÀY để dễ soi từng ngày trên console:
///    ```
///    {collection}/{yyyy-MM-dd}          ← doc ngày: installCount tổng
///      └─ installs/{androidId}          ← từng install đầy đủ info
///    {collection}_devices/{androidId}   ← marker dedupe trọn đời
///    ```
///    CHỈ ghi lần resolve thật, bằng 1 batch nguyên tử: marker + counter +1
///    + doc install. Rules chỉ cho CREATE marker → máy đã được đếm (clear
///    data / cài lại) ghi lại marker = update → server từ chối CẢ batch →
///    không +1 trùng. Batch không cần quyền đọc (khác transaction) và vẫn
///    chạy offline: SDK giữ batch trong hàng đợi local, gửi khi có mạng.
///    KHÔNG dùng array trong 1 doc: Firestore giới hạn 1MB/document, ngày
///    chạy campaign mạnh (~2000 install) sẽ vỡ — subcollection scale vô hạn.
///
/// Mọi thao tác đều fire-and-forget + try/catch — telemetry KHÔNG ĐƯỢC PHÉP
/// làm chậm hay crash luồng khởi động.
class InstallTrackerTelemetry {
  InstallTrackerTelemetry._();

  static const MethodChannel _channel =
      MethodChannel('flutter_install_tracker');

  static const Duration _firestoreTimeout = Duration(seconds: 10);

  /// Batch install đã vào hàng đợi Firestore nhưng server CHƯA xác nhận
  /// (offline / app bị kill) → launch sau đánh thức Firestore để gửi nốt.
  static const String _prefsKeyFirestorePending =
      'install_tracker_firestore_pending';

  static Future<void> log({
    required InstallTrackerTelemetryConfig config,
    required InstallAttribution attribution,
    required bool isFullAds,
    required int totalDurationMs,
    required int referrerFetchMs,
  }) async {
    // ---- 1. Analytics: timing MỌI launch (aggregate median/p95) ----
    if (config.analyticsEnabled) {
      try {
        // User property → segment audience trong GA4 theo nguồn cài. Bỏ qua
        // max_full (kill-switch, không phải nguồn cài) để giữ giá trị thật.
        if (attribution.network != 'max_full') {
          await FirebaseAnalytics.instance.setUserProperty(
            name: 'install_network',
            value: attribution.network,
          );
        }
        await FirebaseAnalytics.instance.logEvent(
          name: 'install_tracker_timing',
          parameters: {
            'total_ms': totalDurationMs,
            'referrer_fetch_ms': referrerFetchMs,
            'network': attribution.network,
            'from_cache': attribution.fromCache.toString(),
            'is_full_ads': isFullAds.toString(),
          },
        );
        debugPrint(
            '[InstallTracker] 📊 Analytics timing đã gửi (total=${totalDurationMs}ms, '
            'fetch=${referrerFetchMs}ms)');
      } catch (e) {
        debugPrint('[InstallTracker] ✖ analytics timing failed: $e');
      }
    }

    // ---- 2. install_source: 1 lần ở lần resolve thật ----
    // Gate theo !fromCache, KHÔNG theo kết quả Firestore: Firestore lỗi /
    // offline / chưa tạo database không được làm mất event. Không lặp vì
    // persist xong mới emit, maxFull trả fromCache=true và facade chỉ log
    // 1 lần/process. Clear data → bắn lại, khớp GA4 (app instance mới).
    if (config.analyticsEnabled && !attribution.fromCache) {
      try {
        await FirebaseAnalytics.instance.logEvent(
          name: 'install_source',
          parameters: {
            'network': attribution.network,
            'is_full_ads': isFullAds.toString(),
            // Firebase giới hạn param value 100 ký tự.
            if (attribution.referrer != null)
              'referrer': attribution.referrer!.length > 100
                  ? attribution.referrer!.substring(0, 100)
                  : attribution.referrer!,
          },
        );
        debugPrint('[InstallTracker] 📊 Analytics install_source đã gửi');
      } catch (e) {
        debugPrint('[InstallTracker] ✖ analytics install_source failed: $e');
      }
    }

    // ---- 3. Firestore: ghi 1 lần / máy trọn đời ----
    if (!config.firestoreEnabled) {
      return;
    }
    if (attribution.fromCache) {
      await _flushPendingInstall();
      return;
    }
    await _writeInstall(
      config: config,
      attribution: attribution,
      isFullAds: isFullAds,
      totalDurationMs: totalDurationMs,
      referrerFetchMs: referrerFetchMs,
    );
  }

  /// Lần resolve thật: 1 batch nguyên tử — marker + counter +1 + doc install.
  static Future<void> _writeInstall({
    required InstallTrackerTelemetryConfig config,
    required InstallAttribution attribution,
    required bool isFullAds,
    required int totalDurationMs,
    required int referrerFetchMs,
  }) async {
    // Native plugin chỉ có Android → nền tảng khác không có ID máy ổn định.
    if (!Platform.isAndroid) {
      debugPrint('[InstallTracker] 🔥 Firestore skip — chỉ hỗ trợ Android');
      return;
    }
    try {
      // ANDROID_ID: sống qua cài lại / clear data → dedupe trọn đời. KHÔNG
      // dùng androidInfo.id của device_info_plus — đó là Build.ID (tên bản
      // firmware), hàng nghìn máy trùng nhau.
      final deviceId = await _channel.invokeMethod<String>('getAndroidId');
      if (deviceId == null || deviceId.isEmpty) {
        // Thà thiếu còn hơn đếm trùng: không có ID thì không dedupe được.
        debugPrint(
            '[InstallTracker] 🔥 Firestore skip — không đọc được ANDROID_ID');
        return;
      }

      final android = await DeviceInfoPlugin().androidInfo;
      final packageInfo = await PackageInfo.fromPlatform();
      // Pseudo user id của Firebase Analytics — join được với event/GA4.
      final appInstanceId = await FirebaseAnalytics.instance.appInstanceId;

      // Doc id ngày theo [config.dayUtcOffset]: '2026-08-17'.
      final now = DateTime.now().toUtc().add(config.dayUtcOffset);
      final dateId = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      final firestore = FirebaseFirestore.instance;
      final dayDoc =
          firestore.collection(config.firestoreCollection).doc(dateId);
      final installDoc = dayDoc.collection('installs').doc(deviceId);
      final deviceDoc =
          firestore.collection(config.firestoreDevicesCollection).doc(deviceId);

      // Batch NGUYÊN TỬ: marker đã tồn tại → rules từ chối (chỉ cho create)
      // → CẢ batch bị huỷ, counter không +1. Không đọc trước nên không cần
      // quyền read như transaction.
      final batch = firestore.batch()
        ..set(deviceDoc, {
          'date': dateId,
          'createdAt': FieldValue.serverTimestamp(),
        })
        ..set(
          dayDoc,
          {
            'date': dateId,
            'installCount': FieldValue.increment(1),
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        )
        ..set(installDoc, {
          'deviceId': deviceId,
          'appInstanceId': appInstanceId,
          // Kết quả tracker
          'network': attribution.network,
          'referrer': attribution.referrer,
          'isFullAds': isFullAds,
          // Timing
          'totalDurationMs': totalDurationMs,
          'referrerFetchMs': referrerFetchMs,
          // Device
          'device': {
            'model': android.model,
            'manufacturer': android.manufacturer,
            'brand': android.brand,
            'sdkInt': android.version.sdkInt,
            'androidVersion': android.version.release,
            'isPhysicalDevice': android.isPhysicalDevice,
          },
          // App
          'appVersion': packageInfo.version,
          'buildNumber': packageInfo.buildNumber,
          'packageName': packageInfo.packageName,
          if (config.flavor != null) 'flavor': config.flavor,
          // Context
          'locale': Platform.localeName,
          'timezone': DateTime.now().timeZoneName,
          'createdAt': FieldValue.serverTimestamp(),
          ...config.extraFields,
        });

      // Đánh dấu pending TRƯỚC commit: app bị kill khi batch còn nằm trong
      // hàng đợi offline → launch sau vẫn biết để đánh thức Firestore.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKeyFirestorePending, true);
      try {
        await batch.commit().timeout(_firestoreTimeout);
        debugPrint('[InstallTracker] 🔥 Firestore NEW (+1) → '
            '${config.firestoreCollection}/$dateId/installs/$deviceId');
      } on FirebaseException catch (e) {
        // Server từ chối → CẢ batch bị huỷ, không +1. permission-denied =
        // máy này đã được đếm (marker đã có) — hoặc rules chưa publish.
        debugPrint('[InstallTracker] 🔥 Firestore từ chối (${e.code}) → '
            'không +1 (máy đã được đếm, hoặc chưa publish rules)');
      }
      await prefs.remove(_prefsKeyFirestorePending);
    } on TimeoutException {
      // Server chưa xác nhận (offline / mạng chậm): batch vẫn nằm trong hàng
      // đợi local, SDK tự gửi khi có mạng — giữ cờ pending cho launch sau.
      debugPrint('[InstallTracker] 🔥 Firestore chưa xác nhận sau '
          '${_firestoreTimeout.inSeconds}s → gửi khi có mạng');
    } catch (e) {
      debugPrint('[InstallTracker] ✖ firestore failed: $e '
          '(check đã tạo database + publish rules chưa)');
    }
  }

  /// Launch sau: batch install lần trước chưa được xác nhận (app bị kill khi
  /// offline) → đánh thức Firestore để SDK gửi nốt hàng đợi local — batch đã
  /// nằm sẵn trên disk, giữ nguyên ngày + data gốc. Không có cờ pending thì
  /// không chạm Firestore → launch bình thường không tốn gì.
  static Future<void> _flushPendingInstall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefsKeyFirestorePending) != true) {
        debugPrint(
            '[InstallTracker] 🔥 Firestore skip — fromCache=true (chỉ ghi lần resolve đầu)');
        return;
      }
      await FirebaseFirestore.instance
          .waitForPendingWrites()
          .timeout(_firestoreTimeout);
      await prefs.remove(_prefsKeyFirestorePending);
      debugPrint('[InstallTracker] 🔥 Firestore đã xử lý xong batch install '
          'còn treo từ launch trước');
    } catch (e) {
      debugPrint('[InstallTracker] 🔥 Firestore batch install vẫn treo: $e');
    }
  }
}
