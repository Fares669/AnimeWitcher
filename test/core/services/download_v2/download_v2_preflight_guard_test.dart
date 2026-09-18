import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download launcher preserves non-transport preflight without V1', () {
    final launcher = File(
      'lib/features/details/presentation/download_launcher.dart',
    ).readAsStringSync();
    final helper = File(
      'lib/features/details/presentation/download_start_preflight_v2.dart',
    ).readAsStringSync();
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(launcher, contains('cacheSkipSegmentsForDownloadV2('));
    expect(launcher, contains('requestNotifications: !notificationPrefs.noneEnabled'));
    expect(helper, contains('bool requestNotifications = true'));
    expect(helper, contains('if (requestNotifications &&'));
    expect(helper, contains('Permission.ignoreBatteryOptimizations'));
    expect(helper, contains('Permission.manageExternalStorage'));
    expect(helper, contains('Permission.storage.request()'));
    expect(helper, contains('PermissionType.notifications'));
    expect(helper, contains('.permissions.request('));
    expect(helper, contains('bd.PermissionType.notifications'));
    expect(
      appDelegate,
      isNot(contains('UNUserNotificationCenter.current().requestAuthorization')),
      reason: 'notification permission belongs to the first real download, not app launch',
    );
    expect(helper, contains('skipSegmentCacheProvider'));
    expect(helper, contains('aniSkipServiceProvider'));
    expect(helper, isNot(contains('download_service.dart')));
    expect(helper, isNot(contains('downloadServiceProvider')));
  });
}
