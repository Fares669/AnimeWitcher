final class ResolvedDownloadSourceV2 {
  const ResolvedDownloadSourceV2({
    required this.url,
    this.headers = const <String, String>{},
    this.expectedBytes,
  }) : assert(url != '');

  final String url;
  final Map<String, String> headers;
  final int? expectedBytes;
}

/// Resolves a fresh transport source from stable application-owned provider
/// metadata. Signed URLs and auth headers remain transient and are never
/// persisted in the logical download store.
abstract interface class DownloadSourceResolverV2 {
  Future<ResolvedDownloadSourceV2> resolve(Map<String, Object?> descriptor);
}
