import 'dart:io';

/// Result of validating the final artifact produced by the transport package.
final class DownloadIntegrityResult {
  const DownloadIntegrityResult.valid(int bytes)
    : assert(bytes > 0),
      isValid = true,
      bytes = bytes,
      reason = null;

  const DownloadIntegrityResult.invalid(String reason)
    : assert(reason != ''),
      isValid = false,
      bytes = null,
      reason = reason;

  final bool isValid;
  final int? bytes;
  final String? reason;
}

/// Verifies only stable final-file properties owned by AnimeWitcher.
///
/// Transport completion is not logical completion until this verifier accepts
/// the final artifact. Resume/chunk state remains owned by background_downloader.
final class DownloadIntegrityVerifierV2 {
  const DownloadIntegrityVerifierV2();

  Future<DownloadIntegrityResult> verify(
    File file, {
    int? expectedBytes,
  }) async {
    if (!await file.exists()) {
      return const DownloadIntegrityResult.invalid('missing');
    }

    final bytes = await file.length();
    if (bytes <= 0) {
      return const DownloadIntegrityResult.invalid('empty');
    }

    if (expectedBytes != null && expectedBytes > 0 && bytes != expectedBytes) {
      return const DownloadIntegrityResult.invalid('size-mismatch');
    }

    return DownloadIntegrityResult.valid(bytes);
  }
}
