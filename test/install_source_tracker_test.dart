import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_install_tracker/flutter_install_tracker.dart';

void main() {
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
}
