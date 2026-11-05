import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Platform-specific facts for AnimeRift's device registration.
///
/// The gateway's installation-scoped deviceId is managed separately by the
/// client: changing the advertised model must never rotate an existing session.
class AnimeRiftDeviceDescriptor {
  const AnimeRiftDeviceDescriptor({
    required this.os,
    required this.osId,
    required this.details,
    this.installSource,
  });

  final String os;
  final String osId;
  final Map<String, dynamic> details;
  final String? installSource;

  static Future<AnimeRiftDeviceDescriptor> detect(String legacyBuildId) async {
    if (!kIsWeb && Platform.isAndroid) {
      return fromAndroid(await DeviceInfoPlugin().androidInfo);
    }
    if (!kIsWeb && Platform.isIOS) {
      return fromIos(await DeviceInfoPlugin().iosInfo);
    }
    // Desktop/web builds continue using the existing Android-compatible
    // protocol because AnimeRift has no known native gateway contract for them.
    return emulatedAndroid(legacyBuildId);
  }

  static AnimeRiftDeviceDescriptor fromAndroid(AndroidDeviceInfo info) {
    return AnimeRiftDeviceDescriptor(
      os: 'android',
      osId: info.id,
      // Retain the existing Android gateway's required installation-source
      // protocol value; the hardware and OS fields below are real.
      installSource: 'IS_INSTALLED_FROM_PLAY_PACKAGE_INSTALLER',
      details: {
        'model': info.model,
        'brand': info.brand,
        'manufacturer': info.manufacturer,
        'device': info.device,
        'hardware': info.hardware,
        'product': info.product,
        'androidVersion': info.version.release,
        'sdkInt': info.version.sdkInt,
        'securityPatch': info.version.securityPatch,
        'isPhysicalDevice': info.isPhysicalDevice,
        'supportedAbis': info.supportedAbis,
        'tags': info.tags,
        'type': info.type,
        'buildId': info.id,
        'host': info.host,
        'fingerprint': info.fingerprint,
      },
    );
  }

  static AnimeRiftDeviceDescriptor fromIos(IosDeviceInfo info) {
    return AnimeRiftDeviceDescriptor(
      os: 'ios',
      osId: info.systemVersion,
      details: {
        'model': info.modelName.isEmpty ? info.model : info.modelName,
        'brand': 'Apple',
        'manufacturer': 'Apple',
        'device': info.utsname.machine,
        'product': info.model,
        'systemName': info.systemName,
        'systemVersion': info.systemVersion,
        'localizedModel': info.localizedModel,
        'isPhysicalDevice': info.isPhysicalDevice,
        'machine': info.utsname.machine,
      },
      // No invented App Store install-source enum: the iOS gateway contract
      // has not been captured and installation source is not device identity.
    );
  }

  static AnimeRiftDeviceDescriptor emulatedAndroid(String buildId) {
    return AnimeRiftDeviceDescriptor(
      os: 'android',
      osId: buildId,
      installSource: 'IS_INSTALLED_FROM_PLAY_PACKAGE_INSTALLER',
      details: {
        'model': 'Pixel 8 Pro',
        'brand': 'google',
        'manufacturer': 'Google',
        'device': 'google',
        'hardware': 'qcom',
        'product': 'google',
        'androidVersion': '14',
        'sdkInt': 34,
        'securityPatch': '2025-01-01',
        'isPhysicalDevice': true,
        'supportedAbis': ['arm64-v8a'],
        'tags': 'release-keys',
        'type': 'user',
        'buildId': buildId,
        'host': 'build-server-client',
        'fingerprint':
            'google/Pixel 8 Pro/google:14/$buildId/V.1e9a_client:user/release-keys',
      },
    );
  }
}
