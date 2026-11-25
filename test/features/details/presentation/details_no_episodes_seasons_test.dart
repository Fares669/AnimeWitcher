import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_hero_actions.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_seasons_bar.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

final class _Storage extends MemoryStorageService {
  @override
  String? getString(String key) => settings[key] as String?;

  @override
  int getPosition(String url) => 0;
}

final class _EmptyLibrary extends Library {
  @override
  LibraryState build() =>
      const LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);

  @override
  bool isFavorite(String url, {String? providerId}) => false;

  @override
  LibraryCategory? itemCategory(
    String url, {
    String? providerId,
    bool manga = false,
  }) => null;

  @override
  Future<void> setFavorite(
    MultimediaItem item,
    bool favorite, {
    LibraryMembership? membership,
  }) async {}
}

final class _MembershipAccount extends AnimeWitcherAccountService {
  _MembershipAccount(_Storage storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  LibraryMembership membership = (
    category: LibraryCategory.continueLater,
    favorite: true,
  );
  int reads = 0;

  @override
  bool get isSignedIn => true;

  @override
  String get accountUid => 'test-account';

  @override
  Future<LibraryMembership?> fetchAnimeLibraryMembership(String url) async {
    reads++;
    return membership;
  }

  @override
  Future<int?> loadAnimeUserRating(String animeId) async => null;
}

final class _NoEpisodeDetailsController extends DetailsController {
  _NoEpisodeDetailsController(this.item);

  final MultimediaItem item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData<MultimediaItem?>(item),
    episodes: const AsyncData<List<Episode>>(<Episode>[]),
    cast: const AsyncData<List<Actor>>(<Actor>[]),
    trailers: const AsyncData<List<Trailer>>(<Trailer>[]),
    related: AsyncData<List<MultimediaItem>>(
      item.related ?? const <MultimediaItem>[],
    ),
    recommendations: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    item: item,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}
}

void main() {
  testWidgets(
    'details reload server membership on reopen and update the heart immediately',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(590, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = _Storage();
      final account = _MembershipAccount(storage);
      final item = MultimediaItem(
        title: 'Anime',
        url: 'https://animewitcher.com/watch/anime',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(account),
            libraryProvider.overrideWith(_EmptyLibrary.new),
            detailsControllerProvider(item.url)
                .overrideWith(() => _NoEpisodeDetailsController(item)),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DetailsScreen(item: item),
                    ),
                  ),
                  child: const Text('Open anime'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open anime'));
      await tester.pumpAndSettle();
      expect(find.text('أكملها لاحقًا'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.favorite_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);

      Navigator.of(tester.element(find.byType(DetailsScreen))).pop();
      await tester.pumpAndSettle();
      account.membership = (
        category: LibraryCategory.completed,
        favorite: true,
      );
      await tester.tap(find.text('Open anime'));
      await tester.pumpAndSettle();
      expect(account.reads, 2);
      expect(find.text('تمت مشاهدته'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    },
  );

  testWidgets('seasons stay visible when an anime has no episodes yet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(590, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final firstSeason = MultimediaItem(
      title: 'Example Season 1',
      url: 'https://animewitcher.test/watch/example-s1',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      catalogType: 'مسلسل',
      relationType: 'PREQUEL',
      year: 2024,
    );
    final upcomingSeason = MultimediaItem(
      title: 'Example Season 2',
      url: 'https://animewitcher.test/watch/example-s2',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      catalogType: 'مسلسل',
      year: 2027,
      description: 'Upcoming season',
      related: <MultimediaItem>[firstSeason],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          libraryProvider.overrideWith(_EmptyLibrary.new),
          detailsControllerProvider(upcomingSeason.url)
              .overrideWith(() => _NoEpisodeDetailsController(upcomingSeason)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: DetailsScreen(item: upcomingSeason),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(DetailsSeasonsBar), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('details-episodes-toggle')),
      findsOneWidget,
    );
    expect(
      find.byType(DetailsHeroPlayPill),
      findsNothing,
      reason: 'series playback stays inside the collapsed episodes section',
    );
  });
}
