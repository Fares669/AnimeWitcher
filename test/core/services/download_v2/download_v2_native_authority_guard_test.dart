import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('V2 native refill does not inherit the legacy retry owner', () {
    final nativeQueue = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();
    final compact = nativeQueue.replaceAll(RegExp(r'\s+'), ' ');

    expect(
      compact,
      contains('private static func isPromotableMultipartPart('),
      reason:
          'Persisted generation-fenced plans may refill URLSession slots for '
          'V2, but that is distinct from legacy native retry ownership.',
    );
    expect(
      compact,
      contains(
        'return isPromotableMultipartPart(task) && !isV2DurableMultipartPart(task)',
      ),
      reason:
          'V2 transient failures must return to the V2 coordinator rather than '
          'being recreated by the legacy retry path.',
    );
    expect(
      compact,
      contains(
        'if isPromotableMultipartPart(task) { promoteMultipartIfPossible(',
      ),
      reason:
          'A finished or failed background Range must free its slot and let '
          'the native persisted plan start the next immutable Range.',
    );
  });

  test('legacy iOS hook is observation-only after the V2 cutover', () {
    final compatibility = File(
      'ios/Runner/DownloadCallbackCompatibility.swift',
    ).readAsStringSync();
    final nativeQueue = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();
    final compactCompatibility = compatibility.replaceAll(RegExp(r'\s+'), ' ');
    final compactQueue = nativeQueue.replaceAll(RegExp(r'\s+'), ' ');

    // Installing compatible delegate observers may remain for diagnostics, but
    // production V2 must never turn that observation into transport ownership.
    expect(
      compactCompatibility,
      contains('private let transportOwnershipEnabled: Bool'),
    );
    expect(
      compactCompatibility,
      contains('init(transportOwnershipEnabled: Bool = false)'),
    );
    expect(
      compactCompatibility,
      contains('if isInstalled { return transportOwnershipEnabled }'),
    );
    expect(
      compactCompatibility,
      contains('return transportOwnershipEnabled'),
    );

    // Every legacy retry/promotion path remains fenced behind the ownership
    // result. V1 source stays dormant until the device gate allows Task 14 to
    // delete it; background_downloader remains the sole V2 transport authority.
    expect(
      compactQueue,
      contains(
        'static var nativePromotionAvailable: Bool { lock.lock() defer { lock.unlock() } return hookInstalled }',
      ),
    );
    expect(
      compactQueue,
      contains(
        'static func retryBackgroundTransferIfNeeded( session: URLSession, task: URLSessionTask, error: Error ) -> Bool { guard nativePromotionAvailable else { return false }',
      ),
    );
    expect(
      compactQueue,
      contains(
        'static func promoteMultipartIfPossible( on suppliedSession: URLSession? = nil, parentId: String? = nil ) { guard nativePromotionAvailable else { return }',
      ),
    );
    expect(
      compactQueue,
      contains('let ownsCompletion = DownloadNativeWaitingQueue.nativePromotionAvailable'),
    );
  });
}
