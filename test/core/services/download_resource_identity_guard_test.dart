
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

  }
