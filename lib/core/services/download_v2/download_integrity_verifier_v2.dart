import 'dart:io';

import '../../utils/local_video_payload_probe.dart';

/// Result of validating the final artifact produced by the transport package.
final class DownloadIntegrityResult {
  const DownloadIntegrityResult.valid(int bytes, {this.completedPages, this.totalPages})
    : assert(bytes > 0),
      isValid = true,
      bytes = bytes,
      reason = null;

  const DownloadIntegrityResult.invalid(String reason, {this.completedPages, this.totalPages})
    : assert(reason != ''),
      isValid = false,
      bytes = null,
      reason = reason;

  final bool isValid;
  final int? bytes;
  final String? reason;
  final int? completedPages;
  final int? totalPages;
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
    // Opt in only for newly completed transfers. Existing completed records
    // retain their original integrity semantics and must not be deleted by a
    // startup migration; playback separately checks recognizable text payloads.
    bool rejectNonVideoPayload = false,
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

    if (rejectNonVideoPayload) {
      final problem = await probeLocalVideoPayload(file);
      if (problem != null) {
        return DownloadIntegrityResult.invalid(problem.reason);
      }
    }

    return DownloadIntegrityResult.valid(bytes);
  }
}
