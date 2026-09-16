import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'background_downloader native callbacks do not depend on legacy URLSession hook',
    () {
      final source = File(
        'ios/Runner/DownloadNativeWaitingQueue.swift',
      ).readAsStringSync();

      expect(source, contains('private static var pluginObserversInstalled = false'));

      final installStart = source.indexOf('static func installUrlSessionHook() {');
      final installEnd = source.indexOf(
        '/// Dart persist is source of truth',
        installStart,
      );
      expect(installStart, greaterThanOrEqualTo(0));
      expect(installEnd, greaterThan(installStart));
      final install = source.substring(installStart, installEnd);

      expect(install, contains('if !pluginObserversInstalled {'));
      expect(install, contains('BDPlugin.onNativeTaskStatusChange'));
      expect(install, contains('BDPlugin.onNativeTaskProgressChange'));
      expect(install, contains('pluginObserversInstalled = true'));
      expect(install, contains('hookInstalled = DownloadUrlSessionHook.install()'));

      final progressStart = source.indexOf(
        'private static func handleSupportedPluginProgress(',
      );
      final progressEnd = source.indexOf(
        'static func handleBytesWritten(',
        progressStart,
      );
      expect(progressStart, greaterThanOrEqualTo(0));
      expect(progressEnd, greaterThan(progressStart));
      final progressHandler = source.substring(progressStart, progressEnd);

      expect(progressHandler, isNot(contains('nativePromotionAvailable')));
      expect(
        progressHandler,
        contains('guard progress.isFinite, progress >= 0 else { return }'),
      );
    },
  );
}
