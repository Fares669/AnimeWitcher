import 'dart:async';

import 'comment_edit_dialog.dart';
import 'comment_pager.dart';
import '../../../core/utils/relative_time.dart';
import '../../../shared/widgets/confirm_dialog.dart';

import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/services/notification_service.dart';

import 'animewitcher_replies_screen.dart';
import 'widgets/animewitcher_comment_sort_control.dart';
import '../../../core/utils/avatar_image.dart';

class AnimeWitcherCommentsScreen extends ConsumerStatefulWidget {
  const AnimeWitcherCommentsScreen({super.key, required this.target});

  final AnimeWitcherCommentTarget target;

  @override
  ConsumerState<AnimeWitcherCommentsScreen> createState() =>
      _AnimeWitcherCommentsScreenState();
}

class _AnimeWitcherCommentsScreenState
    extends ConsumerState<AnimeWitcherCommentsScreen> {
  int get _pageSize => _isReviews ? kAnimeWitcherReviewsPageSize : 20;

  bool get _isReviews => widget.target.isReviews;

  String _screenTitle() => _isReviews ? 'المراجعات' : 'التعليقات';

  String _sortTooltip() => _isReviews ? 'ترتيب المراجعات' : 'ترتيب التعليقات';

  String _emptyListText() => _isReviews
      ? 'لا توجد مراجعات منشورة بعد.'
      : 'لا توجد تعليقات منشورة بعد.';

  String _composerHint() => _isReviews ? 'اكتب مراجعة...' : 'اكتب تعليقًا...';

  String _signInComposerText() => _isReviews
      ? 'سجّل الدخول إلى حساب AnimeWitcher لإضافة مراجعة.'
      : 'سجّل الدخول إلى حساب AnimeWitcher لإضافة تعليق.';

  String _publishedMessage() =>
      _isReviews ? 'جاري مراجعته.' : 'تم نشر تعليقك وهو قيد المراجعة.';

  String _editDialogTitle() => _isReviews ? 'تعديل المراجعة' : 'تعديل التعليق';

  String _editHint() => _isReviews ? 'اكتب مراجعة...' : 'اكتب التعليق...';

  String _editedMessage() =>
      _isReviews ? 'تم تعديل المراجعة.' : 'تم تعديل التعليق.';

  final TextEditingController _commentController = TextEditingController();
  final Set<String> _revealedSpoilers = <String>{};
  final Set<String> _pendingLikes = <String>{};
  final Set<String> _pendingCommentActions = <String>{};
  late final ScrollController _scrollController;

  final CommentPager _pager = CommentPager();
  AnimeWitcherCommentSort _sort = AnimeWitcherCommentSort.commentsDefault;
  bool _spoiler = false;
  bool _publishing = false;

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
    applePersistentGlassHeaderController.hide(this);
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _commentController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_pager.shouldLoadMore(_scrollController)) _loadMore();
  }

  Future<AnimeWitcherCommentPage> _fetchPage(FirestoreDocument? cursor) {
    final sort = _sort;
    return ref
        .read(animeWitcherAccountServiceProvider)
        .loadComments(
          widget.target,
          sort: sort,
          cursor: cursor,
          limit: _pageSize,
        );
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
        if (mounted) _showMessage(_commentErrorText(error), isError: true);
      },
    );
    setState(() {});
    if (await future && mounted) setState(() {});
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    setState(() => _publishing = true);
    try {
      await ref
          .read(animeWitcherAccountServiceProvider)
          .publishComment(
            widget.target,
            text,
            spoiler: _isReviews ? false : _spoiler,
          );
      if (!mounted) return;
      _commentController.clear();
      setState(() => _spoiler = false);
      _showMessage(_publishedMessage());
      await _loadInitial();
    } catch (error) {
      if (!mounted) return;
      _showMessage(_commentErrorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _toggleLike(AnimeWitcherComment comment) async {
    if (_pendingLikes.contains(comment.path)) return;
    final service = ref.read(animeWitcherAccountServiceProvider);

    if (!service.isSignedIn) {
      _showMessage('يجب تسجيل الدخول', isInfo: true);
      return;
    }
    if (service.ownsComment(comment)) {
      return;
    }

    setState(() => _pendingLikes.add(comment.path));
    try {
      final updated = await service.toggleCommentLike(comment);
      if (!mounted) return;
      final index = _pager.items.indexWhere(
        (item) => item.path == comment.path,
      );
      if (index >= 0) {
        setState(() => _pager.items[index] = updated);
      }
    } catch (error) {
      if (mounted) {
        _showMessage(_commentErrorText(error), isError: true);
      }
    } finally {
      if (mounted) setState(() => _pendingLikes.remove(comment.path));
    }
  }

  Future<void> _openReplies(AnimeWitcherComment comment) async {
    // Keep this route alive under the replies stack. The previous
    // implementation refetched comments on pop, which rebuilt the list and
    // jumped scroll position. Match APK: comments stay as they were.
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AnimeWitcherRepliesScreen(parentComment: comment),
      ),
    );
  }

  Future<void> _applyCommentSort(AnimeWitcherCommentSort selected) async {
    if (selected == _sort || !mounted) return;
    setState(() => _sort = selected);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    await _loadInitial();
  }

  Future<void> _handleOwnCommentAction(
    AnimeWitcherComment comment,
    _OwnCommentAction action,
  ) async {
    switch (action) {
      case _OwnCommentAction.edit:
        await _editOwnComment(comment);
        return;
      case _OwnCommentAction.delete:
        await _deleteOwnComment(comment);
        return;
      case _OwnCommentAction.closeReplies:
        await _closeOwnCommentReplies(comment);
        return;
    }
  }

  Future<void> _editOwnComment(AnimeWitcherComment comment) async {
    final draft = await showCommentEditDialog(
      context,
      title: _editDialogTitle(),
      hint: _editHint(),
      initialText: comment.text,
      initialSpoiler: comment.spoiler,
      isReview: _isReviews,
    );
    if (draft == null || !mounted) return;
    _setCommentActionPending(comment.path, true);
    try {
      final updated = await ref
          .read(animeWitcherAccountServiceProvider)
          .updateOwnComment(comment, draft.text, spoiler: draft.spoiler);
      if (!mounted) return;
      _replaceComment(updated);
      _showMessage(_editedMessage());
    } catch (error) {
      if (mounted) {
        _showMessage(_commentErrorText(error), isError: true);
      }
    } finally {
      if (mounted) _setCommentActionPending(comment.path, false);
    }
  }

  Future<void> _deleteOwnComment(AnimeWitcherComment comment) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'حذف التعليق؟',
      message: 'هل أنت متأكد من حذف هذا التعليق؟',
      confirmLabel: 'حذف',
    );
    if (!confirmed || !mounted) return;

    _setCommentActionPending(comment.path, true);
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
      if (mounted) {
        _showMessage(_commentErrorText(error), isError: true);
      }
    } finally {
      if (mounted) _setCommentActionPending(comment.path, false);
    }
  }

  Future<void> _closeOwnCommentReplies(AnimeWitcherComment comment) async {
    if (comment.repliesClosed) return;

    final confirmed = await showConfirmDialog(
      context,
      title: 'منع الردود؟',
      message: 'هل أنت متأكد من منع الردود على هذا التعليق؟',
      confirmLabel: 'منع',
      destructive: false,
    );
    if (!confirmed || !mounted) return;

    _setCommentActionPending(comment.path, true);
    try {
      final updated = await ref
          .read(animeWitcherAccountServiceProvider)
          .closeOwnCommentReplies(comment);
      if (!mounted) return;
      _replaceComment(updated);
      _showMessage('تم منع الردود.');
    } catch (error) {
      if (mounted) {
        _showMessage(_commentErrorText(error), isError: true);
      }
    } finally {
      if (mounted) _setCommentActionPending(comment.path, false);
    }
  }

  void _replaceComment(AnimeWitcherComment updated) {
    final index = _pager.items.indexWhere((item) => item.path == updated.path);
    if (index < 0) return;
    setState(() => _pager.items[index] = updated);
  }

  void _setCommentActionPending(String path, bool pending) {
    setState(() {
      if (pending) {
        _pendingCommentActions.add(path);
      } else {
        _pendingCommentActions.remove(path);
      }
    });
  }

  AnimeWitcherCommentSort _commentSortFromValue(String value) {
    for (final option in AnimeWitcherCommentSort.values) {
      if (option.name == value) return option;
    }
    return _sort;
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

  @override
  Widget build(BuildContext context) {
    final accountState = ref.watch(animeWitcherAccountControllerProvider);
    final service = ref.read(animeWitcherAccountServiceProvider);
    final isSignedIn =
        accountState.asData?.value.isSignedIn ?? service.isSignedIn;

    if (appleUsesPersistentLiquidGlassHeader) {
      final colors = Theme.of(context).colorScheme;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
        applePersistentGlassHeaderController.show(
          ApplePersistentGlassHeaderConfig(
            owner: this,
            route: ModalRoute.of(context),
            onBack: () => Navigator.of(context).pop(),
            backForegroundColor: colors.onSurface,
            backFallbackColor: colors.surfaceContainerHigh,
            allowInstantBoundaryMorph: true,
            toolbarTrailingInset:
                AnimeWitcherCommentSortControl.persistentTrailingInset,
            trailingButtons: AnimeWitcherCommentSortControl.persistentButtons(
              context: context,
              tooltip: _sortTooltip(),
              sort: _sort,
              onSelected: (value) {
                _applyCommentSort(_commentSortFromValue(value));
              },
            ),
          ),
        );
      });
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: _screenTitle(),
        onBack: () => Navigator.of(context).pop(),
        actions: appleUsesPersistentLiquidGlassHeader
            ? const <Widget>[]
            : AnimeWitcherCommentSortControl.appBarActions(
                tooltip: _sortTooltip(),
                selectedValue: _sort.name,
                items: AnimeWitcherCommentSortControl.menuItems(),
                onSelected: (value) {
                  _applyCommentSort(_commentSortFromValue(value));
                },
              ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildCommentsBody(context)),
          _buildComposer(context, isSignedIn),
        ],
      ),
    );
  }

  Widget _buildCommentsBody(BuildContext context) {
    if (_pager.loadingInitial) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pager.loadError != null && _pager.items.isEmpty) {
      return _CommentsLoadError(isReviews: _isReviews, onRetry: _loadInitial);
    }
    if (_pager.items.isEmpty) {
      return MouseDragRefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: appPageHeaderContentTopInset(context)),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _emptyListText(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
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
          24,
        ),
        itemCount:
            _pager.items.length +
            (_pager.hasMore || _pager.loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= _pager.items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
            );
          }
          return _buildCommentCard(context, _pager.items[index]);
        },
      ),
    );
  }

  Widget _buildCommentCard(BuildContext context, AnimeWitcherComment comment) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final photo = comment.userPhotoUrl?.trim() ?? '';
    final reveal =
        _isReviews ||
        !comment.spoiler ||
        _revealedSpoilers.contains(comment.path);
    final likePending = _pendingLikes.contains(comment.path);
    final actionPending = _pendingCommentActions.contains(comment.path);
    final ownsComment = ref
        .read(animeWitcherAccountServiceProvider)
        .ownsComment(comment);

    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                    backgroundImage: avatarImage(context, photo, radius: 20),
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
                        const SizedBox(height: 2),
                        Text(
                          formatArabicRelativeTime(comment.date),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (ownsComment)
                    actionPending
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : PopupMenuButton<_OwnCommentAction>(
                            tooltip: 'إدارة التعليق',
                            onSelected: (action) {
                              unawaited(
                                _handleOwnCommentAction(comment, action),
                              );
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem<_OwnCommentAction>(
                                value: _OwnCommentAction.edit,
                                child: _commentActionRow(
                                  Icons.edit_rounded,
                                  'تعديل',
                                ),
                              ),
                              PopupMenuItem<_OwnCommentAction>(
                                value: _OwnCommentAction.delete,
                                child: _commentActionRow(
                                  Icons.delete_outline_rounded,
                                  'حذف',
                                ),
                              ),
                              PopupMenuItem<_OwnCommentAction>(
                                value: _OwnCommentAction.closeReplies,
                                enabled: !comment.repliesClosed,
                                child: _commentActionRow(
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
            const SizedBox(height: 10),
            if (reveal)
              Directionality(
                textDirection: TextDirection.rtl,
                child: Text(
                  comment.text,
                  textAlign: TextAlign.start,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _revealedSpoilers.add(comment.path));
                  },
                  icon: const Icon(Icons.local_fire_department_rounded),
                  label: Text('تعليق يحتوي على حرق — إظهار'),
                ),
              ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _ReactionButton(
                    icon: comment.likedByMe
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    count: comment.likes,
                    active: comment.likedByMe,
                    busy: likePending,
                    tooltip: 'إعجاب',
                    onTap: () => _toggleLike(comment),
                  ),
                  const SizedBox(width: 14),
                  _ReactionButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    count: comment.replies,
                    tooltip: 'الردود',
                    onTap: () => _openReplies(comment),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commentActionRow(IconData icon, String label) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 10), Text(label)],
    );
  }

  Widget _buildComposer(BuildContext context, bool isSignedIn) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: isSignedIn
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 500,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: _composerHint(),
                        counterText: '',
                        filled: true,
                        fillColor: colors.surfaceContainerLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide(
                            color: colors.primary,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (!_isReviews)
                    IconButton(
                      tooltip: 'يحتوي على حرق',
                      onPressed: () => setState(() => _spoiler = !_spoiler),
                      icon: Icon(
                        Icons.local_fire_department_rounded,
                        color: _spoiler
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  IconButton.filled(
                    tooltip: 'نشر',
                    onPressed: _publishing ? null : _publish,
                    icon: _publishing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _signInComposerText(),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ReactionButton extends StatelessWidget {
  const _ReactionButton({
    required this.icon,
    required this.count,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final int count;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = active ? colors.primary : colors.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foreground,
                  ),
                )
              else
                Icon(icon, size: 19, color: foreground),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentsLoadError extends StatelessWidget {
  const _CommentsLoadError({required this.onRetry, this.isReviews = false});

  final bool isReviews;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40),
            const SizedBox(height: 10),
            Text(
              isReviews ? 'تعذر تحميل المراجعات.' : 'تعذر تحميل التعليقات.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _OwnCommentAction { edit, delete, closeReplies }

String _commentErrorText(Object error) {
  if (error is AnimeWitcherAccountException) {
    return switch (error.code) {
      'not-signed-in' => 'يجب تسجيل الدخول قبل تنفيذ هذه العملية.',
      'comment-empty' => 'يرجى إدخال نص.',
      'comment-too-long' => 'الحد الأعلى للنص 500 حرف.',
      'comment-banned' => 'تم حظرك من التعليق.',
      'comment-account-too-new' =>
        'يجب أن يمر على إنشاء حسابك 7 أيام قبل أن تتمكن من كتابة التعليقات.',
      'comment-cooldown' => 'انتظر قليلاً حتى يمكنك التعليق مرة أخرى.',
      'comment-limit' => 'لقد وصلت للحد الأقصى لعدد التعليقات على هذا المحتوى.',
      'comments-closed' => 'تم إيقاف التعليقات على هذا المحتوى.',
      'reviews-closed' => 'تم ايقاف المراجعات علي هذا الأنمي',
      'review-exists' => 'لديك مراجعة واحدة فقط على هذا الأنمي.',
      'replies-closed' => 'تم إيقاف الردود على هذا التعليق.',
      'permission-denied' => 'لا يمكن تعديل هذا التعليق.',
      _ => error.message,
    };
  }
  return 'حدث خطأ. حاول مرة أخرى.';
}
