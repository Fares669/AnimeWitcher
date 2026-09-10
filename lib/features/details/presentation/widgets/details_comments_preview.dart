/// The start of the conversation about an anime, at the foot of its page.
///
/// Comments used to be a button in the row of actions, which said only that
/// they existed. A few of them on the page says what people made of the
/// thing a viewer is deciding whether to watch, and the way in is reading
/// one rather than pressing an icon to find out whether there are any.
library;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/account/firestore_rest_client.dart';
import '../../../../core/account/animewitcher_comment_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../comments/presentation/animewitcher_comments_screen.dart';
import '../../../comments/presentation/animewitcher_replies_screen.dart';
import '../../../../core/utils/avatar_image.dart';

const Key kDetailsCommentsPreviewKey = Key('details-comments-preview');

/// How many arrive at a time as the page is scrolled.
const int kDetailsCommentsPageSize = 6;

/// How close to the foot of the page counts as asking for more.
const double kDetailsCommentsLoadMargin = 700;

class DetailsCommentsPreview extends ConsumerStatefulWidget {
  const DetailsCommentsPreview({super.key, required this.item});

  final MultimediaItem item;

  @override
  ConsumerState<DetailsCommentsPreview> createState() =>
      _DetailsCommentsPreviewState();
}

class _DetailsCommentsPreviewState
    extends ConsumerState<DetailsCommentsPreview> {
  List<AnimeWitcherComment> _comments = const <AnimeWitcherComment>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  FirestoreDocument? _cursor;
  Object? _error;
  ScrollPosition? _watchedPosition;

  AnimeWitcherCommentTarget? get _target =>
      animeWitcherAnimeCommentTarget(widget.item);

  @override
  void initState() {
    super.initState();
    _load();
    // The comments sit at the foot of the page's own scroll rather than in a
    // list of their own, so more of them are asked for by watching that.
    WidgetsBinding.instance.addPostFrameCallback((_) => _watchPageScroll());
  }

  void _watchPageScroll() {
    if (!mounted) return;
    final position = Scrollable.maybeOf(context)?.position;
    if (identical(position, _watchedPosition)) return;
    _watchedPosition?.removeListener(_onPageScroll);
    _watchedPosition = position?..addListener(_onPageScroll);
  }

  void _onPageScroll() {
    final position = _watchedPosition;
    if (position == null || !position.hasContentDimensions) return;
    final remaining = position.maxScrollExtent - position.pixels;
    if (remaining <= kDetailsCommentsLoadMargin) _loadMore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchPageScroll();
  }

  @override
  void dispose() {
    _watchedPosition?.removeListener(_onPageScroll);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DetailsCommentsPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url) _load();
  }

  Future<void> _load() async {
    final target = _target;
    if (target == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _cursor = null;
      _error = null;
    });
    try {
      final page = await ref
          .read(animeWitcherAccountServiceProvider)
          .loadComments(target, limit: kDetailsCommentsPageSize);
      if (!mounted) return;
      setState(() {
        _comments = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final target = _target;
    if (target == null || _loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(animeWitcherAccountServiceProvider)
          .loadComments(
            target,
            cursor: _cursor,
            limit: kDetailsCommentsPageSize,
          );
      if (!mounted) return;
      setState(() {
        _comments = <AnimeWitcherComment>[..._comments, ...page.items];
        _cursor = page.cursor;
        // A page that came back short is the end of them, whatever it says.
        _hasMore = page.hasMore && page.items.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // The ones already read stay on the page; the next scroll tries again.
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _openReplies(AnimeWitcherComment comment) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimeWitcherRepliesScreen(parentComment: comment),
      ),
    );
    // The count on the row is part of the comment as it was read, so it is
    // re-read rather than guessed at after a reply is left.
    if (mounted) _load();
  }

  Future<void> _openAll() async {
    final target = _target;
    if (target == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimeWitcherCommentsScreen(target: target),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_target == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final title = appText(context, english: 'Comments', arabic: 'التعليقات');

    return KeyedSubtree(
      key: kDetailsCommentsPreviewKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _openAll,
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: Text(
                  appText(context, english: 'See all', arabic: 'عرض الكل'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _PreviewNotice(
              text: appText(
                context,
                english: 'Comments could not be loaded',
                arabic: 'تعذر تحميل التعليقات',
              ),
              onTap: _load,
            )
          else if (_comments.isEmpty)
            _PreviewNotice(
              text: appText(
                context,
                english: 'No comments yet — be the first',
                arabic: 'لا توجد تعليقات بعد — كن أول من يكتب',
              ),
              onTap: _openAll,
            )
          else ...[
            for (final comment in _comments)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _CommentRow(
                  comment: comment,
                  onTap: _openAll,
                  onReplies: () => _openReplies(comment),
                ),
              ),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.onTap,
    required this.onReplies,
  });

  final AnimeWitcherComment comment;
  final VoidCallback onTap;
  final VoidCallback onReplies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: colors.surfaceContainerHighest,
                backgroundImage: avatarImage(
                  context,
                  comment.userPhotoUrl,
                  radius: 18,
                ),
                child:
                    (comment.userPhotoUrl == null ||
                        comment.userPhotoUrl!.isEmpty)
                    ? Icon(
                        Icons.person,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comment.userName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      // A comment marked as a spoiler stays covered here:
                      // this is a page for deciding what to watch.
                      comment.spoiler
                          ? appText(
                              context,
                              english: 'Spoiler — open to read',
                              arabic: 'يحتوي على حرق — افتح للقراءة',
                            )
                          : comment.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: comment.spoiler
                            ? colors.onSurfaceVariant
                            : colors.onSurface.withValues(alpha: 0.86),
                        fontStyle: comment.spoiler
                            ? FontStyle.italic
                            : FontStyle.normal,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CommentTally(
                    icon: Icons.favorite_rounded,
                    count: comment.likes,
                  ),
                  const SizedBox(width: 14),
                  // The replies are their own conversation, so the count is
                  // the way into it rather than a number beside the text.
                  _CommentTally(
                    icon: Icons.mode_comment_outlined,
                    count: comment.replies,
                    onTap: comment.replies > 0 ? onReplies : null,
                    tooltip: appText(
                      context,
                      english: 'Replies',
                      arabic: 'الردود',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Text(text, style: TextStyle(color: colors.onSurfaceVariant)),
        ),
      ),
    );
  }
}

/// A count with its mark, tappable when it leads somewhere.
class _CommentTally extends StatelessWidget {
  const _CommentTally({
    required this.icon,
    required this.count,
    this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final int count;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = onTap != null;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
          color: colors.onSurfaceVariant.withValues(alpha: active ? 0.95 : 0.7),
        ),
        const SizedBox(width: 4),
        Text(
          '$count',
          style: theme.textTheme.labelMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );

    if (!active) return content;
    final tappable = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: content,
        ),
      ),
    );
    return tooltip == null
        ? tappable
        : Tooltip(message: tooltip!, child: tappable);
  }
}
