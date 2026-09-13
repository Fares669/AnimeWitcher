import 'dart:io';

import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Apple settings', () {
    test('Eco defaults off and copyWith preserves the manual quality ceiling', () {
      const initial = PlayerSettings(
        anime4kEcoEnabled: false,
      );

      final enabled = initial.copyWith(anime4kEcoEnabled: true);

      expect(initial.anime4kEcoEnabled, isFalse);
      expect(enabled.anime4kEcoEnabled, isTrue);
      expect(enabled.anime4kQuality, initial.anime4kQuality);
      expect(enabled.anime4kMode, initial.anime4kMode);
    });

    test('MetalFX defaults off and is independent from Eco', () {
      const initial = PlayerSettings(
        anime4kEcoEnabled: false,
        anime4kMetalFxEnabled: false,
      );

      final enabled = initial.copyWith(anime4kMetalFxEnabled: true);

      expect(initial.anime4kMetalFxEnabled, isFalse);
      expect(enabled.anime4kMetalFxEnabled, isTrue);
      expect(enabled.anime4kEcoEnabled, isFalse);
      expect(enabled.anime4kQuality, initial.anime4kQuality);
      expect(enabled.anime4kMode, initial.anime4kMode);
    });

    test('provider persists Eco and MetalFX separately from mode and quality', () {
      final source = File(
        'lib/features/settings/presentation/player_settings_provider.dart',
      ).readAsStringSync();

      expect(source, contains("'player_anime4k_eco_enabled'"));
      expect(source, contains('setAnime4kEcoEnabled'));
      expect(source, contains('anime4kEcoEnabled: anime4kEcoEnabled'));
      expect(source, contains("'player_anime4k_metalfx_enabled'"));
      expect(source, contains('setAnime4kMetalFxEnabled'));
      expect(source, contains('anime4kMetalFxEnabled: anime4kMetalFxEnabled'));
    });

    test('Anime4K dialog exposes MetalFX directly under Eco on Apple', () {
      final source = File(
        'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
      ).readAsStringSync();

      expect(source, contains('Platform.isIOS || Platform.isMacOS'));
      expect(source, contains('settings.anime4kEcoEnabled'));
      expect(source, contains('setAnime4kEcoEnabled'));
      expect(source, contains('settings.anime4kMetalFxEnabled'));
      expect(source, contains('setAnime4kMetalFxEnabled'));
      expect(source, contains("english: 'MetalFX (experimental)'"));
      expect(source, contains("arabic: 'MetalFX (تجريبي)'"));

      final eco = source.indexOf("english: 'Eco / Auto'");
      final metalFx = source.indexOf("english: 'MetalFX (experimental)'");
      expect(eco, greaterThanOrEqualTo(0));
      expect(metalFx, greaterThan(eco));
    });

    test('Eco diagnostics show requested/effective quality and live backend', () {
      final source = File(
        'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
      ).readAsStringSync();

      expect(source, contains('ref.watch(anime4kDiagnosticsProvider)'));
      expect(source, contains("english: 'Requested quality'"));
      expect(source, contains("english: 'Effective quality'"));
      expect(source, contains("english: 'Backend'"));
      expect(source, contains('diagnostics.requestedQuality.suffix'));
      expect(source, contains('diagnostics.effectiveQuality.suffix'));
      expect(source, contains('diagnostics.backend'));
    });
  });
}
