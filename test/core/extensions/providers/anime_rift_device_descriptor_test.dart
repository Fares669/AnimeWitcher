import 'package:animewitcher/core/extensions/providers/anime_rift_device_descriptor.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android registration uses actual hardware and OS information', () {
    final android = AndroidDeviceInfo.fromMap({
      'version': {
        'release': '16',
        'sdkInt': 36,
        'securityPatch': '2026-10-05',
        'codename': 'REL',
        'incremental': '12345',
        'previewSdkInt': 0,
      },
      'board': 'board',
      'bootloader': 'bootloader',
      'brand': 'samsung',
      'device': 'e3q',
      'display': 'display',
      'fingerprint': 'samsung/e3q/build',
      'hardware': 'qcom',
      'host': 'host',
      'id': 'AP4A.real-build',
      'manufacturer': 'Samsung',
      'model': 'SM-S928B',
      'product': 'e3qxxx',
      'name': 'Private phone name',
      'supportedAbis': ['arm64-v8a'],
      'tags': 'release-keys',
      'time': 1,
      'type': 'user',
      'isPhysicalDevice': true,
      'freeDiskSize': 1,
      'totalDiskSize': 2,
      'systemFeatures': <String>[],
      'isLowRamDevice': false,
      'physicalRamSize': 8192,
      'availableRamSize': 4096,
    });
    final identity = AnimeRiftDeviceDescriptor.fromAndroid(android);
    expect(identity.os, 'android');
    expect(identity.osId, 'AP4A.real-build');
    expect(identity.details['model'], 'SM-S928B');
    expect(identity.details['brand'], 'samsung');
    expect(identity.details['androidVersion'], '16');
    expect(identity.details['sdkInt'], 36);
    expect(identity.details['fingerprint'], 'samsung/e3q/build');
    expect(identity.details.toString(), isNot(contains('Private phone name')));
    expect(identity.installSource, 'IS_INSTALLED_FROM_PLAY_PACKAGE_INSTALLER');
  });

  test(
    'iOS registration advertises real marketed model without personal name',
    () {
      final ios = IosDeviceInfo.fromMap({
        'name': 'Private iPhone name',
        'model': 'iPhone',
        'modelName': 'iPhone 12 Pro Max',
        'systemName': 'iOS',
        'systemVersion': '26.1',
        'localizedModel': 'iPhone',
        'identifierForVendor': 'private-vendor-identifier',
        'freeDiskSize': 1,
        'totalDiskSize': 2,
        'isPhysicalDevice': true,
        'physicalRamSize': 8192,
        'availableRamSize': 4096,
        'isiOSAppOnMac': false,
        'isiOSAppOnVision': false,
        'utsname': {
          'release': '25.0.0',
          'version': 'Darwin Version',
          'machine': 'iPhone13,4',
          'sysname': 'Darwin',
          'nodename': 'private-name',
        },
      });
      final identity = AnimeRiftDeviceDescriptor.fromIos(ios);
      expect(identity.os, 'ios');
      expect(identity.osId, 'private-vendor-identifier');
      expect(identity.details['model'], 'iPhone 12 Pro Max');
      expect(identity.details['device'], 'iPhone13,4');
      expect(identity.details['systemName'], 'iOS');
      expect(
        identity.details.toString(),
        isNot(contains('Private iPhone name')),
      );
      expect(
        identity.details.toString(),
        isNot(contains('private-vendor-identifier')),
      );
      expect(identity.installSource, 'IS_INSTALLED_FROM_APP_STORE');
    },
  );

  test('other platforms continue using legacy synthetic Android identity', () {
    final identity = AnimeRiftDeviceDescriptor.emulatedAndroid('build-123');
    expect(identity.os, 'android');
    expect(identity.osId, 'build-123');
    expect(identity.details['model'], 'Pixel 8 Pro');
    expect(identity.details['androidVersion'], '14');
    expect(identity.installSource, 'IS_INSTALLED_FROM_PLAY_PACKAGE_INSTALLER');
  });
}
