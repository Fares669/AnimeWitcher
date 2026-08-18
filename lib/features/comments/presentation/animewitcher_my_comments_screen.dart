import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/account/animewitcher_comment_models.dart';
import '../../../core/account/animewitcher_sync_ids.dart';
import '../../../core/account/firestore_rest_client.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../details/presentation/details_screen.dart';
import 'animewitcher_replies_screen.dart';

class AnimeWitcherMyCommentsScreen extends ConsumerStatefulWidget {
  const AnimeWitcherMyCommentsScreen({super.key});

  @override
  ConsumerState<AnimeWitcherMyCommentsScreen> createState() =>
      _AnimeWitcherMyCommentsScreenState();
}

class _AnimeWitcherMyCommentsScreenState
    extends ConsumerState<AnimeWitcherMyCommentsScreen> {
  static const int _pageSize = 20;

  late final ScrollController _scrollController;
  final Set<String> _busyComments = <String>{};

  List<AnimeWitcherComment> _comments = <AnimeWitcherComment>[];
  AnimeWitcherCommentSort _sort = AnimeWitcherCommentSort.newest;
  FirestoreDocument? _cursor;
  Object? _loadError;
  bool _loadingInitial = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  bool get _isArabic =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

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
          .loadMyComments(sort: _sort, limit: _pageSize);
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
          .loadMyComments(
            sort: _sort,
            cursor: _cursor,
            limit: _pageSize,
          );
      if (!mounted) return;
      final paths = _comments.map((comment) => comment.path).toSet();
      final additions = page.items
          .where((comment) => paths.add(comment.path))
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
        _loadError = error;
        _loadingMore = false;
      });
      _showMessage(_errorText(error));
    }
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
    final controller = TextEditingController(text: comment.text);
    var spoiler = comment.spoiler;
    try {
      final draft = await showDialog<_CommentEditDraft>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(_isArabic ? 'تعديل التعليق' : 'Edit comment'),
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
                        _isArabic ? TextDirection.rtl : TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: _isArabic
                          ? 'اكتب التعليق...'
                          : 'Write your comment...',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  CheckboxListTile(
                    value: spoiler,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _isArabic ? 'يحتوي على حرق' : 'Contains spoilers',
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
                child: Text(_isArabic ? 'إلغاء' : 'Cancel'),
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
                child: Text(_isArabic ? 'حفظ' : 'Save'),
              ),
            ],
          ),
        ),
      );
      if (draft == null || !mounted) return;
      _setBusy(comment.path, true);
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
        _showMessage(
          _isArabic
              ? 'تم تعديل التعليق.'
              : 'Comment updated.',
        );
      } catch (error) {
        if (mounted) _showMessage(_errorText(error));
      } finally {
        if (mounted) _setBusy(comment.path, false);
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteComment(AnimeWitcherComment comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_isArabic ? 'حذف التعليق؟' : 'Delete comment?'),
        content: Text(
          _isArabic
              ? 'هل أنت متأكد من حذف هذا التعليق؟'
              : 'Are you sure you want to delete this comment?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_isArabic ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _setBusy(comment.path, true);
    try {
      await ref
          .read(animeWitcherAccountServiceProvider)
          .deleteOwnComment(comment);
      if (!mounted) return;
      setState(() {
        _comments.removeWhere((item) => item.path == comment.path);
      });
      _showMessage(_isArabic ? 'تم حذف التعليق.' : 'Comment deleted.');
    } catch (error) {
      if (mounted) _showMessage(_errorText(error));
    } finally {
      if (mounted) _setBusy(comment.path, false);
    }
  }

  Future<void> _closeReplies(AnimeWitcherComment comment) async {
    if (comment.repliesClosed) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_isArabic ? 'منع الردود؟' : 'Disable replies?'),
        content: Text(
          _isArabic
              ? 'هل أنت متأكد من منع الردود على هذا التعليق؟'
              : 'Are you sure you want to disable replies for this comment?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_isArabic ? 'منع' : 'Disable'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _setBusy(comment.path, true);
    try {
      final updated = await ref
          .read(animeWitcherAccountServiceProvider)
          .closeOwnCommentReplies(comment);
      if (!mounted) return;
      _replaceComment(updated);
      _showMessage(
        _isArabic ? 'تم منع الردود.' : 'Replies disabled.',
      );
    } catch (error) {
      if (mounted) _showMessage(_errorText(error));
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
    if (mounted) await _loadInitial();
  }

  void _openAnime(AnimeWitcherComment comment) {
    final animeId = comment.animeId?.trim();
    if (animeId == null || animeId.isEmpty) return;

    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DetailsScreen(
          item: MultimediaItem(
            title: animeId,
            url: AnimeWitcherSyncIds.mainUrl(animeId),
            posterUrl: '',
            contentType: MultimediaContentType.anime,
            provider: animeWitcherNativeProviderId,
          ),
        ),
      ),
    );
  }

  void _replaceComment(AnimeWitcherComment updated) {
    final index = _comments.indexWhere((item) => item.path == updated.path);
    if (index < 0) return;
    setState(() => _comments[index] = updated);
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

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(animeWitcherAccountControllerProvider);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: !appleUsesPersistentLiquidGlassHeader &&
                Navigator.of(context).canPop()
            ? const AppleLiquidGlassBackButton()
            : null,
        title: ApplePersistentGlassHeaderScope(
          enabled: Navigator.of(context).canPop(),
          onBack: () => Navigator.of(context).maybePop(),
          child: Text(_isArabic ? 'تعليقاتي' : 'My comments'),
        ),
        actions: [
          PopupMenuButton<AnimeWitcherCommentSort>(
            tooltip: _isArabic ? 'ترتيب التعليقات' : 'Sort comments',
            initialValue: _sort,
            onSelected: _changeSort,
            itemBuilder: (context) => AnimeWitcherCommentSort.values
                .map(
                  (sort) => PopupMenuItem<AnimeWitcherCommentSort>(
                    value: sort,
                    child: Row(
                      children: [
                        Icon(_sortIcon(sort), size: 20),
                        const SizedBox(width: 10),
                        Text(_sortLabel(sort)),
                      ],
                    ),
                  ),
                )
                .toList(growable: false),
            icon: const Icon(Icons.sort_rounded),
          ),
        ],
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
    if (_loadingInitial) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _comments.isEmpty) {
      return _MyCommentsError(
        message: _errorText(_loadError!),
        retryLabel: _isArabic ? 'إعادة المحاولة' : 'Retry',
        onRetry: _loadInitial,
      );
    }
    if (_comments.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.26),
            const Icon(Icons.forum_outlined, size: 46),
            const SizedBox(height: 12),
            Text(
              _isArabic
                  ? 'لم تكتب أي تعليقات بعد.'
                  : 'You have not written any comments yet.',
              textAlign: TextAlign.center,
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
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        itemCount: _comments.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index >= _comments.length) {
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
          final comment = _comments[index];
          return _buildCommentCard(
            comment,
            busy: _busyComments.contains(comment.path),
          );
        },
      ),
    );
  }

  Widget _buildCommentCard(
    AnimeWitcherComment comment, {
    required bool busy,
  }) {
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
                      textDirection:
                          _isArabic ? TextDirection.rtl : TextDirection.ltr,
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: colors.surfaceContainerHighest,
                            backgroundImage: photo.isEmpty
                                ? null
                                : CachedNetworkImageProvider(photo),
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
                                  _timeAgo(comment.date),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<_MyCommentAction>(
                            tooltip:
                                _isArabic ? 'إدارة التعليق' : 'Manage comment',
                            onSelected: (action) {
                              _handleAction(comment, action);
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem<_MyCommentAction>(
                                value: _MyCommentAction.edit,
                                child: _actionRow(
                                  Icons.edit_rounded,
                                  _isArabic ? 'تعديل' : 'Edit',
                                ),
                              ),
                              PopupMenuItem<_MyCommentAction>(
                                value: _MyCommentAction.delete,
                                child: _actionRow(
                                  Icons.delete_outline_rounded,
                                  _isArabic ? 'حذف' : 'Delete',
                                ),
                              ),
                              PopupMenuItem<_MyCommentAction>(
                                value: _MyCommentAction.closeReplies,
                                enabled: !comment.repliesClosed,
                                child: _actionRow(
                                  Icons.block_rounded,
                                  comment.repliesClosed
                                      ? (_isArabic
                                            ? 'الردود متوقفة'
                                            : 'Replies disabled')
                                      : (_isArabic
                                            ? 'منع الردود'
                                            : 'Disable replies'),
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
                      textDirection:
                          _isArabic ? TextDirection.rtl : TextDirection.ltr,
                      child: Text(
                        comment.text,
                        textAlign: TextAlign.start,
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (comment.spoiler || comment.repliesClosed) ...[
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (comment.spoiler)
                            _statusChip(
                              Icons.visibility_off_rounded,
                              _isArabic ? 'حرق' : 'Spoiler',
                              colors.errorContainer,
                              colors.onErrorContainer,
                            ),
                          if (comment.repliesClosed)
                            _statusChip(
                              Icons.block_rounded,
                              _isArabic ? 'الردود متوقفة' : 'Replies disabled',
                              colors.secondaryContainer,
                              colors.onSecondaryContainer,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    Directionality(
                      textDirection:
                          _isArabic ? TextDirection.rtl : TextDirection.ltr,
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
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Text(label),
      ],
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
      tags.add(_tag(Icons.newspaper_rounded, _isArabic ? 'خبر' : 'News'));
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
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  IconData _sortIcon(AnimeWitcherCommentSort sort) {
    return switch (sort) {
      AnimeWitcherCommentSort.newest => Icons.schedule_rounded,
      AnimeWitcherCommentSort.oldest => Icons.history_rounded,
      AnimeWitcherCommentSort.mostLiked => Icons.favorite_border_rounded,
    };
  }

  String _sortLabel(AnimeWitcherCommentSort sort) {
    return switch (sort) {
      AnimeWitcherCommentSort.newest => _isArabic ? 'الأحدث' : 'Newest',
      AnimeWitcherCommentSort.oldest => _isArabic ? 'الأقدم' : 'Oldest',
      AnimeWitcherCommentSort.mostLiked =>
        _isArabic ? 'الأكثر إعجابًا' : 'Most liked',
    };
  }

  String _errorText(Object error) {
    if (error is AnimeWitcherAccountException) {
      return switch (error.code) {
        'not-signed-in' => _isArabic
            ? 'يجب تسجيل الدخول.'
            : 'Sign in first.',
        'comment-empty' =>
          _isArabic ? 'يرجى إدخال نص.' : 'Enter some text first.',
        'comment-too-long' => _isArabic
            ? 'الحد الأعلى للنص 500 حرف.'
            : 'The maximum length is 500 characters.',
        'comment-banned' => _isArabic
            ? 'تم حظرك من التعليق.'
            : 'This account is blocked from commenting.',
        'comment-account-too-new' => _isArabic
            ? 'يجب أن يمر 7 أيام على إنشاء الحساب.'
            : 'The account must be at least 7 days old.',
        'permission-denied' => _isArabic
            ? 'لا يمكن تعديل هذا التعليق.'
            : 'This comment cannot be modified.',
        _ => error.message,
      };
    }
    return _isArabic
        ? 'حدث خطأ. حاول مرة أخرى.'
        : 'Something went wrong. Try again.';
  }

  String _timeAgo(DateTime? date) {
    if (date == null) return '';
    final raw = DateTime.now().difference(date);
    final elapsed = raw.isNegative ? Duration.zero : raw;
    if (elapsed.inMinutes < 1) return _isArabic ? 'منذ لحظات' : 'just now';
    if (elapsed.inMinutes < 60) {
      return _isArabic
          ? 'منذ ${elapsed.inMinutes} دقيقة'
          : '${elapsed.inMinutes} minutes ago';
    }
    if (elapsed.inHours < 24) {
      return _isArabic
          ? 'منذ ${elapsed.inHours} ساعة'
          : '${elapsed.inHours} hours ago';
    }
    if (elapsed.inDays < 30) {
      return _isArabic
          ? 'منذ ${elapsed.inDays} يوم'
          : '${elapsed.inDays} days ago';
    }
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }
}

enum _MyCommentAction { edit, delete, closeReplies }

class _CommentEditDraft {
  const _CommentEditDraft({required this.text, required this.spoiler});

  final String text;
  final bool spoiler;
}

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
