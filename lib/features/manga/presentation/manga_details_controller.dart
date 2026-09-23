import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/services/download_parallel.dart';
import '../../../core/services/download_v2/download_file_planner_v2.dart';
import '../../../core/services/download_v2/download_manager_v2.dart';
import '../../../core/services/download_v2/download_v2_identity.dart';
import '../../../core/services/download_v2/download_v2_models.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';
import '../../../core/storage/storage_service.dart';
import 'manga_details_state.dart';

part 'manga_details_controller.g.dart';

MultimediaItem mergeMangaDetails({
  required MultimediaItem base,
  required MultimediaItem incoming,
}) {
  final mergedSync = <String, String>{
    ...?base.syncData,
    ...?incoming.syncData,
  };
  final incomingTags = incoming.tags;
  return MultimediaItem(
    title: incoming.title.trim().isEmpty ? base.title : incoming.title,
    url: incoming.url.trim().isEmpty ? base.url : incoming.url,
    posterUrl: incoming.posterUrl.trim().isEmpty
        ? base.posterUrl
        : incoming.posterUrl,
    fullPosterUrl: incoming.fullPosterUrl ?? base.fullPosterUrl,
    bannerUrl: incoming.bannerUrl ?? base.bannerUrl,
    logoUrl: incoming.logoUrl ?? base.logoUrl,
    description: (incoming.description ?? '').trim().isEmpty
        ? base.description
        : incoming.description,
    contentType: MultimediaContentType.manga,
    provider: incoming.provider ?? base.provider,
    headers: incoming.headers ?? base.headers,
    year: incoming.year ?? base.year,
    score: incoming.score ?? base.score,
    status: incoming.status,
    tags: incomingTags == null || incomingTags.isEmpty
        ? base.tags
        : incomingTags,
    contentRating: incoming.contentRating ?? base.contentRating,
    syncData: mergedSync.isEmpty ? null : mergedSync,
    tmdbId: incoming.tmdbId ?? base.tmdbId,
    imdbId: incoming.imdbId ?? base.imdbId,
    source: incoming.source ?? base.source,
    catalogType: incoming.catalogType ?? base.catalogType,
    publishedAt: incoming.publishedAt ?? base.publishedAt,
    isDubbed: incoming.isDubbed || base.isDubbed,
  );
}

Future<DownloadStartRequestV2> mangaChapterDownloadRequest(
  MultimediaItem manga,
  MangaChapter chapter, {
  int parallelChunks = 4,
}) async {
  final mangaId =
      manga.syncData?['mangaId']?.trim().isNotEmpty == true
      ? manga.syncData!['mangaId']!.trim()
      : chapter.mangaId.trim();
  final chapterId = chapter.id.trim();
  final providerId = manga.provider?.trim() ?? '';
  if (mangaId.isEmpty || chapterId.isEmpty || providerId.isEmpty) {
    throw StateError('Manga download identity is incomplete.');
  }

  final logicalId = logicalDownloadIdForMangaChapter(
    mangaId: mangaId,
    chapterId: chapterId,
  );
  final destination = await mangaChapterDestinationDirectoryV2(manga, chapter);

  return DownloadStartRequestV2(
    logicalId: logicalId,
    mediaKind: DownloadMediaKind.mangaChapter,
    mediaId: mangaId,
    unitKey: chapterId,
    variantKey: 'pages',
    destinationPath: destination,
    sourceDescriptor: <String, Object?>{
      'providerId': providerId,
      'mangaUrl': manga.url,
      'mangaId': mangaId,
      'chapterId': chapterId,
      'chapterUrl': chapter.url,
      'chapterName': chapter.name,
      if (chapter.number != null) 'chapterNumber': chapter.number,
    },
    allowPause: true,
    retries: 2,
    parallelChunks: parallelChunks
        .clamp(kDownloadPartsMin, kDownloadPartsMax)
        .toInt(),
  );
}

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

  Future<void> downloadChapter(MangaChapter chapter) async {
    final item = state.item;
    if (item == null) {
      throw StateError('Manga details are not loaded.');
    }
    final storage = ref.read(storageServiceProvider);
    final request = await mangaChapterDownloadRequest(
      item,
      chapter,
      parallelChunks: mangaChapterPageConnectionsFromPreference(
        storage.getDownloadParallelParts(),
      ),
    );
    await storage.saveDownloadMetadata(
      request.logicalId.value,
      item,
      trackingUrl: chapter.url,
      filePath: request.destinationPath,
      logicalId: request.logicalId.value,
      taskSnapshot: <String, dynamic>{
        'mediaKind': DownloadMediaKind.mangaChapter.name,
        'chapter': <String, Object?>{
          'id': chapter.id,
          'mangaId': chapter.mangaId,
          'url': chapter.url,
          'name': chapter.name,
          if (chapter.number != null) 'number': chapter.number,
          if (chapter.publishedAt != null)
            'publishedAt': chapter.publishedAt!.toIso8601String(),
        },
      },
    );

    try {
      await ref.read(downloadManagerV2Provider).start(request);
    } catch (error, stackTrace) {
      await storage.removeDownloadMetadata(request.logicalId.value);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _load(MultimediaItem item) async {
    final provider = _providerFor(item);
    state = state.copyWith(
      item: item,
      details: const AsyncLoading<MultimediaItem?>(),
      chapters: const AsyncLoading<List<MangaChapter>>(),
    );

    // The real AnimeWitcher chapter endpoint resolves Manga metadata through
    // getMangaDetails as well. Finish the route-owned details request first so
    // the chapter load reuses the populated provider cache instead of racing a
    // second manga_list/<id> document read.
    await _loadDetails(provider, item);
    if (!ref.mounted) return;
    await _loadChapters(provider, item);
  }

  Future<void> _loadDetails(
    AnimeWitcherProvider provider,
    MultimediaItem item,
  ) async {
    try {
      final fetched = await provider.getMangaDetails(item.url);
      final merged = mergeMangaDetails(base: item, incoming: fetched);
      if (!ref.mounted) return;
      state = state.copyWith(
        item: merged,
        details: AsyncData<MultimediaItem?>(merged),
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
