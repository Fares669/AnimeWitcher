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

    expect(launcher, contains('cacheSkipSegmentsForDownloadV2('));
    expect(launcher, contains('await requestDownloadPermissionsV2();'));
    expect(helper, contains('Permission.ignoreBatteryOptimizations'));
    expect(helper, contains('Permission.manageExternalStorage'));
    expect(helper, contains('Permission.storage.request()'));
    expect(helper, contains('skipSegmentCacheProvider'));
    expect(helper, contains('aniSkipServiceProvider'));
    expect(helper, isNot(contains('download_service.dart')));
    expect(helper, isNot(contains('downloadServiceProvider')));
  });
}
