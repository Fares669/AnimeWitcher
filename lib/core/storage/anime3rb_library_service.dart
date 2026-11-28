import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;

import '../account/anime3rb_account_models.dart';
import '../account/anime3rb_account_service.dart';
import '../account/anime3rb_livewire.dart';
import '../domain/entity/multimedia_item.dart';
import '../extensions/providers/anime3rb_provider.dart';
import '../extensions/providers/anime3rb_transport.dart';
import 'library_category.dart';
import 'library_mutation_epochs.dart';
import 'storage_service.dart';

bool isAnime3rbSyncedCategory(LibraryCategory category) => switch (category) {
  LibraryCategory.watching ||
  LibraryCategory.completed ||
  LibraryCategory.continueLater ||
  LibraryCategory.notInterested ||
  LibraryCategory.planToWatch => true,
  LibraryCategory.favorite => false,
};

String? anime3rbCategorySlug(LibraryCategory? category) => switch (category) {
  LibraryCategory.watching => 'watching',
  LibraryCategory.completed => 'completed',
  LibraryCategory.continueLater => 'on-hold',
  LibraryCategory.notInterested => 'dropped',
  LibraryCategory.planToWatch => 'plan-to-watch',
  LibraryCategory.favorite || null => null,
};

LibraryCategory? libraryCategoryFromAnime3rbSlug(String? slug) =>
    switch (slug?.trim().toLowerCase()) {
      'watching' || 'أشاهده حاليا' || 'أشاهده حاليًا' => LibraryCategory.watching,
      'completed' ||
      'انهيت مشاهدته' ||
      'أنهيت مشاهدته' ||
      'تمت مشاهدته' => LibraryCategory.completed,
      'on-hold' ||
      'on_hold' ||
      'onhold' ||
      'سأكمله لاحقا' ||
      'أكملها لاحقًا' => LibraryCategory.continueLater,
      'dropped' ||
      'لن أكمله' ||
      'لا أرغب بمشاهدته' => LibraryCategory.notInterested,
      'plan-to-watch' ||
      'plan_to_watch' ||
      'سأشاهده لاحقا' ||
      'أرغب بمشاهدته' => LibraryCategory.planToWatch,
      _ => null,
    };

class Anime3rbPermanentRejectionException implements Exception {
  const Anime3rbPermanentRejectionException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class Anime3rbStoredLibraryEntry {
  const Anime3rbStoredLibraryEntry({
    required this.item,
    this.category,
    this.confirmedCategory,
    this.favorite = false,
    this.userRating,
    this.confirmedUserRating,
    this.updatedAtMillis = 0,
  });

  final MultimediaItem item;
  final LibraryCategory? category;
  final LibraryCategory? confirmedCategory;
  final bool favorite;
  final int? userRating;
  final int? confirmedUserRating;
  final int updatedAtMillis;

  Anime3rbStoredLibraryEntry copyWith({
    MultimediaItem? item,
    LibraryCategory? category,
    bool clearCategory = false,
    LibraryCategory? confirmedCategory,
    bool clearConfirmedCategory = false,
    bool? favorite,
    int? userRating,
    bool clearUserRating = false,
    int? confirmedUserRating,
    bool clearConfirmedUserRating = false,
    int? updatedAtMillis,
  }) => Anime3rbStoredLibraryEntry(
    item: item ?? this.item,
    category: clearCategory ? null : (category ?? this.category),
    confirmedCategory: clearConfirmedCategory
        ? null
        : (confirmedCategory ?? this.confirmedCategory),
    favorite: favorite ?? this.favorite,
    userRating: clearUserRating ? null : (userRating ?? this.userRating),
    confirmedUserRating: clearConfirmedUserRating
        ? null
        : (confirmedUserRating ?? this.confirmedUserRating),
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'item': item.toJson(),
    if (category != null) 'category': category!.storageKey,
    if (confirmedCategory != null)
      'confirmedCategory': confirmedCategory!.storageKey,
    'favorite': favorite,
    if (userRating != null) 'userRating': userRating,
    if (confirmedUserRating != null)
      'confirmedUserRating': confirmedUserRating,
    'updatedAtMillis': updatedAtMillis,
  };

  static Anime3rbStoredLibraryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final rawItem = map['item'];
    if (rawItem is! Map) return null;
    final item = MultimediaItem.fromJson(Map<String, dynamic>.from(rawItem));
    LibraryCategory? decodeCat(Object? value) {
      final rawStr = value?.toString().trim() ?? '';
      if (rawStr.isEmpty) return null;
      return libraryCategoryFromAnime3rbSlug(rawStr) ??
          LibraryCategory.fromStorageKey(rawStr);
    }

    int? decodeRate(Object? value) {
      if (value == null) return null;
      final parsed = value is num
          ? value.toInt()
          : int.tryParse(value.toString().trim());
      if (parsed == null || parsed < 1 || parsed > 10) return null;
      return parsed;
    }

    return Anime3rbStoredLibraryEntry(
      item: item,
      category: decodeCat(map['category']),
      confirmedCategory: decodeCat(map['confirmedCategory']),
      favorite: map['favorite'] == true,
      userRating: decodeRate(map['userRating']),
      confirmedUserRating: decodeRate(map['confirmedUserRating']),
      updatedAtMillis: (map['updatedAtMillis'] is num)
          ? (map['updatedAtMillis'] as num).toInt()
          : int.tryParse(map['updatedAtMillis']?.toString() ?? '') ?? 0,
    );
  }
}

class Anime3rbPendingMutation {
  const Anime3rbPendingMutation({
    required this.workUrl,
    required this.item,
    required this.field,
    this.category,
    this.userRating,
    required this.updatedAtMillis,
  });

  final String workUrl;
  final MultimediaItem item;

  /// `'category'` or `'rating'`.
  final String field;
  final LibraryCategory? category;
  final int? userRating;
  final int updatedAtMillis;

  Map<String, Object?> toJson() => <String, Object?>{
    'workUrl': workUrl,
    'item': item.toJson(),
    'field': field,
    if (category != null) 'category': category!.storageKey,
    if (userRating != null) 'userRating': userRating,
    'updatedAtMillis': updatedAtMillis,
  };

  static Anime3rbPendingMutation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final workUrl = map['workUrl']?.toString().trim() ?? '';
    final field = map['field']?.toString().trim() ?? '';
    final rawItem = map['item'];
    if (workUrl.isEmpty ||
        (field != 'category' && field != 'rating') ||
        rawItem is! Map) {
      return null;
    }
    final catRaw = map['category']?.toString().trim() ?? '';
    final category = catRaw.isEmpty
        ? null
        : (libraryCategoryFromAnime3rbSlug(catRaw) ??
              LibraryCategory.fromStorageKey(catRaw));
    final rateRaw = map['userRating'];
    final rate = rateRaw is num
        ? rateRaw.toInt()
        : int.tryParse(rateRaw?.toString() ?? '');
    return Anime3rbPendingMutation(
      workUrl: workUrl,
      item: MultimediaItem.fromJson(Map<String, dynamic>.from(rawItem)),
      field: field,
      category: category,
      userRating: (rate != null && rate >= 1 && rate <= 10) ? rate : null,
      updatedAtMillis: (map['updatedAtMillis'] is num)
          ? (map['updatedAtMillis'] as num).toInt()
          : int.tryParse(map['updatedAtMillis']?.toString() ?? '') ?? 0,
    );
  }
}

class Anime3rbRemoteShelfSnapshot {
  const Anime3rbRemoteShelfSnapshot({
    required this.shelves,
    required this.ratings,
  });

  final Map<LibraryCategory, List<MultimediaItem>> shelves;
  final Map<String, ({MultimediaItem item, int rating})> ratings;
}

abstract interface class Anime3rbLibraryBackend {
  Future<Anime3rbRemoteShelfSnapshot> fetchLibrary({
    required String sessionCookie,
    required String userSlug,
  });

  Future<({LibraryCategory? category, int? userRating})?> fetchTitleState({
    required String sessionCookie,
    required String workUrl,
  });

  Future<LibraryCategory?> setCategory({
    required String sessionCookie,
    required String workUrl,
    required LibraryCategory? category,
  });

  Future<int?> setRating({
    required String sessionCookie,
    required String workUrl,
    required int? rating,
  });
}

class HttpAnime3rbLibraryBackend implements Anime3rbLibraryBackend {
  HttpAnime3rbLibraryBackend(this._transport, {Uri? origin})
    : _origin = origin ?? Uri.parse(Anime3rbProvider.originUrl);

  final Anime3rbTransport _transport;
  final Uri _origin;

  static const int _maxPagesPerShelf = 5;

  Map<String, String> _cookieHeaders(String cookie) => cookie.trim().isEmpty
      ? const <String, String>{}
      : <String, String>{'Cookie': cookie.trim()};

  Future<({List<MultimediaItem> items, Map<String, int> cardRatings})>
  _fetchShelfPageLoop({
    required String sessionCookie,
    required Uri initialUri,
    required String operation,
  }) async {
    final items = <String, MultimediaItem>{};
    final cardRatings = <String, int>{};
    var currentUri = initialUri;
    for (var page = 1; page <= _maxPagesPerShelf; page++) {
      final resp = await _transport.get(
        currentUri,
        headers: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          ..._cookieHeaders(sessionCookie),
        },
        operation: operation,
      );
      if (resp.statusCode == 401 ||
          resp.statusCode == 419 ||
          Anime3rbLivewireClient.isLoginUri(resp.finalUri)) {
        throw const Anime3rbAuthRequiredException();
      }
      if (!resp.isSuccess) {
        throw Anime3rbLivewireException(
          'Anime3rb HTTP ${resp.statusCode}',
          statusCode: resp.statusCode,
        );
      }
      final base = resp.finalUri ?? currentUri;
      final doc = html_parser.parse(resp.body);
      final parsed = Anime3rbProvider.parseTitleCardsFromDocument(doc, base);
      for (final card in doc.querySelectorAll('.title-card')) {
        final slug = card.attributes['data-title']?.trim() ?? '';
        final rawRate = card.attributes['data-rate']?.trim() ?? '';
        final parsedRate = int.tryParse(rawRate);
        if (parsedRate != null && parsedRate >= 1 && parsedRate <= 10) {
          final href = card
              .querySelector('a[href*="/titles/"]')
              ?.attributes['href']
              ?.trim();
          final workUrl = href != null
              ? Anime3rbProvider.canonicalWorkUrl(base.resolve(href).toString())
              : Anime3rbProvider.canonicalWorkUrl(
                  _origin.resolve('/titles/$slug').toString(),
                );
          cardRatings[workUrl] = parsedRate;
        }
      }
      for (final item in parsed) {
        items.putIfAbsent(Anime3rbLibraryService.canonicalWorkUrl(item.url), () => item);
      }
      final nextHref = doc
          .querySelector('a[rel="next"], nav[aria-label*="Pagination"] a[href*="page="]')
          ?.attributes['href']
          ?.trim();
      final nextUri = (nextHref != null && nextHref.isNotEmpty)
          ? base.resolve(nextHref)
          : null;
      if (nextUri == null || nextUri == currentUri || parsed.isEmpty) break;
      currentUri = nextUri;
    }
    return (items: items.values.toList(growable: false), cardRatings: cardRatings);
  }

  @override
  Future<Anime3rbRemoteShelfSnapshot> fetchLibrary({
    required String sessionCookie,
    required String userSlug,
  }) async {
    final shelves = <LibraryCategory, List<MultimediaItem>>{};
    final combinedRatings = <String, ({MultimediaItem item, int rating})>{};
    final slug = Uri.encodeComponent(userSlug.trim());

    for (final category in LibraryCategory.primaryValues) {
      final listSlug = anime3rbCategorySlug(category);
      if (listSlug == null) continue;
      final uri = _origin.resolve('/titles/$slug/$listSlug');
      final fetched = await _fetchShelfPageLoop(
        sessionCookie: sessionCookie,
        initialUri: uri,
        operation: 'library_pull_$listSlug',
      );
      shelves[category] = fetched.items;
      for (final item in fetched.items) {
        final workUrl = Anime3rbLibraryService.canonicalWorkUrl(item.url);
        final rate = fetched.cardRatings[workUrl];
        if (rate != null) {
          combinedRatings[workUrl] = (item: item, rating: rate);
        }
      }
    }

    final ratingsUri = _origin.resolve('/titles/$slug/ratings');
    final ratingsFetched = await _fetchShelfPageLoop(
      sessionCookie: sessionCookie,
      initialUri: ratingsUri,
      operation: 'library_pull_ratings',
    );
    for (final item in ratingsFetched.items) {
      final workUrl = Anime3rbLibraryService.canonicalWorkUrl(item.url);
      final rate =
          ratingsFetched.cardRatings[workUrl] ?? item.score?.round().clamp(1, 10);
      if (rate != null && rate >= 1 && rate <= 10) {
        combinedRatings[workUrl] = (item: item, rating: rate);
      }
    }

    return Anime3rbRemoteShelfSnapshot(
      shelves: shelves,
      ratings: combinedRatings,
    );
  }

  @override
  Future<({LibraryCategory? category, int? userRating})?> fetchTitleState({
    required String sessionCookie,
    required String workUrl,
  }) async {
    final link = Anime3rbProvider.parseCatalogLink(workUrl);
    if (link == null) return null;
    final resp = await _transport.get(
      link.work,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        ..._cookieHeaders(sessionCookie),
      },
      operation: 'library_title_state',
    );
    if (resp.statusCode == 401 || Anime3rbLivewireClient.isLoginUri(resp.finalUri)) {
      return null;
    }
    if (!resp.isSuccess) return null;
    final doc = html_parser.parse(resp.body);
    if (!Anime3rbLivewireClient.looksAuthenticatedDocument(
      doc,
      finalUri: resp.finalUri,
    )) {
      return null;
    }
    final card = doc.querySelector('.title-card[data-title]');
    if (card == null) return null;
    final listAttr = card.attributes['data-list']?.trim();
    final rateAttr = card.attributes['data-rate']?.trim();
    final parsedRate = int.tryParse(rateAttr ?? '');
    return (
      category: libraryCategoryFromAnime3rbSlug(listAttr),
      userRating: (parsedRate != null && parsedRate >= 1 && parsedRate <= 10)
          ? parsedRate
          : null,
    );
  }

  @override
  Future<LibraryCategory?> setCategory({
    required String sessionCookie,
    required String workUrl,
    required LibraryCategory? category,
  }) async {
    final link = Anime3rbProvider.parseCatalogLink(workUrl);
    final slug = Anime3rbProvider.slugFromUrl(workUrl);
    if (link == null || slug == null) {
      throw const Anime3rbPermanentRejectionException('رابط الأنمي غير صالح.');
    }
    final targetSlug = anime3rbCategorySlug(category);
    try {
      final result = await Anime3rbLivewireClient.callComponent(
        transport: _transport,
        pageUri: link.work,
        componentName: 'title.title-menus',
        method: 'addToList',
        params: <Object?>[slug, targetSlug],
        headers: _cookieHeaders(sessionCookie),
        operation: 'library_set_list',
      );
      if (result.returns.isNotEmpty && result.returns.first is Map) {
        final ret = Map<String, dynamic>.from(result.returns.first as Map);
        return libraryCategoryFromAnime3rbSlug(ret['list']?.toString());
      }
      return category;
    } on Anime3rbLivewireException catch (error) {
      if (error.permanent) {
        throw Anime3rbPermanentRejectionException(
          error.message,
          statusCode: error.statusCode,
        );
      }
      rethrow;
    }
  }

  @override
  Future<int?> setRating({
    required String sessionCookie,
    required String workUrl,
    required int? rating,
  }) async {
    final link = Anime3rbProvider.parseCatalogLink(workUrl);
    final slug = Anime3rbProvider.slugFromUrl(workUrl);
    if (link == null || slug == null) {
      throw const Anime3rbPermanentRejectionException('رابط الأنمي غير صالح.');
    }
    final bounded = (rating != null && rating >= 1 && rating <= 10)
        ? rating
        : null;
    try {
      final result = await Anime3rbLivewireClient.callComponent(
        transport: _transport,
        pageUri: link.work,
        componentName: 'title.title-menus',
        method: 'rate',
        params: <Object?>[slug, bounded],
        headers: _cookieHeaders(sessionCookie),
        operation: 'library_set_rate',
      );
      if (result.returns.isNotEmpty && result.returns.first is Map) {
        final ret = Map<String, dynamic>.from(result.returns.first as Map);
        final r = ret['rate'];
        if (r == null) return null;
        final parsed = r is num ? r.toInt() : int.tryParse(r.toString());
        return (parsed != null && parsed >= 1 && parsed <= 10) ? parsed : null;
      }
      return bounded;
    } on Anime3rbLivewireException catch (error) {
      if (error.permanent) {
        throw Anime3rbPermanentRejectionException(
          error.message,
          statusCode: error.statusCode,
        );
      }
      rethrow;
    }
  }
}

class Anime3rbLibraryService extends ChangeNotifier {
  Anime3rbLibraryService({
    required StorageService storage,
    required Anime3rbAccountService accountService,
    required Anime3rbLibraryBackend backend,
    DateTime Function()? now,
  }) : _storage = storage,
       _accountService = accountService,
       _backend = backend,
       _now = now ?? DateTime.now;

  final StorageService _storage;
  final Anime3rbAccountService _accountService;
  final Anime3rbLibraryBackend _backend;
  final DateTime Function() _now;

  final _epochs = LibraryMutationEpochs(canonicalWorkUrl);
  bool _isSyncing = false;
  String? _lastError;

  String? get _activeAccountId => _accountService.accountId;
  bool get isSyncing => _isSyncing;
  String? get lastError => _lastError;

  String _scopeHash(String accountId) => base64Url.encode(utf8.encode(accountId));
  String _entriesKey(String accountId) => 'anime3rb_lib_v1:${_scopeHash(accountId)}';
  String _pendingKey(String accountId) => 'anime3rb_pending_v1:${_scopeHash(accountId)}';

  static String canonicalWorkUrl(String url) =>
      Anime3rbProvider.canonicalWorkUrl(url);

  Map<String, Anime3rbStoredLibraryEntry> _readEntries(String accountId) =>
      _decodeEntries(_storage.getString(_entriesKey(accountId)));

  Map<String, Anime3rbStoredLibraryEntry> _decodeEntries(
    String? raw, {
    Map<String, Map<String, dynamic>>? itemJson,
  }) {
    if (raw == null || raw.isEmpty) {
      return <String, Anime3rbStoredLibraryEntry>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, Anime3rbStoredLibraryEntry>{};
      final result = <String, Anime3rbStoredLibraryEntry>{};
      for (final entry in decoded.entries) {
        final parsed = Anime3rbStoredLibraryEntry.fromJson(entry.value);
        if (parsed == null) continue;
        final key = entry.key.toString();
        result[key] = parsed;
        if (itemJson != null) {
          itemJson[key] = Map<String, dynamic>.from(
            (entry.value as Map)['item'] as Map,
          );
        }
      }
      return result;
    } catch (_) {
      return <String, Anime3rbStoredLibraryEntry>{};
    }
  }

  Future<void> _writeEntries(
    String accountId,
    Map<String, Anime3rbStoredLibraryEntry> entries,
  ) => _storage.setString(
    _entriesKey(accountId),
    jsonEncode({
      for (final entry in entries.entries) entry.key: entry.value.toJson(),
    }),
  );

  List<Anime3rbPendingMutation> _readPending(String accountId) {
    final raw = _storage.getString(_pendingKey(accountId));
    if (raw == null || raw.isEmpty) return <Anime3rbPendingMutation>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Anime3rbPendingMutation>[];
      return decoded
          .map(Anime3rbPendingMutation.fromJson)
          .whereType<Anime3rbPendingMutation>()
          .toList();
    } catch (_) {
      return <Anime3rbPendingMutation>[];
    }
  }

  Future<void> _writePending(
    String accountId,
    List<Anime3rbPendingMutation> items,
  ) => _storage.setString(
    _pendingKey(accountId),
    jsonEncode([for (final item in items) item.toJson()]),
  );

  Future<void> _upsertPending(
    String accountId,
    Anime3rbPendingMutation mutation,
  ) async {
    final pending = _readPending(accountId)
      ..removeWhere(
        (m) => m.workUrl == mutation.workUrl && m.field == mutation.field,
      )
      ..add(mutation);
    await _writePending(accountId, pending);
  }

  Future<void> _removePending(
    String accountId,
    String workUrl,
    String field,
  ) async {
    final pending = _readPending(accountId)
      ..removeWhere((m) => m.workUrl == workUrl && m.field == field);
    await _writePending(accountId, pending);
  }

  bool isItemPending(String url) {
    final accountId = _activeAccountId;
    if (accountId == null) return false;
    final key = canonicalWorkUrl(url);
    return _readPending(accountId).any((m) => m.workUrl == key);
  }

  LibraryMembership? cachedMembership(String url) {
    final accountId = _activeAccountId;
    if (accountId == null) return null;
    final entry = _readEntries(accountId)[canonicalWorkUrl(url)];
    if (entry == null) return null;
    return (category: entry.category, favorite: entry.favorite);
  }

  int? cachedUserRating(String url) {
    final accountId = _activeAccountId;
    if (accountId == null) return null;
    return _readEntries(accountId)[canonicalWorkUrl(url)]?.userRating;
  }

  // Weak keys keep the projection reachable only through its actual session.
  // Re-authentication uses a new key, even if the account ID and JSON match.
  final _shelfProjections = Expando<({
    String? raw,
    Map<LibraryCategory, List<Map<String, dynamic>>> shelves,
  })>();

  List<MultimediaItem> itemsForCategory(LibraryCategory category) {
    final accountId = _activeAccountId;
    if (accountId == null) return const <MultimediaItem>[];
    final session = _accountService.session;
    final owner = session?.accountId == accountId ? session : null;
    final raw = _storage.getString(_entriesKey(accountId));
    var snapshot = owner == null ? null : _shelfProjections[owner];
    if (snapshot == null || snapshot.raw != raw) {
      final itemJson = <String, Map<String, dynamic>>{};
      final entries = _decodeEntries(raw, itemJson: itemJson).entries.toList()
        ..sort(
          (a, b) => b.value.updatedAtMillis.compareTo(a.value.updatedAtMillis),
        );
      final shelves = <LibraryCategory, List<Map<String, dynamic>>>{};
      for (final entry in entries) {
        final row = itemJson[entry.key]!;
        final category = entry.value.category;
        if (category != null && category != LibraryCategory.favorite) {
          (shelves[category] ??= []).add(row);
        }
        if (entry.value.favorite) {
          (shelves[LibraryCategory.favorite] ??= []).add(row);
        }
      }
      snapshot = (raw: raw, shelves: shelves);
      if (owner != null) _shelfProjections[owner] = snapshot;
    }
    // Never hand out cached models: nested item collections remain independent
    // of both this read projection and the mutable merge/write path.
    return <MultimediaItem>[
      for (final row
          in snapshot.shelves[category] ?? const <Map<String, dynamic>>[])
        MultimediaItem.fromJson(row),
    ];
  }

  int countForCategory(LibraryCategory category) {
    final localCount = itemsForCategory(category).length;
    if (localCount > 0) return localCount;
    return _accountService.profile?.counts.countFor(category) ?? 0;
  }

  Anime3rbListCounts _computeCounts(
    Map<String, Anime3rbStoredLibraryEntry> entries,
  ) {
    var watching = 0;
    var completed = 0;
    var onHold = 0;
    var dropped = 0;
    var planToWatch = 0;
    var ratings = 0;
    for (final entry in entries.values) {
      switch (entry.category) {
        case LibraryCategory.watching:
          watching++;
        case LibraryCategory.completed:
          completed++;
        case LibraryCategory.continueLater:
          onHold++;
        case LibraryCategory.notInterested:
          dropped++;
        case LibraryCategory.planToWatch:
          planToWatch++;
        case LibraryCategory.favorite || null:
          break;
      }
      if (entry.userRating != null) ratings++;
    }
    return Anime3rbListCounts(
      watching: watching,
      completed: completed,
      onHold: onHold,
      dropped: dropped,
      planToWatch: planToWatch,
      ratings: ratings,
    );
  }

  Future<void> _updateCounts(String accountId) async {
    if (_accountService.accountId != accountId) return;
    final counts = _computeCounts(_readEntries(accountId));
    await _accountService.updateCachedCounts(counts);
  }

  Future<void> setCategory(
    MultimediaItem item,
    LibraryCategory? nextCategory, {
    LibraryMembership? previousMembership,
    VoidCallback? onLocalChanged,
  }) async {
    final session = _accountService.session;
    if (session == null) {
      throw const Anime3rbAuthRequiredException();
    }
    final accountId = session.accountId;
    final key = canonicalWorkUrl(item.url);
    _epochs.bump(accountId, key);
    final entries = _readEntries(accountId);
    final existing = entries[key];
    final previousConfirmed =
        existing?.confirmedCategory ?? previousMembership?.category;
    final keepFavorite =
        existing?.favorite ?? previousMembership?.favorite ?? false;
    final nowMillis = _now().millisecondsSinceEpoch;

    final nextNormalized =
        (nextCategory != null && isAnime3rbSyncedCategory(nextCategory))
        ? nextCategory
        : null;

    if (nextNormalized == null &&
        !keepFavorite &&
        existing?.userRating == null) {
      entries.remove(key);
    } else {
      entries[key] = (existing ?? Anime3rbStoredLibraryEntry(item: item))
          .copyWith(
            item: item,
            category: nextNormalized,
            clearCategory: nextNormalized == null,
            confirmedCategory: previousConfirmed,
            clearConfirmedCategory: previousConfirmed == null,
            favorite: keepFavorite,
            updatedAtMillis: nowMillis,
          );
    }
    await _writeEntries(accountId, entries);
    await _updateCounts(accountId);
    onLocalChanged?.call();
    notifyListeners();

    try {
      await _backend.setCategory(
        sessionCookie: session.sessionCookie,
        workUrl: key,
        category: nextNormalized,
      );
      if (_accountService.accountId != accountId) return;
      final refreshed = _readEntries(accountId);
      final current = refreshed[key];
      if (current != null) {
        refreshed[key] = current.copyWith(
          confirmedCategory: nextNormalized,
          clearConfirmedCategory: nextNormalized == null,
        );
        await _writeEntries(accountId, refreshed);
      }
      await _removePending(accountId, key, 'category');
      _lastError = null;
      notifyListeners();
    } on Anime3rbPermanentRejectionException catch (error) {
      if (_accountService.accountId == accountId) {
        final rollback = _readEntries(accountId);
        final current = rollback[key];
        if (current != null) {
          rollback[key] = current.copyWith(
            category: previousConfirmed,
            clearCategory: previousConfirmed == null,
            confirmedCategory: previousConfirmed,
            clearConfirmedCategory: previousConfirmed == null,
          );
          await _writeEntries(accountId, rollback);
        }
        await _removePending(accountId, key, 'category');
        await _updateCounts(accountId);
        _lastError = error.message;
        onLocalChanged?.call();
        notifyListeners();
      }
      rethrow;
    } on Anime3rbAuthRequiredException {
      await _accountService.signOut(notifyRemote: false);
      rethrow;
    } catch (error) {
      if (_accountService.accountId == accountId) {
        await _upsertPending(
          accountId,
          Anime3rbPendingMutation(
            workUrl: key,
            item: item,
            field: 'category',
            category: nextNormalized,
            updatedAtMillis: nowMillis,
          ),
        );
        _lastError = error.toString();
        notifyListeners();
      }
    }
  }

  Future<void> setFavorite(
    MultimediaItem item,
    bool favorite, {
    LibraryMembership? previousMembership,
    VoidCallback? onLocalChanged,
  }) async {
    final session = _accountService.session;
    if (session == null) {
      throw const Anime3rbAuthRequiredException();
    }
    final accountId = session.accountId;
    final key = canonicalWorkUrl(item.url);
    final entries = _readEntries(accountId);
    final existing = entries[key];
    final keepCategory =
        existing?.category ?? previousMembership?.category;
    final nowMillis = _now().millisecondsSinceEpoch;
    if (!favorite && keepCategory == null && existing?.userRating == null) {
      entries.remove(key);
    } else {
      entries[key] = (existing ?? Anime3rbStoredLibraryEntry(item: item))
          .copyWith(
            item: item,
            category: keepCategory,
            clearCategory: keepCategory == null,
            favorite: favorite,
            updatedAtMillis: nowMillis,
          );
    }
    await _writeEntries(accountId, entries);
    onLocalChanged?.call();
    notifyListeners();
  }

  Future<int?> loadUserRating(MultimediaItem item) async {
    final session = _accountService.session;
    if (session == null) return null;
    final key = canonicalWorkUrl(item.url);
    final cached = _readEntries(session.accountId)[key]?.userRating;
    if (cached != null) return cached;

    final sync = item.syncData ?? const <String, String>{};
    final fromSync = int.tryParse(sync['aw3rbUserRate'] ?? '');
    if (fromSync != null && fromSync >= 1 && fromSync <= 10) {
      await _cacheTitleState(
        session.accountId,
        item,
        category: libraryCategoryFromAnime3rbSlug(sync['aw3rbUserList']),
        userRating: fromSync,
      );
      return fromSync;
    }
    try {
      final state = await _backend.fetchTitleState(
        sessionCookie: session.sessionCookie,
        workUrl: key,
      );
      if (state != null && _accountService.accountId == session.accountId) {
        await _cacheTitleState(
          session.accountId,
          item,
          category: state.category,
          userRating: state.userRating,
        );
        return state.userRating;
      }
    } catch (_) {}
    return null;
  }

  Future<int?> setUserRating(
    MultimediaItem item,
    int? rating, {
    VoidCallback? onLocalChanged,
  }) async {
    final session = _accountService.session;
    if (session == null) {
      throw const Anime3rbAuthRequiredException();
    }
    final accountId = session.accountId;
    final key = canonicalWorkUrl(item.url);
    _epochs.bump(accountId, key);
    final bounded = (rating != null && rating >= 1 && rating <= 10)
        ? rating
        : null;
    final entries = _readEntries(accountId);
    final existing = entries[key];
    final previousConfirmed = existing?.confirmedUserRating ?? existing?.userRating;
    final nowMillis = _now().millisecondsSinceEpoch;

    if (bounded == null &&
        existing?.category == null &&
        existing?.favorite != true) {
      entries.remove(key);
    } else {
      entries[key] = (existing ?? Anime3rbStoredLibraryEntry(item: item))
          .copyWith(
            item: item,
            userRating: bounded,
            clearUserRating: bounded == null,
            confirmedUserRating: previousConfirmed,
            clearConfirmedUserRating: previousConfirmed == null,
            updatedAtMillis: nowMillis,
          );
    }
    await _writeEntries(accountId, entries);
    await _updateCounts(accountId);
    onLocalChanged?.call();
    notifyListeners();

    try {
      final saved = await _backend.setRating(
        sessionCookie: session.sessionCookie,
        workUrl: key,
        rating: bounded,
      );
      if (_accountService.accountId != accountId) return saved;
      final refreshed = _readEntries(accountId);
      final current = refreshed[key];
      if (current != null) {
        refreshed[key] = current.copyWith(
          userRating: saved,
          clearUserRating: saved == null,
          confirmedUserRating: saved,
          clearConfirmedUserRating: saved == null,
        );
        await _writeEntries(accountId, refreshed);
      }
      await _removePending(accountId, key, 'rating');
      _lastError = null;
      notifyListeners();
      return saved;
    } on Anime3rbPermanentRejectionException catch (error) {
      if (_accountService.accountId == accountId) {
        final rollback = _readEntries(accountId);
        final current = rollback[key];
        if (current != null) {
          rollback[key] = current.copyWith(
            userRating: previousConfirmed,
            clearUserRating: previousConfirmed == null,
            confirmedUserRating: previousConfirmed,
            clearConfirmedUserRating: previousConfirmed == null,
          );
          await _writeEntries(accountId, rollback);
        }
        await _removePending(accountId, key, 'rating');
        await _updateCounts(accountId);
        _lastError = error.message;
        onLocalChanged?.call();
        notifyListeners();
      }
      rethrow;
    } on Anime3rbAuthRequiredException {
      await _accountService.signOut(notifyRemote: false);
      rethrow;
    } catch (error) {
      if (_accountService.accountId == accountId) {
        await _upsertPending(
          accountId,
          Anime3rbPendingMutation(
            workUrl: key,
            item: item,
            field: 'rating',
            userRating: bounded,
            updatedAtMillis: nowMillis,
          ),
        );
        _lastError = error.toString();
        notifyListeners();
      }
      return bounded;
    }
  }

  Future<void> _cacheTitleState(
    String accountId,
    MultimediaItem item, {
    LibraryCategory? category,
    int? userRating,
  }) async {
    final key = canonicalWorkUrl(item.url);
    final entries = _readEntries(accountId);
    final existing = entries[key];
    if (category == null && userRating == null && existing == null) return;
    entries[key] = (existing ?? Anime3rbStoredLibraryEntry(item: item)).copyWith(
      item: item,
      category: category ?? existing?.category,
      confirmedCategory: category ?? existing?.confirmedCategory,
      userRating: userRating ?? existing?.userRating,
      confirmedUserRating: userRating ?? existing?.confirmedUserRating,
      updatedAtMillis: existing?.updatedAtMillis ?? _now().millisecondsSinceEpoch,
    );
    await _writeEntries(accountId, entries);
    await _updateCounts(accountId);
    notifyListeners();
  }

  Future<LibraryMembership?> fetchMembership(MultimediaItem item) async {
    final session = _accountService.session;
    if (session == null) return null;
    final key = canonicalWorkUrl(item.url);
    final local = _readEntries(session.accountId)[key];
    if (local != null) {
      return (category: local.category, favorite: local.favorite);
    }
    final sync = item.syncData ?? const <String, String>{};
    if (sync.containsKey('aw3rbUserList') || sync.containsKey('aw3rbUserRate')) {
      final listCat = libraryCategoryFromAnime3rbSlug(sync['aw3rbUserList']);
      final rate = int.tryParse(sync['aw3rbUserRate'] ?? '');
      if (listCat != null || (rate != null && rate >= 1 && rate <= 10)) {
        await _cacheTitleState(
          session.accountId,
          item,
          category: listCat,
          userRating: rate,
        );
        return (category: listCat, favorite: false);
      }
    }
    try {
      final state = await _backend.fetchTitleState(
        sessionCookie: session.sessionCookie,
        workUrl: key,
      );
      if (state != null && _accountService.accountId == session.accountId) {
        await _cacheTitleState(
          session.accountId,
          item,
          category: state.category,
          userRating: state.userRating,
        );
        return (category: state.category, favorite: false);
      }
    } catch (_) {}
    return null;
  }

  Future<void> retryPendingSync({VoidCallback? onLocalChanged}) async {
    final session = _accountService.session;
    if (session == null) return;
    final accountId = session.accountId;
    final pending = _readPending(accountId);
    if (pending.isEmpty) return;

    for (final mutation in List<Anime3rbPendingMutation>.from(pending)) {
      if (_accountService.accountId != accountId) return;
      try {
        if (mutation.field == 'category') {
          await _backend.setCategory(
            sessionCookie: session.sessionCookie,
            workUrl: mutation.workUrl,
            category: mutation.category,
          );
          final entries = _readEntries(accountId);
          final cur = entries[mutation.workUrl];
          if (cur != null) {
            entries[mutation.workUrl] = cur.copyWith(
              confirmedCategory: mutation.category,
              clearConfirmedCategory: mutation.category == null,
            );
            await _writeEntries(accountId, entries);
          }
        } else if (mutation.field == 'rating') {
          await _backend.setRating(
            sessionCookie: session.sessionCookie,
            workUrl: mutation.workUrl,
            rating: mutation.userRating,
          );
          final entries = _readEntries(accountId);
          final cur = entries[mutation.workUrl];
          if (cur != null) {
            entries[mutation.workUrl] = cur.copyWith(
              confirmedUserRating: mutation.userRating,
              clearConfirmedUserRating: mutation.userRating == null,
            );
            await _writeEntries(accountId, entries);
          }
        }
        await _removePending(accountId, mutation.workUrl, mutation.field);
      } on Anime3rbPermanentRejectionException {
        await _removePending(accountId, mutation.workUrl, mutation.field);
        onLocalChanged?.call();
      } on Anime3rbAuthRequiredException {
        await _accountService.signOut(notifyRemote: false);
        return;
      } catch (_) {
        // Leave transient failures queued.
      }
    }
    notifyListeners();
  }

  Future<void> refreshListsFromServer() async {
    final session = _accountService.session;
    if (session == null || _isSyncing) return;
    final accountId = session.accountId;
    _isSyncing = true;
    notifyListeners();

    try {
      await retryPendingSync();
      if (_accountService.accountId != accountId) return;
      final startPending = _readPending(accountId);
      final pendingCategoryKeys = {
        for (final m in startPending)
          if (m.field == 'category') m.workUrl,
      };
      final pendingRatingKeys = {
        for (final m in startPending)
          if (m.field == 'rating') m.workUrl,
      };

      final snapshot = await _backend.fetchLibrary(
        sessionCookie: session.sessionCookie,
        userSlug: session.profile.userSlug,
      );
      if (_accountService.accountId != accountId) return;

      final existing = _readEntries(accountId);
      final remoteByKey = <String, ({MultimediaItem item, LibraryCategory? cat, int? rate})>{};
      for (final shelfEntry in snapshot.shelves.entries) {
        for (final item in shelfEntry.value) {
          final key = canonicalWorkUrl(item.url);
          remoteByKey[key] = (
            item: item,
            cat: shelfEntry.key,
            rate: remoteByKey[key]?.rate,
          );
        }
      }
      for (final ratingEntry in snapshot.ratings.entries) {
        final key = canonicalWorkUrl(ratingEntry.key);
        final prev = remoteByKey[key];
        remoteByKey[key] = (
          item: prev?.item ?? ratingEntry.value.item,
          cat: prev?.cat,
          rate: ratingEntry.value.rating,
        );
      }

      final epochSnapshot = <String, int>{
        for (final key in {...existing.keys, ...remoteByKey.keys})
          key: _epochs.current(accountId, key),
      };

      final merged = <String, Anime3rbStoredLibraryEntry>{};
      for (final key in {...existing.keys, ...remoteByKey.keys}) {
        final local = existing[key];
        final remote = remoteByKey[key];
        if ((epochSnapshot[key] ?? 0) != _epochs.current(accountId, key) &&
            local != null) {
          merged[key] = local;
          continue;
        }
        final keepCat = pendingCategoryKeys.contains(key)
            ? local?.category
            : remote?.cat;
        final keepRate = pendingRatingKeys.contains(key)
            ? local?.userRating
            : remote?.rate;
        final keepFav = local?.favorite ?? false;
        if (keepCat == null && keepRate == null && !keepFav) continue;
        final baseItem = remote?.item ?? local!.item;
        merged[key] = Anime3rbStoredLibraryEntry(
          item: baseItem,
          category: keepCat,
          confirmedCategory: remote?.cat,
          favorite: keepFav,
          userRating: keepRate,
          confirmedUserRating: remote?.rate,
          updatedAtMillis: local?.updatedAtMillis ?? _now().millisecondsSinceEpoch,
        );
      }
      await _writeEntries(accountId, merged);
      await _updateCounts(accountId);
      _lastError = null;
    } on Anime3rbAuthRequiredException {
      await _accountService.signOut(notifyRemote: false);
    } catch (error) {
      _lastError = error.toString();
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> wipeLocalSessionData([String? accountId]) async {
    final target = accountId ?? _activeAccountId;
    if (target == null) return;
    await _storage.setString(_entriesKey(target), '');
    await _storage.setString(_pendingKey(target), '');
    notifyListeners();
  }
}

final anime3rbLibraryServiceProvider = Provider<Anime3rbLibraryService>((ref) {
  final storage = ref.watch(storageServiceProvider);
  final accountService = ref.watch(anime3rbAccountServiceProvider);
  final transport = ref.watch(anime3rbTransportProvider);
  final service = Anime3rbLibraryService(
    storage: storage,
    accountService: accountService,
    backend: HttpAnime3rbLibraryBackend(transport),
  );
  if (accountService.isSignedIn) {
    unawaited(service.retryPendingSync());
  }
  return service;
});
