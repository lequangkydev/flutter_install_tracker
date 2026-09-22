/// Track nguồn cài đặt qua Google Play Install Referrer (thay Adjust):
/// organic → không full ads, network (Google Ads / Meta / TikTok / utm khác)
/// → full ads. Kèm telemetry Firebase Analytics + Firestore (optional).
///
/// Cách dùng (gọi 1 lần lúc khởi động, sau khi Firebase.initializeApp):
/// ```dart
/// await InstallTracker.initialize(
///   options: InstallTrackerOptions.fromJson(remoteConfigJson), // hoặc default
///   telemetry: const InstallTrackerTelemetryConfig(flavor: 'prod'),
///   onResolved: (attribution, isFullAds) {
///     Global.instance.isFullAds = isFullAds;
///     // ... sync native, save network, v.v.
///   },
/// );
/// ```
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'src/install_source_tracker.dart';
import 'src/install_tracker_telemetry.dart';
import 'src/model/install_attribution.dart';
import 'src/model/install_tracker_options.dart';

export 'src/install_source_tracker.dart';
export 'src/install_tracker_telemetry.dart';
export 'src/model/install_attribution.dart';
export 'src/model/install_tracker_options.dart';

/// Facade gọn: chạy tracker + đo thời gian trả kết quả + telemetry.
///
/// `totalMs` = từ lúc gọi → `isFullAds` CÓ KẾT QUẢ (lần đầu gồm cả persist
/// cache — persist xong mới trả kết quả).
class InstallTracker {
  InstallTracker._();

  /// Telemetry chỉ chạy 1 lần/process: gọi [initialize] lại vẫn nhận callback
  /// nhưng không log timing ~0ms / install_source lặp.
  static bool _telemetryLogged = false;

  /// [fullAdsOverride]: ép cứng kết quả (vd từ
  /// `--dart-define=FULL_ADS=true/false` phía app) — attribution vẫn được
  /// resolve + log đầy đủ, chỉ giá trị isFullAds đưa vào callback bị thay.
  static Future<void> initialize({
    InstallTrackerOptions options = const InstallTrackerOptions(),
    InstallTrackerTelemetryConfig? telemetry,
    bool? fullAdsOverride,
    required void Function(InstallAttribution attribution, bool isFullAds)
        onResolved,
  }) async {
    final stopwatch = Stopwatch()..start();
    await InstallSourceTracker.instance.initialize(
      options: options,
      onResolved: (attribution) {
        stopwatch.stop();
        final totalMs = stopwatch.elapsedMilliseconds;
        final fetchMs = InstallSourceTracker.instance.lastResolveDurationMs;
        final isFullAds = fullAdsOverride ?? attribution.isFullAds;

        debugPrint('╔══════════════ [InstallTracker] TỔNG KẾT ══════════════');
        debugPrint('║ isFullAds        : $isFullAds'
            '${fullAdsOverride != null ? ' (OVERRIDE)' : ''}');
        debugPrint('║ trả về sau       : ${totalMs}ms'
            ' (riêng fetch referrer: ${fetchMs}ms)');
        debugPrint('║ network          : ${attribution.network}');
        debugPrint('║ fromCache        : ${attribution.fromCache}');
        debugPrint('║ referrer         : ${attribution.referrer ?? '(null)'}');
        debugPrint('╚═══════════════════════════════════════════════════════');

        onResolved(attribution, isFullAds);

        if (telemetry != null && !_telemetryLogged) {
          _telemetryLogged = true;
          // Fire-and-forget — không block luồng khởi động của app.
          unawaited(InstallTrackerTelemetry.log(
            config: telemetry,
            attribution: attribution,
            isFullAds: isFullAds,
            totalDurationMs: totalMs,
            referrerFetchMs: fetchMs,
          ));
        }
      },
    );
  }
}
