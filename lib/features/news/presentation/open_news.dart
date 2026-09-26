import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/shared/widgets/taskbar_visibility.dart';

import 'news_list_screen.dart';
import 'news_utils.dart';

/// Opens the full news list from anywhere in the app — the news button in
/// the side rail and the top bar, which take the news off the home page.
///
/// Starts from the articles home already fetched when there are any, so the
/// page opens full; the list fetches its own otherwise.
void openNewsScreen(BuildContext context, WidgetRef ref) {
  final provider = ref.read(activeProviderProvider);
  if (provider == null) return;
  final home = ref.read(homeDataProvider);
  final initial = home is HomeSuccess ? home.news : const <NewsItem>[];

  pushOverTaskbar<void>(
    context,
    MaterialPageRoute<void>(
      builder: (routeContext) => NewsListScreen(
        initialItems: initial,
        loadPage: (offset, limit) =>
            provider.getNewsPage(offset: offset, limit: limit),
        onOpen: openNewsUrl,
        onAnimeTap: (item) => _openLinkedAnime(routeContext, provider, item),
      ),
    ),
  );
}

Future<void> _openLinkedAnime(
  BuildContext context,
  AnimeWitcherProvider provider,
  NewsItem item,
) async {
  final animeId = item.animeId?.trim();
  if (animeId == null || animeId.isEmpty) return;
  try {
    final baseUrl = provider.mainUrl.replaceFirst(RegExp(r'/$'), '');
    final details = await provider.getDetails(
      '$baseUrl/watch/${Uri.encodeComponent(animeId)}',
    );
    if (!context.mounted) return;
    DetailsRoute($extra: DetailsRouteExtra(item: details)).push<void>(context);
  } catch (_) {
    // The article remains usable even if its linked anime is unavailable.
  }
}
