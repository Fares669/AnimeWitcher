import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
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
  });

  final AnimeWitcherComment parentComment;

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

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

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
      _showMessage(_replyErrorText(error, _isArabic(context)), isError: true);
    }
  }

  Future<void> _toggleLike(AnimeWitcherComment reply) async {
    if (_pendingLikes.contains(reply.path)) return;
    final service = ref.read(animeWitcherAccountServiceProvider);
    final isArabic = _isArabic(context);
    if (!service.isSignedIn) {
      _showMessage(
        isArabic ? 'يجب تسجيل الدخول' : 'Sign in to like replies.',
        isInfo: true,
      );
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
        _showMessage(_replyErrorText(error, isArabic), isError: true);
      }
    } finally {
      if (mounted) setState(() => _pendingLikes.remove(reply.path));
    }
  }

  Future<void> _publishReply() async {
    if (_publishing) return;
    final text = _replyController.text.trim();
    if (text.isEmpty) return;
    final isArabic = _isArabic(context);
    final userTagId = _userTagId;
    setState(() => _publishing = true);
    try {
      await ref.read(animeWitcherAccountServiceProvider).publishReply(
            widget.parentComment,
            text,
            userTagId: userTagId,
          );
      if (!mounted) return;
      _replyController.clear();
      setState(() => _userTagId = null);
      _showMessage(isArabic ? 'تم إرسال الرد.' : 'Reply sent.');
      await _loadInitial();
    } catch (error) {
      if (mounted) {
        _showMessage(_replyErrorText(error, isArabic), isError: true);
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
    final isArabic = _isArabic(context);
    if (!service.isSignedIn) {
      _showMessage(
        isArabic ? 'يجب تسجيل الدخول' : 'Sign in to mention a reply.',
        isInfo: true,
      );
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
        _showMessage(
          animeWitcherReplyAlreadyTaggedMessage(isArabic: isArabic),
          isInfo: true,
        );
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
    final isArabic = _isArabic(context);
    final accountState = ref.watch(animeWitcherAccountControllerProvider);
    final service = ref.read(animeWitcherAccountServiceProvider);
    final isSignedIn = accountState.asData?.value.isSignedIn ?? service.isSignedIn;

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
              isArabic: isArabic,
              tooltip: isArabic ? 'ترتيب الردود' : 'Sort replies',
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
                  child: Text(isArabic ? 'الردود' : 'Replies'),
                ),
              ),
            ),
            actions: appleUsesPersistentLiquidGlassHeader
                ? const <Widget>[]
                : AnimeWitcherCommentSortControl.appBarActions(
                    tooltip: isArabic ? 'ترتيب الردود' : 'Sort replies',
                    selectedValue: _sort.name,
                    items: AnimeWitcherCommentSortControl.menuItems(isArabic),
                    onSelected: (value) {
                      _applyReplySort(_replySortFromValue(value));
                    },
                  ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildRepliesBody(context, isArabic)),
          _buildComposer(context, isArabic, isSignedIn),
        ],
      ),
    );
  }

  Widget _buildRepliesBody(BuildContext context, bool isArabic) {
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
              Text(isArabic ? 'تعذر تحميل الردود.' : 'Could not load replies.'),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _loadInitial,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
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
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.24),
            Text(
              isArabic ? 'لا توجد ردود بعد.' : 'No replies yet.',
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
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
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
          return _buildReplyCard(context, _replies[index], isArabic);
        },
      ),
    );
  }

  Widget _buildReplyCard(
    BuildContext context,
    AnimeWitcherComment reply,
    bool isArabic,
  ) {
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
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: colors.surfaceContainerHighest,
                    backgroundImage: avatarImage(context, photo, radius: 20),
                    child: photo.isEmpty
                        ? Icon(Icons.person_rounded, color: colors.onSurfaceVariant)
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
                          _replyTimeAgo(reply.date, isArabic),
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
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: Text(
                reply.text,
                textAlign: TextAlign.start,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Tooltip(
                    message: isArabic ? 'رد' : 'Reply',
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
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
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

  Widget _buildComposer(
    BuildContext context,
    bool isArabic,
    bool isSignedIn,
  ) {
    final colors = Theme.of(context).colorScheme;
    if (widget.parentComment.repliesClosed) {
      return SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Text(
            isArabic
                ? 'تم إيقاف الردود على هذا التعليق.'
                : 'Replies are disabled for this comment.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
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
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
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
                      textDirection:
                          isArabic ? TextDirection.rtl : TextDirection.ltr,
                      decoration: InputDecoration(
                        hintText: isArabic ? 'اكتب رداً...' : 'Write a reply...',
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
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: isArabic ? 'إرسال' : 'Send',
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
                        isArabic
                            ? 'سجّل الدخول إلى حساب AnimeWitcher لإضافة رد.'
                            : 'Sign in to your AnimeWitcher account to reply.',
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

String _replyErrorText(Object error, bool isArabic) {
  if (error is AnimeWitcherAccountException) {
    return switch (error.code) {
      'not-signed-in' => isArabic ? 'يجب تسجيل الدخول' : 'Sign in first.',
      'comment-empty' =>
        isArabic ? 'يرجى إدخال نص.' : 'Enter some text first.',
      'comment-too-long' => isArabic
          ? 'الحد الأعلى للنص 500 حرف.'
          : 'The maximum length is 500 characters.',
      'comment-banned' => isArabic
          ? 'تم حظرك من التعليق.'
          : 'This account is blocked from commenting.',
      'comment-account-too-new' => isArabic
          ? 'يجب أن يمر على إنشاء حسابك 7 أيام قبل أن تتمكن من كتابة الردود.'
          : 'Your account must be at least 7 days old before replying.',
      'comment-cooldown' => isArabic
          ? 'انتظر قليلاً حتى يمكنك الرد مرة أخرى.'
          : 'Wait a moment before replying again.',
      'replies-closed' => isArabic
          ? 'تم إيقاف الردود على هذا التعليق.'
          : 'Replies are disabled for this comment.',
      _ => error.message,
    };
  }
  return isArabic ? 'حدث خطأ. حاول مرة أخرى.' : 'Something went wrong. Try again.';
}

String _replyTimeAgo(DateTime? date, bool isArabic) {
  if (date == null) return '';
  final raw = DateTime.now().difference(date);
  final elapsed = raw.isNegative ? Duration.zero : raw;
  if (elapsed.inMinutes < 1) return isArabic ? 'منذ لحظات' : 'just now';
  if (elapsed.inMinutes < 60) {
    final value = elapsed.inMinutes;
    return isArabic ? 'منذ $value دقيقة' : '$value minutes ago';
  }
  if (elapsed.inHours < 24) {
    final value = elapsed.inHours;
    return isArabic ? 'منذ $value ساعة' : '$value hours ago';
  }
  if (elapsed.inDays < 30) {
    final value = elapsed.inDays;
    return isArabic ? 'منذ $value يوم' : '$value days ago';
  }
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year}';
}

