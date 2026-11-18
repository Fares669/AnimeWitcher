import 'dart:convert';

import 'package:animewitcher/core/account/witanime_account_models.dart';
import 'package:animewitcher/core/account/witanime_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_transport.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/witanime_library_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

class _LibraryMemoryStorage extends MemoryStorageService {
  final Map<String, String> _categories = {};
  final Set<String> _favorites = {};
  String _selectedCategory = 'watching';

  @override
  String getSelectedLibraryCategory() => _selectedCategory;

  @override
  Future<void> setSelectedLibraryCategory(String category) async {
    _selectedCategory = category;
  }

  @override
  String? getLibraryItemCategory(String url) => _categories[url];

  @override
  Future<void> setLibraryItemCategory(String url, String? category) async {
    if (category == null) {
      _categories.remove(url);
    } else {
      _categories[url] = category;
    }
  }

  @override
  bool isLibraryItemFavorite(String url) => _favorites.contains(url);
}

class _MemoryTokenStorage extends SecureTokenStorage {
  _MemoryTokenStorage(super.legacy, {this.failWrite = false});

  final Map<String, String> values = <String, String>{};
  bool failWrite;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('Keychain unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _FakeAccountBackend implements WitanimeAccountBackend {
  final Map<String, WitanimeProfile> profilesByCookie = {};

  @override
  Future<WitanimeProfile?> fetchProfile(String sessionCookie) async =>
      profilesByCookie[sessionCookie];

  @override
  Future<void> signOut(String sessionCookie) async {}

  @override
  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {}

  @override
  Future<WitanimeProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    String? email,
    String? avatarUrl,
  }) async {
    final existing = profilesByCookie[sessionCookie]!;
    final updated = existing.copyWith(
      displayName: displayName,
      email: email ?? existing.email,
      avatarUrl: avatarUrl ?? existing.avatarUrl,
    );
    profilesByCookie[sessionCookie] = updated;
    return updated;
  }
}

class _FakeLibraryBackend implements WitanimeLibraryBackend {
  final Map<String, ({LibraryCategory? category, bool favorite})> remote = {};
  final List<WitanimeStoredLibraryEntry> remoteLists = [];
  bool offline = false;
  int? permanentErrorCode;
  Future<LibraryMembership?> Function()? overrideRead;

  @override
  Future<LibraryMembership?> fetchMembership({
    required String sessionCookie,
    required String workUrl,
  }) async {
    if (overrideRead != null) return overrideRead!();
    return remote[workUrl];
  }

  @override
  Future<List<WitanimeStoredLibraryEntry>> fetchLists({
    required String sessionCookie,
  }) async {
    if (offline) throw const WitanimeTransientSyncException('offline');
    return List<WitanimeStoredLibraryEntry>.from(remoteLists);
  }

  @override
  Future<void> setCategory({
    required String sessionCookie,
    required String workUrl,
    required LibraryCategory? category,
  }) async {
    if (permanentErrorCode != null) {
      throw WitanimePermanentRejectionException(
        'رفض خادم Witanime حفظ التعديل (HTTP $permanentErrorCode).',
        statusCode: permanentErrorCode,
      );
    }
    if (offline) throw const WitanimeTransientSyncException('offline');
    final existing = remote[workUrl];
    remote[workUrl] = (category: category, favorite: existing?.favorite ?? false);
  }

  @override
  Future<void> setFavorite({
    required String sessionCookie,
    required String workUrl,
    required bool favorite,
  }) async {
    if (permanentErrorCode != null) {
      throw WitanimePermanentRejectionException(
        'رفض خادم Witanime حفظ المفضلة (HTTP $permanentErrorCode).',
        statusCode: permanentErrorCode,
      );
    }
    if (offline) throw const WitanimeTransientSyncException('offline');
    final existing = remote[workUrl];
    remote[workUrl] = (category: existing?.category, favorite: favorite);
  }
}

void main() {
  test('Witanime profile HTML parser extracts counters and falls back to memory when storage fails', () async {
    const profileHtml = '''
    <main data-user-id="u-42">
      <h1 data-profile-name>أحمد</h1>
      <span data-profile-email>ahmed@example.com</span>
      <img data-profile-avatar src="/avatars/u42.png">
      <div data-count="watching">5</div>
      <div data-count="completed">12</div>
      <div data-count="plan_to_watch">8</div>
      <div data-count="favorites">3</div>
    </main>
    ''';
    final parsed = WitanimeProfile.fromProfileHtml(
      profileHtml,
      baseUri: Uri.https('witanime.site'),
    );
    expect(parsed, isNotNull);
    expect(parsed!.accountId, 'u-42');
    expect(parsed.displayName, 'أحمد');
    expect(parsed.avatarUrl, 'https://witanime.site/avatars/u42.png');
    expect(parsed.counts.watching, 5);
    expect(parsed.counts.completed, 12);
    expect(parsed.counts.planToWatch, 8);
    expect(parsed.counts.favorites, 3);

    final storage = MemoryStorageService();
    final tokens = _MemoryTokenStorage(storage, failWrite: true);
    final backend = _FakeAccountBackend()..profilesByCookie['sess-1'] = parsed;
    final opened = <Uri>[];
    final account = WitanimeAccountService(
      tokenStorage: tokens,
      backend: backend,
      openWebsite: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await account.beginOfficialAuth(
      WitanimeAuthAction.signIn,
      returnRoute: '/anime/one-piece',
    );
    expect(opened.single.toString(), 'https://witanime.site/login');

    final completed = await account.completeBrowserAuth(sessionCookie: 'sess-1');
    expect(completed.returnRoute, '/anime/one-piece');
    expect(account.isSignedIn, isTrue);
    expect(account.usingInMemorySessionFallback, isTrue);

    await account.signOut();
    expect(account.isSignedIn, isFalse);
  });

  test('Witanime library keeps favorite independent of list removal, guards stale reads, and retries offline mutations', () async {
    final storage = _LibraryMemoryStorage();
    await storage.setActiveProviderId(WitanimeProvider.id);
    final tokens = _MemoryTokenStorage(storage);
    final accountBackend = _FakeAccountBackend()
      ..profilesByCookie['cookie-a'] = const WitanimeProfile(
        accountId: 'acc-a',
        displayName: 'User A',
      )
      ..profilesByCookie['cookie-b'] = const WitanimeProfile(
        accountId: 'acc-b',
        displayName: 'User B',
      );
    final accountService = WitanimeAccountService(
      tokenStorage: tokens,
      backend: accountBackend,
    );
    await accountService.completeBrowserAuth(sessionCookie: 'cookie-a');

    final libBackend = _FakeLibraryBackend();
    final libService = WitanimeLibraryService(
      storage: storage,
      accountService: accountService,
      backend: libBackend,
    );
    final witanime = WitanimeProvider((_, {cancelToken}) async => '<main></main>');
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        secureTokenStorageProvider.overrideWithValue(tokens),
        witanimeAccountServiceProvider.overrideWithValue(accountService),
        witanimeLibraryServiceProvider.overrideWithValue(libService),
        witanimeCatalogProvider.overrideWithValue(witanime),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(libraryProvider.notifier);
    final anime = MultimediaItem(
      title: 'Sample',
      url: 'https://witanime.site/anime/sample',
      posterUrl: '',
      provider: WitanimeProvider.id,
      status: ShowStatus.completed,
    );

    // 1. Add to watching AND favorite -> verify independent removal
    await notifier.addItem(anime, category: LibraryCategory.watching);
    await notifier.setFavorite(anime, true);
    expect(notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.watching), 1);
    expect(notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.favorite), 1);

    await notifier.clearItemCategory(anime.url, providerId: WitanimeProvider.id);
    expect(notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.watching), 0);
    expect(notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.favorite), 1);
    expect(notifier.isFavorite(anime.url, providerId: WitanimeProvider.id), isTrue);

    // 2. Reverse: set category completed, remove favorite -> stays in completed
    await notifier.addItem(anime, category: LibraryCategory.completed);
    await notifier.setFavorite(anime, false);
    expect(notifier.itemCategory(anime.url, providerId: WitanimeProvider.id), LibraryCategory.completed);
    expect(notifier.isFavorite(anime.url, providerId: WitanimeProvider.id), isFalse);

    // 3. Offline mutation stays locally visible and queues pending sync
    libBackend.offline = true;
    await notifier.addItem(anime, category: LibraryCategory.planToWatch);
    expect(libService.isItemPending(anime.url), isTrue);
    expect(notifier.itemCategory(anime.url, providerId: WitanimeProvider.id), LibraryCategory.planToWatch);

    libBackend.offline = false;
    await libService.retryPendingSync();
    expect(libService.isItemPending(anime.url), isFalse);
    expect(libBackend.remote[anime.url]?.category, LibraryCategory.planToWatch);

    // 4. Permanent rejection rolls back to confirmed server state
    libBackend.permanentErrorCode = 422;
    await expectLater(
      notifier.addItem(anime, category: LibraryCategory.watching),
      throwsA(isA<WitanimePermanentRejectionException>()),
    );
    expect(notifier.itemCategory(anime.url, providerId: WitanimeProvider.id), LibraryCategory.planToWatch);
    libBackend.permanentErrorCode = null;

    // 5. Account switch isolates data and rejects stale responses
    await accountService.completeBrowserAuth(sessionCookie: 'cookie-b');
    expect(notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.planToWatch), 0);
  });

  test('HttpWitanimeLibraryBackend reads and mutates Witanime Livewire lists and favorites', () async {
    final calls = <Map<String, Object?>>[];
    final watchSnapshot = jsonEncode({
      'data': {
        'mediaId': 2319,
        'mediaType': 'anime',
        'status': 'watching',
        'isFavorite': true,
        'compact': false,
      },
      'memo': {'id': 'comp-watch', 'name': 'watchlist-button'},
      'checksum': 'chk-1',
    });
    final listsSnapshot = jsonEncode({
      'data': {'tab': 'watching', 'page': 1},
      'memo': {'id': 'comp-lists', 'name': 'my-anime-list'},
      'checksum': 'chk-lists',
    });

    final transport = _StubLivewireTransport((method, uri, body, headers) async {
      if (method == 'GET' && uri.path == '/anime/devils-crest') {
        return WitanimeHttpResponse(
          statusCode: 200,
          headers: const {
            'set-cookie': ['witanime_session=rotated-sess; Path=/'],
          },
          body: '''
            <html>
              <head><meta name="csrf-token" content="csrf-livewire"></head>
              <body>
                <div wire:id="comp-watch" wire:name="watchlist-button" wire:snapshot='${const HtmlEscape(HtmlEscapeMode.attribute).convert(watchSnapshot)}'></div>
                <script src="/livewire-747df6fe/livewire.min.js" data-update-uri="https://witanime.site/livewire-747df6fe/update"></script>
              </body>
            </html>
          ''',
        );
      }
      if (method == 'GET' && uri.path == '/profile/lists') {
        return WitanimeHttpResponse(
          statusCode: 200,
          body: '''
            <html>
              <head><meta name="csrf-token" content="csrf-lists"></head>
              <body>
                <div wire:id="comp-lists" wire:name="my-anime-list" wire:snapshot='${const HtmlEscape(HtmlEscapeMode.attribute).convert(listsSnapshot)}'>
                  <button wire:click="setTab('favorites')">المفضلة <span>1</span></button>
                  <button wire:click="setTab('watching')">أشاهده <span>1</span></button>
                  <button wire:click="setTab('completed')">أكملته <span>0</span></button>
                  <button wire:click="setTab('plan')">أنوي مشاهدته <span>0</span></button>
                  <div wire:key="grid-1">
                    <a href="https://witanime.site/anime/devils-crest">
                      <img src="https://images.witanime.site/posters/dc.jpg" alt="Devils' Crest">
                      <h3>Devils' Crest</h3>
                    </a>
                  </div>
                </div>
                <script src="/livewire-747df6fe/livewire.min.js" data-update-uri="https://witanime.site/livewire-747df6fe/update"></script>
              </body>
            </html>
          ''',
        );
      }
      if (method == 'POST' && uri.path == '/livewire-747df6fe/update') {
        final payload = jsonDecode(body as String) as Map<String, dynamic>;
        final comp = (payload['components'] as List).first as Map<String, dynamic>;
        final call = (comp['calls'] as List).first as Map<String, dynamic>;
        calls.add({
          'token': payload['_token'],
          'cookie': headers['Cookie'],
          'xLivewire': headers['X-Livewire'],
          'method': call['method'],
          'params': call['params'],
        });
        if (call['method'] == 'setTab') {
          return WitanimeHttpResponse(
            statusCode: 200,
            body: jsonEncode({
              'components': [
                {
                  'snapshot': listsSnapshot,
                  'effects': {
                    'html': '''
                      <div wire:name="my-anime-list">
                        <a href="https://witanime.site/anime/devils-crest">
                          <img src="https://images.witanime.site/posters/dc.jpg" alt="Devils' Crest">
                          <h3>Devils' Crest</h3>
                        </a>
                      </div>
                    ''',
                  },
                },
              ],
            }),
          );
        }
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '{"components":[{"snapshot":"{}","effects":{}}]}',
        );
      }
      return const WitanimeHttpResponse(statusCode: 404, body: '');
    });

    final backend = HttpWitanimeLibraryBackend(transport);

    final membership = await backend.fetchMembership(
      sessionCookie: 'witanime_session=initial',
      workUrl: 'https://witanime.site/anime/devils-crest',
    );
    expect(membership?.category, LibraryCategory.watching);
    expect(membership?.favorite, isTrue);

    await backend.setCategory(
      sessionCookie: 'witanime_session=initial',
      workUrl: 'https://witanime.site/anime/devils-crest',
      category: LibraryCategory.completed,
    );
    await backend.setCategory(
      sessionCookie: 'witanime_session=initial',
      workUrl: 'https://witanime.site/anime/devils-crest',
      category: null,
    );
    // Already true -> idempotent no-op.
    await backend.setFavorite(
      sessionCookie: 'witanime_session=initial',
      workUrl: 'https://witanime.site/anime/devils-crest',
      favorite: true,
    );
    // Toggling off calls toggleFavorite.
    await backend.setFavorite(
      sessionCookie: 'witanime_session=initial',
      workUrl: 'https://witanime.site/anime/devils-crest',
      favorite: false,
    );

    final lists = await backend.fetchLists(
      sessionCookie: 'witanime_session=initial',
    );
    expect(lists.length, 1);
    expect(lists.single.item.title, "Devils' Crest");
    expect(lists.single.category, LibraryCategory.watching);
    expect(lists.single.favorite, isTrue);

    expect(calls.map((c) => c['method']).toList(), [
      'setStatus',
      'removeFromList',
      'toggleFavorite',
      'setTab',
    ]);
    expect(calls[0]['params'], ['completed']);
    expect(calls[0]['cookie'], 'witanime_session=rotated-sess');
    expect(calls[0]['xLivewire'], '1');
    expect(calls[3]['params'], ['favorites']);
  });
}

class _StubLivewireTransport implements WitanimeTransport {
  _StubLivewireTransport(this.handler);

  final Future<WitanimeHttpResponse> Function(
    String method,
    Uri uri,
    Object? body,
    Map<String, String> headers,
  )
  handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<String> fetchHtml(
    Uri uri, {
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async => (await get(uri, cancelToken: cancelToken, operation: operation)).body;

  @override
  Future<WitanimeHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) => handler('GET', uri, null, headers);

  @override
  Future<WitanimeHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) => handler('POST', uri, body, headers);
}
