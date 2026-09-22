/// Cấu hình phân loại full-ads theo nguồn cài đặt.
///
/// Semantics giữ NGUYÊN tên cờ của `fullAdsOption` thời còn dùng Adjust để
/// ops đỡ phải học lại (chỉnh qua Remote Config key `install_tracker_config`):
/// - [maxFull]: kill-switch — true → MỌI user đều full ads, bỏ qua referrer.
///   Không được persist (tắt cờ là hết hiệu lực ngay launch sau).
/// - [useNull]: referrer KHÔNG đọc được (API unavailable, sideload, timeout)
///   → coi là full ads? (mặc định true — an toàn doanh thu).
/// - [useEmpty]: referrer đọc được nhưng CHUỖI RỖNG → full ads?
/// - [useUnAttributed]: referrer có nội dung nhưng không match pattern nào
///   (không organic, không network nhận diện được) → full ads?
/// - [organicKeywords]: các keyword trong `utm_medium` được coi là organic
///   → KHÔNG full ads. Mặc định ['organic'].
class InstallTrackerOptions {
  const InstallTrackerOptions({
    this.maxFull = false,
    this.useNull = true,
    this.useEmpty = true,
    this.useUnAttributed = true,
    this.organicKeywords = const ['organic'],
  });

  factory InstallTrackerOptions.fromJson(Map<String, dynamic> map) {
    return InstallTrackerOptions(
      maxFull: map['maxFull'] as bool? ?? false,
      useNull: map['useNull'] as bool? ?? true,
      useEmpty: map['useEmpty'] as bool? ?? true,
      useUnAttributed: map['useUnAttributed'] as bool? ?? true,
      organicKeywords: (map['organicKeywords'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['organic'],
    );
  }

  final bool maxFull;
  final bool useNull;
  final bool useEmpty;
  final bool useUnAttributed;
  final List<String> organicKeywords;

  Map<String, dynamic> toJson() {
    return {
      'maxFull': maxFull,
      'useNull': useNull,
      'useEmpty': useEmpty,
      'useUnAttributed': useUnAttributed,
      'organicKeywords': organicKeywords,
    };
  }
}
