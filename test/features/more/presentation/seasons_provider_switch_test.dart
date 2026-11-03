import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/features/more/presentation/seasons_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SeasonProvider extends AnimeRiftProvider {
  _SeasonProvider(this.packageName, this.label);
  @override
  final String packageName;
  final String label;
  final pages = <Completer<ProviderMediaPage>>[];
  @override
  Future<ProviderSeasonConfig> getSeasonConfig() async =>
      const ProviderSeasonConfig(
        past: 'ربيع عام 2026',
        current: 'صيف عام 2026',
        next: 'خريف عام 2026',
      );
  @override
  Future<List<String>> getAllSeasons({bool refresh = false}) async => [
    'صيف عام 2026',
  ];
  @override
  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) {
    final pending = Completer<ProviderMediaPage>();
    pages.add(pending);
    return pending.future;
  }

  ProviderMediaPage result() => ProviderMediaPage(
    items: [
      MultimediaItem(
        title: label,
        url: 'https://anime-rift.com/anime/$label',
        posterUrl: '',
        provider: packageName,
      ),
    ],
    nextOffset: 1,
    hasMore: false,
  );
}

class _Selection extends ActiveProvider {
  _Selection(this.initial);
  final AnimeWitcherProvider initial;
  @override
  AnimeWitcherProvider? build() => initial;
  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

void main() {
  testWidgets(
    'season results stay isolated during rapid switching and late responses',
    (tester) async {
      final first = _SeasonProvider(
        'com.fares669.animewitcher.native',
        'Witcher',
      );
      final second = _SeasonProvider('com.animerift.provider', 'Rift');
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWith(() => _Selection(first)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SeasonsScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(first.pages, hasLength(1));
      await container.read(activeProviderProvider.notifier).set(second);
      await tester.pump();
      await tester.pump();
      expect(second.pages, hasLength(1));
      second.pages.single.complete(second.result());
      await tester.pump();
      first.pages.single.complete(first.result());
      await tester.pump();
      expect(find.text('Rift'), findsWidgets);
      expect(find.text('Witcher'), findsNothing);
      await container.read(activeProviderProvider.notifier).set(first);
      await tester.pump();
      await tester.pump();
      expect(find.text('Rift'), findsNothing);
      expect(first.pages, hasLength(2));
      first.pages.last.complete(first.result());
      await tester.pump();
      expect(find.text('Witcher'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
