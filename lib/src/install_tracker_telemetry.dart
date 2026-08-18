import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
  /// Yêu cầu app đã tạo Firestore database + mở rules cho
  /// [firestoreCollection] (xem README).
  final bool firestoreEnabled;

  /// Collection gốc trên Firestore.
  final String firestoreCollection;

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
///    BigQuery. Kèm `install_source` event (lần đầu) + user property
///    `install_network` (mọi launch) để segment GA4 theo nguồn cài.
/// 2. **Firestore** — cấu trúc THEO NGÀY để dễ soi từng ngày trên console:
///    ```
///    {collection}/{yyyy-MM-dd}          ← doc ngày: installCount tổng
///      └─ installs/{deviceId}           ← từng install đầy đủ info
///    ```
///    CHỈ ghi lần resolve ĐẦU TIÊN (fromCache=false) → mỗi install đúng
///    1 lần ghi trọn đời, chi phí ~0 khi scale (free tier 20K writes/ngày).
///    KHÔNG dùng array trong 1 doc: Firestore giới hạn 1MB/document, ngày
///    chạy campaign mạnh (~2000 install) sẽ vỡ — subcollection scale vô hạn.
///
/// Mọi thao tác đều fire-and-forget + try/catch — telemetry KHÔNG ĐƯỢC PHÉP
/// làm chậm hay crash luồng khởi động.
class InstallTrackerTelemetry {
  InstallTrackerTelemetry._();

  static Future<void> log({
    required InstallTrackerTelemetryConfig config,
    required InstallAttribution attribution,
    required bool isFullAds,
    required int totalDurationMs,
    required int referrerFetchMs,
  }) async {
    // ---- 1. Analytics ----
    if (config.analyticsEnabled) {
      try {
        // User property → segment audience trong GA4 theo nguồn cài.
        await FirebaseAnalytics.instance.setUserProperty(
          name: 'install_network',
          value: attribution.network,
        );
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
        // install_source: đúng 1 lần cho cả đời install.
        if (!attribution.fromCache) {
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
        }
        debugPrint(
            '[InstallTracker] 📊 Analytics đã gửi (total=${totalDurationMs}ms, '
            'fetch=${referrerFetchMs}ms)');
      } catch (e) {
        debugPrint('[InstallTracker] ✖ analytics failed: $e');
      }
    }

    // ---- 2. Firestore: chỉ lần resolve đầu (1 write / install) ----
    if (!config.firestoreEnabled) {
      return;
    }
    if (attribution.fromCache) {
      debugPrint(
          '[InstallTracker] 🔥 Firestore skip — fromCache=true (chỉ ghi lần resolve đầu)');
      return;
    }
    try {
      final deviceInfo = DeviceInfoPlugin();
      String deviceId = 'unknown';
      final Map<String, Object?> deviceMeta = {};
      if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
        deviceId = android.id;
        deviceMeta.addAll({
          'model': android.model,
          'manufacturer': android.manufacturer,
          'brand': android.brand,
          'sdkInt': android.version.sdkInt,
          'androidVersion': android.version.release,
          'isPhysicalDevice': android.isPhysicalDevice,
        });
      }

      final packageInfo = await PackageInfo.fromPlatform();
      // Pseudo user id của Firebase Analytics — join được với event/GA4.
      final appInstanceId = await FirebaseAnalytics.instance.appInstanceId;

      // Doc id ngày theo [config.dayUtcOffset]: '2026-08-17'.
      final now = DateTime.now().toUtc().add(config.dayUtcOffset);
      final dateId = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      final firestore = FirebaseFirestore.instance;
      final dayDoc = firestore.collection(config.firestoreCollection).doc(dateId);
      final installDoc = dayDoc.collection('installs').doc(deviceId);

      // Batch = 1 round-trip, atomic: doc ngày (counter) + doc install.
      final batch = firestore.batch();
      batch.set(
        dayDoc,
        {
          'date': dateId,
          'installCount': FieldValue.increment(1),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      batch.set(
        installDoc,
        {
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
          'device': deviceMeta,
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
        },
        SetOptions(merge: true),
      );
      await batch.commit().timeout(const Duration(seconds: 10));
      debugPrint('[InstallTracker] 🔥 Firestore written → '
          '${config.firestoreCollection}/$dateId/installs/$deviceId (count +1)');
    } catch (e) {
      debugPrint('[InstallTracker] ✖ firestore failed: $e '
          '(check đã tạo database + publish rules chưa)');
    }
  }
}
