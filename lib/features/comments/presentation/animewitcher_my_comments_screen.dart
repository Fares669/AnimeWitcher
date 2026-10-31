import 'package:flutter/material.dart';

import 'comment_edit_dialog.dart';
import 'comment_pager.dart';
import '../../../core/utils/relative_time.dart';
import '../../../shared/widgets/confirm_dialog.dart';

import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/account/animewitcher_comment_models.dart';
import '../../../core/account/animewitcher_sync_ids.dart';
import '../../../core/account/firestore_rest_client.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/router/app_router.dart';
import 'animewitcher_replies_screen.dart';
import 'widgets/animewitcher_comment_sort_control.dart';
import '../../../core/utils/avatar_image.dart';

const Key kMyCommentsSortButtonKey = kAnimeWitcherCommentSortControlKey;
const Key kMyCommentsTitleKey = Key('my-comments-title');

class AnimeWitcherMyCommentsScreen extends ConsumerStatefulWidget {
  const AnimeWitcherMyCommentsScreen({super.key, this.isReviews = false});

  final bool isReviews;

  @override
  ConsumerState<AnimeWitcherMyCommentsScreen> createState() =>
      _AnimeWitcherMyCommentsScreenState();
}

class _AnimeWitcherMyCommentsScreenState
    extends ConsumerState<AnimeWitcherMyCommentsScreen> {
  int get _pageSize => widget.isReviews ? kAnimeWitcherReviewsPageSize : 20;

  bool get _isReviews => widget.isReviews;

  late final ScrollController _scrollController;
  final Set<String> _busyComments = <String>{};

  final CommentPager _pager = CommentPager();
  AnimeWitcherCommentSort _sort = AnimeWitcherCommentSort.newest;

  String get _editDialogTitle =>
      _isReviews ? 'تعديل المراجعة' : 'تعديل التعليق';

  String get _editHint => _isReviews ? 'اكتب مراجعة...' : 'اكتب التعليق...';

  String get _editedMessage =>
      _isReviews ? 'تم تعديل المراجعة.' : 'تم تعديل التعليق.';

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadInitial();
    });
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_pager.shouldLoadMore(_scrollController)) _loadMore();
  }

  Future<AnimeWitcherCommentPage> _fetchPage(FirestoreDocument? cursor) {
    final sort = _sort;
    final service = ref.read(animeWitcherAccountServiceProvider);
    return _isReviews
        ? service.loadMyReviews(sort: sort, cursor: cursor, limit: _pageSize)
        : service.loadMyComments(sort: sort, cursor: cursor, limit: _pageSize);
  }

  Future<void> _loadInitial() async {
    if (!mounted) return;
    final future = _pager.loadInitial(_fetchPage);
    setState(() {});
    if (await future && mounted) setState(() {});
  }

  Future<void> _loadMore() async {
    if (_pager.loadingInitial || _pager.loadingMore || !_pager.hasMore) {
      return;
    }
    final future = _pager.loadMore(
      _fetchPage,
      onError: (error) {
        if (mounted) _showMessage(_errorText(error), isError: true);
      },
    );
    setState(() {});
    if (await future && mounted) setState(() {});
  }

  Future<void> _changeSort(AnimeWitcherCommentSort sort) async {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _loadInitial();
  }

  Future<void> _handleAction(
    AnimeWitcherComment comment,
    _MyCommentAction action,
  ) async {
    switch (action) {
      case _MyCommentAction.edit:
        await _editComment(comment);
        return;
      case _MyCommentAction.delete:
        await _deleteComment(comment);
        return;
      case _MyCommentAction.closeReplies:
        await _closeReplies(comment);
        return;
    }
  }

  Future<void> _editComment(AnimeWitcherComment comment) async {
    final draft = await showCommentEditDialog(
      context,
      title: _editDialogTitle,
      hint: _editHint,
      initialText: comment.text,
      initialSpoiler: comment.spoiler,
      isReview: _isReviews,
    );
    if (draft == null || !mounted) return;
    _setBusy(comment.path, true);
    try {
      final updated = await ref
          .read(animeWitcherAccountServiceProvider)
          .updateOwnComment(comment, draft.text, spoiler: draft.spoiler);
      if (!mounted) return;
      _replaceComment(updated);
      _showMessage(_editedMessage);
    } catch (error) {
      if (mounted) _showMessage(_errorText(error), isError: true);
    } finally {
      if (mounted) _setBusy(comment.path, false);
    }
  }

  Future<void> _deleteComment(AnimeWitcherComment comment) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'حذف التعليق؟',
      message: 'هل أنت متأكد من حذف هذا التعليق؟',
      confirmLabel: 'حذف',
    );
    if (!confirmed || !mounted) return;

    _setBusy(comment.path, true);
    try {
      await ref
          .read(animeWitcherAccountServiceProvider)
          .deleteOwnComment(comment);
      if (!mounted) return;
      setState(() {
        _pager.items.removeWhere((item) => item.path == comment.path);
      });
      _showMessage('تم حذف التعليق.');
    } catch (error) {
      if (mounted) _showMessage(_errorText(error), isError: true);
    } finally {
      if (mounted) _setBusy(comment.path, false);
    }
  }

  Future<void> _closeReplies(AnimeWitcherComment comment) async {
    if (comment.repliesClosed) return;
    final confirmed = await showConfirmDialog(
      context,
      title: 'منع الردود؟',
      message: 'هل أنت متأكد من منع الردود على هذا التعليق؟',
      confirmLabel: 'منع',
      destructive: false,
    );
    if (!confirmed || !mounted) return;

    _setBusy(comment.path, true);
    try {
      final updated = await ref
          .read(animeWitcherAccountServiceProvider)
          .closeOwnCommentReplies(comment);
      if (!mounted) return;
      _replaceComment(updated);
      _showMessage('تم منع الردود.');
    } catch (error) {
      if (mounted) _showMessage(_errorText(error), isError: true);
    } finally {
      if (mounted) _setBusy(comment.path, false);
    }
  }

  Future<void> _openReplies(AnimeWitcherComment comment) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AnimeWitcherRepliesScreen(parentComment: comment),
      ),
    );
  }

  void _openAnime(AnimeWitcherComment comment) {
    final animeId = comment.animeId?.trim();
    if (animeId == null || animeId.isEmpty) return;

    DetailsRoute(
      $extra: DetailsRouteExtra(
        item: MultimediaItem(
          title: animeId,
          url: AnimeWitcherSyncIds.mainUrl(animeId),
          posterUrl: '',
          contentType: MultimediaContentType.anime,
          provider: animeWitcherNativeProviderId,
        ),
      ),
    ).push<void>(context);
  }

  void _replaceComment(AnimeWitcherComment updated) {
    final index = _pager.items.indexWhere((item) => item.path == updated.path);
    if (index < 0) return;
    setState(() => _pager.items[index] = updated);
  }

  void _setBusy(String path, bool busy) {
    setState(() {
      if (busy) {
        _busyComments.add(path);
      } else {
        _busyComments.remove(path);
      }
    });
  }

  void _showMessage(
    String message, {
    bool isError = false,
    bool isInfo = false,
  }) {
    if (!mounted) return;
    final notifications = ref.read(notificationServiceProvider);
    if (isError) {
      notifications.showError(message);
    } else if (isInfo) {
      notifications.showInfo(message);
    } else {
      notifications.showSuccess(message);
    }
  }

  String _sortTooltip() => _isReviews ? 'ترتيب المراجعات' : 'ترتيب التعليقات';

  String _screenTitle() => ((_isReviews ? 'مراجعاتي' : 'تعليقاتي'));

  AnimeWitcherCommentSort _sortFromValue(String value) {
    for (final option in AnimeWitcherCommentSort.values) {
      if (option.name == value) return option;
    }
    return _sort;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(animeWitcherAccountControllerProvider);

    final usePersistentGlass = appleUsesPersistentLiquidGlassHeader;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: _screenTitle(),
        titleKey: kMyCommentsTitleKey,
        onBack: () => Navigator.of(context).maybePop(),
        actions: usePersistentGlass
            ? const <Widget>[]
            : AnimeWitcherCommentSortControl.appBarActions(
                tooltip: _sortTooltip(),
                selectedValue: _sort.name,
                items: AnimeWitcherCommentSortControl.menuItems(),
                onSelected: (value) {
                  _changeSort(_sortFromValue(value));
                },
              ),
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
    if (_pager.loadingInitial) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pager.loadError != null && _pager.items.isEmpty) {
      return _MyCommentsError(
        message: _errorText(_pager.loadError!),
        retryLabel: 'إعادة المحاولة',
        onRetry: _loadInitial,
      );
    }
    if (_pager.items.isEmpty) {
      return MouseDragRefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: appPageHeaderContentTopInset(context)),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.26),
            const Icon(Icons.forum_outlined, size: 46),
            const SizedBox(height: 12),
            Text(
              ((_isReviews
                  ? 'لم تكتب أي مراجعات بعد.'
                  : 'لم تكتب أي تعليقات بعد.')),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return MouseDragRefreshIndicator(
      onRefresh: _loadInitial,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          12,
          appPageHeaderContentTopInset(context) + 12,
          12,
          28,
        ),
        itemCount:
            _pager.items.length +
            (_pager.hasMore || _pager.loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index >= _pager.items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
            );
          }
          final comment = _pager.items[index];
          return _buildCommentCard(
            comment,
            busy: _busyComments.contains(comment.path),
          );
        },
      ),
    );
  }

  Widget _buildCommentCard(AnimeWitcherComment comment, {required bool busy}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final photo = comment.userPhotoUrl?.trim() ?? '';
    final tags = _commentTags(comment);

    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 2),
          IgnorePointer(
            ignoring: busy,
            child: Opacity(
              opacity: busy ? 0.58 : 1,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Directionality(
                      textDirection: TextDirection.rtl,
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: colors.surfaceContainerHighest,
                            backgroundImage: avatarImage(
                              context,
                              photo,
                              radius: 20,
                            ),
                            child: photo.isEmpty
                                ? Icon(
                                    Icons.person_rounded,
                                    color: colors.onSurfaceVariant,
                                  )
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  comment.userName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  formatArabicRelativeTime(comment.date),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<_MyCommentAction>(
                            tooltip: 'إدارة التعليق',
                            onSelected: (action) {
                              _handleAction(comment, action);
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem<_MyCommentAction>(
                                value: _MyCommentAction.edit,
                                child: _actionRow(Icons.edit_rounded, 'تعديل'),
                              ),
                              PopupMenuItem<_MyCommentAction>(
                                value: _MyCommentAction.delete,
                                child: _actionRow(
                                  Icons.delete_outline_rounded,
                                  'حذف',
                                ),
                              ),
                              PopupMenuItem<_MyCommentAction>(
                                value: _MyCommentAction.closeReplies,
                                enabled: !comment.repliesClosed,
                                child: _actionRow(
                                  Icons.block_rounded,
                                  comment.repliesClosed
                                      ? 'الردود متوقفة'
                                      : 'منع الردود',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(spacing: 6, runSpacing: 6, children: tags),
                    ],
                    const SizedBox(height: 10),
                    Directionality(
                      textDirection: TextDirection.rtl,
                      child: Text(
                        comment.text,
                        textAlign: TextAlign.start,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if ((!_isReviews && comment.spoiler) ||
                        comment.repliesClosed ||
                        (_isReviews && !comment.published)) ...[
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (_isReviews && !comment.published)
                            _statusChip(
                              Icons.hourglass_top_rounded,
                              'جاري مراجعته',
                              colors.tertiaryContainer,
                              colors.onTertiaryContainer,
                            ),
                          if (!_isReviews && comment.spoiler)
                            _statusChip(
                              Icons.local_fire_department_rounded,
                              'حرق',
                              colors.errorContainer,
                              colors.onErrorContainer,
                            ),
                          if (comment.repliesClosed)
                            _statusChip(
                              Icons.block_rounded,
                              'الردود متوقفة',
                              colors.secondaryContainer,
                              colors.onSecondaryContainer,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    Directionality(
                      textDirection: TextDirection.rtl,
                      child: Row(
                        children: [
                          const Spacer(),
                          Icon(
                            Icons.favorite_border_rounded,
                            size: 18,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text('${comment.likes}'),
                          const SizedBox(width: 14),
                          InkWell(
                            onTap: () => _openReplies(comment),
                            borderRadius: BorderRadius.circular(18),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.chat_bubble_outline_rounded,
                                    size: 18,
                                    color: colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text('${comment.replies}'),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(IconData icon, String label) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 10), Text(label)],
    );
  }

  List<Widget> _commentTags(AnimeWitcherComment comment) {
    final tags = <Widget>[];
    if (comment.animeId?.isNotEmpty == true) {
      tags.add(
        _tag(
          Icons.movie_outlined,
          comment.animeId!,
          onTap: () => _openAnime(comment),
        ),
      );
    } else if (comment.characterName?.isNotEmpty == true) {
      tags.add(_tag(Icons.person_search_rounded, comment.characterName!));
    }
    if (comment.episodeName?.isNotEmpty == true) {
      tags.add(_tag(Icons.play_circle_outline_rounded, comment.episodeName!));
    }
    if (comment.newsId?.isNotEmpty == true) {
      tags.add(_tag(Icons.newspaper_rounded, 'خبر'));
    }
    return tags;
  }

  Widget _tag(IconData icon, String label, {VoidCallback? onTap}) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(10);
    return Semantics(
      button: onTap != null,
      label: label,
      child: Material(
        color: colors.primaryContainer,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: colors.onPrimaryContainer),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip(
    IconData icon,
    String label,
    Color background,
    Color foreground,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  String _errorText(Object error) {
    if (error is AnimeWitcherAccountException) {
      return switch (error.code) {
        'not-signed-in' => 'يجب تسجيل الدخول.',
        'comment-empty' => 'يرجى إدخال نص.',
        'comment-too-long' => 'الحد الأعلى للنص 500 حرف.',
        'comment-banned' => 'تم حظرك من التعليق.',
        'comment-account-too-new' => 'يجب أن يمر 7 أيام على إنشاء الحساب.',
        'permission-denied' => 'لا يمكن تعديل هذا التعليق.',
        'review-exists' => 'لديك مراجعة واحدة فقط على هذا الأنمي.',
        _ => error.message,
      };
    }
    return 'حدث خطأ. حاول مرة أخرى.';
  }
}

enum _MyCommentAction { edit, delete, closeReplies }

class _MyCommentsError extends StatelessWidget {
  const _MyCommentsError({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
