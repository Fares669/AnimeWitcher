import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:animewitcher/core/services/download_resource_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-06 resource completion identity', () {
    test('observed bytes can never self-certify an unknown expected size', () {
      expect(
        downloadCompletionEvidenceMatches(
          observedFileBytes: 1000,
          expectedResourceBytes: -1,
          prefixMatches: true,
        ),
        isFalse,
      );
    });

    test('truncated and wrong-size finals are rejected', () {
      for (final observed in <int>[999, 1001]) {
        expect(
          downloadCompletionEvidenceMatches(
            observedFileBytes: observed,
            expectedResourceBytes: 1000,
            prefixMatches: true,
          ),
          isFalse,
        );
      }
    });

    test('same-size changed resource is rejected by strong validator', () {
      expect(
        downloadCompletionEvidenceMatches(
          observedFileBytes: 1000,
          expectedResourceBytes: 1000,
          prefixMatches: true,
          persistedFingerprint: const DownloadResourceFingerprint(
            strongEtag: '"v1"',
            expectedBytes: 1000,
          ),
          currentFingerprint: const DownloadResourceFingerprint(
            strongEtag: '"v2"',
            expectedBytes: 1000,
          ),
        ),
        isFalse,
      );
    });

    test('signed URL rotation is accepted when stable identity still matches', () {
      expect(
        downloadCompletionEvidenceMatches(
          observedFileBytes: 1000,
          expectedResourceBytes: 1000,
          prefixMatches: true,
          persistedFingerprint: const DownloadResourceFingerprint(
            strongEtag: '"same"',
            lastModified: 'date',
            expectedBytes: 1000,
            finalUrl: 'https://cdn.test/file?token=old',
          ),
          currentFingerprint: const DownloadResourceFingerprint(
            strongEtag: '"same"',
            lastModified: 'date',
            expectedBytes: 1000,
            finalUrl: 'https://cdn.test/file?token=new',
          ),
        ),
        isTrue,
      );
    });

    test('validators absent still require byte-prefix proof', () {
      expect(
        downloadCompletionEvidenceMatches(
          observedFileBytes: 1000,
          expectedResourceBytes: 1000,
          prefixMatches: false,
          persistedFingerprint: const DownloadResourceFingerprint(
            expectedBytes: 1000,
          ),
          currentFingerprint: const DownloadResourceFingerprint(
            expectedBytes: 1000,
          ),
        ),
        isFalse,
      );
      expect(
        downloadCompletionEvidenceMatches(
          observedFileBytes: 1000,
          expectedResourceBytes: 1000,
          prefixMatches: true,
          persistedFingerprint: const DownloadResourceFingerprint(
            expectedBytes: 1000,
          ),
          currentFingerprint: const DownloadResourceFingerprint(
            expectedBytes: 1000,
          ),
        ),
        isTrue,
      );
    });

    test('weak ETag is not accepted as a strong resource validator', () {
      expect(strongDownloadEtag('W/"v1"'), isNull);
      expect(strongDownloadEtag(' w/"v1" '), isNull);
      expect(strongDownloadEtag('"v1"'), '"v1"');
    });
  });
}
