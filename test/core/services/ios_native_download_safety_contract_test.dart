import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final queue = File('ios/Runner/DownloadNativeWaitingQueue.swift')
      .readAsStringSync();
  final manager = File('ios/Runner/DownloadContinuedProcessingManager.swift')
      .readAsStringSync();
  final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

  test('foreground byte callbacks use a locked lifecycle cache', () {
    final start = queue.indexOf('private static func isAppInForeground()');
    final end = queue.indexOf('private static func start(', start);
    final check = queue.substring(start, end);
    expect(check, contains('foregroundStateLock.lock()'));
    expect(check, isNot(contains('runOnMainActor')));
    expect(check, isNot(contains('UIApplication.shared')));
    expect(check, isNot(contains('lastForegroundCheckTime')));
    expect(
      delegate,
      contains('DownloadNativeWaitingQueue.installLifecycleObservers()'),
    );
    expect(queue, contains('UIScene.willDeactivateNotification'));
    expect(queue, contains('UIScene.didActivateNotification'));
  });

  test('expiration completes immediately and fences replacement leases', () {
    final start = manager.indexOf('task.expirationHandler = {');
    final end = manager.indexOf('\n    if let snapshot', start);
    final handler = manager.substring(start, end);
    expect(
      handler.indexOf('setTaskCompleted(success: false)'),
      lessThan(handler.indexOf('Task { @MainActor')),
    );
    expect(handler, contains('self.activeTask === task'));
    expect(
      handler,
      contains('completion.finish { task.setTaskCompleted(success: false) }'),
    );
    expect(
      manager,
      contains(
        'completion.finish { task.setTaskCompleted(success: verifiedSuccess) }',
      ),
    );
    expect(handler, isNot(contains('cancellationHandler?')));
  });

  test('native queue protects complete payloads with a Keychain key', () {
    expect(queue, contains('import CryptoKit'));
    expect(queue, contains('import Security'));
    expect(queue, contains('AES.GCM.seal'));
    expect(queue, contains('AES.GCM.open'));
    expect(queue, contains('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly'));
    final start = queue.indexOf('private static func saveLocked(');
    final end = queue.indexOf('private static func unique(', start);
    final save = queue.substring(start, end);
    expect(save, contains('DownloadNativeQueueEncryption.encrypt(data)'));
    expect(
      save,
      isNot(contains('UserDefaults.standard.set(data, forKey: stateKey)')),
    );
    expect(
      save.indexOf('set(encrypted, forKey: encryptedStateKey)'),
      lessThan(save.indexOf('removeObject(forKey: stateKey)')),
    );
    expect(queue, contains('return saved ? acceptedVersion : -1'));
  });

  test('native V2 parent background samples include measured speed', () {
    final start = queue.indexOf('if id.hasPrefix("aw_v2_") {');
    final end = queue.indexOf('guard nativePromotionAvailable else { return }', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final parent = queue.substring(start, end);
    expect(parent, contains('rollingSpeedLocked('));
    expect(parent, contains('speedBytesPerSecond: nativeSpeed'));
  });

  test('disk capacity bridge works before the iOS 26 overlay guard', () {
    final start = delegate.indexOf('if call.method == "availableDiskBytes"');
    expect(start, greaterThanOrEqualTo(0));
    final channel = delegate.indexOf(
      'name: "com.animewitcher.app/download_continued_processing"',
    );
    expect(
      start,
      lessThan(delegate.indexOf('guard #available(iOS 26.0, *)', channel)),
    );
    expect(delegate, contains('volumeAvailableCapacityForImportantUsageKey'));
    expect(delegate, contains('.systemFreeSize'));
  });
}
