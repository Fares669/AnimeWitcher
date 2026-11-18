import 'package:animewitcher/core/account/witanime_account_models.dart';
import 'package:animewitcher/core/account/witanime_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/witanime_library_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
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
}
