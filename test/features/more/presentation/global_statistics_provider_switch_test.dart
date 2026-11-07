import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/features/more/presentation/global_statistics_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _RankingNative extends AnimeWitcherNativeProvider {
  _RankingNative() : super(Dio(), SettingsRepository(MemoryStorageService()));

  final requests = <Completer<ProviderMediaPage>>[];

  @override
  Future<ProviderMediaPage> getGlobalRankingPage(
    AnimeWitcherGlobalRanking ranking, {
    int offset = 0,
    int limit = animeWitcherRankingPageSize,
  }) {
    final request = Completer<ProviderMediaPage>();
    requests.add(request);
    return request.future;
  }
}

class _SelectedProvider extends ActiveProvider {
  _SelectedProvider(this.initial);

  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider? build() => initial;

  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

ProviderMediaPage _page(String title) => ProviderMediaPage(
  items: [
    MultimediaItem(
      title: title,
      url: 'https://animewitcher.test/$title',
      posterUrl: '',
    ),
  ],
  nextOffset: 1,
  hasMore: false,
);

void main() {
  testWidgets('Rift rankings are unsupported and do not retain Witcher data', (
    tester,
  ) async {
    final native = _RankingNative();
    final rift = AnimeRiftProvider();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWith(() => _SelectedProvider(native)),
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
          home: GlobalStatisticsScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(native.requests, hasLength(1));
    native.requests.first.complete(_page('Witcher ranking'));
    await tester.pump();
    expect(find.text('Witcher ranking'), findsWidgets);

    await container.read(activeProviderProvider.notifier).set(rift);
    await tester.pump();
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsOneWidget);
    expect(find.text('Witcher ranking'), findsNothing);

    await container.read(activeProviderProvider.notifier).set(native);
    await tester.pump();
    expect(native.requests, hasLength(2));
    native.requests.last.complete(_page('Witcher ranking restored'));
    await tester.pump();
    expect(find.text('Witcher ranking restored'), findsWidgets);
  });
}
