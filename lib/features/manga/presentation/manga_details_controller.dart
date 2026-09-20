import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import 'manga_details_state.dart';

part 'manga_details_controller.g.dart';

@riverpod
class MangaDetailsController extends _$MangaDetailsController {
  bool _started = false;

  @override
  MangaDetailsState build(String itemUrl) => const MangaDetailsState();

  AnimeWitcherProvider _providerFor(MultimediaItem item) {
    final manager = ref.read(extensionManagerProvider.notifier);
    final requested = item.provider?.trim() ?? '';
    final selected = requested.isEmpty ? null : manager.getProvider(requested);
    if (selected != null) return selected;

    for (final provider in manager.getAllProviders()) {
      if (provider.supportedTypes.contains(ProviderType.manga)) {
        return provider;
      }
    }
    throw StateError('No Manga provider is available.');
  }

  Future<void> load(MultimediaItem item) async {
    if (_started) return;
    _started = true;
    await _load(item);
  }

  Future<void> retry() async {
    final item = state.item;
    if (item == null) return;
    await _load(item);
  }

  Future<void> _load(MultimediaItem item) async {
    final provider = _providerFor(item);
    state = state.copyWith(
      item: item,
      details: const AsyncLoading<MultimediaItem?>(),
      chapters: const AsyncLoading<List<MangaChapter>>(),
    );

    await Future.wait<void>([
      _loadDetails(provider, item),
      _loadChapters(provider, item),
    ]);
  }

  Future<void> _loadDetails(
    AnimeWitcherProvider provider,
    MultimediaItem item,
  ) async {
    try {
      final fetched = await provider.getMangaDetails(item.url);
      if (!ref.mounted) return;
      state = state.copyWith(
        item: fetched,
        details: AsyncData<MultimediaItem?>(fetched),
      );
    } catch (error, stackTrace) {
      if (!ref.mounted) return;
      state = state.copyWith(
        details: AsyncError<MultimediaItem?>(error, stackTrace),
      );
    }
  }

  Future<void> _loadChapters(
    AnimeWitcherProvider provider,
    MultimediaItem item,
  ) async {
    try {
      final chapters = await provider.getMangaChapters(item.url);
      if (!ref.mounted) return;
      state = state.copyWith(
        chapters: AsyncData<List<MangaChapter>>(chapters),
      );
    } catch (error, stackTrace) {
      if (!ref.mounted) return;
      state = state.copyWith(
        chapters: AsyncError<List<MangaChapter>>(error, stackTrace),
      );
    }
  }
}
