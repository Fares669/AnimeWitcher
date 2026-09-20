import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/underline_segment_tabs.dart';
import 'manga_details_controller.dart';
import 'widgets/manga_chapter_list.dart';
import 'widgets/manga_information_section.dart';

class MangaDetailsScreen extends ConsumerStatefulWidget {
  const MangaDetailsScreen({
    super.key,
    required this.item,
    this.onOpenChapter,
    this.onDownloadChapter,
  });

  final MultimediaItem item;
  final ValueChanged<MangaChapter>? onOpenChapter;
  final ValueChanged<MangaChapter>? onDownloadChapter;

  @override
  ConsumerState<MangaDetailsScreen> createState() => _MangaDetailsScreenState();
}

class _MangaDetailsScreenState extends ConsumerState<MangaDetailsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(mangaDetailsControllerProvider(widget.item.url).notifier)
          .load(widget.item);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      mangaDetailsControllerProvider(widget.item.url),
    );
    final l10n = AppLocalizations.of(context)!;
    final item = state.details.asData?.value ?? state.item ?? widget.item;

    return Scaffold(
      appBar: AppBar(
        title: Text(item.title),
        bottom: FilterStyleTabBar(
          controller: _tabs,
          isScrollable: false,
          indicatorSize: TabBarIndicatorSize.tab,
          tabs: <Widget>[
            FilterStyleTab(label: l10n.mangaDetails),
            FilterStyleTab(label: l10n.chapters),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          _MangaDetailsTab(
            item: item,
            loading: state.details.isLoading,
            error: state.details.hasError,
            onRetry: () => ref
                .read(mangaDetailsControllerProvider(widget.item.url).notifier)
                .retry(),
          ),
          state.chapters.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (_, __) => _RetryPanel(
              onRetry: () => ref
                  .read(
                    mangaDetailsControllerProvider(widget.item.url).notifier,
                  )
                  .retry(),
            ),
            data: (chapters) => MangaChapterList(
              chapters: chapters,
              onOpen: widget.onOpenChapter ??
                  (chapter) => MangaReaderRoute(
                    $extra: MangaReaderRouteExtra(
                      manga: item,
                      chapter: chapter,
                      chapters: chapters,
                    ),
                  ).push<void>(context),
              onDownload: widget.onDownloadChapter ??
                  (chapter) => unawaited(
                    ref
                        .read(
                          mangaDetailsControllerProvider(
                            widget.item.url,
                          ).notifier,
                        )
                        .downloadChapter(chapter),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MangaDetailsTab extends StatelessWidget {
  const _MangaDetailsTab({
    required this.item,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final MultimediaItem item;
  final bool loading;
  final bool error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (error) return _RetryPanel(onRetry: onRetry);

    final poster = item.posterUrl.trim();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 96),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: 130,
                      height: 195,
                      child: poster.isEmpty
                          ? const ColoredBox(
                              color: Color(0x22000000),
                              child: Icon(Icons.menu_book_rounded, size: 44),
                            )
                          : CachedNetworkImage(
                              imageUrl: poster,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) =>
                                  const Icon(Icons.broken_image_outlined),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        if ((item.description ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            item.description!.trim(),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              MangaInformationSection(item: item),
            ],
          ),
        ),
      ),
    );
  }
}

class _RetryPanel extends StatelessWidget {
  const _RetryPanel({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: FilledButton.tonalIcon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(l10n.retry),
      ),
    );
  }
}
