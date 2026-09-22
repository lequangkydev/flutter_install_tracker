/// Kết quả phân loại nguồn cài đặt.
class InstallAttribution {
  const InstallAttribution({
    required this.isFullAds,
    required this.network,
    this.referrer,
    this.fromCache = false,
  });

  /// true → user tới từ network (non-organic) → bật full ads.
  final bool isFullAds;

  /// Label nguồn cài: 'organic' | 'google_ads' | 'meta' | 'tiktok' |
  /// utm_source thô | 'null' | 'empty' | 'unattributed' | 'max_full'.
  final String network;

  /// Raw referrer string từ Play (null nếu không đọc được).
  final String? referrer;

  /// false CHỈ ở lần resolve thật (đọc referrer + persist) → app dùng cờ này
  /// cho việc 1-lần-mỗi-install (vd log event). true khi quyết định lấy từ
  /// cache (các launch sau) hoặc bị ép bởi `maxFull` (không resolve thật).
  final bool fromCache;

  @override
  String toString() =>
      'InstallAttribution(isFullAds: $isFullAds, network: $network, '
      'fromCache: $fromCache, referrer: $referrer)';
}
