import 'dart:io';

import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Eco setting', () {
    test('defaults off and copyWith preserves the manual quality ceiling', () {
      const initial = PlayerSettings(
        anime4kEcoEnabled: false,
      );

      final enabled = initial.copyWith(anime4kEcoEnabled: true);

      expect(initial.anime4kEcoEnabled, isFalse);
      expect(enabled.anime4kEcoEnabled, isTrue);
      expect(enabled.anime4kQuality, initial.anime4kQuality);
      expect(enabled.anime4kMode, initial.anime4kMode);
    });

    test('provider persists Eco separately from mode and quality', () {
      final source = File(
        'lib/features/settings/presentation/player_settings_provider.dart',
      ).readAsStringSync();

      expect(source, contains("'player_anime4k_eco_enabled'"));
      expect(source, contains('setAnime4kEcoEnabled'));
      expect(source, contains('anime4kEcoEnabled: anime4kEcoEnabled'));
    });

    test('Anime4K dialog exposes Eco only on Apple platforms', () {
      final source = File(
        'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
      ).readAsStringSync();

      expect(source, contains('Platform.isIOS || Platform.isMacOS'));
      expect(source, contains('settings.anime4kEcoEnabled'));
      expect(source, contains('setAnime4kEcoEnabled'));
    });

    test('Eco diagnostics show requested/effective quality and live backend', () {
      final source = File(
        'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
      ).readAsStringSync();

      expect(source, contains('anime4kPerformanceSnapshot'));
      expect(source, contains("english: 'Requested quality'"));
      expect(source, contains("english: 'Effective quality'"));
      expect(source, contains("english: 'Backend'"));
      expect(source, contains('_anime4kDiagnosticsTimer'));
      expect(source, contains('Timer.periodic(const Duration(seconds: 1)'));
      expect(source, contains('_anime4kDiagnosticsTimer?.cancel()'));
    });
  });
}
