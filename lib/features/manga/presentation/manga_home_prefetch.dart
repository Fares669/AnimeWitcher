// Page pre-loading after Harbor's idle prefetch
// (src/lib/query/use-idle-page-prefetch.ts), ported to Riverpod.
// Harbor: Copyright (c) 2026 Harbor, MIT License — see THIRD_PARTY_NOTICES.md.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/network/poster_cache.dart';

/// The catalogue that answers for manga: the first that lists manga among
/// what it carries, else the first there is.
AnimeWitcherProvider? mangaCatalogueOf(List<AnimeWitcherProvider> providers) {
  for (final provider in providers) {
    if (provider.supportedTypes.contains(ProviderType.manga)) return provider;
  }
  return providers.isEmpty ? null : providers.first;
}

Future<List<MangaLatestChapter>> loadMangaHomeLatest(
  AnimeWitcherProvider provider,
) async => (await provider.getLatestMangaPage(limit: 30)).items;

Future<List<MultimediaItem>> loadMangaHomePopular(
  AnimeWitcherProvider provider,
) async => (await provider.searchMangaPage(
  '',
  const ProviderSearchFilters(),
  offset: 0,
  limit: provider.searchPageSize,
)).items;

/// The two rails complete separately so neither delays the other's first
/// paint. An unfinished prefetch can be adopted by the first screen to open.
class MangaHomePrefetch {
  MangaHomePrefetch._(this.source) {
    _latest = _loadLatest();
    _popular = _loadPopular();
  }

  final AnimeWitcherProvider source;
  late final Future<List<MangaLatestChapter>?> _latest;
  late final Future<List<MultimediaItem>?> _popular;
  List<MangaLatestChapter>? _cachedLatest;
  List<MultimediaItem>? _cachedPopular;
  bool _latestSettled = false;
  bool _popularSettled = false;

  List<MangaLatestChapter>? get cachedLatest => _cachedLatest;
  List<MultimediaItem>? get cachedPopular => _cachedPopular;
  Future<List<MangaLatestChapter>?>? get pendingLatest =>
      _latestSettled ? null : _latest;
  Future<List<MultimediaItem>?>? get pendingPopular =>
      _popularSettled ? null : _popular;

  Future<List<MangaLatestChapter>?> _loadLatest() async {
    try {
      return _cachedLatest = await loadMangaHomeLatest(source);
    } catch (_) {
      return null;
    } finally {
      _latestSettled = true;
    }
  }

  Future<List<MultimediaItem>?> _loadPopular() async {
    try {
      final items = _cachedPopular = await loadMangaHomePopular(source);
      warmPosters(items.take(12).map((item) => item.posterUrl));
      return items;
    } catch (_) {
      return null;
    } finally {
      _popularSettled = true;
    }
  }
}

/// Owns the delayed Home warm-up for this navigation shell. Once Manga opens,
/// its actual load replaces any need for a speculative second request.
class MangaHomeWarmup {
  bool _opened = false;
  MangaHomePrefetch? _prefetch;

  void prefetch(AnimeWitcherProvider? Function() findSource) {
    if (_opened || _prefetch != null) return;
    final source = findSource();
    if (source != null) _prefetch = MangaHomePrefetch._(source);
  }

  MangaHomePrefetch? open() {
    _opened = true;
    final prefetch = _prefetch;
    _prefetch = null;
    return prefetch;
  }
}

final mangaHomeWarmupProvider = Provider<MangaHomeWarmup>(
  (_) => MangaHomeWarmup(),
);
