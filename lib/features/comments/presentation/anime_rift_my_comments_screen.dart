import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/anime_rift_account_content.dart';
import '../../../core/extensions/providers/anime_rift_comments.dart';
import '../../../core/extensions/providers/anime_rift_provider.dart';
import '../../../core/storage/anime_rift_account_scope.dart';
import '../../../core/utils/avatar_image.dart';
import '../../../core/utils/relative_time.dart';
import '../../../shared/widgets/app_page_header.dart';
import '../../../shared/widgets/mouse_drag_refresh_indicator.dart';
import 'anime_rift_comments_screen.dart';

/// Rift's own `/comment/history` data, styled like Witcher's My Comments.
class AnimeRiftMyCommentsScreen extends ConsumerStatefulWidget {
  const AnimeRiftMyCommentsScreen({super.key, required this.provider});

  final AnimeRiftProvider provider;

  @override
  ConsumerState<AnimeRiftMyCommentsScreen> createState() =>
      _AnimeRiftMyCommentsScreenState();
}

class _AnimeRiftMyCommentsScreenState
    extends ConsumerState<AnimeRiftMyCommentsScreen> {
  final _scroll = ScrollController();
  final _revealedSpoilers = <String>{};
  List<AnimeRiftMyComment> _items = const [];
  String? _account;
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _nextPage = 1;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void didUpdateWidget(covariant AnimeRiftMyCommentsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.provider, oldWidget.provider)) _reload();
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.hasClients &&
        _hasMore &&
        !_loading &&
        !_loadingMore &&
        _scroll.position.extentAfter < 400) {
      _loadMore();
    }
  }

  bool _current(int generation, String? account) =>
      mounted &&
      generation == _generation &&
      AnimeRiftLocalAccountScope.accountHash == account;

  Future<void> _reload() async {
    final generation = ++_generation;
    final account = AnimeRiftLocalAccountScope.accountHash;
    setState(() {
      _account = account;
      _items = const [];
      _loading = true;
      _loadingMore = false;
      _hasMore = false;
      _nextPage = 1;
      _error = null;
      _revealedSpoilers.clear();
    });
    try {
      if (account == null || !await widget.provider.restoreAccountSession()) {
        if (_current(generation, account)) {
          setState(() => _loading = false);
        }
        return;
      }
      final page = await widget.provider.loadMyComments();
      if (!_current(generation, account)) return;
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (_current(generation, account)) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = _generation;
    final account = _account;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.provider.loadMyComments(page: _nextPage);
      if (!_current(generation, account)) return;
      setState(() {
        final seen = _items.map((item) => item.comment.id).toSet();
        _items = [
          ..._items,
          ...page.items.where((item) => seen.add(item.comment.id)),
        ];
        _nextPage++;
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (_current(generation, account)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر تحميل المزيد من تعليقات Anime Rift.'),
          ),
        );
      }
    } finally {
      if (_current(generation, account)) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _openReplies(AnimeRiftMyComment item) {
    final animeId = item.animeId;
    if (animeId == null) return;
    final target = AnimeRiftCommentTarget(
      animeId: animeId,
      title: item.animeTitle ?? 'Anime Rift',
      parentId: item.comment.id,
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            AnimeRiftCommentsScreen(provider: widget.provider, target: target),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(accountDataRevisionProvider);
    if (!identical(ref.watch(activeProviderProvider), widget.provider)) {
      return Scaffold(
        appBar: AppPageAppBar(title: 'تعليقاتي', canPop: true),
        body: const Center(
          child: Text('انتقل إلى حساب Anime Rift لعرض تعليقاتك.'),
        ),
      );
    }
    if (_account != AnimeRiftLocalAccountScope.accountHash) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reload();
      });
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: 'تعليقاتي',
        canPop: Navigator.of(context).canPop(),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_account != AnimeRiftLocalAccountScope.accountHash || _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('تعذر جلب تعليقات حساب Anime Rift.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _reload,
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return MouseDragRefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: appPageHeaderContentTopInset(context)),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.26),
            const Icon(Icons.forum_outlined, size: 46),
            const SizedBox(height: 12),
            Text(
              _account == null
                  ? 'اربط حساب Anime Rift لعرض تعليقاتك.'
                  : 'لم تكتب أي تعليقات بعد.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return MouseDragRefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          12,
          appPageHeaderContentTopInset(context) + 12,
          12,
          28,
        ),
        itemCount: _items.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) => index == _items.length
            ? const Padding(
                padding: EdgeInsets.all(18),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : _card(_items[index]),
      ),
    );
  }

  Widget _card(AnimeRiftMyComment item) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final comment = item.comment;
    final photo = comment.photoUrl ?? '';
    final shown = !comment.spoiler || _revealedSpoilers.contains(comment.id);
    return Material(
      key: ValueKey('rift-my-comment-${comment.id}'),
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: colors.surfaceContainerHighest,
                  backgroundImage: avatarImage(context, photo, radius: 20),
                  child: photo.isEmpty
                      ? const Icon(Icons.person_rounded)
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        comment.author,
                        maxLines: 1,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        formatArabicRelativeTime(comment.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (item.isReview) const Chip(label: Text('مراجعة')),
              ],
            ),
            if (item.animeTitle != null) ...[
              const SizedBox(height: 8),
              Text(
                item.animeTitle!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.primary,
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (shown)
              Text(
                comment.text,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _revealedSpoilers.add(comment.id)),
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('تعليق يحتوي على حرق — إظهار'),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.favorite_outline_rounded, size: 18),
                const SizedBox(width: 4),
                Text('${comment.likes}'),
                const SizedBox(width: 18),
                TextButton.icon(
                  onPressed: item.animeId == null
                      ? null
                      : () => _openReplies(item),
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                  label: Text('${comment.replies}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
