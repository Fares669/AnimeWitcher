import 'dart:io';

import 'package:animewitcher/core/logger/app_diagnostics.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _FailingStorage extends MemoryStorageService {
  @override
  Future<void> setAppDiagnosticLog(bool value) async {
    if (value) throw const FileSystemException('storage unavailable');
    return super.setAppDiagnosticLog(value);
  }
}

class _FailingDisableStorage extends MemoryStorageService {
  @override
  Future<void> setAppDiagnosticLog(bool value) async {
    if (!value) throw const FileSystemException('storage unavailable');
    return super.setAppDiagnosticLog(value);
  }
}

void main() {
  test('general settings restore the independent app log opt-in', () async {
    final storage = MemoryStorageService();
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    expect(container.read(generalSettingsProvider).appDiagnosticLog, isFalse);
    await storage.setAppDiagnosticLog(true);
    container.invalidate(generalSettingsProvider);
    expect(container.read(generalSettingsProvider).appDiagnosticLog, isTrue);
    expect(
      container.read(generalSettingsProvider).downloadDiagnosticLog,
      isFalse,
    );
  });

  test(
    'app log toggle persists before enabling and preserves download setting',
    () async {
      final storage = MemoryStorageService();
      final directory = await Directory.systemTemp.createTemp(
        'aw-app-log-toggle-',
      );
      var checkedPersistence = false;
      final log = AppDiagnostics(
        directoryProvider: () async {
          if (!checkedPersistence) {
            expect(storage.getAppDiagnosticLog(), isTrue);
            checkedPersistence = true;
          }
          return directory;
        },
      );
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          appDiagnosticsProvider.overrideWithValue(log),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await log.setEnabled(false);
        await log.flush();
        await directory.delete(recursive: true);
      });

      final notifier = container.read(generalSettingsProvider.notifier);
      await notifier.setAppDiagnosticLog(true);
      expect(log.enabled, isTrue);
      expect(storage.getAppDiagnosticLog(), isTrue);
      expect(container.read(generalSettingsProvider).appDiagnosticLog, isTrue);
      expect(storage.getDownloadDiagnosticLog(), isFalse);
      await notifier.setAppDiagnosticLog(false);
      expect(log.enabled, isFalse);
      expect(storage.getAppDiagnosticLog(), isFalse);
      expect(container.read(generalSettingsProvider).appDiagnosticLog, isFalse);
    },
  );

  test('failed preference write does not enable diagnostics', () async {
    final storage = _FailingStorage();
    final log = AppDiagnostics(
      directoryProvider: () async =>
          throw StateError('logger must not be enabled before persistence'),
    );
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        appDiagnosticsProvider.overrideWithValue(log),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(generalSettingsProvider.notifier)
          .setAppDiagnosticLog(true),
      throwsA(isA<FileSystemException>()),
    );
    expect(log.enabled, isFalse);
    expect(storage.getAppDiagnosticLog(), isFalse);
    expect(container.read(generalSettingsProvider).appDiagnosticLog, isFalse);
  });

  test('failed logger enable restores the stored opt-in', () async {
    final storage = MemoryStorageService();
    final log = AppDiagnostics(
      directoryProvider: () async =>
          throw const FileSystemException('storage unavailable'),
    );
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        appDiagnosticsProvider.overrideWithValue(log),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(generalSettingsProvider.notifier)
          .setAppDiagnosticLog(true),
      throwsA(isA<FileSystemException>()),
    );
    expect(log.enabled, isFalse);
    expect(storage.getAppDiagnosticLog(), isFalse);
    expect(container.read(generalSettingsProvider).appDiagnosticLog, isFalse);
  });

  test(
    'logging stops for this session even when disabling cannot be persisted',
    () async {
      final storage = _FailingDisableStorage();
      await storage.setAppDiagnosticLog(true);
      final directory = await Directory.systemTemp.createTemp(
        'aw-app-log-stop-',
      );
      final log = AppDiagnostics(directoryProvider: () async => directory);
      await log.setEnabled(true);
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          appDiagnosticsProvider.overrideWithValue(log),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await log.setEnabled(false);
        await log.flush();
        await directory.delete(recursive: true);
      });

      await expectLater(
        container
            .read(generalSettingsProvider.notifier)
            .setAppDiagnosticLog(false),
        throwsA(isA<FileSystemException>()),
      );
      expect(log.enabled, isFalse);
      expect(container.read(generalSettingsProvider).appDiagnosticLog, isFalse);
      expect(storage.getAppDiagnosticLog(), isTrue);
    },
  );
}
