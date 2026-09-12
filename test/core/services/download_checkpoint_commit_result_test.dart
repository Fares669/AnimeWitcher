import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/services/download_service.dart';

void main() {
  test('authoritative checkpoint reports committed writes', () async {
    final result = await commitAuthoritativeDownloadCheckpoint(
      () async => true,
    );
    expect(result, DownloadLifecycleCheckpointCommit.committed);
  });

  test('authoritative checkpoint reports rejected writes', () async {
    final result = await commitAuthoritativeDownloadCheckpoint(
      () async => false,
    );
    expect(result, DownloadLifecycleCheckpointCommit.rejected);
  });

  test(
    'authoritative checkpoint converts backend exceptions to failed',
    () async {
      final result = await commitAuthoritativeDownloadCheckpoint(() async {
        throw StateError('backend write failed');
      });
      expect(result, DownloadLifecycleCheckpointCommit.failed);
    },
  );
}
