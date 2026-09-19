import 'dart:io';

import 'package:animewitcher/core/services/download_v2/legacy_download_migration_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('legacy restart-required migration contract', () {
    test('restart-required descriptor is durable presentation metadata only', () {
      final descriptor = legacyRestartRequiredSourceDescriptorV2(
        trackingUrl: '/anime/21/12',
        providerId: 'provider.example',
        sourceHint: 'server-a',
        quality: '1080p',
      );

      expect(sourceDescriptorRequiresLegacyRestartV2(descriptor), isTrue);
      expect(descriptor['trackingUrl'], '/anime/21/12');
      expect(descriptor['providerId'], 'provider.example');
      expect(descriptor['sourceHint'], 'server-a');
      expect(descriptor['quality'], '1080p');
      expect(descriptor, isNot(contains('url')));
      expect(descriptor, isNot(contains('headers')));
      expect(descriptor, isNot(contains('resumeData')));
      expect(descriptor, isNot(contains('ranges')));
    });

    test('production migration does not drop incomplete rows without refresh state', () {
      final source = File(
        'lib/core/services/download_v2/download_v2_provider.dart',
      ).readAsStringSync();

      expect(
        source,
        isNot(
          contains(
            'if (!finalFileValid && refreshDescriptor == null) continue;',
          ),
        ),
      );
      expect(source, contains('legacyRestartRequiredSourceDescriptorV2('));
    });
  });
}
