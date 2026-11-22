/// Shared stream/playback error contract across multi-provider extensions.
abstract interface class ProviderStreamException implements Exception {}

/// Rate-limit error raised while listing or resolving provider streams.
class ProviderRateLimitException implements ProviderStreamException {
  const ProviderRateLimitException([
    this.message = 'تجاوزت حد الطلبات على المزوّد، انتظر قليلًا أو جرّب سيرفرًا آخر.',
  ]);

  final String message;

  /// Whether auto-selection should still probe another source candidate.
  bool get canTryNextSource => false;

  @override
  String toString() => message;
}

/// Raised when a chosen server/mirror yields no playable stream.
class ProviderSourceUnavailableException implements ProviderStreamException {
  const ProviderSourceUnavailableException([
    this.message = 'تعذّر تحميل هذا السيرفر، يُرجى اختيار سيرفر آخر.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Raised when Cloudflare/Turnstile or interactive verification is required.
class ProviderBrowserRequiredException implements ProviderStreamException {
  const ProviderBrowserRequiredException(this.message, {this.watchUrl});

  final String message;
  final Uri? watchUrl;

  @override
  String toString() => message;
}
