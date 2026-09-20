import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('V2 native refill never owns multipart retry', () {
    final nativeQueue = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();
    final compact = nativeQueue.replaceAll(RegExp(r'\s+'), ' ');

    expect(
      compact,
      contains('private static func isPromotableMultipartPart('),
    );
    expect(
      compact,
      contains(
        'if isDownloadPart(task) { return false }',
      ),
      reason:
          'Multipart Range failures must return to the V2 coordinator; native '
          'may only refill persisted zero-byte candidates while Dart sleeps.',
    );
    expect(
      compact,
      contains(
        'if isPromotableMultipartPart(task) { promoteMultipartIfPossible(',
      ),
    );
  });

  test('delegate hooks remain fenced behind native capability', () {
    final compatibility = File(
      'ios/Runner/DownloadCallbackCompatibility.swift',
    ).readAsStringSync();
    final nativeQueue = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();
    final compactCompatibility = compatibility.replaceAll(RegExp(r'\s+'), ' ');
    final compactQueue = nativeQueue.replaceAll(RegExp(r'\s+'), ' ');

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

    expect(
      compactQueue,
      contains(
        'static var nativePromotionAvailable: Bool { lock.lock() defer { lock.unlock() } return hookInstalled }',
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
