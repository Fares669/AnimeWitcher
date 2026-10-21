import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/animewitcher_reply_mention.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/utils/request_generation.dart';

import 'widgets/animewitcher_comment_sort_control.dart';
import '../../../core/utils/avatar_image.dart';

class AnimeWitcherRepliesScreen extends ConsumerStatefulWidget {
  const AnimeWitcherRepliesScreen({
    super.key,
    required this.parentComment,
    this.showParent = false,
  });

  final AnimeWitcherComment parentComment;
  final bool showParent;

  @override
  ConsumerState<AnimeWitcherRepliesScreen> createState() =>
      _AnimeWitcherRepliesScreenState();
}

class _AnimeWitcherRepliesScreenState
    extends ConsumerState<AnimeWitcherRepliesScreen> {
  static const int _pageSize = 20;

  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();
  final Set<String> _pendingLikes = <String>{};
  late final ScrollController _scrollController;

  List<AnimeWitcherComment> _replies = <AnimeWitcherComment>[];
  AnimeWitcherCommentSort _sort = AnimeWitcherCommentSort.repliesDefault;
  Object? _loadError;
  FirestoreDocument? _cursor;
  bool _loadingInitial = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _publishing = false;
  bool _parentRevealed = false;
  String? _userTagId;
  final RequestGeneration _loadGeneration = RequestGeneration();

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    _replyController.addListener(_onReplyTextChanged);
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
    _replyController
      ..removeListener(_onReplyTextChanged)
      ..dispose();
    _replyFocusNode.dispose();
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
    final generation = _loadGeneration.begin();
    final sort = _sort;
    setState(() {
      _loadingInitial = true;
      _loadingMore = false;
      _loadError = null;
      _cursor = null;
      _hasMore = true;
    });
    try {
      final page = await ref
          .read(animeWitcherAccountServiceProvider)
          .loadReplies(
            widget.parentComment,
            sort: sort,
            cursor: null,
            limit: _pageSize,
          );
      if (!mounted || !_loadGeneration.isCurrent(generation)) return;
      setState(() {
        _replies = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loadingInitial = false;
      });
    } catch (error) {
      if (!mounted || !_loadGeneration.isCurrent(generation)) return;
      setState(() {
        _loadError = error;
        _loadingInitial = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingInitial || _loadingMore || !_hasMore) return;
    final generation = _loadGeneration.current;
    final sort = _sort;
    final cursor = _cursor;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(animeWitcherAccountServiceProvider)
          .loadReplies(
            widget.parentComment,
            sort: sort,
            cursor: cursor,
            limit: _pageSize,
          );
      if (!mounted || !_loadGeneration.isCurrent(generation)) return;
      final existing = _replies.map((item) => item.path).toSet();
      final additions = page.items
          .where((item) => existing.add(item.path))
          .toList(growable: false);
      setState(() {
        _replies = <AnimeWitcherComment>[..._replies, ...additions];
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || !_loadGeneration.isCurrent(generation)) return;
      setState(() {
        _loadError = error;
        _loadingMore = false;
      });
      _showMessage(_replyErrorText(error), isError: true);
    }
  }

  Future<void> _toggleLike(AnimeWitcherComment reply) async {
    if (_pendingLikes.contains(reply.path)) return;
    final service = ref.read(animeWitcherAccountServiceProvider);

    if (!service.isSignedIn) {
      _showMessage('يجب تسجيل الدخول', isInfo: true);
      return;
    }
    if (reply.userId == service.snapshot.profile?.documentId) return;

    setState(() => _pendingLikes.add(reply.path));
    try {
      final updated = await service.toggleCommentLike(reply);
      if (!mounted) return;
      final index = _replies.indexWhere((item) => item.path == reply.path);
      if (index >= 0) setState(() => _replies[index] = updated);
    } catch (error) {
      if (mounted) {
        _showMessage(_replyErrorText(error), isError: true);
      }
    } finally {
      if (mounted) setState(() => _pendingLikes.remove(reply.path));
    }
  }

  Future<void> _publishReply() async {
    if (_publishing) return;
    final text = _replyController.text.trim();
    if (text.isEmpty) return;

    final userTagId = _userTagId;
    setState(() => _publishing = true);
    try {
      await ref
          .read(animeWitcherAccountServiceProvider)
          .publishReply(widget.parentComment, text, userTagId: userTagId);
      if (!mounted) return;
      _replyController.clear();
      setState(() => _userTagId = null);
      _showMessage('تم إرسال الرد.');
      await _loadInitial();
    } catch (error) {
      if (mounted) {
        _showMessage(_replyErrorText(error), isError: true);
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  void _onReplyTextChanged() {
    if (!mounted) return;
    final nextTagId = animeWitcherReplyUserTagIdAfterTextChange(
      text: _replyController.text,
      currentUserTagId: _userTagId,
    );
    if (nextTagId == _userTagId) return;
    setState(() => _userTagId = nextTagId);
  }

  void _mentionReply(AnimeWitcherComment reply) {
    final service = ref.read(animeWitcherAccountServiceProvider);

    if (!service.isSignedIn) {
      _showMessage('يجب تسجيل الدخول', isInfo: true);
      return;
    }
    if (widget.parentComment.repliesClosed) return;

    final outcome = applyAnimeWitcherReplyMention(
      currentText: _replyController.text,
      currentUserTagId: _userTagId,
      replyUserId: reply.userId,
      replyUserName: reply.userName,
      isOwnReply: service.ownsComment(reply),
    );
    switch (outcome.status) {
      case AnimeWitcherReplyMentionStatus.ownReply:
        return;
      case AnimeWitcherReplyMentionStatus.alreadyTagged:
        _showMessage(animeWitcherReplyAlreadyTaggedMessage(), isInfo: true);
        return;
      case AnimeWitcherReplyMentionStatus.applied:
        _replyController.value = TextEditingValue(
          text: outcome.text,
          selection: TextSelection.collapsed(offset: outcome.text.length),
        );
        setState(() => _userTagId = outcome.userTagId);
        _replyFocusNode.requestFocus();
    }
  }

  Future<void> _applyReplySort(AnimeWitcherCommentSort selected) async {
    if (selected == _sort || !mounted) return;
    setState(() => _sort = selected);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    await _loadInitial();
  }

  AnimeWitcherCommentSort _replySortFromValue(String value) {
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
            trailingButtons: AnimeWitcherCommentSortControl.persistentButtons(
              context: context,
              tooltip: 'ترتيب الردود',
              sort: _sort,
              onSelected: (value) {
                _applyReplySort(_replySortFromValue(value));
              },
            ),
          ),
        );
      });
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: 'الردود',
        onBack: () => Navigator.of(context).pop(),
        actions: appleUsesPersistentLiquidGlassHeader
            ? const <Widget>[]
            : AnimeWitcherCommentSortControl.appBarActions(
                tooltip: 'ترتيب الردود',
                selectedValue: _sort.name,
                items: AnimeWitcherCommentSortControl.menuItems(),
                onSelected: (value) {
                  _applyReplySort(_replySortFromValue(value));
                },
              ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildRepliesBody(context)),
          _buildComposer(context, isSignedIn),
        ],
      ),
    );
  }

  Widget _buildRepliesBody(BuildContext context) {
    if (widget.showParent) return _buildNotificationThread(context);
    if (_loadingInitial) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _replies.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 40),
              const SizedBox(height: 10),
              Text('تعذر تحميل الردود.'),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _loadInitial,
                icon: const Icon(Icons.refresh_rounded),
                label: Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }
    if (_replies.isEmpty) {
      return MouseDragRefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: appPageHeaderContentTopInset(context)),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.24),
            Text(
              'لا توجد ردود بعد.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        itemCount: _replies.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= _replies.length) {
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
          return _buildReplyCard(context, _replies[index]);
        },
      ),
    );
  }

  Widget _buildNotificationThread(BuildContext context) {
    final parent = widget.parentComment;
    final showText = !parent.spoiler || _parentRevealed;
    return MouseDragRefreshIndicator(
      onRefresh: _loadInitial,
      child: ListView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          12,
          appPageHeaderContentTopInset(context) + 12,
          12,
          24,
        ),
        children: [
          Text(
            parent.isReview ? 'المراجعة' : 'التعليق الأصلي',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (showText)
            _buildReplyCard(context, parent, showActions: false)
          else
            TextButton.icon(
              onPressed: () => setState(() => _parentRevealed = true),
              icon: const Icon(Icons.visibility_off_outlined),
              label: const Text('تعليق يحتوي على حرق — اضغط للعرض'),
            ),
          const SizedBox(height: 16),
          if (_loadingInitial)
            const Center(child: CircularProgressIndicator())
          else ...[
            if (_loadError != null)
              TextButton(
                onPressed: _loadInitial,
                child: const Text('تعذر تحميل الردود. إعادة المحاولة'),
              ),
            if (_replies.isEmpty && _loadError == null)
              const Text('لا توجد ردود بعد.', textAlign: TextAlign.center),
            for (final reply in _replies) ...[
              _buildReplyCard(context, reply),
              const SizedBox(height: 8),
            ],
            if (_loadingMore) const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }

  Widget _buildReplyCard(
    BuildContext context,
    AnimeWitcherComment reply, {
    bool showActions = true,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final photo = reply.userPhotoUrl?.trim() ?? '';
    final pending = _pendingLikes.contains(reply.path);

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
                          reply.userName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _replyTimeAgo(reply.date),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Text(
                reply.text,
                textAlign: TextAlign.start,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
            if (showActions) const SizedBox(height: 8),
            if (showActions)
              Directionality(
                textDirection: TextDirection.rtl,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Tooltip(
                      message: 'رد',
                      child: InkWell(
                        key: ValueKey<String>('reply-mention-${reply.path}'),
                        onTap: () => _mentionReply(reply),
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 5,
                          ),
                          child: Icon(
                            Icons.reply_rounded,
                            size: 19,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: pending ? null : () => _toggleLike(reply),
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 5,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (pending)
                              SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: reply.likedByMe
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                ),
                              )
                            else
                              Icon(
                                reply.likedByMe
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                size: 19,
                                color: reply.likedByMe
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            const SizedBox(width: 5),
                            Text('${reply.likes}'),
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
    );
  }

  Widget _buildComposer(BuildContext context, bool isSignedIn) {
    final colors = Theme.of(context).colorScheme;
    if (widget.parentComment.repliesClosed) {
      return SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Text(
            'تم إيقاف الردود على هذا التعليق.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: isSignedIn
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      focusNode: _replyFocusNode,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 500,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: 'اكتب رداً...',
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
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'إرسال',
                    onPressed: _publishing ? null : _publishReply,
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
                        'سجّل الدخول إلى حساب AnimeWitcher لإضافة رد.',
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

String _replyErrorText(Object error) {
  if (error is AnimeWitcherAccountException) {
    return switch (error.code) {
      'not-signed-in' => 'يجب تسجيل الدخول',
      'comment-empty' => 'يرجى إدخال نص.',
      'comment-too-long' => 'الحد الأعلى للنص 500 حرف.',
      'comment-banned' => 'تم حظرك من التعليق.',
      'comment-account-too-new' =>
        'يجب أن يمر على إنشاء حسابك 7 أيام قبل أن تتمكن من كتابة الردود.',
      'comment-cooldown' => 'انتظر قليلاً حتى يمكنك الرد مرة أخرى.',
      'replies-closed' => 'تم إيقاف الردود على هذا التعليق.',
      _ => error.message,
    };
  }
  return 'حدث خطأ. حاول مرة أخرى.';
}

String _replyTimeAgo(DateTime? date) {
  if (date == null) return '';
  final raw = DateTime.now().difference(date);
  final elapsed = raw.isNegative ? Duration.zero : raw;
  if (elapsed.inMinutes < 1) return 'منذ لحظات';
  if (elapsed.inMinutes < 60) {
    final value = elapsed.inMinutes;
    return 'منذ $value دقيقة';
  }
  if (elapsed.inHours < 24) {
    final value = elapsed.inHours;
    return 'منذ $value ساعة';
  }
  if (elapsed.inDays < 30) {
    final value = elapsed.inDays;
    return 'منذ $value يوم';
  }
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year}';
}
