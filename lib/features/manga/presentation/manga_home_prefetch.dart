// Page pre-loading after Harbor's idle prefetch
// (src/lib/query/use-idle-page-prefetch.ts), ported to Riverpod.
// Harbor: Copyright (c) 2026 Harbor, MIT License — see THIRD_PARTY_NOTICES.md.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/network/poster_cache.dart';

/// The manga tab's first page: the new chapters and the most read.
@immutable
class MangaHomeFirstPage {
  const MangaHomeFirstPage({required this.latest, required this.popular});

  final List<MangaLatestChapter> latest;
  final List<MultimediaItem> popular;
}

/// The catalogue that answers for manga: the first that lists manga among
/// what it carries, else the first there is.
AnimeWitcherProvider? mangaCatalogueOf(List<AnimeWitcherProvider> providers) {
  for (final provider in providers) {
    if (provider.supportedTypes.contains(ProviderType.manga)) return provider;
  }
  return providers.isEmpty ? null : providers.first;
}

/// The manga tab's first page, fetched before the tab is opened — a few
/// seconds after home has loaded — so the tab opens with its rows already
/// there and refreshes them behind. Each half that fails is left empty for
/// the tab's own request.
final mangaHomeFirstPageProvider = FutureProvider<MangaHomeFirstPage>((
  ref,
) async {
  final provider = mangaCatalogueOf(
    ref.read(extensionManagerProvider.notifier).getAllProviders(),
  );
  if (provider == null) {
    return const MangaHomeFirstPage(latest: [], popular: []);
  }
  final latest = provider
      .getLatestMangaPage(limit: 30)
      .then((page) => page.items)
      .catchError((Object _) => const <MangaLatestChapter>[]);
  final popular = provider
      .searchMangaPage(
        '',
        const ProviderSearchFilters(),
        offset: 0,
        limit: provider.searchPageSize,
      )
      .then((page) => page.items)
      .catchError((Object _) => const <MultimediaItem>[]);
  final page = MangaHomeFirstPage(latest: await latest, popular: await popular);
  warmPosters(page.popular.take(12).map((item) => item.posterUrl));
  return page;
});
