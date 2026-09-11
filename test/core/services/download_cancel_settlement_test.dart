import 'package:animewitcher/core/services/download_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDownloadCancelCommand', () {
    test('positive executor acknowledgement is canceled', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: true,
          commandSucceeded: true,
          commandThrew: false,
        ),
        DownloadCancelSettlement.canceled,
      );
    });

    test('negative acknowledgement with tracked owner remains stillOwned', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: true,
          commandSucceeded: false,
          commandThrew: false,
        ),
        DownloadCancelSettlement.stillOwned,
      );
    });

    test('negative acknowledgement without owner evidence is unknown', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: false,
          commandSucceeded: false,
          commandThrew: false,
        ),
        DownloadCancelSettlement.unknown,
      );
    });

    test('throw never claims release', () {
      expect(
        resolveDownloadCancelCommand(
          hadTrackedOwner: true,
          commandSucceeded: false,
          commandThrew: true,
        ),
        DownloadCancelSettlement.unknown,
      );
    });
  });
}
