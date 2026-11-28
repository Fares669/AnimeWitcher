import 'dart:convert';

import 'package:animewitcher/core/account/anime3rb_account_models.dart';
import 'package:animewitcher/core/account/anime3rb_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_transport.dart';
import 'package:animewitcher/core/storage/anime3rb_library_service.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/details_ratings.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_ratings_row.dart';
import 'package:animewitcher/features/settings/presentation/widgets/anime3rb_account_section.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

class _FakeAccountBackend implements Anime3rbAccountBackend {
  Anime3rbProfile profile = const Anime3rbProfile(
    accountId: '99',
    userSlug: 'tester',
    displayName: 'Tester',
  );

  @override
  Future<Anime3rbProfile?> fetchProfile(String sessionCookie) async =>
      sessionCookie.trim().isEmpty ? null : profile;

  @override
  Future<List<Anime3rbNotificationItem>> fetchNotifications(
    String sessionCookie,
  ) async => const <Anime3rbNotificationItem>[];

  @override
  Future<({bool blocked, String? blockedMessage, List<Anime3rbReportIssueOption> issues, List<Anime3rbReportScopeOption> scopes})>
  fetchReportForm({
    required String sessionCookie,
    required Uri episodeUri,
  }) async => const (
    issues: <Anime3rbReportIssueOption>[],
    scopes: Anime3rbReportScopeOption.defaults,
    blocked: false,
    blockedMessage: null,
  );

  @override
  Future<void> logoutOtherBrowserSessions({
    required String sessionCookie,
    required String password,
  }) async {}

  @override
  Future<void> markNotificationsRead(String sessionCookie) async {}

  @override
  Future<void> signOut(String sessionCookie) async {}

  @override
  Future<void> submitEpisodeReport({
    required String sessionCookie,
    required Uri episodeUri,
    required int issueId,
    required String scope,
    String? videosNumbers,
    String message = '',
  }) async {}

  @override
  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String password,
    required String passwordConfirmation,
  }) async {}

  @override
  Future<Anime3rbProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    required String email,
  }) async => profile.copyWith(displayName: displayName, email: email);
}

class _LivewireStubTransport implements Anime3rbTransport {
  final List<({Uri uri, Map<String, dynamic> payload})> livewirePosts = [];
  String? currentList;
  int? currentRate;
  bool failNextPostTransient = false;
  bool failNextPostPermanent = false;

  static final _itemCard = '''
    <div class="title-card" data-title="one-piece" data-list="watching" data-rate="9">
      <a href="https://anime3rb.com/titles/one-piece">
        <img src="https://images.anime3rb.com/poster.jpg" alt="One Piece">
        <h2 class="title-name">One Piece</h2>
      </a>
    </div>
  ''';

  @override
  Future<Anime3rbHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) async {
    if (uri.path == '/titles/tester/watching') {
      return Anime3rbHttpResponse(
        statusCode: 200,
        finalUri: uri,
        body: '<div class="titles-list">$_itemCard</div>',
      );
    }
    if (uri.path == '/titles/tester/ratings') {
      return Anime3rbHttpResponse(
        statusCode: 200,
        finalUri: uri,
        body: '<div class="titles-list">$_itemCard</div>',
      );
    }
    if (uri.path.startsWith('/titles/tester/')) {
      return Anime3rbHttpResponse(
        statusCode: 200,
        finalUri: uri,
        body: '<div class="titles-list"></div>',
      );
    }
    final menuSnap = const HtmlEscape().convert(
      jsonEncode({
        'data': {'classes': ''},
        'memo': {'name': 'title.title-menus'},
      }),
    );
    return Anime3rbHttpResponse(
      statusCode: 200,
      finalUri: uri,
      body: '''
        <html>
          <head><meta name="csrf-token" content="csrf-abc"></head>
          <body>
            <form action="/logout"></form>
            <div class="title-card" data-title="one-piece" ${currentList != null ? 'data-list="$currentList"' : ''} ${currentRate != null ? 'data-rate="$currentRate"' : ''}></div>
            <div wire:name="title.title-menus" wire:snapshot="$menuSnap"></div>
            <script data-update-uri="https://anime3rb.com/livewire-daa1cdb1/update"></script>
          </body>
        </html>
      ''',
    );
  }

  @override
  Future<Anime3rbHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) async {
    if (failNextPostTransient) {
      failNextPostTransient = false;
      return const Anime3rbHttpResponse(statusCode: 503, body: 'busy');
    }
    if (failNextPostPermanent) {
      failNextPostPermanent = false;
      return const Anime3rbHttpResponse(
        statusCode: 422,
        body: '{"message":"تقييم غير صالح"}',
      );
    }
    final decoded = jsonDecode(body as String) as Map<String, dynamic>;
    livewirePosts.add((uri: uri, payload: decoded));
    final comps = decoded['components'] as List;
    final calls = (comps.first as Map)['calls'] as List;
    final call = calls.first as Map;
    final method = call['method']?.toString();
    final params = call['params'] as List;
    if (method == 'addToList') {
      currentList = params[1]?.toString();
      return Anime3rbHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'components': [
            {
              'snapshot': '{}',
              'effects': {
                'returns': [
                  {'list': currentList, 'html': ''},
                ],
              },
            },
          ],
        }),
      );
    }
    if (method == 'rate') {
      currentRate = params[1] as int?;
      return Anime3rbHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'components': [
            {
              'snapshot': '{}',
              'effects': {
                'returns': [
                  {'rate': currentRate, 'html': ''},
                ],
              },
            },
          ],
        }),
      );
    }
    return const Anime3rbHttpResponse(statusCode: 404, body: '{}');
  }

  @override
  Future<Anime3rbHttpResponse> put(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'put',
  }) async => const Anime3rbHttpResponse(statusCode: 404, body: '');

  @override
  Future<Anime3rbHttpResponse> delete(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'delete',
  }) async => const Anime3rbHttpResponse(statusCode: 404, body: '');

  @override
  Future<String> fetchHtml(
    Uri uri, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async => (await get(uri, headers: headers)).body;

  @override
  void close({bool force = false}) {}
}

class _MemoryTokenStorage extends SecureTokenStorage {
  _MemoryTokenStorage(super.fallback);

  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class _LocalLibraryStorage extends MemoryStorageService {
  final Map<String, String> _witcherCategories = <String, String>{};

  @override
  String? getLibraryItemCategory(String url) => _witcherCategories[url];

  @override
  Future<void> setLibraryItemCategory(String url, String? category) async {
    if (category == null) {
      _witcherCategories.remove(url);
    } else {
      _witcherCategories[url] = category;
    }
  }
}

void main() {
  final onePiece = MultimediaItem(
    title: 'One Piece',
    url: 'https://anime3rb.com/titles/one-piece',
    posterUrl: 'https://images.anime3rb.com/poster.jpg',
    provider: Anime3rbProvider.id,
    score: 8.9,
  );

  test('HttpAnime3rbLibraryBackend pulls all 5 shelves + ratings and invokes Livewire addToList/rate', () async {
    final transport = _LivewireStubTransport();
    final backend = HttpAnime3rbLibraryBackend(transport);

    final pulled = await backend.fetchLibrary(
      sessionCookie: 's=1',
      userSlug: 'tester',
    );
    expect(pulled.shelves[LibraryCategory.watching], hasLength(1));
    expect(pulled.shelves[LibraryCategory.watching]!.single.url, onePiece.url);
    expect(pulled.ratings[onePiece.url]?.rating, 9);

    final updatedList = await backend.setCategory(
      sessionCookie: 's=1',
      workUrl: onePiece.url,
      category: LibraryCategory.continueLater,
    );
    expect(updatedList, LibraryCategory.continueLater);
    expect(
      transport.livewirePosts.last.uri.toString(),
      'https://anime3rb.com/livewire-daa1cdb1/update',
    );
    final call1 =
        ((transport.livewirePosts.last.payload['components'] as List).first
                as Map)['calls']
            as List;
    expect((call1.first as Map)['params'], ['one-piece', 'on-hold']);

    final savedRate = await backend.setRating(
      sessionCookie: 's=1',
      workUrl: onePiece.url,
      rating: 10,
    );
    expect(savedRate, 10);
  });

  test('Anime3rb shelves keep order and fresh isolated cards across writes and accounts', () async {
    final storage = _LocalLibraryStorage();
    final accountBackend = _FakeAccountBackend();
    final account = Anime3rbAccountService(
      tokenStorage: _MemoryTokenStorage(storage),
      backend: accountBackend,
    );
    final service = Anime3rbLibraryService(
      storage: storage,
      accountService: account,
      backend: HttpAnime3rbLibraryBackend(_LivewireStubTransport()),
    );
    addTearDown(service.dispose);
    addTearDown(account.dispose);
    await account.completeBrowserAuth(sessionCookie: 'fixture=first');
    String key(String id) =>
        'anime3rb_lib_v1:${base64Url.encode(utf8.encode(id))}';
    Map<String, dynamic> card(String name, int stamp, {bool favorite = true}) =>
        {
          'item': {
            'title': '$name &amp;lt;',
            'url': 'https://anime3rb.com/titles/$name',
            'posterUrl': '',
            'headers': {'x-fixture': 'unchanged'},
            'tags': ['fixture'],
            'episodes': [
              {
                'name': 'Episode',
                'url': 'https://example.test/synthetic',
                'headers': {'x-fixture': 'nested unchanged'},
              },
            ],
          },
          'category': 'watching',
          'favorite': favorite,
          'updatedAtMillis': stamp,
        };
    final tieFirst = card('tie-first', 10);
    final tieNext = card('tie-next', 10, favorite: false);
    final recent = card('latest', 14);
    String snapshot() => jsonEncode({
      'tie-first': tieFirst,
      'tie-next': tieNext,
      'latest': recent,
    });
    List<String> urls(List<MultimediaItem> cards) => [
      for (final item in cards) item.url.split('/').last,
    ];
    const watching = LibraryCategory.watching;
    const favorite = LibraryCategory.favorite;
    await storage.setString(key('99'), snapshot());
    expect(urls(service.itemsForCategory(watching)), [
      'latest',
      'tie-first',
      'tie-next',
    ]);
    final delivered = service.itemsForCategory(favorite);
    expect(urls(delivered), ['latest', 'tie-first']);
    expect(service.countForCategory(watching), 3);
    expect(
      delivered.first.title,
      MultimediaItem.fromJson(recent['item'] as Map<String, dynamic>).title,
    );
    delivered.first.headers!['x-fixture'] = 'changed';
    delivered.first.tags!.clear();
    delivered.first.episodes!.single.headers!['x-fixture'] = 'changed';
    delivered.clear();
    final fresh = service.itemsForCategory(favorite);
    expect(urls(fresh), ['latest', 'tie-first']);
    expect(fresh.first.headers!['x-fixture'], 'unchanged');
    expect(
      fresh.first.episodes!.single.headers!['x-fixture'],
      'nested unchanged',
    );
    expect(fresh.first.tags, ['fixture']);

    await storage.setString(
      key('99'),
      jsonEncode({'older': card('older', 30)}),
    );
    expect(urls(service.itemsForCategory(watching)), ['older']);
    await storage.setString(key('99'), '{invalid');
    expect(service.itemsForCategory(watching), isEmpty);
    await storage.setString(
      key('99'),
      jsonEncode({
        'valid': card('valid', 30),
        'bad': {
          'item': {'title': 7},
        },
      }),
    );
    expect(service.itemsForCategory(favorite), isEmpty);
    await storage.setString(key('99'), snapshot());

    // Re-authentication happens between reads, with identical bytes/UID.
    expect(urls(service.itemsForCategory(watching)), [
      'latest',
      'tie-first',
      'tie-next',
    ]);
    await account.signOut(notifyRemote: false);
    await account.completeBrowserAuth(sessionCookie: 'fixture=relogin');
    expect(urls(service.itemsForCategory(watching)), [
      'latest',
      'tie-first',
      'tie-next',
    ]);
    await storage.setString(
      key('100'),
      jsonEncode({'second': card('second-account', 1)}),
    );

    await account.signOut(notifyRemote: false);
    expect(service.itemsForCategory(watching), isEmpty);
    accountBackend.profile = const Anime3rbProfile(
      accountId: '100',
      userSlug: 'tester-two',
      displayName: 'Fixture Two',
    );
    await account.completeBrowserAuth(sessionCookie: 'fixture=second');
    expect(urls(service.itemsForCategory(watching)), ['second-account']);
    await storage.setString(key('100'), null);
    expect(service.itemsForCategory(watching), isEmpty);
  });

  test('Anime3rbLibraryService supports optimistic sync, outbox retry, rollback, and Witcher isolation', () async {
    final storage = _LocalLibraryStorage();
    await storage.setLibraryItemCategory(
      'https://animewitcher.com/anime/99',
      LibraryCategory.completed.storageKey,
    );

    final transport = _LivewireStubTransport();
    final accountService = Anime3rbAccountService(
      tokenStorage: _MemoryTokenStorage(storage),
      backend: _FakeAccountBackend(),
    );
    await accountService.completeBrowserAuth(sessionCookie: 's=1');

    final service = Anime3rbLibraryService(
      storage: storage,
      accountService: accountService,
      backend: HttpAnime3rbLibraryBackend(transport),
    );

    await service.refreshListsFromServer();
    expect(
      service.itemsForCategory(LibraryCategory.watching).single.url,
      onePiece.url,
    );
    expect(service.cachedUserRating(onePiece.url), 9);

    // Transient error queues pending category mutation and retries later.
    transport.failNextPostTransient = true;
    await service.setCategory(onePiece, LibraryCategory.notInterested);
    expect(
      service.cachedMembership(onePiece.url)?.category,
      LibraryCategory.notInterested,
    );
    expect(service.isItemPending(onePiece.url), isTrue);

    await service.retryPendingSync();
    expect(service.isItemPending(onePiece.url), isFalse);
    expect(transport.currentList, 'dropped');

    // Permanent rejection rolls rating back cleanly.
    transport.failNextPostPermanent = true;
    await expectLater(
      () => service.setUserRating(onePiece, 3),
      throwsA(isA<Anime3rbPermanentRejectionException>()),
    );
    expect(service.cachedUserRating(onePiece.url), 9);

    // Local Witcher storage remains untouched.
    expect(
      storage.getLibraryItemCategory('https://animewitcher.com/anime/99'),
      LibraryCategory.completed.storageKey,
    );

    await service.wipeLocalSessionData();
    expect(service.itemsForCategory(LibraryCategory.notInterested), isEmpty);
    expect(
      storage.getLibraryItemCategory('https://animewitcher.com/anime/99'),
      LibraryCategory.completed.storageKey,
    );
  });

  test('AnimeDetailsRatings enables rating for Anime3rb without Witcher id', () {
    final ratings = AnimeDetailsRatings.fromItem(onePiece);
    expect(ratings.isAnime3rb, isTrue);
    expect(ratings.canRate, isTrue);
    expect(ratings.witcherScore, 8.9);
  });

  testWidgets('Anime3rbAccountSection and DetailsRatingsRow render Anime3rb controls cleanly', (tester) async {
    final storage = _LocalLibraryStorage();
    final accountService = Anime3rbAccountService(
      tokenStorage: _MemoryTokenStorage(storage),
      backend: _FakeAccountBackend(),
    );
    final libraryService = Anime3rbLibraryService(
      storage: storage,
      accountService: accountService,
      backend: HttpAnime3rbLibraryBackend(_LivewireStubTransport()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          anime3rbAccountServiceProvider.overrideWithValue(accountService),
          anime3rbLibraryServiceProvider.overrideWithValue(libraryService),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          home: Scaffold(
            body: ListView(
              children: [
                const Anime3rbAccountSection(),
                DetailsRatingsRow(item: onePiece),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('تسجيل الدخول إلى Anime3rb'), findsOneWidget);
    expect(find.text('تقييم أنمي عرب'), findsOneWidget);
    expect(find.text('التعليقات'), findsOneWidget);

    await tester.runAsync(
      () => accountService.completeBrowserAuth(sessionCookie: 's=1'),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Tester (@tester)'), findsOneWidget);
  });
}
