from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

signature = 'Future<DownloadResourceFingerprint?> _probeResourceFingerprint('
if signature in source:
    raise SystemExit(0)

probe_method = r'''  Future<DownloadResourceFingerprint?> _probeResourceFingerprint(
    String url, {
    Map<String, String>? headers,
  }) async {
    String? strongEtag;
    String? lastModified;
    var expectedBytes = -1;
    String? finalUrl;

    void absorb(Response<dynamic> response) {
      strongEtag ??= strongDownloadEtag(response.headers.value('etag'));
      final modified = response.headers.value('last-modified')?.trim();
      if (lastModified == null && modified != null && modified.isNotEmpty) {
        lastModified = modified;
      }
      final range = RegExp(r'^bytes\s+\d+-\d+/(\d+)$')
          .firstMatch(response.headers.value('content-range') ?? '');
      final rangeBytes = range == null ? null : int.tryParse(range[1]!);
      final contentBytes = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (rangeBytes != null && rangeBytes > 0) {
        expectedBytes = rangeBytes;
      } else if (response.statusCode != 206 &&
          contentBytes != null &&
          contentBytes > 0) {
        expectedBytes = contentBytes;
      }
      final resolved = response.realUri.toString().trim();
      if (resolved.isNotEmpty) finalUrl = resolved;
    }

    try {
      final response = await _dio
          .head<dynamic>(
            url,
            options: Options(
              headers: {...?headers, 'Accept-Encoding': 'identity'},
              followRedirects: true,
            ),
          )
          .timeout(const Duration(seconds: 10));
      absorb(response);
    } catch (_) {}

    if (expectedBytes <= 0 || (strongEtag == null && lastModified == null)) {
      try {
        final response = await _dio
            .get<dynamic>(
              url,
              options: Options(
                headers: {
                  ...?headers,
                  'Range': 'bytes=0-0',
                  'Accept-Encoding': 'identity',
                },
                followRedirects: true,
                responseType: ResponseType.stream,
                validateStatus: (status) =>
                    status != null && (status == 200 || status == 206),
              ),
            )
            .timeout(const Duration(seconds: 10));
        absorb(response);
        final body = response.data;
        if (body is ResponseBody) {
          final subscription = body.stream.listen(null);
          await subscription.cancel();
        }
      } catch (_) {}
    }

    final fingerprint = DownloadResourceFingerprint(
      strongEtag: strongEtag,
      lastModified: lastModified,
      expectedBytes: expectedBytes,
      finalUrl: finalUrl ?? url,
    );
    return fingerprint.hasIdentityEvidence ? fingerprint : null;
  }

'''
marker = '  Future<DownloadMetadata?> getMetadata(\n'
if marker not in source:
    raise SystemExit('getMetadata insertion anchor missing')
source = source.replace(marker, probe_method + marker, 1)
path.write_text(source)
