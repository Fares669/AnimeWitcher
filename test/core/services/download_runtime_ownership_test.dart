import 'package:animewitcher/core/services/download_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runtime download ownership', () {
    test('persisted paused status cannot negate a runtime-active task', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: true,
      );
      expect(ownership, DownloadRuntimeOwnership.owned);
      expect(ownership.blocksNewWriter, isTrue);
    });

    test('stale persisted running status cannot create runtime ownership', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: false,
      );
      expect(ownership, DownloadRuntimeOwnership.notOwned);
      expect(ownership.blocksNewWriter, isFalse);
    });

    test(
      'rehydrated Transfer handle plus failed executor query stays unknown',
      () {
        final ownership = resolveDownloadRuntimeOwnership(
          runtimeQuerySucceeded: false,
          runtimeTaskPresent: false,
          transferHandlePresent: true,
        );
        expect(ownership, DownloadRuntimeOwnership.unknown);
        expect(ownership.blocksNewWriter, isTrue);
      },
    );

    test('liveness query failure without a handle also stays unknown', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
      );
      expect(ownership, DownloadRuntimeOwnership.unknown);
      expect(ownership.blocksNewWriter, isTrue);
    });

    test('settling ownership blocks a second writer', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: false,
        operationSettling: true,
      );
      expect(ownership, DownloadRuntimeOwnership.settling);
      expect(ownership.blocksNewWriter, isTrue);
    });

    test('local Range ownership is independently authoritative', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
        localRangeWriterActive: true,
      );
      expect(ownership, DownloadRuntimeOwnership.owned);
    });
  });
}
