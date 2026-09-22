import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_install_tracker/flutter_install_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chạy [InstallSourceTracker.initialize] và trả về kết quả callback.
Future<InstallAttribution> _resolve(
  InstallSourceTracker tracker, [
  InstallTrackerOptions options = const InstallTrackerOptions(),
]) async {
  InstallAttribution? result;
  await tracker.initialize(options: options, onResolved: (a) => result = a);
  return result!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const options = InstallTrackerOptions(); // default: useNull/Empty/UnAttributed=true

  group('InstallSourceTracker.classify', () {
    test('organic Play referrer → NOT full ads', () {
      final r = InstallSourceTracker.classify(
        'utm_source=google-play&utm_medium=organic',
        options,
      );
      expect(r.isFullAds, false);
      expect(r.network, 'organic');
    });

    test('URL-encoded organic referrer → NOT full ads', () {
      final r = InstallSourceTracker.classify(
        'utm_source%3Dgoogle-play%26utm_medium%3Dorganic',
        options,
      );
      expect(r.isFullAds, false);
      expect(r.network, 'organic');
    });

    test('gclid → google_ads, full ads', () {
      final r = InstallSourceTracker.classify(
        'gclid=Cj0KCQiA&utm_source=google&utm_medium=cpc',
        options,
      );
      expect(r.isFullAds, true);
      expect(r.network, 'google_ads');
    });

    test('gbraid (Android privacy click-id) → google_ads', () {
      final r = InstallSourceTracker.classify('gbraid=1abcxyz', options);
      expect(r.isFullAds, true);
      expect(r.network, 'google_ads');
    });

    test('meta referrer → meta, full ads', () {
      final r = InstallSourceTracker.classify(
        'utm_source=apps.facebook.com&utm_campaign=fb4a',
        options,
      );
      expect(r.isFullAds, true);
      expect(r.network, 'meta');
    });

    test('tiktok click id → tiktok, full ads', () {
      final r = InstallSourceTracker.classify('ttclid=abc123', options);
      expect(r.isFullAds, true);
      expect(r.network, 'tiktok');
    });

    test('utm_source khác → network = utm_source, full ads', () {
      final r = InstallSourceTracker.classify(
        'utm_source=applovin&utm_campaign=x',
        options,
      );
      expect(r.isFullAds, true);
      expect(r.network, 'applovin');
    });

    test('null referrer → theo useNull (default true)', () {
      final r = InstallSourceTracker.classify(null, options);
      expect(r.isFullAds, true);
      expect(r.network, 'null');
    });

    test('null referrer + useNull=false → NOT full ads', () {
      const opts = InstallTrackerOptions(useNull: false);
      final r = InstallSourceTracker.classify(null, opts);
      expect(r.isFullAds, false);
    });

    test('empty referrer → theo useEmpty (default true)', () {
      final r = InstallSourceTracker.classify('  ', options);
      expect(r.isFullAds, true);
      expect(r.network, 'empty');
    });

    test('referrer lạ không parse được → unattributed', () {
      final r = InstallSourceTracker.classify('some-random-string', options);
      expect(r.isFullAds, true);
      expect(r.network, 'unattributed');
    });

    test('"(not set)" placeholder của Play → unattributed', () {
      final r = InstallSourceTracker.classify(
        'utm_source=(not set)&utm_medium=(not set)',
        options,
      );
      expect(r.network, 'unattributed');
      expect(r.isFullAds, true);
    });

    test('google-play source nhưng KHÔNG organic medium → unattributed', () {
      // Không được nhầm google-play (store) thành campaign network.
      final r = InstallSourceTracker.classify(
        'utm_source=google-play&utm_medium=cpc-ish',
        options,
      );
      expect(r.network, 'unattributed');
      expect(r.isFullAds, true);
    });

    test('organicKeywords tùy biến qua remote config', () {
      const opts = InstallTrackerOptions(organicKeywords: ['organic', 'seo']);
      final r = InstallSourceTracker.classify(
        'utm_source=blog&utm_medium=seo',
        opts,
      );
      expect(r.isFullAds, false);
      expect(r.network, 'organic');
    });
  });

  group('InstallTrackerOptions.fromJson', () {
    test('parse đúng cờ từ remote config', () {
      final opts = InstallTrackerOptions.fromJson({
        'maxFull': true,
        'useNull': false,
        'useEmpty': false,
        'useUnAttributed': false,
        'organicKeywords': ['organic', 'referral'],
      });
      expect(opts.maxFull, true);
      expect(opts.useNull, false);
      expect(opts.useEmpty, false);
      expect(opts.useUnAttributed, false);
      expect(opts.organicKeywords, ['organic', 'referral']);
    });

    test('json rỗng → default an toàn', () {
      final opts = InstallTrackerOptions.fromJson(const {});
      expect(opts.maxFull, false);
      expect(opts.useNull, true);
      expect(opts.useEmpty, true);
      expect(opts.useUnAttributed, true);
      expect(opts.organicKeywords, ['organic']);
    });
  });

  group('InstallSourceTracker.initialize', () {
    const channel = MethodChannel('flutter_install_tracker');
    const organic = 'utm_source=google-play&utm_medium=organic';
    late int nativeCalls;

    void mockReferrer(String referrer) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        nativeCalls++;
        return {'referrer': referrer};
      });
    }

    setUp(() {
      nativeCalls = 0;
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('lần đầu đọc native + persist → launch sau cache HIT', () async {
      mockReferrer(organic);

      final first = await _resolve(InstallSourceTracker.forTesting());
      expect(first.fromCache, false);
      expect(first.network, 'organic');

      // Launch sau = tracker mới, prefs giữ nguyên.
      final next = await _resolve(InstallSourceTracker.forTesting());
      expect(next.fromCache, true);
      expect(next.isFullAds, false);
      expect(next.network, 'organic');
      expect(next.referrer, organic);
      expect(nativeCalls, 1);
    });

    test('gọi lần 2 khi lần đầu chưa xong → cả 2 callback, native 1 lần',
        () async {
      mockReferrer('gclid=abc');
      final tracker = InstallSourceTracker.forTesting();
      final results = <InstallAttribution>[];

      await Future.wait([
        tracker.initialize(onResolved: results.add),
        tracker.initialize(onResolved: results.add),
      ]);

      expect(results, hasLength(2));
      expect(results.map((r) => r.network), everyElement('google_ads'));
      expect(nativeCalls, 1);
    });

    test('maxFull → fromCache=true, không đọc native, không persist',
        () async {
      mockReferrer(organic);

      final forced = await _resolve(
        InstallSourceTracker.forTesting(),
        const InstallTrackerOptions(maxFull: true),
      );
      expect(forced.isFullAds, true);
      expect(forced.network, 'max_full');
      expect(forced.fromCache, true);
      expect(nativeCalls, 0);

      // Tắt cờ → launch sau mới là lần resolve thật.
      final real = await _resolve(InstallSourceTracker.forTesting());
      expect(real.fromCache, false);
      expect(real.network, 'organic');
      expect(nativeCalls, 1);
    });
  });
}
