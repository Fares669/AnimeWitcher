import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selectDownloadExecutionBackend', () {
    test('single connection always uses plugin single transport', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 1,
          pluginParallelAccepted: false,
          legacySessionExists: false,
        ),
        DownloadExecutionBackend.pluginSingle,
      );
    });

    test('unsupported multipart stays on legacy executor', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 8,
          pluginParallelAccepted: false,
          legacySessionExists: false,
        ),
        DownloadExecutionBackend.legacyParallel,
      );
    });

    test('accepted new multipart uses plugin parallel transport', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 8,
          pluginParallelAccepted: true,
          legacySessionExists: false,
        ),
        DownloadExecutionBackend.pluginParallel,
      );
    });

    test('existing legacy multipart never changes executor mid-session', () {
      expect(
        selectDownloadExecutionBackend(
          connections: 8,
          pluginParallelAccepted: true,
          legacySessionExists: true,
        ),
        DownloadExecutionBackend.legacyParallel,
      );
    });
  });
}
