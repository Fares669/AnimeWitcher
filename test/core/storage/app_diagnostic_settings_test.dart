import 'dart:io';

import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('aw-app-log-settings-');
    Hive.init(directory.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'app diagnostics are opt-in and persist independently of download logs',
    () async {
      var box = await Hive.openBox<dynamic>('app_diagnostics');
      final storage = StorageService()..debugBindSettingsBox(box);
      final repository = SettingsRepository(storage);

      expect(repository.getAppDiagnosticLog(), isFalse);
      await repository.setAppDiagnosticLog(true);
      expect(storage.getDownloadDiagnosticLog(), isFalse);
      await box.close();

      box = await Hive.openBox<dynamic>('app_diagnostics');
      storage.debugBindSettingsBox(box);
      expect(repository.getAppDiagnosticLog(), isTrue);
      await storage.setDownloadDiagnosticLog(true);
      await repository.setAppDiagnosticLog(false);
      expect(repository.getAppDiagnosticLog(), isFalse);
      expect(storage.getDownloadDiagnosticLog(), isTrue);
    },
  );
}
