import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html;

import '../account/witanime_account_service.dart';
import '../domain/entity/multimedia_item.dart';
import '../extensions/providers/witanime_provider.dart';
import '../extensions/providers/witanime_transport.dart';
import 'library_category.dart';
import 'storage_service.dart';

bool isWitanimeSyncedCategory(LibraryCategory category) => switch (category) {
  LibraryCategory.watching ||
  LibraryCategory.completed ||
  LibraryCategory.planToWatch ||
  LibraryCategory.favorite => true,
  LibraryCategory.continueLater || LibraryCategory.notInterested => false,
};

String witanimeCategorySlug(LibraryCategory category) => switch (category) {
  LibraryCategory.watching => 'watching',
  LibraryCategory.completed => 'completed',
  LibraryCategory.planToWatch => 'plan_to_watch',
  LibraryCategory.favorite => 'favorites',
  LibraryCategory.continueLater => 'continue_later',
  LibraryCategory.notInterested => 'not_interested',
};

LibraryCategory? libraryCategoryFromWitanimeSlug(String? slug) =>
    switch (slug?.trim().toLowerCase()) {
      'watching' || 'أشاهده' || 'أشاهده حاليًا' => LibraryCategory.watching,
      'completed' || 'أكملته' || 'تمت مشاهدته' => LibraryCategory.completed,
      'plan_to_watch' ||
      'plan-to-watch' ||
      'أنوي مشاهدته' ||
      'أرغب بمشاهدته' => LibraryCategory.planToWatch,
      'favorites' || 'favorite' || 'المفضلة' => LibraryCategory.favorite,
      _ => null,
    };

class WitanimePermanentRejectionException implements Exception {
  const WitanimePermanentRejectionException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class WitanimeTransientSyncException implements Exception {
  const WitanimeTransientSyncException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class WitanimeStoredLibraryEntry {
  const WitanimeStoredLibraryEntry({
    required this.item,
    this.category,
    this.confirmedCategory,
    this.favorite = false,
    this.confirmedFavorite = false,
    this.updatedAtMillis = 0,
  });

  final MultimediaItem item;
  final LibraryCategory? category;
  final LibraryCategory? confirmedCategory;
  final bool favorite;
  final bool confirmedFavorite;
  final int updatedAtMillis;

  WitanimeStoredLibraryEntry copyWith({
    MultimediaItem? item,
    LibraryCategory? category,
    bool clearCategory = false,
    LibraryCategory? confirmedCategory,
    bool clearConfirmedCategory = false,
    bool? favorite,
    bool? confirmedFavorite,
    int? updatedAtMillis,
  }) => WitanimeStoredLibraryEntry(
    item: item ?? this.item,
    category: clearCategory ? null : (category ?? this.category),
    confirmedCategory: clearConfirmedCategory
        ? null
        : (confirmedCategory ?? this.confirmedCategory),
    favorite: favorite ?? this.favorite,
    confirmedFavorite: confirmedFavorite ?? this.confirmedFavorite,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );

  Map<String, Object?> toJson() => {
    'item': item.toJson(),
    if (category != null) 'category': category!.storageKey,
    if (confirmedCategory != null)
      'confirmedCategory': confirmedCategory!.storageKey,
    'favorite': favorite,
    'confirmedFavorite': confirmedFavorite,
    'updatedAtMillis': updatedAtMillis,
  };

  static WitanimeStoredLibraryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final itemRaw = raw['item'];
    if (itemRaw is! Map) return null;
    final item = MultimediaItem.fromJson(Map<String, dynamic>.from(itemRaw));
    if (item.url.trim().isEmpty) return null;
    LibraryCategory? parseCat(Object? value) {
      final s = value?.toString().trim() ?? '';
      return s.isEmpty ? null : LibraryCategory.fromStorageKey(s);
    }

    return WitanimeStoredLibraryEntry(
      item: item,
      category: parseCat(raw['category']),
      confirmedCategory: parseCat(raw['confirmedCategory']),
      favorite: raw['favorite'] == true,
      confirmedFavorite: raw['confirmedFavorite'] == true,
      updatedAtMillis: (raw['updatedAtMillis'] as num?)?.toInt() ?? 0,
    );
  }
}

class WitanimePendingMutation {
  const WitanimePendingMutation({
    required this.workUrl,
    required this.item,
    required this.field,
    this.category,
    this.favorite,
    this.updatedAtMillis = 0,
  });

  final String workUrl;
  final MultimediaItem item;
  final String field; // 'category' | 'favorite'
  final LibraryCategory? category;
  final bool? favorite;
  final int updatedAtMillis;

  Map<String, Object?> toJson() => {
    'workUrl': workUrl,
    'item': item.toJson(),
    'field': field,
    if (category != null) 'category': category!.storageKey,
    if (favorite != null) 'favorite': favorite,
    'updatedAtMillis': updatedAtMillis,
  };

  static WitanimePendingMutation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final workUrl = raw['workUrl']?.toString().trim() ?? '';
    final field = raw['field']?.toString().trim() ?? '';
    final itemRaw = raw['item'];
    if (workUrl.isEmpty || field.isEmpty || itemRaw is! Map) return null;
    final catRaw = raw['category']?.toString().trim() ?? '';
    return WitanimePendingMutation(
      workUrl: workUrl,
      item: MultimediaItem.fromJson(Map<String, dynamic>.from(itemRaw)),
      field: field,
      category: catRaw.isEmpty ? null : LibraryCategory.fromStorageKey(catRaw),
      favorite: raw['favorite'] as bool?,
      updatedAtMillis: (raw['updatedAtMillis'] as num?)?.toInt() ?? 0,
    );
  }
}

class WitanimeSyncSnapshot {
  const WitanimeSyncSnapshot({
    this.pendingUrls = const <String>{},
    this.isSyncing = false,
    this.lastError,
  });

  final Set<String> pendingUrls;
  final bool isSyncing;
  final String? lastError;

  int get pendingCount => pendingUrls.length;
  bool get hasPending => pendingUrls.isNotEmpty;
}

abstract interface class WitanimeLibraryBackend {
  Future<LibraryMembership?> fetchMembership({
    required String sessionCookie,
    required String workUrl,
  });

  Future<List<WitanimeStoredLibraryEntry>> fetchLists({
    required String sessionCookie,
  });

  Future<void> setCategory({
    required String sessionCookie,
    required String workUrl,
    required LibraryCategory? category,
  });

  Future<void> setFavorite({
    required String sessionCookie,
    required String workUrl,
    required bool favorite,
  });
}

class HttpWitanimeLibraryBackend implements WitanimeLibraryBackend {
  HttpWitanimeLibraryBackend(this._transport, {Uri? origin})
    : _origin = origin ?? Uri.https('witanime.site');

  final WitanimeTransport _transport;
  final Uri _origin;

  Future<String> _fetchCsrf(String sessionCookie, String url) async {
    final resp = await _transport.get(
      Uri.parse(url),
      headers: {'Cookie': sessionCookie},
      operation: 'library_csrf',
    );
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WitanimePermanentRejectionException(
        'انتهت جلسة Witanime أو يلزم تسجيل الدخول مجددًا.',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode == 429 || resp.statusCode >= 500) {
      throw WitanimeTransientSyncException(
        'تعذر الوصول إلى خادم Witanime مؤقتًا.',
        statusCode: resp.statusCode,
      );
    }
    final csrf =
        RegExp(
          r'''name=["']csrf-token["'][^>]*content=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(resp.body)?.group(1) ??
        RegExp(
          r'''data-csrf=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(resp.body)?.group(1);
    if (csrf == null || csrf.trim().isEmpty) {
      throw const WitanimeTransientSyncException(
        'تعذر قراءة رمز الجلسة من Witanime.',
      );
    }
    return csrf.trim();
  }

  @override
  Future<LibraryMembership?> fetchMembership({
    required String sessionCookie,
    required String workUrl,
  }) async {
    final resp = await _transport.get(
      Uri.parse(workUrl),
      headers: {'Cookie': sessionCookie},
      operation: 'library_read',
    );
    if (!resp.isSuccess) return null;
    final doc = html.parse(resp.body);
    final rawStatus =
        doc.querySelector('[data-user-list-status]')?.attributes['data-user-list-status'] ??
        doc.querySelector('select[name="list_status"] option[selected]')?.attributes['value'];
    final favAttr =
        doc.querySelector('[data-user-favorite]')?.attributes['data-user-favorite'];
    if (rawStatus == null && favAttr == null) return null;
    final category = libraryCategoryFromWitanimeSlug(rawStatus);
    final favorite = favAttr == 'true' || favAttr == '1';
    return (category: category, favorite: favorite);
  }

  @override
  Future<List<WitanimeStoredLibraryEntry>> fetchLists({
    required String sessionCookie,
  }) async {
    final uri = _origin.replace(path: '/profile/lists');
    final resp = await _transport.get(
      uri,
      headers: {'Cookie': sessionCookie},
      operation: 'library_lists',
    );
    if (resp.statusCode == 429 || resp.statusCode >= 500) {
      throw WitanimeTransientSyncException(
        'تعذر تحديث قوائم Witanime مؤقتًا.',
        statusCode: resp.statusCode,
      );
    }
    if (!resp.isSuccess) {
      throw WitanimePermanentRejectionException(
        'تعذر فتح قوائم Witanime.',
        statusCode: resp.statusCode,
      );
    }
    final doc = html.parse(resp.body);
    final byUrl = <String, WitanimeStoredLibraryEntry>{};
    for (final section in doc.querySelectorAll('[data-list-section]')) {
      final sectionKey = section.attributes['data-list-section'];
      final category = libraryCategoryFromWitanimeSlug(sectionKey);
      if (category == null) continue;
      for (final card in section.querySelectorAll('a[href]')) {
        final link = WitanimeProvider.parseCatalogLink(
          card.attributes['href'] ?? '',
        );
        if (link == null) continue;
        final workUrl = link.work.toString();
        final title =
            card.querySelector('h3, h2')?.text.trim() ??
            card.querySelector('img')?.attributes['alt']?.trim() ??
            '';
        if (title.isEmpty) continue;
        final poster = card.querySelector('img')?.attributes['src'] ?? '';
        final item = MultimediaItem(
          title: title,
          url: workUrl,
          posterUrl: poster,
          provider: WitanimeProvider.id,
          contentType: link.movie
              ? MultimediaContentType.movie
              : MultimediaContentType.anime,
        );
        final existing = byUrl[workUrl];
        if (category == LibraryCategory.favorite) {
          byUrl[workUrl] = (existing ?? WitanimeStoredLibraryEntry(item: item))
              .copyWith(favorite: true, confirmedFavorite: true);
        } else {
          byUrl[workUrl] = (existing ?? WitanimeStoredLibraryEntry(item: item))
              .copyWith(category: category, confirmedCategory: category);
        }
      }
    }
    return byUrl.values.toList(growable: false);
  }

  @override
  Future<void> setCategory({
    required String sessionCookie,
    required String workUrl,
    required LibraryCategory? category,
  }) async {
    final csrf = await _fetchCsrf(sessionCookie, workUrl);
    final endpoint = _origin.replace(path: '/profile/lists/status');
    final resp = await _transport.post(
      endpoint,
      body: jsonEncode({
        'url': workUrl,
        'status': category == null ? null : witanimeCategorySlug(category),
      }),
      headers: {
        'Cookie': sessionCookie,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-TOKEN': csrf,
        'X-Requested-With': 'XMLHttpRequest',
        'Origin': _origin.origin,
        'Referer': workUrl,
      },
      operation: 'library_write_category',
    );
    _throwOnErrorResponse(resp);
  }

  @override
  Future<void> setFavorite({
    required String sessionCookie,
    required String workUrl,
    required bool favorite,
  }) async {
    final csrf = await _fetchCsrf(sessionCookie, workUrl);
    final endpoint = _origin.replace(path: '/profile/lists/favorite');
    final resp = await _transport.post(
      endpoint,
      body: jsonEncode({'url': workUrl, 'favorite': favorite}),
      headers: {
        'Cookie': sessionCookie,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-TOKEN': csrf,
        'X-Requested-With': 'XMLHttpRequest',
        'Origin': _origin.origin,
        'Referer': workUrl,
      },
      operation: 'library_write_favorite',
    );
    _throwOnErrorResponse(resp);
  }

  void _throwOnErrorResponse(WitanimeHttpResponse resp) {
    if (resp.isSuccess) return;
    if (resp.statusCode == 429 || resp.statusCode >= 500 || resp.statusCode == 0) {
      throw WitanimeTransientSyncException(
        'تعذر مزامنة التعديل الآن، سيتم حفظه وإعادة المحاولة لاحقًا.',
        statusCode: resp.statusCode,
      );
    }
    throw WitanimePermanentRejectionException(
      'رفض خادم Witanime حفظ هذا التعديل (HTTP ${resp.statusCode}).',
      statusCode: resp.statusCode,
    );
  }
}

class WitanimeLibraryService extends ChangeNotifier {
  WitanimeLibraryService({
    required StorageService storage,
    required WitanimeAccountService accountService,
    required WitanimeLibraryBackend backend,
    DateTime Function()? now,
  }) : _storage = storage,
       _accountService = accountService,
       _backend = backend,
       _now = now ?? DateTime.now;

  final StorageService _storage;
  final WitanimeAccountService _accountService;
  final WitanimeLibraryBackend _backend;
  final DateTime Function() _now;

  final Map<String, int> _mutationEpochs = <String, int>{};
  bool _isSyncing = false;
  String? _lastError;

  String? get _activeAccountId => _accountService.accountId;

  String _scopeHash(String accountId) => base64Url.encode(utf8.encode(accountId));
  String _entriesKey(String accountId) => 'witanime_lib_v1:${_scopeHash(accountId)}';
  String _pendingKey(String accountId) => 'witanime_pending_v1:${_scopeHash(accountId)}';

  String _mutationKey(String accountId, String workUrl) =>
      '$accountId|${canonicalWorkUrl(workUrl)}';

  int _bumpEpoch(String accountId, String workUrl) {
    final key = _mutationKey(accountId, workUrl);
    final next = (_mutationEpochs[key] ?? 0) + 1;
    _mutationEpochs[key] = next;
    return next;
  }

  int _epochFor(String accountId, String workUrl) =>
      _mutationEpochs[_mutationKey(accountId, workUrl)] ?? 0;

  static String canonicalWorkUrl(String url) =>
      WitanimeProvider.parseCatalogLink(url)?.work.toString() ?? url.trim();

  Map<String, WitanimeStoredLibraryEntry> _readEntries(String accountId) {
    final raw = _storage.getString(_entriesKey(accountId));
    if (raw == null || raw.isEmpty) return <String, WitanimeStoredLibraryEntry>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, WitanimeStoredLibraryEntry>{};
      final result = <String, WitanimeStoredLibraryEntry>{};
      for (final entry in decoded.entries) {
        final parsed = WitanimeStoredLibraryEntry.fromJson(entry.value);
        if (parsed != null) result[entry.key.toString()] = parsed;
      }
      return result;
    } catch (_) {
      return <String, WitanimeStoredLibraryEntry>{};
    }
  }

  Future<void> _writeEntries(
    String accountId,
    Map<String, WitanimeStoredLibraryEntry> entries,
  ) => _storage.setString(
    _entriesKey(accountId),
    jsonEncode({
      for (final entry in entries.entries) entry.key: entry.value.toJson(),
    }),
  );

  List<WitanimePendingMutation> _readPending(String accountId) {
    final raw = _storage.getString(_pendingKey(accountId));
    if (raw == null || raw.isEmpty) return <WitanimePendingMutation>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <WitanimePendingMutation>[];
      return [
        for (final row in decoded)
          if (WitanimePendingMutation.fromJson(row) case final parsed?) parsed,
      ];
    } catch (_) {
      return <WitanimePendingMutation>[];
    }
  }

  Future<void> _writePending(
    String accountId,
    List<WitanimePendingMutation> pending,
  ) => _storage.setString(
    _pendingKey(accountId),
    jsonEncode([for (final item in pending) item.toJson()]),
  );

  Future<void> _upsertPending(
    String accountId,
    WitanimePendingMutation mutation,
  ) async {
    final list = _readPending(accountId)
      ..removeWhere(
        (m) => m.workUrl == mutation.workUrl && m.field == mutation.field,
      );
    list.add(mutation);
    await _writePending(accountId, list);
  }

  Future<void> _removePending(
    String accountId,
    String workUrl,
    String field,
  ) async {
    final list = _readPending(accountId)
      ..removeWhere((m) => m.workUrl == workUrl && m.field == field);
    await _writePending(accountId, list);
  }

  WitanimeSyncSnapshot syncSnapshot() {
    final accountId = _activeAccountId;
    if (accountId == null) return const WitanimeSyncSnapshot();
    final pending = _readPending(accountId);
    return WitanimeSyncSnapshot(
      pendingUrls: {for (final m in pending) m.workUrl},
      isSyncing: _isSyncing,
      lastError: _lastError,
    );
  }

  bool isItemPending(String workUrl) {
    final accountId = _activeAccountId;
    if (accountId == null) return false;
    final key = canonicalWorkUrl(workUrl);
    return _readPending(accountId).any((m) => m.workUrl == key);
  }

  List<MultimediaItem> itemsForCategory(LibraryCategory category) {
    final accountId = _activeAccountId;
    if (accountId == null || !isWitanimeSyncedCategory(category)) {
      return const <MultimediaItem>[];
    }
    final entries = _readEntries(accountId).values.where((entry) {
      if (category == LibraryCategory.favorite) return entry.favorite;
      return entry.category == category;
    }).toList()
      ..sort((a, b) => b.updatedAtMillis.compareTo(a.updatedAtMillis));
    return [for (final entry in entries) entry.item];
  }

  int countForCategory(LibraryCategory category) =>
      itemsForCategory(category).length;

  LibraryMembership? cachedMembership(String workUrl) {
    final accountId = _activeAccountId;
    if (accountId == null) return null;
    final entry = _readEntries(accountId)[canonicalWorkUrl(workUrl)];
    if (entry == null) return null;
    return (category: entry.category, favorite: entry.favorite);
  }

  /// Reads current membership from Witanime for the active account, rejecting
  /// stale responses if the account switched or a newer local mutation happened.
  Future<LibraryMembership?> fetchMembership(MultimediaItem item) async {
    final session = _accountService.session;
    if (session == null) return null;
    final accountId = session.accountId;
    final key = canonicalWorkUrl(item.url);
    final requestEpoch = _epochFor(accountId, key);

    try {
      final remote = await _backend.fetchMembership(
        sessionCookie: session.sessionCookie,
        workUrl: key,
      );
      if (_accountService.accountId != accountId ||
          _epochFor(accountId, key) != requestEpoch) {
        return null;
      }
      if (remote == null) return cachedMembership(key);

      final pending = _readPending(accountId)
          .where((m) => m.workUrl == key)
          .toList(growable: false);
      final hasPendingCat = pending.any((m) => m.field == 'category');
      final hasPendingFav = pending.any((m) => m.field == 'favorite');

      final entries = _readEntries(accountId);
      final existing = entries[key];
      final effectiveCategory = hasPendingCat
          ? existing?.category
          : remote.category;
      final effectiveFavorite = hasPendingFav
          ? (existing?.favorite ?? false)
          : remote.favorite;

      entries[key] = (existing ?? WitanimeStoredLibraryEntry(item: item)).copyWith(
        item: item,
        category: effectiveCategory,
        clearCategory: effectiveCategory == null,
        confirmedCategory: remote.category,
        clearConfirmedCategory: remote.category == null,
        favorite: effectiveFavorite,
        confirmedFavorite: remote.favorite,
        updatedAtMillis: existing?.updatedAtMillis ?? _now().millisecondsSinceEpoch,
      );
      await _writeEntries(accountId, entries);
      notifyListeners();
      return (category: effectiveCategory, favorite: effectiveFavorite);
    } catch (_) {
      if (_accountService.accountId != accountId) return null;
      return cachedMembership(key);
    }
  }

  Future<void> setCategory(
    MultimediaItem item,
    LibraryCategory? nextCategory, {
    LibraryMembership? previousMembership,
    VoidCallback? onLocalChanged,
  }) async {
    final session = _accountService.session;
    if (session == null) {
      throw StateError('سجّل الدخول إلى حساب Witanime أولًا.');
    }
    if (nextCategory != null && !isWitanimeSyncedCategory(nextCategory)) {
      throw ArgumentError('هذا التصنيف يُحفظ في AnimeWitcher فقط.');
    }
    final accountId = session.accountId;
    final key = canonicalWorkUrl(item.url);
    _bumpEpoch(accountId, key);
    final entries = _readEntries(accountId);
    final existing = entries[key];
    final previousConfirmed =
        existing?.confirmedCategory ?? previousMembership?.category;
    final keepFavorite =
        existing?.favorite ?? previousMembership?.favorite ?? false;
    final nowMillis = _now().millisecondsSinceEpoch;

    entries[key] = (existing ?? WitanimeStoredLibraryEntry(item: item)).copyWith(
      item: item,
      category: nextCategory,
      clearCategory: nextCategory == null,
      confirmedCategory: previousConfirmed,
      clearConfirmedCategory: previousConfirmed == null,
      favorite: keepFavorite,
      confirmedFavorite: existing?.confirmedFavorite ?? keepFavorite,
      updatedAtMillis: nowMillis,
    );
    await _writeEntries(accountId, entries);
    onLocalChanged?.call();
    notifyListeners();

    try {
      await _backend.setCategory(
        sessionCookie: session.sessionCookie,
        workUrl: key,
        category: nextCategory,
      );
      if (_accountService.accountId != accountId) return;
      final refreshed = _readEntries(accountId);
      final current = refreshed[key];
      if (current != null) {
        refreshed[key] = current.copyWith(
          confirmedCategory: nextCategory,
          clearConfirmedCategory: nextCategory == null,
        );
        await _writeEntries(accountId, refreshed);
      }
      await _removePending(accountId, key, 'category');
      _lastError = null;
      notifyListeners();
    } on WitanimePermanentRejectionException catch (error) {
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
        _lastError = error.message;
        onLocalChanged?.call();
        notifyListeners();
      }
      rethrow;
    } catch (error) {
      if (_accountService.accountId == accountId) {
        await _upsertPending(
          accountId,
          WitanimePendingMutation(
            workUrl: key,
            item: item,
            field: 'category',
            category: nextCategory,
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
      throw StateError('سجّل الدخول إلى حساب Witanime أولًا.');
    }
    final accountId = session.accountId;
    final key = canonicalWorkUrl(item.url);
    _bumpEpoch(accountId, key);
    final entries = _readEntries(accountId);
    final existing = entries[key];
    final previousConfirmed =
        existing?.confirmedFavorite ?? previousMembership?.favorite ?? false;
    final keepCategory =
        existing?.category ?? previousMembership?.category;
    final nowMillis = _now().millisecondsSinceEpoch;

    entries[key] = (existing ?? WitanimeStoredLibraryEntry(item: item)).copyWith(
      item: item,
      category: keepCategory,
      clearCategory: keepCategory == null,
      confirmedCategory: existing?.confirmedCategory ?? keepCategory,
      clearConfirmedCategory:
          (existing?.confirmedCategory ?? keepCategory) == null,
      favorite: favorite,
      confirmedFavorite: previousConfirmed,
      updatedAtMillis: nowMillis,
    );
    await _writeEntries(accountId, entries);
    onLocalChanged?.call();
    notifyListeners();

    try {
      await _backend.setFavorite(
        sessionCookie: session.sessionCookie,
        workUrl: key,
        favorite: favorite,
      );
      if (_accountService.accountId != accountId) return;
      final refreshed = _readEntries(accountId);
      final current = refreshed[key];
      if (current != null) {
        refreshed[key] = current.copyWith(confirmedFavorite: favorite);
        await _writeEntries(accountId, refreshed);
      }
      await _removePending(accountId, key, 'favorite');
      _lastError = null;
      notifyListeners();
    } on WitanimePermanentRejectionException catch (error) {
      if (_accountService.accountId == accountId) {
        final rollback = _readEntries(accountId);
        final current = rollback[key];
        if (current != null) {
          rollback[key] = current.copyWith(
            favorite: previousConfirmed,
            confirmedFavorite: previousConfirmed,
          );
          await _writeEntries(accountId, rollback);
        }
        await _removePending(accountId, key, 'favorite');
        _lastError = error.message;
        onLocalChanged?.call();
        notifyListeners();
      }
      rethrow;
    } catch (error) {
      if (_accountService.accountId == accountId) {
        await _upsertPending(
          accountId,
          WitanimePendingMutation(
            workUrl: key,
            item: item,
            field: 'favorite',
            favorite: favorite,
            updatedAtMillis: nowMillis,
          ),
        );
        _lastError = error.toString();
        notifyListeners();
      }
    }
  }

  Future<void> refreshListsFromServer() async {
    final session = _accountService.session;
    if (session == null) return;
    final accountId = session.accountId;
    final epochBefore = Map<String, int>.from(_mutationEpochs);
    final fetched = await _backend.fetchLists(
      sessionCookie: session.sessionCookie,
    );
    if (_accountService.accountId != accountId) return;

    final pending = _readPending(accountId);
    final entries = _readEntries(accountId);
    final fetchedByUrl = {
      for (final item in fetched) canonicalWorkUrl(item.item.url): item,
    };

    for (final key in fetchedByUrl.keys) {
      final mutationKey = _mutationKey(accountId, key);
      if ((_mutationEpochs[mutationKey] ?? 0) !=
          (epochBefore[mutationKey] ?? 0)) {
        continue;
      }
      final remote = fetchedByUrl[key]!;
      final hasPendingCat = pending.any(
        (m) => m.workUrl == key && m.field == 'category',
      );
      final hasPendingFav = pending.any(
        (m) => m.workUrl == key && m.field == 'favorite',
      );
      final local = entries[key];
      entries[key] = remote.copyWith(
        category: hasPendingCat ? local?.category : remote.category,
        clearCategory: hasPendingCat
            ? local?.category == null
            : remote.category == null,
        favorite: hasPendingFav ? (local?.favorite ?? false) : remote.favorite,
        updatedAtMillis: local?.updatedAtMillis ?? _now().millisecondsSinceEpoch,
      );
    }
    await _writeEntries(accountId, entries);
    notifyListeners();
  }

  Future<void> retryPendingSync({VoidCallback? onLocalChanged}) async {
    final session = _accountService.session;
    if (session == null || _isSyncing) return;
    final accountId = session.accountId;
    final pending = _readPending(accountId);
    if (pending.isEmpty) return;

    _isSyncing = true;
    _lastError = null;
    notifyListeners();
    try {
      for (final mutation in pending) {
        if (_accountService.accountId != accountId) break;
        try {
          if (mutation.field == 'category') {
            await _backend.setCategory(
              sessionCookie: session.sessionCookie,
              workUrl: mutation.workUrl,
              category: mutation.category,
            );
          } else if (mutation.field == 'favorite') {
            await _backend.setFavorite(
              sessionCookie: session.sessionCookie,
              workUrl: mutation.workUrl,
              favorite: mutation.favorite ?? false,
            );
          }
          if (_accountService.accountId == accountId) {
            final entries = _readEntries(accountId);
            final existing = entries[mutation.workUrl];
            if (existing != null) {
              entries[mutation.workUrl] = mutation.field == 'category'
                  ? existing.copyWith(
                      confirmedCategory: mutation.category,
                      clearConfirmedCategory: mutation.category == null,
                    )
                  : existing.copyWith(
                      confirmedFavorite: mutation.favorite ?? false,
                    );
              await _writeEntries(accountId, entries);
            }
          }
          await _removePending(accountId, mutation.workUrl, mutation.field);
        } on WitanimePermanentRejectionException catch (error) {
          final entries = _readEntries(accountId);
          final existing = entries[mutation.workUrl];
          if (existing != null) {
            entries[mutation.workUrl] = mutation.field == 'category'
                ? existing.copyWith(
                    category: existing.confirmedCategory,
                    clearCategory: existing.confirmedCategory == null,
                  )
                : existing.copyWith(favorite: existing.confirmedFavorite);
            await _writeEntries(accountId, entries);
            onLocalChanged?.call();
          }
          await _removePending(accountId, mutation.workUrl, mutation.field);
          _lastError = error.message;
        } catch (error) {
          _lastError = error.toString();
        }
      }
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }
}

final witanimeLibraryServiceProvider = Provider<WitanimeLibraryService>((ref) {
  final service = WitanimeLibraryService(
    storage: ref.watch(storageServiceProvider),
    accountService: ref.watch(witanimeAccountServiceProvider),
    backend: HttpWitanimeLibraryBackend(ref.watch(witanimeTransportProvider)),
  );
  ref.onDispose(service.dispose);
  return service;
});
