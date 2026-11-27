import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/features/search/presentation/widgets/phone_suggestion_box.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_result_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// Use the same Material compatibility types as SearchScreen.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

const _oldQuery = 'old title';
const _newQuery = 'new title';
const _mediaIndexes = ['series', 'all_animation', 'manga_views_desc'];
const _indexes = [..._mediaIndexes, 'characters'];
const _rowsPerMedia = 12;
const _jsonHeaders = <String, List<String>>{
  Headers.contentTypeHeader: ['application/json'],
};

/// The body has started, including headers and a JSON prefix. Dio must cancel
/// the subscription rather than simply ignoring the already parsed result.
class _HeldBody {
  _HeldBody(this.index, this.token) {
    _controller = StreamController<Uint8List>(
      onListen: () {
        started = true;
        _controller.add(Uint8List.fromList(utf8.encode('{"hits":')));
      },
      onCancel: () {
        if (!completed) aborted = true;
      },
    );
  }

  final String index;
  final CancelToken? token;
  late final StreamController<Uint8List> _controller;
  bool started = false;
  bool completed = false;
  bool aborted = false;

  ResponseBody get stream =>
      ResponseBody(_controller.stream, 200, headers: _jsonHeaders);

  void release() {
    if (_controller.isClosed) return;
    if (!aborted) {
      completed = true;
      _controller.add(
        Uint8List.fromList(
          utf8.encode('${jsonEncode(_hits('Expired', index))},"nbPages":1}'),
        ),
      );
    }
    unawaited(_controller.close());
  }
}

List<Map<String, Object>> _hits(String title, String index) => [
  for (var i = 0; i < (index == 'characters' ? 1 : _rowsPerMedia); i++)
    {'objectID': '$title-$index-$i', 'name': '$title $index $i', 'likes': i},
];

class _OfflineCatalogApi implements HttpClientAdapter {
  final held = <_HeldBody>[];
  final later = <(String, String, CancelToken?)>[];
  final unexpected = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    if (uri.path.endsWith('/Settings/constants')) {
      return ResponseBody.fromString(
        '{"fields":{"load_servers_type":{"stringValue":"fixture"}}}',
        200,
        headers: _jsonHeaders,
      );
    }
    if (uri.path.endsWith('/services/search')) {
      return ResponseBody.fromString('{}', 200, headers: _jsonHeaders);
    }
    final parts = uri.pathSegments;
    if (!uri.host.endsWith('.algolia.net') ||
        parts.length != 4 ||
        parts[1] != 'indexes' ||
        !_indexes.contains(parts[2])) {
      // The initial, empty character browse reads service configuration; it
      // isn't part of the held nonempty search below.
      if (uri.path.contains('/documents/')) {
        return ResponseBody.fromString('{}', 200, headers: _jsonHeaders);
      }
      unexpected.add(uri);
      return ResponseBody.fromString('{}', 400, headers: _jsonHeaders);
    }
    final index = parts[2];
    final body = options.data as Map<String, dynamic>;
    final query = Uri.splitQueryString(body['params'] as String)['query'];
    if (query == _oldQuery && !held.any((request) => request.index == index)) {
      final request = _HeldBody(index, options.cancelToken);
      held.add(request);
      return request.stream;
    }
    if (query != null && query.isNotEmpty) {
      later.add((query, index, options.cancelToken));
    }
    // One failed category should not discard the other instant suggestions.
    if (query == _newQuery && index == 'manga_views_desc') {
      return ResponseBody.fromString('{}', 400, headers: _jsonHeaders);
    }
    return ResponseBody.fromString(
      jsonEncode({
        'hits': query == null || query.isEmpty
            ? const <Map<String, Object>>[]
            : _hits('Current', index),
        'nbPages': 1,
      }),
      200,
      headers: _jsonHeaders,
    );
  }

  @override
  void close({bool force = false}) {
    for (final body in held) {
      body.release();
    }
  }
}

class _ObservedNative extends AnimeWitcherNativeProvider {
  _ObservedNative(Dio dio, StorageService storage)
    : super(
        dio,
        SettingsRepository(storage),
        algoliaSearchApiKey: 'synthetic-offline-fixture-only',
      );

  final expiredMappedRows = <String, int>{};

  Future<ProviderMediaPage> _observe(
    String index,
    Future<ProviderMediaPage> read,
  ) async {
    final page = await read;
    expiredMappedRows[index] =
        (expiredMappedRows[index] ?? 0) +
        page.items.where((item) => item.title.startsWith('Expired')).length;
    return page;
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) => _observe(
    'series',
    super.searchPage(
      query,
      filters,
      offset: offset,
      limit: limit,
      cancelToken: cancelToken,
    ),
  );

  @override
  Future<ProviderMediaPage> searchAnimationPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) => _observe(
    'all_animation',
    super.searchAnimationPage(
      query,
      filters,
      offset: offset,
      limit: limit,
      cancelToken: cancelToken,
    ),
  );

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) => _observe(
    'manga_views_desc',
    super.searchMangaPage(
      query,
      filters,
      offset: offset,
      limit: limit,
      cancelToken: cancelToken,
    ),
  );
}

class _Manager extends ExtensionManager {
  _Manager(this.source);
  final AnimeWitcherProvider source;

  @override
  List<AnimeWitcherProvider> build() => [source];
}

class _OfflineArtwork extends ArtworkFallbackService {
  _OfflineArtwork(super.dio, super.storage);

  @override
  Future<({String? cover, String? banner})> mangaArtwork({
    int? malId,
    String title = '',
  }) async => (cover: null, banner: null);
}

class _IgnoresCancellation extends _ObservedNative {
  _IgnoresCancellation(super.dio, super.storage, this.packageName);

  @override
  final String packageName;
  final calls = <(CancelToken?, Completer<List<MultimediaItem>>)>[];

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) {
    final result = Completer<List<MultimediaItem>>();
    calls.add((cancelToken, result));
    return result.future;
  }

  @override
  Future<ProviderCharacterPage> searchCharacterPage(
    String query, {
    int page = 0,
  }) async => ProviderCharacterPage(
    items: [Actor(name: 'Current character', id: 'current')],
    page: page,
    hasMore: false,
  );
}

class _ActiveSelection extends ActiveProvider {
  _ActiveSelection(this.initial);
  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider? build() => initial;
  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

enum _Reset { clear, shortQuery, account, domain, provider, dispose }

MultimediaItem _item(String title) => MultimediaItem(
  url: 'https://fixture.invalid/$title',
  title: title,
  posterUrl: '',
  contentType: MultimediaContentType.anime,
);

void main() {
  for (final submit in [false, true]) {
    testWidgets(
      submit
          ? 'submitting releases stale suggestion bodies, not the submitted query'
          : 'typing a replacement releases stale suggestion bodies',
      (tester) async {
        final oldPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(412, 760);
        addTearDown(() {
          debugDefaultTargetPlatformOverride = oldPlatform;
          tester.view.reset();
        });
        final storage = MemoryStorageService();
        final adapter = _OfflineCatalogApi();
        final dio = Dio()..httpClientAdapter = adapter;
        final native = _ObservedNative(dio, storage);
        addTearDown(() => dio.close(force: true));
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            artworkFallbackServiceProvider.overrideWithValue(
              _OfflineArtwork(dio, storage),
            ),
            extensionManagerProvider.overrideWith(() => _Manager(native)),
            activeProviderProvider.overrideWithValue(native),
            deviceProfileProvider.overrideWith(
              (_) async => const DeviceProfile(),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(searchDomainProvider.notifier).set(SearchDomain.all);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: SearchScreen(),
              locale: Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        final field = find.byType(TextField);
        await tester.enterText(field, _oldQuery);
        await tester.pump(const Duration(milliseconds: 349));
        expect(adapter.held, isEmpty);
        await pumpUntil(
          tester,
          () =>
              adapter.held.length == 4 &&
              adapter.held.every((body) => body.started),
          'all four suggestions have started streaming',
        );
        final staleMedia = adapter.held
            .where((body) => _mediaIndexes.contains(body.index))
            .toList();
        final staleCharacter = adapter.held.singleWhere(
          (body) => body.index == 'characters',
        );
        expect(staleMedia.map((body) => body.token).toSet(), hasLength(1));
        expect(staleMedia.first.token, isNotNull);
        expect(staleCharacter.token, isNull);

        if (submit) {
          // This submits the exact same text while its instant result is live.
          await tester.testTextInput.receiveAction(TextInputAction.search);
        } else {
          await tester.enterText(field, _newQuery);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(staleMedia.where((body) => body.aborted), hasLength(3));
        expect(staleMedia.where((body) => body.completed), isEmpty);
        expect(staleCharacter.aborted, isFalse);

        final query = submit ? _oldQuery : _newQuery;
        await pumpUntil(
          tester,
          () => adapter.later.where((call) => call.$1 == query).length == 4,
          'separate current search for all four categories',
        );
        final currentMedia = adapter.later.where(
          (call) => call.$1 == query && _mediaIndexes.contains(call.$2),
        );
        expect(currentMedia, hasLength(3));
        expect(
          currentMedia.every(
            (call) =>
                !identical(call.$3, staleMedia.first.token) &&
                call.$3?.isCancelled != true,
          ),
          isTrue,
        );

        if (submit) {
          await pumpUntil(
            tester,
            () =>
                !container.read(searchPagedResultsProvider).isLoading &&
                container.read(searchPagedResultsProvider).results.length == 3,
            'the currently submitted results',
          );
          expect(find.byType(SearchResultSection), findsWidgets);
          expect(find.byType(PhoneSuggestionBox), findsNothing);
          final state = container.read(searchPagedResultsProvider);
          expect(
            state.results.map((group) => group.results.first.title),
            _mediaIndexes.map((index) => 'Current $index 0'),
          );
        } else {
          await pumpUntil(
            tester,
            () => !container.read(searchSuggestionControllerProvider).isLoading,
            'the current suggestions',
          );
          expect(find.byType(PhoneSuggestionBox), findsOneWidget);
          final state = container.read(searchSuggestionControllerProvider);
          expect(state.items.first.title, 'Current series 0');
          expect(state.animation.first.title, 'Current all_animation 0');
          expect(state.manga, isEmpty);
          expect(state.characters.single.name, 'Current characters 0');
        }

        for (final body in adapter.held) {
          body.release();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(staleCharacter.completed, isTrue);
        expect(staleMedia.where((body) => body.completed), isEmpty);
        expect(
          native.expiredMappedRows.values.fold(0, (n, rows) => n + rows),
          0,
        );
        expect(find.textContaining('Expired'), findsNothing);
        if (submit) {
          expect(
            container.read(searchSuggestionControllerProvider).hasResults,
            isFalse,
          );
          expect(
            container.read(searchPagedResultsProvider).characters.single.name,
            'Current characters 0',
          );
        } else {
          expect(
            container
                .read(searchSuggestionControllerProvider)
                .characters
                .single
                .name,
            'Current characters 0',
          );
        }
        expect(adapter.unexpected, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
  for (final reset in _Reset.values) {
    testWidgets('suggestion reset: ${reset.name}', (tester) async {
      final storage = MemoryStorageService();
      final dio = Dio()..httpClientAdapter = _OfflineCatalogApi();
      addTearDown(() => dio.close(force: true));
      final original = _IgnoresCancellation(dio, storage, 'offline.original');
      final alternate = _IgnoresCancellation(dio, storage, 'offline.alternate');
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(() => _Manager(original)),
          activeProviderProvider.overrideWith(() => _ActiveSelection(original)),
        ],
      );
      if (reset != _Reset.dispose) addTearDown(container.dispose);
      final subscription = container.listen(
        searchSuggestionControllerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      final controller = container.read(
        searchSuggestionControllerProvider.notifier,
      );
      controller.onQueryChanged(_oldQuery);
      await tester.pump(const Duration(milliseconds: 351));
      final (token, oldBody) = original.calls.single;
      expect(token, isNotNull);
      expect(token!.isCancelled, isFalse);

      switch (reset) {
        case _Reset.clear:
          controller.clear();
        case _Reset.shortQuery:
          controller.onQueryChanged('x');
        case _Reset.account:
          container.read(accountDataRevisionProvider.notifier).bump();
        case _Reset.domain:
          container
              .read(searchDomainProvider.notifier)
              .set(SearchDomain.characters);
        case _Reset.provider:
          await container.read(activeProviderProvider.notifier).set(alternate);
        case _Reset.dispose:
          container.dispose();
      }
      expect(token.isCancelled, isTrue);
      await tester.pump(const Duration(milliseconds: 351));
      final nextProvider = reset == _Reset.account
          ? original
          : reset == _Reset.provider
          ? alternate
          : null;
      if (nextProvider != null) {
        final (newToken, newBody) = nextProvider.calls.last;
        expect(newToken, isNotNull);
        expect(newToken, isNot(same(token)));
        expect(newToken!.isCancelled, isFalse);
        newBody.complete([_item('Current')]);
        await tester.pump();
      }

      // Like an adapter or WebView that cannot be interrupted, this fake
      // finishes despite the token. Its stale result must still be ignored.
      oldBody.complete([_item('Expired')]);
      await tester.pump();
      if (reset == _Reset.dispose) {
        expect(tester.takeException(), isNull);
        return;
      }
      final state = container.read(searchSuggestionControllerProvider);
      expect(state.isLoading, isFalse);
      if (nextProvider != null) {
        expect(state.items.single.title, 'Current');
      } else if (reset == _Reset.domain) {
        expect(state.items, isEmpty);
        expect(state.characters.single.name, 'Current character');
      } else {
        expect(state.hasResults, isFalse);
        expect(original.calls, hasLength(1));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
