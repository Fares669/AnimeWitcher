import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/characters/presentation/anime_characters_screen.dart';
import 'package:animewitcher/features/characters/presentation/character_card.dart';
import 'package:animewitcher/features/characters/presentation/character_details_screen.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_extra_tabs.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
// Use the same Material compatibility API as the production screen.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/test_fonts.dart';

const _shot = ValueKey('character-details-route-shot');
const _stock = bool.fromEnvironment('CHARACTERS_GRID_STOCK');

final class _Storage extends MemoryStorageService {
  @override
  List<Map<String, dynamic>> getWatchHistory() => const [];

  @override
  int getPosition(String url) => 0;

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async =>
      const {};
}

final class _Downloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];
}

final class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => const [];
}

final class _Library extends Library {
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
}

final class _Account extends AnimeWitcherAccountService {
  _Account(_Storage storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  bool favorite = false;
  int toggles = 0;

  @override
  bool get isSignedIn => true;

  @override
  String get accountUid => 'fixture-account';

  @override
  Future<LibraryMembership?> fetchAnimeLibraryMembership(String url) async =>
      null;

  @override
  Future<int?> loadAnimeUserRating(String animeId) async => null;

  @override
  Future<bool> isFavoriteCharacter(String characterId) async => favorite;

  @override
  Future<bool> toggleFavoriteCharacter(String characterId) async {
    expect(characterId, 'cast-0');
    toggles++;
    return favorite = !favorite;
  }

  @override
  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async =>
      const AnimeWitcherCommentPage(items: [], cursor: null, hasMore: false);
}

final class _Manager extends ExtensionManager {
  _Manager(this.source);

  final AnimeWitcherProvider source;

  @override
  List<AnimeWitcherProvider> build() => [source];
}

final class _Details extends DetailsController {
  _Details(this.show, this.cast);

  final MultimediaItem show;
  final List<Actor> cast;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData(show),
    episodes: const AsyncData([]),
    cast: AsyncData(cast),
    trailers: const AsyncData([]),
    related: const AsyncData([]),
    recommendations: const AsyncData([]),
    item: show,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}

  @override
  Future<void> loadCastIfNeeded() async {}

  @override
  Future<void> loadRecommendationsIfNeeded() async {}
}

final class _ObservedShow extends AnimeWitcherCharacterShow {
  _ObservedShow(int index, this.onProjection, {String? title, String? role})
    : super(
        item: MultimediaItem(
          title: title ?? 'العمل رقم $index',
          url: 'https://animewitcher.com/watch/character-project-$index',
          posterUrl: '',
          contentType: MultimediaContentType.anime,
          catalogType: index.isEven ? 'مسلسل' : 'فيلم',
          year: 2022,
        ),
        role: role ?? (index.isEven ? 'Main' : 'Supporting'),
      );

  final VoidCallback onProjection;

  @override
  String get roleLabel {
    onProjection();
    return super.roleLabel;
  }
}

final class _Native extends AnimeWitcherNativeProvider {
  _Native(_Storage storage, this.cast, this.shows)
    : super(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => throw StateError(
                'Unexpected network request for ${options.uri}',
              ),
            ),
          ),
        SettingsRepository(storage),
      );

  final List<Actor> cast;
  final List<AnimeWitcherCharacterShow> shows;
  final requests = <String>[];

  @override
  Future<List<Actor>> getAnimeCharactersByRole(
    String animeId,
    String role,
  ) async {
    requests.add('cast:$animeId:$role');
    return cast;
  }

  @override
  Future<AnimeWitcherCharacterDocument?> getCharacterDocument(String id) async {
    requests.add('doc:$id');
    return const AnimeWitcherCharacterDocument(
      id: 'cast-0',
      name: 'البطل الأول',
      likes: 28,
    );
  }

  @override
  Future<List<AnimeWitcherCharacterShow>> getCharacterAnimes(
    AnimeWitcherCharacterDocument character,
  ) async {
    requests.add('shows:${character.id}');
    return shows;
  }
}

Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 40),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 6),
);

Finder _card(int index) => find.byKey(ValueKey('character-animes-grid-$index'));

Finder _profileButton(String tooltip) => find.byWidgetPredicate(
  (w) => w is AppleLiquidGlassToolbarButton && w.tooltip == tooltip,
);

int _mountedGridCards() => find
    .byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('character-animes-grid-');
    })
    .evaluate()
    .length;

Future<String> _pixels(WidgetTester tester) async {
  final object = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
  return (await tester.runAsync(() async {
    final image = await object.toImage();
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return sha256
          .convert(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          )
          .toString();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets(
    'Arabic Details reuses the character anime grid across a favorite change',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(590, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(TestFonts.loadWalkthroughFonts);
      const catalogSize = 120;
      final storage = _Storage();
      final account = _Account(storage);
      final cast = List.generate(
        12,
        (i) => Actor(
          id: 'cast-$i',
          name: i == 0 ? 'البطل الأول' : 'البطل $i',
          image: '',
          role: 'شخصية رئيسية',
        ),
      );
      var projections = 0;
      final provider = _Native(storage, cast, [
        for (var i = 0; i < catalogSize; i++)
          _ObservedShow(i, () => projections++),
      ]);
      final item = MultimediaItem(
        title: 'مغامرة الأبطال',
        url: 'https://animewitcher.com/watch/role-fixture',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
        provider: provider.packageName,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(account),
            activeProviderProvider.overrideWithValue(provider),
            extensionManagerProvider.overrideWith(() => _Manager(provider)),
            detailsControllerProvider(item.url)
                .overrideWith(() => _Details(item, cast)),
            libraryProvider.overrideWith(_Library.new),
            downloadsProvider.overrideWith(_Downloads.new),
            watchHistoryProvider.overrideWith(_History.new),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'NotoSansArabic',
            ),
            builder: (context, child) =>
                RepaintBoundary(key: _shot, child: child),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => DetailsScreen(item: item),
                    ),
                  ),
                  child: const Text('فتح الأنمي'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('فتح الأنمي'));
      await _settle(tester);

      final tab = find.text(animeWitcherCharactersTabLabel);
      expect(find.byType(DetailsExtraTabs), findsOneWidget);
      for (var i = 0; i < 6 && tab.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(
          find.byType(DetailsDesktopHero),
          const Offset(0, -260),
        );
        await _settle(tester);
      }
      await Scrollable.ensureVisible(tester.element(tab), alignment: 0.45);
      await _settle(tester);
      expect(tab.hitTestable(), findsOneWidget);
      await tester.tap(tab);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);

      final firstCast = find.byKey(const ValueKey('details-character-Main-0'));
      final rail = Scrollable.of(
        tester.element(firstCast),
        axis: Axis.horizontal,
      ).position;
      rail.jumpTo(rail.maxScrollExtent);
      await _settle(tester);
      final more = find.byKey(const ValueKey('details-character-Main-more'));
      await Scrollable.ensureVisible(tester.element(more), alignment: 0.45);
      await _settle(tester);
      expect(more.hitTestable(), findsOneWidget);
      await tester.tap(more);
      await _settle(tester);
      expect(find.byType(AnimeCharactersScreen), findsOneWidget);
      expect(provider.requests, ['cast:role-fixture:Main']);
      final castCard = find.descendant(
        of: find.byType(AnimeCharactersScreen),
        matching: find.byWidgetPredicate(
          (w) => w is CharacterPosterCard && w.character.id == 'cast-0',
        ),
      );
      expect(castCard.hitTestable(), findsOneWidget);
      await tester.tap(castCard.hitTestable());
      await _settle(tester);

      final screen = find.byType(CharacterDetailsScreen);
      expect(screen, findsOneWidget);
      expect(Directionality.of(tester.element(screen)), TextDirection.rtl);
      final before = (projections, _mountedGridCards());
      final row = [_card(0), _card(1), _card(2)];
      expect(
        tester.getTopLeft(row[0]).dx,
        greaterThan(tester.getTopLeft(row[1]).dx),
      );
      expect(
        tester.getTopLeft(row[1]).dx,
        greaterThan(tester.getTopLeft(row[2]).dx),
      );
      expect(tester.getTopLeft(row[0]).dy, tester.getTopLeft(row[1]).dy);
      expect(
        find.descendant(of: row[0], matching: find.text('شخصية رئيسية')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row[1], matching: find.text('شخصية ثانوية')),
        findsOneWidget,
      );
      final initial = await _pixels(tester);
      final initialCards = [
        for (var i = 0; i < catalogSize; i++)
          tester.widget<MultimediaCard>(_card(i)),
      ];

      projections = 0;
      final favorite = _profileButton('إضافة إلى المفضلة').hitTestable();
      expect(favorite, findsOneWidget);
      await tester.tap(favorite);
      await _settle(tester);
      expect(_profileButton('إزالة من المفضلة'), findsOneWidget);
      expect(account.toggles, 1);
      final favoriteWork = projections;
      final replacedCards = [
        for (var i = 0; i < catalogSize; i++)
          if (!identical(
            initialCards[i],
            tester.widget<MultimediaCard>(_card(i)),
          ))
            i,
      ].length;
      final favorited = await _pixels(tester);

      final gridTitle = find.text('الأنميات');
      final scroll = Scrollable.of(tester.element(gridTitle)).position;
      final extent = scroll.maxScrollExtent;
      scroll.jumpTo(extent);
      await _settle(tester);
      expect(_card(catalogSize - 1).hitTestable(), findsOneWidget);
      expect(
        tester.widget<MultimediaCard>(_card(catalogSize - 1)).title,
        'العمل رقم 119',
      );
      final end = (_mountedGridCards(), await _pixels(tester));

      scroll.jumpTo(0);
      await _settle(tester);
      expect(await _pixels(tester), favorited);
      FocusNode focusOf(Finder card) => tester
          .widget<Focus>(
            find.descendant(of: card, matching: find.byType(Focus)).first,
          )
          .focusNode!;
      final firstFocus = focusOf(row[0]);
      final nextFocus = focusOf(row[1]);
      firstFocus.requestFocus();
      await _settle(tester);
      expect(firstFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await _settle(tester);
      expect(nextFocus.hasPrimaryFocus, isTrue);
      expect(scroll.pixels, 0);
      final focus = await _pixels(tester);

      // A fresh successful request must replace the memoized grid and its
      // role metadata, while a favorite-only update above must not.
      projections = 0;
      provider.shows[0] = _ObservedShow(
        0,
        () => projections++,
        title: 'عمل محدّث',
        role: 'Supporting',
      );
      final refresh = tester
          .state<RefreshIndicatorState>(
            find.descendant(
              of: screen,
              matching: find.byType(RefreshIndicator),
            ),
          )
          .show();
      await _settle(tester);
      await refresh;
      expect(tester.widget<MultimediaCard>(_card(0)).title, 'عمل محدّث');
      expect(
        find.descendant(of: _card(0), matching: find.text('شخصية ثانوية')),
        findsOneWidget,
      );
      final refreshWork = projections;
      final refreshed = await _pixels(tester);
      final view = tester.state<NavigatorState>(find.byType(Navigator));
      view.pop();
      await _settle(tester);
      expect(find.byType(AnimeCharactersScreen), findsOneWidget);
      view.pop();
      await _settle(tester);
      expect(find.byType(DetailsScreen), findsOneWidget);
      expect(provider.requests, [
        'cast:role-fixture:Main',
        'doc:cast-0',
        'shows:cast-0',
        'doc:cast-0',
        'shows:cast-0',
      ]);

      debugPrint(
        'C27_CHARACTERS_REUSE first=$before favoriteWork=$favoriteWork '
        'replacedCards=$replacedCards refreshWork=$refreshWork '
        'endMounted=${end.$1} extent=${extent.toStringAsFixed(4)} '
        'rgba=[$initial,$favorited,${end.$2},$focus,$refreshed]',
      );
      expect(before, (catalogSize, catalogSize));
      expect(end.$1, catalogSize);
      expect(refreshWork, catalogSize);
      expect(favoriteWork, _stock ? catalogSize : 0);
      expect(replacedCards, _stock ? catalogSize : 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
