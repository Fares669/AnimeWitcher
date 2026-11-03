import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/services/anilist_franchise_service.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_seasons_bar.dart';
import 'package:animewitcher/features/details/presentation/widgets/anime_information_section.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _native = AnimeWitcherNativeProvider(
  Dio(),
  SettingsRepository(StorageService()),
);
final _rift = AnimeRiftProvider();

class _Registry extends ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() => [_native, _rift];
}

class _Active extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() => _native;
}

class _RiftActive extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() => _rift;
}

class _RiftFranchise extends AnimeRiftProvider {
  int calls = 0;

  MultimediaItem item(String id, String title, {String? relationType}) =>
      MultimediaItem(
        title: title,
        url: 'https://anime-rift.com/anime/$id',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
        provider: packageName,
        relationType: relationType,
      );

  @override
  Future<List<MultimediaItem>> getRelated(String url) async {
    calls++;
    if (url.endsWith('/season-1')) {
      return <MultimediaItem>[
        item('season-2', 'Rift 2nd Season', relationType: 'SEQUEL'),
      ];
    }
    if (url.endsWith('/season-2')) {
      return <MultimediaItem>[
        item('season-1', 'Rift', relationType: 'PREQUEL'),
      ];
    }
    return const <MultimediaItem>[];
  }
}

class _RiftFranchiseRegistry extends ExtensionManager {
  _RiftFranchiseRegistry(this.rift);
  final _RiftFranchise rift;

  @override
  List<AnimeWitcherProvider> build() => [_native, rift];
}

class _Franchise extends AniListFranchiseService {
  _Franchise() : super(Dio());
  int calls = 0;
  @override
  Future<AniListFranchiseNode?> fetchByMalId(int malId) async {
    calls++;
    return null;
  }
}

void main() {
  testWidgets(
    'Rift seasons bar walks Rift relations without requiring a MAL id',
    (tester) async {
      final rift = _RiftFranchise();
      final franchise = _Franchise();
      final item = rift.item('season-1', 'Rift');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionManagerProvider.overrideWith(
              () => _RiftFranchiseRegistry(rift),
            ),
            activeProviderProvider.overrideWith(_Active.new),
            aniListFranchiseServiceProvider.overrideWithValue(franchise),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: DetailsSeasonsBar(
                itemUrl: item.url,
                current: item,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(rift.calls, greaterThanOrEqualTo(2));
      expect(franchise.calls, 0);
      expect(find.text('الموسم 1'), findsOneWidget);
      expect(find.text('الموسم 2'), findsOneWidget);
    },
  );

  testWidgets(
    'Rift item does not fetch Witcher franchise when Witcher is selected',
    (tester) async {
      final franchise = _Franchise();
      final item = MultimediaItem(
        title: 'Rift',
        url: 'https://rift.test/1',
        posterUrl: '',
        provider: _rift.packageName,
        syncData: const {'malId': '12'},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionManagerProvider.overrideWith(_Registry.new),
            activeProviderProvider.overrideWith(_Active.new),
            aniListFranchiseServiceProvider.overrideWithValue(franchise),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: DetailsSeasonsBar(
                itemUrl: item.url,
                current: item,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(franchise.calls, 0);
    },
  );
  testWidgets(
    'Witcher item resolves its own franchise while Rift is selected',
    (tester) async {
      final franchise = _Franchise();
      final item = MultimediaItem(
        title: 'Native',
        url: 'https://native.test/1',
        posterUrl: '',
        provider: _native.packageName,
        syncData: const {'malId': '12'},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionManagerProvider.overrideWith(_Registry.new),
            activeProviderProvider.overrideWith(_RiftActive.new),
            aniListFranchiseServiceProvider.overrideWithValue(franchise),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: DetailsSeasonsBar(
                itemUrl: item.url,
                current: item,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(franchise.calls, 1);
    },
  );
  testWidgets(
    'Rift studio cannot open Witcher catalog when Witcher is selected',
    (tester) async {
      final item = MultimediaItem(
        title: 'Rift',
        url: 'https://rift.test/1',
        posterUrl: '',
        provider: _rift.packageName,
        syncData: const {'awStudio': 'Test Studio'},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionManagerProvider.overrideWith(_Registry.new),
            activeProviderProvider.overrideWith(_Active.new),
          ],
          child: MaterialApp(
            home: Scaffold(body: AnimeInformationSection(item: item)),
          ),
        ),
      );
      await tester.tap(find.text('Test Studio'));
      await tester.pumpAndSettle();
      expect(find.byType(ViewAllScreen), findsNothing);
    },
  );
}
