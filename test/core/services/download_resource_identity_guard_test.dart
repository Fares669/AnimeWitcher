import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/services/download_job_store.dart';

void main() {
  test('delivery URL alone is not durable resource identity', () {
    const fingerprint = DownloadResourceFingerprint(
      finalUrl: 'https://cdn.example/video.mp4?token=old',
    );

    expect(fingerprint.hasIdentityEvidence, isFalse);
    expect(
      DownloadResourceFingerprint.fromJson(fingerprint.toJson()),
      isNull,
    );
  });

  test('rotating a signed delivery URL does not change resource identity', () {
    const before = DownloadResourceFingerprint(
      strongEtag: '"resource-v1"',
      expectedBytes: 4096,
      finalUrl: 'https://cdn.example/video.mp4?token=old',
    );
    const after = DownloadResourceFingerprint(
      strongEtag: '"resource-v1"',
      expectedBytes: 4096,
      finalUrl: 'https://cdn.example/video.mp4?token=new',
    );

    expect(before.compatibleWith(after), isTrue);
  });

  test('completion never promotes observed file length into expected bytes', () {
    final source = File(
      'lib/core/services/download_service.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'Future<void> _persistCompletedFilePath(Task task) async',
    );
    expect(start, isNonNegative);
    final end = source.indexOf('\n  Future<String> getDownloadPath(', start);
    expect(end, greaterThan(start));
    final completion = source.substring(start, end);

    expect(
      completion,
      isNot(contains('final expectedBytes = knownDownloadSize(<int?>[\n        fileBytes,')),
    );
  });
}
