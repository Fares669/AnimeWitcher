import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';

final class StaticSourceResolverV2 implements DownloadSourceResolverV2 {
  StaticSourceResolverV2({
    this.url = 'https://example.invalid/video.mp4',
    this.headers = const <String, String>{},
    this.expectedBytes,
  });

  final String url;
  final Map<String, String> headers;
  final int? expectedBytes;
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    return ResolvedDownloadSourceV2(
      url: url,
      headers: headers,
      expectedBytes: expectedBytes,
    );
  }
}
