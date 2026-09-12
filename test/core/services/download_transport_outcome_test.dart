import 'package:animewitcher/core/services/download_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDownloadTransportCommandOutcome', () {
    test('accepted command remains distinct from logical success', () {
      expect(
        resolveDownloadTransportCommandOutcome(commandAccepted: true),
        DownloadTransportCommandOutcome.accepted,
      );
    });

    test('rejected command is explicit', () {
      expect(
        resolveDownloadTransportCommandOutcome(commandAccepted: false),
        DownloadTransportCommandOutcome.rejected,
      );
    });

    test('unavailable transport cannot masquerade as rejection', () {
      expect(
        resolveDownloadTransportCommandOutcome(
          commandAccepted: false,
          transportAvailable: false,
        ),
        DownloadTransportCommandOutcome.unavailable,
      );
    });
  });
}
