import 'dart:collection';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_hero_actions.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_ratings_row.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
// Match Details' Material compatibility surface.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

const _frame = ValueKey<String>('offline-rating-projection-frame');
const _open = 'افتح تفاصيل المسلسل';
const _url = 'local://details-offline/rated-anime';

class _RatingFields extends MapBase<String, String> {
  _RatingFields(this._values);

  final Map<String, String> _values;
  int projectionReads = 0;

  @override
  String? operator [](Object? key) {
    // The projection reads this field once per call. Exclude equality
    // checks and any reads outside the compact ratings model.
    if (key == 'awMalScore' &&
        StackTrace.current.toString().contains(
          'AnimeDetailsRatings.fromItem',
        )) {
      projectionReads++;
    }
    return _values[key];
  }

  @override
  void operator []=(String key, String value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<String> get keys => _values.keys;

  @override
  String? remove(Object? key) => _values.remove(key);
}

class _Library extends Library {
  @override
  LibraryState build() =>
      const LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);

  void publishOtherTitleChange() =>
      state = LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);

  @override
  bool isFavorite(String url, {String? providerId}) => false;

  @override
  LibraryCategory? itemCategory(
    String url, {
    String? providerId,
    bool manga = false,
  }) => null;
}

class _Downloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];
}

class _OfflineAccount extends AnimeWitcherAccountService {
  _OfflineAccount(MemoryStorageService storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  final requests = <String>[];
  final writes = <int>[];

  @override
  bool get isSignedIn => true;

  @override
  String get accountUid => 'offline-rating-account';

  @override
  Future<LibraryMembership?> fetchAnimeLibraryMembership(String url) async =>
      null;

  @override
  Future<int?> loadAnimeUserRating(String animeId) async {
    requests.add(animeId);
    return 6;
  }

  @override
  Future<int?> saveAnimeUserRating(String animeId, int rating) async {
    writes.add(rating);
    return rating;
  }

  @override
  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async => const AnimeWitcherCommentPage(
    items: <AnimeWitcherComment>[],
    cursor: null,
    hasMore: false,
  );
}

class _Details extends DetailsController {
  _Details(this.item);

  final MultimediaItem item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData(item),
    episodes: const AsyncData(<Episode>[]),
    cast: const AsyncData(<Actor>[]),
    trailers: const AsyncData(<Trailer>[]),
    related: const AsyncData(<MultimediaItem>[]),
    recommendations: const AsyncData(<MultimediaItem>[]),
    item: item,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}

  void publishDetails(MultimediaItem incoming) =>
      state = state.copyWith(item: incoming, details: AsyncData(incoming));
}

Future<String> _frameHash(WidgetTester tester) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return sha256
          .convert(
            pixels.buffer.asUint8List(
              pixels.offsetInBytes,
              pixels.lengthInBytes,
            ),
          )
          .toString();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets(
      'Arabic Details projects current compact scores once at ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fallback = artworkFallbackEnabled.value;
        artworkFallbackEnabled.value = false;
        final messenger = tester.binding.defaultBinaryMessenger;
        const secure = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        messenger.setMockMethodCallHandler(secure, (_) async => null);
        final oldCallback = debugOnRebuildDirtyWidget;
        addTearDown(() {
          artworkFallbackEnabled.value = fallback;
          messenger.setMockMethodCallHandler(secure, null);
          debugOnRebuildDirtyWidget = oldCallback;
        });

        final scores = _RatingFields({
          'awScore': '٩.١',
          'awScoreCount': '٥٠٤٩',
          'awMalScore': '٨.٧٣',
          'awMalScoringUsers': '٤٣٢١',
          'awImdbId': 'tt123456',
          // Use the legacy MAL-with-IMDb-ID fallback instead of looking up an
          // AniList chain. This route never needs a remote catalog.
        });
        final item = MultimediaItem(
          url: _url,
          title: 'قصة المدينة',
          description: 'وصف من اختبار محلي',
          posterUrl: '',
          provider: 'Local',
          status: ShowStatus.ongoing,
          syncData: scores,
        );
        final storage = MemoryStorageService();
        final account = _OfflineAccount(storage);
        final provider = detailsControllerProvider(_url);
        final container = ProviderContainer(
          overrides: [
            provider.overrideWith(() => _Details(item)),
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(account),
            libraryProvider.overrideWith(_Library.new),
            downloadsProvider.overrideWith(_Downloads.new),
            logicalDownloadStoreV2Provider.overrideWithValue(
              InMemoryLogicalDownloadStoreV2(),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _frame,
            child: UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                locale: const Locale('ar'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: ThemeData.dark(),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => DetailsScreen(item: item),
                        ),
                      ),
                      child: const Text(_open),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text(_open));
        await tester.pumpAndSettle();

        final route = find.byType(DetailsScreen);
        final compact = find.byKey(kDetailsRatingsCompactKey);
        final badge = find.byKey(kDetailsRatingsCompactExternalBadgeKey);
        final rate = find.byWidgetPredicate(
          (widget) =>
              widget is DetailsHeroIconButton && widget.tooltip == 'قيّم',
        );
        expect(route, findsOneWidget);
        expect(Directionality.of(tester.element(route)), TextDirection.rtl);
        expect(find.text('9.1'), findsOneWidget);
        expect(find.text('8.73'), findsOneWidget);
        expect(
          find.descendant(of: badge, matching: find.text('MAL')),
          findsOneWidget,
        );
        expect(account.requests, ['rated-anime']);
        expect(find.text('6/10'), findsOneWidget);
        final hashes = <String>[await _frameHash(tester)];

        final library = container.read(libraryProvider.notifier) as _Library;
        final details = container.read(provider.notifier) as _Details;
        var metadataBuilds = 0;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          oldCallback?.call(element, builtOnce);
          if (element.widget is MetadataBar) metadataBuilds++;
        };
        scores.projectionReads = 0;
        for (var i = 0; i < 12; i++) {
          library.publishOtherTitleChange();
          await tester.pump();
        }
        expect(metadataBuilds, 12);
        expect(scores.projectionReads, metadataBuilds);
        print(
          'C26_DETAIL_RATINGS ${size.width} frames=$metadataBuilds projections=${scores.projectionReads}',
        );
        hashes.add(await _frameHash(tester));
        expect(hashes[1], hashes.first);

        // The freshly parsed result must follow a live score edit even if
        // the map identity stays the same across the next rebuild.
        scores.remove('awMalScore');
        scores['awImdbScore'] = '٧.٤';
        library.publishOtherTitleChange();
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: badge, matching: find.text('IMDb')),
          findsOneWidget,
        );
        expect(find.text('7.4'), findsOneWidget);
        expect(find.text('8.73'), findsNothing);
        hashes.add(await _frameHash(tester));
        expect(hashes[2], isNot(hashes.first));

        // A fresh details publication with no scores removes the whole row.
        details.publishDetails(
          item.copyWith(syncData: const <String, String>{}),
        );
        await tester.pumpAndSettle();
        expect(compact, findsNothing);
        hashes.add(await _frameHash(tester));
        expect(hashes[3], isNot(hashes[2]));

        // Activate the real Details hero rating action using keyboard focus.
        final ratingCaption = find.descendant(
          of: rate,
          matching: find.text('6/10'),
        );
        final focused = Focus.of(tester.element(ratingCaption));
        focused.requestFocus();
        await tester.pump();
        expect(focused.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('6 /10'), findsOneWidget);
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(account.requests, ['rated-anime']);
        expect(account.writes, isEmpty);
        expect(route, findsOneWidget);
        await tester.tap(find.byType(AppleLiquidGlassBackButton));
        await tester.pumpAndSettle();
        expect(find.text(_open), findsOneWidget);
        print('C26_DETAIL_RATINGS ${size.width} rgba=${hashes.join(",")}');
      },
    );
  }
}
