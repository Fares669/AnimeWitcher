import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/extra_anime_list_screen.dart';
import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

class _Registry extends ExtensionManager {
  _Registry(this.providers);
  final List<AnimeWitcherProvider> providers;
  @override
  List<AnimeWitcherProvider> build() => providers;
}

void main() {
  testWidgets('late results are discarded after source item changes', (
    tester,
  ) async {
    final native = AnimeWitcherNativeProvider(
      Dio(),
      SettingsRepository(_MemoryStorage()),
    );
    var calls = 0;
    final pending = Completer<List<MultimediaItem>>();
    Widget screen(MultimediaItem source) => MaterialApp(
      home: ExtraAnimeListScreen(
        source: source,
        title: 'Related',
        emptyMessage: 'Empty',
        keyPrefix: 'test',
        load: (_) => calls++ == 0 ? pending.future : Future.value([]),
      ),
    );
    final nativeItem = MultimediaItem(
      title: 'Native',
      url: 'native',
      posterUrl: '',
      provider: native.packageName,
    );
    final nextItem = MultimediaItem(
      title: 'Next',
      url: 'next',
      posterUrl: '',
      provider: native.packageName,
    );
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(native),
        extensionManagerProvider.overrideWith(() => _Registry([native])),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: screen(nativeItem),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: screen(nextItem)),
    );
    await tester.pump();
    await tester.pump();
    pending.complete([
      MultimediaItem(title: 'Old result', url: 'old', posterUrl: ''),
    ]);
    await tester.pump();
    expect(find.text('Old result'), findsNothing);
    expect(find.text('Empty'), findsOneWidget);
  });

  testWidgets('loading posters start below the progressive header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gate = Completer<List<MultimediaItem>>();
    final provider = AnimeWitcherNativeProvider(
      Dio(),
      SettingsRepository(_MemoryStorage()),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeProviderProvider.overrideWithValue(provider),
          extensionManagerProvider.overrideWith(() => _Registry([provider])),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 44),
            ),
            child: ExtraAnimeListScreen(
              source: MultimediaItem(
                title: 'Source',
                url: 'test://source',
                posterUrl: '',
              ),
              title: 'Similar anime',
              emptyMessage: 'No titles',
              keyPrefix: 'test',
              load: (_) => gate.future,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final header = tester.getRect(find.byType(AppProgressiveHeaderBackdrop));
    final poster = tester.getRect(find.byType(AnimePosterShimmer).first);
    expect(poster.top, greaterThanOrEqualTo(header.bottom));
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(tester.takeException(), isNull);
    gate.complete([]);
    await tester.pump();
  });
}
