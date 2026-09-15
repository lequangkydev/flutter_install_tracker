import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model/install_attribution.dart';
import 'model/install_tracker_options.dart';

typedef InstallAttributionCallback = void Function(
  InstallAttribution attribution,
);

/// Tracker nguồn cài đặt dựa trên Google Play Install Referrer — thay thế
/// Adjust cho bài toán "user tới từ network nào → có bật full ads không".
///
/// Native side nằm trong plugin ([FlutterInstallTrackerPlugin]) — tự đăng ký
/// qua Flutter plugin registry, app KHÔNG cần sửa MainApplication/Activity.
///
/// Flow:
/// 1. [initialize] — nếu đã có quyết định cache (launch thứ 2+) → callback
///    ngay với `fromCache=true`, không đụng API.
/// 2. Lần đầu: hỏi native referrer (timeout [_referrerTimeout]) → [classify]
///    → persist → callback với `fromCache=false` (app dùng cờ này để log
///    event Firebase đúng 1 lần).
/// 3. `options.maxFull` là override runtime — check TRƯỚC cache và KHÔNG
///    persist, để tắt cờ trên Remote Config là launch sau trở lại bình thường.
class InstallSourceTracker {
  InstallSourceTracker._();

  static final InstallSourceTracker instance = InstallSourceTracker._();

  static const MethodChannel _channel =
      MethodChannel('flutter_install_tracker');

  static const Duration _referrerTimeout = Duration(seconds: 5);

  static const String _prefsKeyIsFullAds = 'install_tracker_is_full_ads';
  static const String _prefsKeyNetwork = 'install_tracker_network';
  static const String _prefsKeyReferrer = 'install_tracker_referrer';

  bool _initialized = false;

  /// Kết quả gần nhất (null nếu [initialize] chưa chạy xong).
  InstallAttribution? lastAttribution;

  /// Thời gian (ms) của riêng cú gọi native đọc referrer trong lần
  /// [initialize] này. ≈0 khi resolve từ cache / maxFull. Dùng cho telemetry.
  int lastResolveDurationMs = 0;

  Future<void> initialize({
    InstallTrackerOptions options = const InstallTrackerOptions(),
    required InstallAttributionCallback onResolved,
  }) async {
    if (_initialized) {
      final last = lastAttribution;
      if (last != null) {
        onResolved(last);
      }
      return;
    }
    _initialized = true;
    debugPrint('[InstallTracker] ▶ initialize — options=${options.toJson()}');

    // Kill-switch: full ads cho tất cả — không cache để revert được từ xa.
    if (options.maxFull) {
      debugPrint('[InstallTracker] maxFull=true → force full ads (no cache)');
      _emit(
        const InstallAttribution(isFullAds: true, network: 'max_full'),
        onResolved,
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();

    // Launch thứ 2+ → dùng quyết định đã chốt, không flap giữa các phiên.
    final cachedIsFullAds = prefs.getBool(_prefsKeyIsFullAds);
    if (cachedIsFullAds != null) {
      debugPrint(
          '[InstallTracker] cache HIT → dùng quyết định đã chốt từ lần đầu '
          '(muốn test lại từ đầu: adb shell pm clear <package>)');
      _emit(
        InstallAttribution(
          isFullAds: cachedIsFullAds,
          network: prefs.getString(_prefsKeyNetwork) ?? 'unknown',
          referrer: prefs.getString(_prefsKeyReferrer),
          fromCache: true,
        ),
        onResolved,
      );
      return;
    }

    debugPrint(
        '[InstallTracker] cache MISS (lần đầu) → gọi native đọc Play Install Referrer...');

    // Lần đầu — đọc referrer từ native (native tự cache raw string vì Play
    // giới hạn số lần query + chỉ giữ referrer ~90 ngày).
    String? referrer;
    final stopwatch = Stopwatch()..start();
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('getInstallReferrer')
          .timeout(_referrerTimeout);
      referrer = result?['referrer'] as String?;
    } catch (e) {
      debugPrint('[InstallTracker] ✖ getInstallReferrer FAILED: $e '
          '→ referrer=null (đi nhánh useNull)');
      referrer = null;
    }
    stopwatch.stop();
    lastResolveDurationMs = stopwatch.elapsedMilliseconds;
    debugPrint(
        '[InstallTracker] referrer fetch xong trong ${lastResolveDurationMs}ms '
        '— raw="${referrer ?? '(null)'}"');

    final attribution = classify(referrer, options);

    // Persist TRƯỚC khi emit — bảo đảm cache đã ghi xong rồi mới báo kết quả.
    // Nhờ vậy launch sau CHẮC CHẮN cache HIT (fromCache=true) → không cache-miss
    // lặp → telemetry không log/đếm trùng install. Đánh đổi: thêm ~vài ms ghi
    // disk vào luồng khởi động lần đầu (chỉ lần đầu; các launch sau đi nhánh
    // cache HIT ở trên, không chạm đoạn này). _persist đã try/catch nên lỗi ghi
    // không chặn được kết quả — vẫn emit bình thường bên dưới.
    await _persist(prefs, attribution, referrer);

    _emit(attribution, onResolved);
  }

  Future<void> _persist(
    SharedPreferences prefs,
    InstallAttribution attribution,
    String? referrer,
  ) async {
    try {
      await prefs.setBool(_prefsKeyIsFullAds, attribution.isFullAds);
      await prefs.setString(_prefsKeyNetwork, attribution.network);
      if (referrer != null) {
        await prefs.setString(_prefsKeyReferrer, referrer);
      }
    } catch (e) {
      debugPrint('[InstallTracker] ✖ persist failed: $e');
    }
  }

  void _emit(
    InstallAttribution attribution,
    InstallAttributionCallback onResolved,
  ) {
    lastAttribution = attribution;
    debugPrint('[InstallTracker] ✔ KẾT QUẢ: $attribution');
    onResolved(attribution);
  }

  /// Phân loại referrer → (isFullAds, network). Pure function, static để
  /// test được độc lập.
  ///
  /// Thứ tự ưu tiên:
  /// 1. null / empty → theo cờ useNull / useEmpty.
  /// 2. Organic: `utm_medium` (hoặc utm_source) chứa organicKeywords
  ///    → KHÔNG full ads. (Play organic chuẩn:
  ///    `utm_source=google-play&utm_medium=organic`.)
  /// 3. Click-id của network lớn: gclid/gbraid/wbraid → google_ads,
  ///    fbclid / utm_source facebook|instagram → meta, ttclid → tiktok.
  /// 4. Có `utm_source` khác bất kỳ → coi là campaign network đó.
  /// 5. Còn lại (có nội dung nhưng không nhận diện được) → unattributed
  ///    → theo cờ useUnAttributed.
  static InstallAttribution classify(
    String? referrer,
    InstallTrackerOptions options,
  ) {
    if (referrer == null) {
      return InstallAttribution(
        isFullAds: options.useNull,
        network: 'null',
      );
    }
    final trimmed = referrer.trim();
    if (trimmed.isEmpty) {
      return InstallAttribution(
        isFullAds: options.useEmpty,
        network: 'empty',
        referrer: referrer,
      );
    }

    final params = _parseReferrerParams(trimmed);
    final utmSource = (params['utm_source'] ?? '').toLowerCase();
    final utmMedium = (params['utm_medium'] ?? '').toLowerCase();

    // 1. Organic — check TRƯỚC mọi network pattern: referrer organic chuẩn
    // của Play có utm_source=google-play, không được nhầm thành "campaign".
    final isOrganic = options.organicKeywords.any(
      (k) => utmMedium.contains(k.toLowerCase()),
    );
    if (isOrganic) {
      return InstallAttribution(
        isFullAds: false,
        network: 'organic',
        referrer: referrer,
      );
    }

    // 2. Click-id các network lớn.
    if (params.containsKey('gclid') ||
        params.containsKey('gbraid') ||
        params.containsKey('wbraid')) {
      return InstallAttribution(
        isFullAds: true,
        network: 'google_ads',
        referrer: referrer,
      );
    }
    if (params.containsKey('fbclid') ||
        utmSource.contains('facebook') ||
        utmSource.contains('instagram') ||
        utmSource.contains('meta')) {
      return InstallAttribution(
        isFullAds: true,
        network: 'meta',
        referrer: referrer,
      );
    }
    if (params.containsKey('ttclid') || utmSource.contains('tiktok')) {
      return InstallAttribution(
        isFullAds: true,
        network: 'tiktok',
        referrer: referrer,
      );
    }

    // 3. Có utm_source khác (google-play đã bị organic bắt ở trên; tới đây
    // google-play mà không organic medium → campaign chạy qua Play listing,
    // vd cross-promo có utm riêng) → network = utm_source.
    // '(not set)' là placeholder Play trả khi không có data → unattributed.
    if (utmSource.isNotEmpty &&
        utmSource != 'google-play' &&
        utmSource != '(not set)') {
      return InstallAttribution(
        isFullAds: true,
        network: utmSource,
        referrer: referrer,
      );
    }

    // 4. Không nhận diện được.
    return InstallAttribution(
      isFullAds: options.useUnAttributed,
      network: 'unattributed',
      referrer: referrer,
    );
  }

  /// Parse referrer string dạng query (`a=b&c=d`). Play đôi khi trả chuỗi
  /// bị URL-encode nguyên khối (`utm_source%3D...%26utm_medium%3D...`) →
  /// decode trước khi split nếu thấy pattern đó.
  static Map<String, String> _parseReferrerParams(String referrer) {
    var raw = referrer;
    if (!raw.contains('=') && raw.contains('%3D')) {
      try {
        raw = Uri.decodeComponent(raw);
      } catch (_) {}
    }
    try {
      return Uri.splitQueryString(raw);
    } catch (_) {
      return const {};
    }
  }
}
