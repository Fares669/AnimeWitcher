import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/anime3rb_account_models.dart';
import '../../../core/account/anime3rb_account_service.dart';
import '../../../core/account/anime3rb_comment_models.dart';
import '../../../core/account/anime3rb_comments_service.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/avatar_image.dart';
import '../../../core/utils/relative_time.dart';
import '../../../core/utils/window_controls_inset.dart';
import '../../../shared/widgets/animated_sort_menu_button.dart';
import '../../../shared/widgets/app_page_header.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import 'widgets/animewitcher_comment_sort_control.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mouse_drag_refresh_indicator.dart';
import '../../home/presentation/widgets/home_section_header.dart';
import '../../settings/presentation/account_screen.dart';
import '../../settings/presentation/widgets/anime3rb_auth_webview_screen.dart';

class Anime3rbCommentsScreen extends ConsumerStatefulWidget {
  const Anime3rbCommentsScreen({super.key, required this.target});

  final Anime3rbCommentTarget target;

  @override
  ConsumerState<Anime3rbCommentsScreen> createState() =>
      _Anime3rbCommentsScreenState();
}

class _Anime3rbCommentsScreenState extends ConsumerState<Anime3rbCommentsScreen> {
  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<Anime3rbComment> _comments = <Anime3rbComment>[];
  final Set<String> _pendingVotes = <String>{};
  final Set<String> _expandedReplies = <String>{};
  final Set<String> _loadingReplies = <String>{};
  final Map<String, List<Anime3rbComment>> _repliesByParent =
      <String, List<Anime3rbComment>>{};
  final Map<String, String?> _repliesCursorByParent = <String, String?>{};
  final Map<String, bool> _repliesHasMoreByParent = <String, bool>{};

  Anime3rbCommentSort _sort = Anime3rbCommentSort.popular;
  String? _nextCursor;
  bool _hasMore = false;
  int? _totalCount;
  bool _isTopicClosed = false;
  bool _loadingInitial = true;
  bool _loadingMore = false;
  bool _publishing = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
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
    _composerController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loadingInitial = true;
      _error = null;
      _nextCursor = null;
      _hasMore = false;
    });
    try {
      final page = await ref
          .read(anime3rbCommentsServiceProvider)
          .loadComments(widget.target, sort: _sort, limit: 20);
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(page.items);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && page.nextCursor != null;
        _totalCount = page.totalCount;
        _isTopicClosed = page.isTopicClosed;
        _loadingInitial = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loadingInitial = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingInitial || _loadingMore || !_hasMore || _nextCursor == null) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(anime3rbCommentsServiceProvider)
          .loadComments(
            widget.target,
            sort: _sort,
            cursor: _nextCursor,
            limit: 20,
          );
      if (!mounted) return;
      final existingIds = {for (final c in _comments) c.uuid};
      setState(() {
        for (final item in page.items) {
          if (existingIds.add(item.uuid)) _comments.add(item);
        }
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && page.nextCursor != null;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ref.read(notificationServiceProvider).showError(error.toString());
    }
  }

  Future<void> _openSignIn() async {
    if (Anime3rbAuthWebViewScreen.isSupported) {
      final res = await Anime3rbAuthWebViewScreen.open(
        context,
        action: Anime3rbAuthAction.signIn,
      );
      if (!mounted || res == null) return;
      unawaited(_loadInitial());
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => const AnimeWitcherAccountScreen(),
      ),
    );
    if (mounted) unawaited(_loadInitial());
  }

  Future<void> _publishComment() async {
    if (_publishing || _isTopicClosed) return;
    final text = _composerController.text.trim();
    if (text.isEmpty) return;
    setState(() => _publishing = true);
    try {
      final created = await ref
          .read(anime3rbCommentsServiceProvider)
          .createComment(widget.target, text: text);
      if (!mounted) return;
      _composerController.clear();
      setState(() {
        _comments.insert(0, created);
        if (_totalCount != null) _totalCount = _totalCount! + 1;
        _publishing = false;
      });
      ref.read(notificationServiceProvider).showSuccess('تم نشر التعليق.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _publishing = false);
      ref.read(notificationServiceProvider).showError(error.toString());
    }
  }

  Future<void> _toggleVote(Anime3rbComment comment, int value) async {
    if (_pendingVotes.contains(comment.uuid)) return;
    final account = ref.read(anime3rbAccountServiceProvider);
    if (!account.isSignedIn) {
      ref
          .read(notificationServiceProvider)
          .showInfo('سجّل الدخول إلى Anime3rb للتصويت على التعليقات.');
      return;
    }
    setState(() => _pendingVotes.add(comment.uuid));
    try {
      final updated = await ref
          .read(anime3rbCommentsServiceProvider)
          .toggleVote(widget.target, comment, value);
      if (!mounted) return;
      setState(() {
        _replaceCommentInTree(updated);
      });
    } catch (error) {
      if (!mounted) return;
      ref.read(notificationServiceProvider).showError(error.toString());
    } finally {
      if (mounted) setState(() => _pendingVotes.remove(comment.uuid));
    }
  }

  void _replaceCommentInTree(Anime3rbComment updated) {
    final idx = _comments.indexWhere((c) => c.uuid == updated.uuid);
    if (idx >= 0) _comments[idx] = updated;
    for (final entry in _repliesByParent.entries) {
      final rIdx = entry.value.indexWhere((c) => c.uuid == updated.uuid);
      if (rIdx >= 0) entry.value[rIdx] = updated;
    }
  }

  void _removeCommentFromTree(Anime3rbComment target) {
    _comments.removeWhere((c) => c.uuid == target.uuid);
    if (target.parentUuid != null) {
      _repliesByParent[target.parentUuid]?.removeWhere(
        (c) => c.uuid == target.uuid,
      );
    }
  }

  Future<void> _toggleReplies(Anime3rbComment parent) async {
    final uuid = parent.uuid;
    if (_expandedReplies.contains(uuid)) {
      setState(() => _expandedReplies.remove(uuid));
      return;
    }
    setState(() => _expandedReplies.add(uuid));
    if (_repliesByParent.containsKey(uuid)) return;
    await _loadReplies(parent, reset: true);
  }

  Future<void> _loadReplies(
    Anime3rbComment parent, {
    bool reset = false,
  }) async {
    final uuid = parent.uuid;
    if (_loadingReplies.contains(uuid)) return;
    setState(() => _loadingReplies.add(uuid));
    try {
      final page = await ref
          .read(anime3rbCommentsServiceProvider)
          .loadReplies(
            widget.target,
            uuid,
            cursor: reset ? null : _repliesCursorByParent[uuid],
            sort: Anime3rbCommentSort.oldest,
          );
      if (!mounted) return;
      setState(() {
        final existing = reset
            ? <Anime3rbComment>[]
            : List<Anime3rbComment>.from(_repliesByParent[uuid] ?? const []);
        final seen = {for (final r in existing) r.uuid};
        for (final item in page.items) {
          if (seen.add(item.uuid)) existing.add(item);
        }
        _repliesByParent[uuid] = existing;
        _repliesCursorByParent[uuid] = page.nextCursor;
        _repliesHasMoreByParent[uuid] =
            page.hasMore && page.nextCursor != null;
      });
    } catch (error) {
      if (!mounted) return;
      ref.read(notificationServiceProvider).showError(error.toString());
    } finally {
      if (mounted) setState(() => _loadingReplies.remove(uuid));
    }
  }

  Future<void> _replyTo(Anime3rbComment parent) async {
    final account = ref.read(anime3rbAccountServiceProvider);
    if (!account.isSignedIn) {
      ref
          .read(notificationServiceProvider)
          .showInfo('سجّل الدخول إلى Anime3rb لإضافة رد.');
      return;
    }
    final controller = TextEditingController();
    var busy = false;
    final submitted = await showDialog<Anime3rbComment>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('رد على ${parent.author.name}'),
          content: TextField(
            controller: controller,
            enabled: !busy,
            maxLines: 4,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'اكتب ردك هنا...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final txt = controller.text.trim();
                      if (txt.isEmpty) return;
                      setDialogState(() => busy = true);
                      try {
                        final created = await ref
                            .read(anime3rbCommentsServiceProvider)
                            .createComment(
                              widget.target,
                              text: txt,
                              parentUuid: parent.uuid,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop(created);
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() => busy = false);
                        ref
                            .read(notificationServiceProvider)
                            .showError(error.toString());
                      }
                    },
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('إرسال'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || submitted == null) return;
    setState(() {
      _expandedReplies.add(parent.uuid);
      final list = List<Anime3rbComment>.from(
        _repliesByParent[parent.uuid] ?? const [],
      )..add(submitted);
      _repliesByParent[parent.uuid] = list;
      _replaceCommentInTree(
        parent.copyWith(repliesCount: parent.repliesCount + 1),
      );
    });
  }

  Future<void> _editComment(Anime3rbComment comment) async {
    final controller = TextEditingController(text: comment.bodyText);
    var busy = false;
    final edited = await showDialog<Anime3rbComment>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('تعديل التعليق'),
          content: TextField(
            controller: controller,
            enabled: !busy,
            maxLines: 4,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final txt = controller.text.trim();
                      if (txt.isEmpty) return;
                      setDialogState(() => busy = true);
                      try {
                        final updated = await ref
                            .read(anime3rbCommentsServiceProvider)
                            .editComment(
                              widget.target,
                              commentUuid: comment.uuid,
                              text: txt,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop(updated);
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() => busy = false);
                        ref
                            .read(notificationServiceProvider)
                            .showError(error.toString());
                      }
                    },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || edited == null) return;
    setState(() => _replaceCommentInTree(edited));
  }

  Future<void> _deleteComment(Anime3rbComment comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف التعليق'),
        content: const Text('هل أنت متأكد من حذف هذا التعليق؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(anime3rbCommentsServiceProvider)
          .deleteComment(widget.target, commentUuid: comment.uuid);
      if (!mounted) return;
      setState(() => _removeCommentFromTree(comment));
      ref.read(notificationServiceProvider).showSuccess('تم حذف التعليق.');
    } catch (error) {
      if (!mounted) return;
      ref.read(notificationServiceProvider).showError(error.toString());
    }
  }

  String _sortSystemImage(Anime3rbCommentSort sort) => switch (sort) {
    Anime3rbCommentSort.popular => 'heart',
    Anime3rbCommentSort.latest => 'clock',
    Anime3rbCommentSort.oldest => 'clock.arrow.circlepath',
  };

  IconData _sortFallbackIcon(Anime3rbCommentSort sort) => switch (sort) {
    Anime3rbCommentSort.popular => Icons.favorite_border_rounded,
    Anime3rbCommentSort.latest => Icons.schedule_rounded,
    Anime3rbCommentSort.oldest => Icons.history_rounded,
  };

  List<AppleNativeMenuItem> _sortMenuItems() => [
    for (final s in Anime3rbCommentSort.values)
      AppleNativeMenuItem(
        value: s.name,
        label: s.label,
        systemImage: _sortSystemImage(s),
        icon: _sortFallbackIcon(s),
      ),
  ];

  void _applySortByName(String value) {
    final next = Anime3rbCommentSort.values.firstWhere(
      (s) => s.name == value,
      orElse: () => _sort,
    );
    if (next == _sort || !mounted) return;
    setState(() => _sort = next);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    unawaited(_loadInitial());
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(anime3rbAccountServiceProvider);
    final signedIn = account.isSignedIn;
    final userSlug = account.profile?.userSlug;
    final viewerUuid = ref.watch(anime3rbCommentsServiceProvider).viewerUuid;

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
            trailingButtons: [
              AppleLiquidGlassToolbarButton(
                width: AnimeWitcherCommentSortControl.size,
                tooltip: 'ترتيب التعليقات',
                icon: _sortFallbackIcon(_sort),
                systemImage: _sortSystemImage(_sort),
                title: null,
                color: colors.primary,
                menuTintColor: colors.primary,
                onPressed: null,
                selectedMenuValue: _sort.name,
                menuItems: _sortMenuItems(),
                onMenuSelected: _applySortByName,
              ),
            ],
          ),
        );
      });
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: 'التعليقات',
        onBack: () => Navigator.of(context).pop(),
        actions: appleUsesPersistentLiquidGlassHeader
            ? const <Widget>[]
            : <Widget>[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: AnimeWitcherCommentSortControl.width,
                    height: AnimeWitcherCommentSortControl.size,
                    child: AnimatedSortMenuButton(
                      tooltip: 'ترتيب التعليقات',
                      selectedValue: _sort.name,
                      items: _sortMenuItems(),
                      onSelected: _applySortByName,
                      icon: _sortFallbackIcon(_sort),
                      systemImage: _sortSystemImage(_sort),
                      tintColor: Theme.of(context).colorScheme.primary,
                      size: AnimeWitcherCommentSortControl.size,
                      fallbackIcon: AnimeWitcherCommentSortControl.fallbackIcon,
                    ),
                  ),
                ),
                const WindowControlsGap(),
              ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _buildCommentsBody(
              context,
              viewerUuid: viewerUuid,
              userSlug: userSlug,
            ),
          ),
          _buildComposer(context, signedIn),
        ],
      ),
    );
  }

  Widget _buildCommentsBody(
    BuildContext context, {
    required String? viewerUuid,
    required String? userSlug,
  }) {
    final topInset = appPageHeaderContentTopInset(context);
    if (_loadingInitial) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_error != null && _comments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 40),
              const SizedBox(height: 10),
              const Text(
                'تعذر تحميل التعليقات.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _loadInitial,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }
    if (_comments.isEmpty) {
      return MouseDragRefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: topInset),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'لا توجد تعليقات منشورة بعد.',
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
        padding: EdgeInsets.fromLTRB(12, topInset + 12, 12, 24),
        itemCount: _comments.length + (_loadingMore || _hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 8),
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
          return _buildCommentTile(
            context,
            _comments[index],
            viewerUuid: viewerUuid,
            userSlug: userSlug,
          );
        },
      ),
    );
  }

  Widget _buildComposer(BuildContext context, bool signedIn) {
    final colors = Theme.of(context).colorScheme;
    if (_isTopicClosed) {
      return SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.comments_disabled_outlined,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                'تم إيقاف التعليقات على هذا المحتوى.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
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
        child: signedIn
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composerController,
                      enabled: !_publishing,
                      minLines: 1,
                      maxLines: 4,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: 'اكتب تعليقًا...',
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
                  IconButton.filled(
                    tooltip: 'نشر',
                    onPressed: _publishing ? null : _publishComment,
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
                padding: const EdgeInsets.symmetric(vertical: 4),
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
                        'سجّل الدخول إلى Anime3rb لإضافة تعليق.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _openSignIn,
                      child: const Text('تسجيل الدخول'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildCommentTile(
    BuildContext context,
    Anime3rbComment comment, {
    required String? viewerUuid,
    required String? userSlug,
    bool isReply = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final isMine = comment.isOwnedBy(
      comntoUserUuid: viewerUuid,
      userSlug: userSlug,
    );
    final replies = _repliesByParent[comment.uuid] ?? const <Anime3rbComment>[];
    final expanded = _expandedReplies.contains(comment.uuid);
    final loadingReplies = _loadingReplies.contains(comment.uuid);
    final hasMoreReplies = _repliesHasMoreByParent[comment.uuid] == true;
    final avatarRadius = isReply ? 16.0 : 20.0;
    final avatarUrl = comment.author.avatarUrl?.trim() ?? '';
    final voteBusy = _pendingVotes.contains(comment.uuid);

    return Material(
      color: isReply
          ? colors.surfaceContainer.withValues(alpha: 0.65)
          : colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(isReply ? 12 : 16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(isReply ? 10 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Directionality(
              textDirection: TextDirection.rtl,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: avatarRadius,
                    backgroundColor: colors.surfaceContainerHighest,
                    backgroundImage: avatarImage(
                      context,
                      avatarUrl,
                      radius: avatarRadius,
                    ),
                    child: avatarUrl.isEmpty
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                comment.author.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (comment.isPinned) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.push_pin_rounded,
                                size: 14,
                                color: colors.primary,
                              ),
                            ],
                          ],
                        ),
                        if (comment.createdAt != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${formatArabicRelativeTime(comment.createdAt!)}${comment.isEdited ? ' · معدّل' : ''}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isMine && !comment.isDeleted)
                    PopupMenuButton<String>(
                      tooltip: 'إدارة التعليق',
                      onSelected: (action) {
                        if (action == 'edit') unawaited(_editComment(comment));
                        if (action == 'delete') {
                          unawaited(_deleteComment(comment));
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('تعديل')),
                        PopupMenuItem(value: 'delete', child: Text('حذف')),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Text(
                comment.bodyText,
                textAlign: TextAlign.start,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _Anime3rbReactionButton(
                    icon: comment.userVote == 1
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    count: comment.upvotesCount,
                    active: comment.userVote == 1,
                    busy: voteBusy,
                    tooltip: 'إعجاب',
                    onTap: () => _toggleVote(comment, 1),
                  ),
                  const SizedBox(width: 8),
                  _Anime3rbReactionButton(
                    icon: comment.userVote == -1
                        ? Icons.thumb_down_rounded
                        : Icons.thumb_down_outlined,
                    count: comment.downvotesCount,
                    active: comment.userVote == -1,
                    busy: voteBusy,
                    tooltip: 'لم يعجبني',
                    onTap: () => _toggleVote(comment, -1),
                  ),
                  if (!isReply) ...[
                    const SizedBox(width: 12),
                    _Anime3rbReactionButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      count: comment.repliesCount,
                      active: expanded,
                      tooltip: expanded ? 'إخفاء الردود' : 'الردود',
                      onTap: () {
                        if (comment.repliesCount > 0) {
                          unawaited(_toggleReplies(comment));
                        } else if (!comment.isDeleted) {
                          unawaited(_replyTo(comment));
                        }
                      },
                    ),
                    if (!comment.isDeleted && comment.repliesCount > 0) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'إضافة رد',
                        child: InkWell(
                          onTap: () => _replyTo(comment),
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Icons.reply_rounded,
                              size: 19,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            if (!isReply && expanded) ...[
              const SizedBox(height: 8),
              if (loadingReplies && replies.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: AppLoadingIndicator()),
                )
              else ...[
                for (final reply in replies) ...[
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 14,
                      bottom: 6,
                    ),
                    child: _buildCommentTile(
                      context,
                      reply,
                      viewerUuid: viewerUuid,
                      userSlug: userSlug,
                      isReply: true,
                    ),
                  ),
                ],
                if (hasMoreReplies)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: loadingReplies
                          ? null
                          : () => _loadReplies(comment),
                      child: const Text('عرض المزيد من الردود'),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Anime3rbReactionButton extends StatelessWidget {
  const _Anime3rbReactionButton({
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
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Anime3rbDetailsCommentsPreview extends ConsumerStatefulWidget {
  const Anime3rbDetailsCommentsPreview({super.key, required this.item});

  final MultimediaItem item;

  @override
  ConsumerState<Anime3rbDetailsCommentsPreview> createState() =>
      _Anime3rbDetailsCommentsPreviewState();
}

class _Anime3rbDetailsCommentsPreviewState
    extends ConsumerState<Anime3rbDetailsCommentsPreview> {
  List<Anime3rbComment> _preview = const <Anime3rbComment>[];
  int? _total;
  bool _loading = true;
  String? _loadedUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(covariant Anime3rbDetailsCommentsPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url) {
      _load();
    }
  }

  Future<void> _load() async {
    final target = Anime3rbCommentTarget.fromAnime(widget.item);
    if (target == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _loadedUrl = widget.item.url;
    setState(() => _loading = true);
    try {
      final page = await ref
          .read(anime3rbCommentsServiceProvider)
          .loadComments(target, limit: 3);
      if (!mounted || _loadedUrl != widget.item.url) return;
      setState(() {
        _preview = page.items;
        _total = page.totalCount;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || _loadedUrl != widget.item.url) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = Anime3rbCommentTarget.fromAnime(widget.item);
    if (target == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HomeSectionHeader(
          title: _total != null ? 'التعليقات ($_total)' : 'التعليقات',
          action: HomeViewAllButton(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Anime3rbCommentsScreen(target: target),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: AppLoadingIndicator()),
          )
        else if (_preview.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Anime3rbCommentsScreen(target: target),
                ),
              ),
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('لا توجد تعليقات بعد · أضف أول تعليق'),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (final comment in _preview)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colors.outlineVariant.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                comment.author.name,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (comment.createdAt != null)
                              Text(
                                formatArabicRelativeTime(comment.createdAt!),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          comment.bodyText,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
