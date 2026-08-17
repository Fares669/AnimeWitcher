import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skystream/core/account/account_providers.dart';
import 'package:skystream/core/account/animewitcher_account_models.dart';
import 'package:skystream/core/account/animewitcher_comment_models.dart';
import 'package:skystream/core/account/firestore_rest_client.dart';

import 'animewitcher_replies_screen.dart';

class AnimeWitcherCommentsScreen extends ConsumerStatefulWidget {
  const AnimeWitcherCommentsScreen({
    super.key,
    required this.target,
  });

  final AnimeWitcherCommentTarget target;

  @override
  ConsumerState<AnimeWitcherCommentsScreen> createState() =>
      _AnimeWitcherCommentsScreenState();
}

class _AnimeWitcherCommentsScreenState
    extends ConsumerState<AnimeWitcherCommentsScreen> {
  static const int _pageSize = 20;

  final TextEditingController _commentController = TextEditingController();
  final Set<String> _revealedSpoilers = <String>{};
  final Set<String> _pendingLikes = <String>{};
  final Set<String> _pendingCommentActions = <String>{};
  late final ScrollController _scrollController;

  List<AnimeWitcherComment> _comments = <AnimeWitcherComment>[];
  AnimeWitcherCommentSort _sort = AnimeWitcherCommentSort.newest;
  Object? _loadError;
  FirestoreDocument? _cursor;
  bool _loadingInitial = true;
  bool _loadingMore = false;
  bool _hasMore = true;
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
    if (!_scrollController.hasClients ||
        _loadingInitial ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    if (_scrollController.position.extentAfter < 520) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    if (!mounted) return;
    setState(() {
      _loadingInitial = true;
      _loadingMore = false;
      _hasMore = true;
      _cursor = null;
      _loadError = null;
    });
    try {
      final page = await ref
          .read(animeWitcherAccountServiceProvider)
          .loadComments(
            widget.target,
            sort: _sort,
            cursor: null,
            limit: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _comments = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loadingInitial = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loadingInitial = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingInitial || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(animeWitcherAccountServiceProvider)
          .loadComments(
            widget.target,
            sort: _sort,
            cursor: _cursor,
            limit: _pageSize,
          );
      if (!mounted) return;
      final existing = _comments.map((item) => item.path).toSet();
      final additions = page.items
          .where((item) => existing.add(item.path))
          .toList(growable: false);
      setState(() {
        _comments = <AnimeWitcherComment>[..._comments, ...additions];
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadError = error;
      });
      _showMessage(_commentErrorText(error, _isArabic(context)));
    }
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    final isArabic = _isArabic(context);
    setState(() => _publishing = true);
    try {
      await ref.read(animeWitcherAccountServiceProvider).publishComment(
            widget.target,
            text,
            spoiler: _spoiler,
          );
      if (!mounted) return;
      _commentController.clear();
      setState(() => _spoiler = false);
      _showMessage(
        isArabic
            ? 'تم نشر تعليقك وهو قيد المراجعة.'
            : 'Your comment was submitted and is under review.',
      );
      await _loadInitial();
    } catch (error) {
      if (!mounted) return;
      _showMessage(_commentErrorText(error, isArabic));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _toggleLike(AnimeWitcherComment comment) async {
    if (_pendingLikes.contains(comment.path)) return;
    final service = ref.read(animeWitcherAccountServiceProvider);
    final isArabic = _isArabic(context);
    if (!service.isSignedIn) {
      _showMessage(isArabic ? 'يجب تسجيل الدخول' : 'Sign in to like comments.');
      return;
    }
    if (service.ownsComment(comment)) {
      return;
    }

    setState(() => _pendingLikes.add(comment.path));
    try {
      final updated = await service.toggleCommentLike(comment);
      if (!mounted) return;
      final index = _comments.indexWhere((item) => item.path == comment.path);
      if (index >= 0) {
        setState(() => _comments[index] = updated);
      }
    } catch (error) {
      if (mounted) _showMessage(_commentErrorText(error, isArabic));
    } finally {
      if (mounted) setState(() => _pendingLikes.remove(comment.path));
    }
  }

  Future<void> _openReplies(AnimeWitcherComment comment) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AnimeWitcherRepliesScreen(
          parentComment: comment,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
    // The AnimeWitcher backend owns the authoritative replies counter.
    // Refresh the visible page after returning so it picks up server changes.
    await _loadInitial();
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
    final isArabic = _isArabic(context);
    final controller = TextEditingController(text: comment.text);
    var spoiler = comment.spoiler;
    try {
      final draft = await showDialog<_CommentEditDraft>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(isArabic ? 'تعديل التعليق' : 'Edit comment'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 7,
                    maxLength: 500,
                    textDirection:
                        isArabic ? TextDirection.rtl : TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText:
                          isArabic ? 'اكتب التعليق...' : 'Write your comment...',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  CheckboxListTile(
                    value: spoiler,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      isArabic ? 'يحتوي على حرق' : 'Contains spoilers',
                    ),
                    onChanged: (value) {
                      setDialogState(() => spoiler = value == true);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(isArabic ? 'إلغاء' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final text = controller.text.trim();
                  if (text.isEmpty) return;
                  Navigator.pop(
                    dialogContext,
                    _CommentEditDraft(text: text, spoiler: spoiler),
                  );
                },
                child: Text(isArabic ? 'حفظ' : 'Save'),
              ),
            ],
          ),
        ),
      );
      if (draft == null || !mounted) return;
      _setCommentActionPending(comment.path, true);
      try {
        final updated = await ref
            .read(animeWitcherAccountServiceProvider)
            .updateOwnComment(
              comment,
              draft.text,
              spoiler: draft.spoiler,
            );
        if (!mounted) return;
        _replaceComment(updated);
        _showMessage(isArabic ? 'تم تعديل التعليق.' : 'Comment updated.');
      } catch (error) {
        if (mounted) _showMessage(_commentErrorText(error, isArabic));
      } finally {
        if (mounted) _setCommentActionPending(comment.path, false);
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteOwnComment(AnimeWitcherComment comment) async {
    final isArabic = _isArabic(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isArabic ? 'حذف التعليق؟' : 'Delete comment?'),
        content: Text(
          isArabic
              ? 'هل أنت متأكد من حذف هذا التعليق؟'
              : 'Are you sure you want to delete this comment?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(isArabic ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _setCommentActionPending(comment.path, true);
    try {
      await ref
          .read(animeWitcherAccountServiceProvider)
          .deleteOwnComment(comment);
      if (!mounted) return;
      setState(() {
        _comments.removeWhere((item) => item.path == comment.path);
      });
      _showMessage(isArabic ? 'تم حذف التعليق.' : 'Comment deleted.');
    } catch (error) {
      if (mounted) _showMessage(_commentErrorText(error, isArabic));
    } finally {
      if (mounted) _setCommentActionPending(comment.path, false);
    }
  }

  Future<void> _closeOwnCommentReplies(AnimeWitcherComment comment) async {
    if (comment.repliesClosed) return;
    final isArabic = _isArabic(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isArabic ? 'منع الردود؟' : 'Disable replies?'),
        content: Text(
          isArabic
              ? 'هل أنت متأكد من منع الردود على هذا التعليق؟'
              : 'Are you sure you want to disable replies for this comment?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(isArabic ? 'منع' : 'Disable'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _setCommentActionPending(comment.path, true);
    try {
      final updated = await ref
          .read(animeWitcherAccountServiceProvider)
          .closeOwnCommentReplies(comment);
      if (!mounted) return;
      _replaceComment(updated);
      _showMessage(isArabic ? 'تم منع الردود.' : 'Replies disabled.');
    } catch (error) {
      if (mounted) _showMessage(_commentErrorText(error, isArabic));
    } finally {
      if (mounted) _setCommentActionPending(comment.path, false);
    }
  }

  void _replaceComment(AnimeWitcherComment updated) {
    final index = _comments.indexWhere((item) => item.path == updated.path);
    if (index < 0) return;
    setState(() => _comments[index] = updated);
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

  String _commentSortSystemImage(AnimeWitcherCommentSort sort) {
    return switch (sort) {
      AnimeWitcherCommentSort.newest => 'clock',
      AnimeWitcherCommentSort.oldest => 'clock.arrow.circlepath',
      AnimeWitcherCommentSort.mostLiked => 'heart',
    };
  }

  IconData _commentSortFallbackIcon(AnimeWitcherCommentSort sort) {
    return switch (sort) {
      AnimeWitcherCommentSort.newest => Icons.schedule_rounded,
      AnimeWitcherCommentSort.oldest => Icons.history_rounded,
      AnimeWitcherCommentSort.mostLiked => Icons.favorite_border_rounded,
    };
  }

  List<AppleNativeMenuItem> _commentSortMenuItems(bool isArabic) {
    return <AppleNativeMenuItem>[
      AppleNativeMenuItem(
        value: AnimeWitcherCommentSort.newest.name,
        label: _sortLabel(AnimeWitcherCommentSort.newest, isArabic),
        systemImage: _commentSortSystemImage(AnimeWitcherCommentSort.newest),
      ),
      AppleNativeMenuItem(
        value: AnimeWitcherCommentSort.oldest.name,
        label: _sortLabel(AnimeWitcherCommentSort.oldest, isArabic),
        systemImage: _commentSortSystemImage(AnimeWitcherCommentSort.oldest),
      ),
      AppleNativeMenuItem(
        value: AnimeWitcherCommentSort.mostLiked.name,
        label: _sortLabel(AnimeWitcherCommentSort.mostLiked, isArabic),
        systemImage: _commentSortSystemImage(AnimeWitcherCommentSort.mostLiked),
      ),
    ];
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  Widget build(BuildContext context) {
    final isArabic = _isArabic(context);
    final accountState = ref.watch(animeWitcherAccountControllerProvider);
    final service = ref.read(animeWitcherAccountServiceProvider);
    final isSignedIn = accountState.asData?.value.isSignedIn ?? service.isSignedIn;

    if (appleUsesPersistentLiquidGlassHeader) {
      final colors = Theme.of(context).colorScheme;
      final trailingButtons = <AppleLiquidGlassToolbarButton>[
        AppleLiquidGlassToolbarButton(
          width: isArabic ? 150 : 140,
          tooltip: isArabic ? 'ترتيب التعليقات' : 'Sort comments',
          icon: _commentSortFallbackIcon(_sort),
          systemImage: _commentSortSystemImage(_sort),
          title: _sortLabel(_sort, isArabic),
          color: colors.primary,
          menuTintColor: colors.primary,
          onPressed: null,
          selectedMenuValue: _sort.name,
          menuItems: _commentSortMenuItems(isArabic),
          onMenuSelected: (value) {
            _applyCommentSort(_commentSortFromValue(value));
          },
        ),
      ];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
        applePersistentGlassHeaderController.show(
          ApplePersistentGlassHeaderConfig(
            owner: this,
            route: ModalRoute.of(context),
            onBack: () => Navigator.of(context).pop(),
            backForegroundColor: colors.onSurface,
            backFallbackColor: colors.surfaceContainerHigh,
            trailingButtons: trailingButtons,
          ),
        );
      });
    }

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            centerTitle: false,
            titleSpacing: 16,
            automaticallyImplyLeading: false,
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : AppleLiquidGlassBackButton(
                    onPressed: () => Navigator.of(context).pop(),
                  ),
            title: Padding(
              padding: EdgeInsets.only(
                right: appleUsesPersistentLiquidGlassHeader && isArabic ? 92 : 0,
                left: appleUsesPersistentLiquidGlassHeader && !isArabic ? 92 : 0,
              ),
              child: Align(
                alignment: isArabic ? Alignment.centerRight : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
                  child: Text(isArabic ? 'التعليقات' : 'Comments'),
                ),
              ),
            ),
            actions: appleUsesPersistentLiquidGlassHeader
                ? const <Widget>[]
                : [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: AppleNativeMenuButton(
                        accessibilityLabel:
                            isArabic ? 'ترتيب التعليقات' : 'Sort comments',
                        systemImage: 'arrow.up.arrow.down',
                        fallbackIcon: Icons.filter_list_rounded,
                        size: 46,
                        tintColor: Theme.of(context).colorScheme.primary,
                        selectedValue: _sort.name,
                        items: _commentSortMenuItems(isArabic),
                        onSelected: (value) {
                          _applyCommentSort(_commentSortFromValue(value));
                        },
                      ),
                    ),
                  ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (widget.target.title.trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Directionality(
                textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
                child: Text(
                  widget.target.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.start,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          Expanded(child: _buildCommentsBody(context, isArabic)),
          _buildComposer(context, isArabic, isSignedIn),
        ],
      ),
    );
  }

  Widget _buildCommentsBody(BuildContext context, bool isArabic) {
    if (_loadingInitial) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _comments.isEmpty) {
      return _CommentsLoadError(
        isArabic: isArabic,
        onRetry: _loadInitial,
      );
    }
    if (_comments.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                isArabic
                    ? 'لا توجد تعليقات منشورة بعد.'
                    : 'No published comments yet.',
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

    return RefreshIndicator(
      onRefresh: _loadInitial,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _comments.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= _comments.length) {
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
          return _buildCommentCard(context, _comments[index], isArabic);
        },
      ),
    );
  }

  Widget _buildCommentCard(
    BuildContext context,
    AnimeWitcherComment comment,
    bool isArabic,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final photo = comment.userPhotoUrl?.trim() ?? '';
    final reveal = !comment.spoiler || _revealedSpoilers.contains(comment.path);
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
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: colors.surfaceContainerHighest,
                    backgroundImage:
                        photo.isEmpty ? null : CachedNetworkImageProvider(photo),
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
                          _commentTimeAgo(comment.date, isArabic),
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
                            tooltip: isArabic
                                ? 'إدارة التعليق'
                                : 'Manage comment',
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
                                  isArabic ? 'تعديل' : 'Edit',
                                ),
                              ),
                              PopupMenuItem<_OwnCommentAction>(
                                value: _OwnCommentAction.delete,
                                child: _commentActionRow(
                                  Icons.delete_outline_rounded,
                                  isArabic ? 'حذف' : 'Delete',
                                ),
                              ),
                              PopupMenuItem<_OwnCommentAction>(
                                value: _OwnCommentAction.closeReplies,
                                enabled: !comment.repliesClosed,
                                child: _commentActionRow(
                                  Icons.block_rounded,
                                  comment.repliesClosed
                                      ? (isArabic
                                            ? 'الردود متوقفة'
                                            : 'Replies disabled')
                                      : (isArabic
                                            ? 'منع الردود'
                                            : 'Disable replies'),
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
                textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
                child: Text(
                  comment.text,
                  textAlign: TextAlign.start,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              )
            else
              Align(
                alignment:
                    isArabic ? Alignment.centerRight : Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _revealedSpoilers.add(comment.path));
                  },
                  icon: const Icon(Icons.visibility_off_rounded),
                  label: Text(
                    isArabic
                        ? 'تعليق يحتوي على حرق — إظهار'
                        : 'Spoiler comment — reveal',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
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
                    tooltip: isArabic ? 'إعجاب' : 'Like',
                    onTap: () => _toggleLike(comment),
                  ),
                  const SizedBox(width: 14),
                  _ReactionButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    count: comment.replies,
                    tooltip: isArabic ? 'الردود' : 'Replies',
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
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }

  Widget _buildComposer(
    BuildContext context,
    bool isArabic,
    bool isSignedIn,
  ) {
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
                      textDirection:
                          isArabic ? TextDirection.rtl : TextDirection.ltr,
                      decoration: InputDecoration(
                        hintText: isArabic ? 'اكتب تعليقًا...' : 'Write a comment...',
                        counterText: '',
                        filled: true,
                        fillColor: colors.surfaceContainerLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: isArabic ? 'يحتوي على حرق' : 'Contains spoiler',
                    onPressed: () => setState(() => _spoiler = !_spoiler),
                    icon: Icon(
                      _spoiler
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_outlined,
                      color: _spoiler ? colors.primary : colors.onSurfaceVariant,
                    ),
                  ),
                  IconButton.filled(
                    tooltip: isArabic ? 'نشر' : 'Publish',
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
                        isArabic
                            ? 'سجّل الدخول إلى حساب AnimeWitcher لإضافة تعليق.'
                            : 'Sign in to your AnimeWitcher account to comment.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
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
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentsLoadError extends StatelessWidget {
  const _CommentsLoadError({
    required this.isArabic,
    required this.onRetry,
  });

  final bool isArabic;
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
              isArabic ? 'تعذر تحميل التعليقات.' : 'Could not load comments.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _OwnCommentAction { edit, delete, closeReplies }

class _CommentEditDraft {
  const _CommentEditDraft({required this.text, required this.spoiler});

  final String text;
  final bool spoiler;
}

String _sortLabel(AnimeWitcherCommentSort sort, bool isArabic) {
  return switch (sort) {
    AnimeWitcherCommentSort.newest => isArabic ? 'الأحدث' : 'Newest',
    AnimeWitcherCommentSort.oldest => isArabic ? 'الأقدم' : 'Oldest',
    AnimeWitcherCommentSort.mostLiked =>
      isArabic ? 'الأكثر اعجابا' : 'Most liked',
  };
}

String _commentErrorText(Object error, bool isArabic) {
  if (error is AnimeWitcherAccountException) {
    return switch (error.code) {
      'not-signed-in' => isArabic
          ? 'يجب تسجيل الدخول قبل تنفيذ هذه العملية.'
          : 'Sign in before doing that.',
      'comment-empty' =>
        isArabic ? 'يرجى إدخال نص.' : 'Enter some text first.',
      'comment-too-long' => isArabic
          ? 'الحد الأعلى للنص 500 حرف.'
          : 'The maximum length is 500 characters.',
      'comment-banned' => isArabic
          ? 'تم حظرك من التعليق.'
          : 'This account is blocked from commenting.',
      'comment-account-too-new' => isArabic
          ? 'يجب أن يمر على إنشاء حسابك 7 أيام قبل أن تتمكن من كتابة التعليقات.'
          : 'Your account must be at least 7 days old before commenting.',
      'comment-cooldown' => isArabic
          ? 'انتظر قليلاً حتى يمكنك التعليق مرة أخرى.'
          : 'Wait a moment before commenting again.',
      'comment-limit' => isArabic
          ? 'لقد وصلت للحد الأقصى لعدد التعليقات على هذا المحتوى.'
          : 'You reached the comment limit for this item.',
      'comments-closed' => isArabic
          ? 'تم إيقاف التعليقات على هذا المحتوى.'
          : 'Comments are disabled for this item.',
      'replies-closed' => isArabic
          ? 'تم إيقاف الردود على هذا التعليق.'
          : 'Replies are disabled for this comment.',
      'permission-denied' => isArabic
          ? 'لا يمكن تعديل هذا التعليق.'
          : 'This comment cannot be modified.',
      _ => error.message,
    };
  }
  return isArabic ? 'حدث خطأ. حاول مرة أخرى.' : 'Something went wrong. Try again.';
}

String _commentTimeAgo(DateTime? date, bool isArabic) {
  if (date == null) return '';
  final raw = DateTime.now().difference(date);
  final elapsed = raw.isNegative ? Duration.zero : raw;
  if (elapsed.inMinutes < 1) return isArabic ? 'منذ لحظات' : 'just now';
  if (elapsed.inMinutes < 60) {
    final value = elapsed.inMinutes;
    return isArabic
        ? value == 1
            ? 'منذ دقيقة'
            : 'منذ $value دقيقة'
        : value == 1
            ? '1 minute ago'
            : '$value minutes ago';
  }
  if (elapsed.inHours < 24) {
    final value = elapsed.inHours;
    return isArabic
        ? value == 1
            ? 'منذ ساعة'
            : 'منذ $value ساعة'
        : value == 1
            ? '1 hour ago'
            : '$value hours ago';
  }
  if (elapsed.inDays < 30) {
    final value = elapsed.inDays;
    return isArabic
        ? value == 1
            ? 'منذ يوم'
            : 'منذ $value يوم'
        : value == 1
            ? '1 day ago'
            : '$value days ago';
  }
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year}';
}
