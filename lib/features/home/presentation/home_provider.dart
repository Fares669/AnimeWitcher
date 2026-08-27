import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../../core/account/account_providers.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/base_provider.dart';

import './home_state.dart';

part 'home_provider.g.dart';

@riverpod
class HomeData extends _$HomeData {
  @override
  HomeState build() {
    // Rebuild after a saved account content preference so the provider applies
    // its current ecchi filter to newly loaded cards.
    ref.watch(accountDataRevisionProvider);
    final activeProvider = ref.watch(activeProviderProvider);
    if (activeProvider == null) {
      return const HomeNoProvider();
    }

    // Start initial fetch
    Future.microtask(() => fetch());
    return const HomeLoading();
  }

  Future<void> fetch() async {
    state = const HomeLoading();

    final activeProvider = ref.read(activeProviderProvider);
    if (activeProvider == null) {
      state = const HomeNoProvider();
      return;
    }

    try {
      final results = await Future.wait<dynamic>([
        activeProvider.getHome(),
        () async {
          try {
            return await activeProvider.getHomeNewsPage(limit: 10);
          } catch (_) {
            return const ProviderNewsPage(
              items: <NewsItem>[],
              nextOffset: 0,
              hasMore: false,
            );
          }
        }(),
      ]);
      final items = results[0] as Map<String, List<MultimediaItem>>;
      final newsPage = results[1] as ProviderNewsPage;
      state = HomeSuccess(items, news: newsPage.items);
    } catch (e) {
      state = HomeError(e.toString());
    }
  }
}

@riverpod
class HomeFilter extends _$HomeFilter {
  @override
  ProviderType? build() {
    final storage = ref.read(storageServiceProvider);
    final saved = storage.getHomeCategory();
    if (saved != null) {
      try {
        return ProviderType.values.firstWhere((e) => e.name == saved);
      } catch (_) {}
    }
    return null;
  }

  Future<void> setFilter(ProviderType? type) async {
    state = type;
    final storage = ref.read(storageServiceProvider);
    await storage.setHomeCategory(type?.name);
  }
}
