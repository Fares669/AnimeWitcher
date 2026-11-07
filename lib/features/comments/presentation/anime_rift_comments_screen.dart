import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';

import '../../../core/utils/relative_time.dart';
import '../../../core/utils/avatar_image.dart';

import '../../../core/extensions/providers/anime_rift_comments.dart';
import '../../../core/extensions/providers/anime_rift_provider.dart';
import '../../../core/storage/anime_rift_account_scope.dart';

/// Uses Rift's own gateway/account. Never reads or writes Witcher's Firestore.
class AnimeRiftCommentsScreen extends StatefulWidget {
  const AnimeRiftCommentsScreen({
    super.key,
    required this.provider,
    required this.target,
  });

  final AnimeRiftProvider provider;
  final AnimeRiftCommentTarget target;

  @override
  State<AnimeRiftCommentsScreen> createState() =>
      _AnimeRiftCommentsScreenState();
}

class _AnimeRiftCommentsScreenState extends State<AnimeRiftCommentsScreen> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Set<String> _revealedSpoilers = <String>{};
  final Set<String> _reactingIds = <String>{};
  // Keep local results over later list responses, which may predate a reaction.
  final Map<String, ({bool liked, int count})> _reactions = {};
  String? _reactionAccountHash;
  List<AnimeRiftComment> _comments = const [];
  bool _initialLoading = true;
  bool _moreLoading = false;
  bool _hasMore = false;
  bool _posting = false;
  bool _linked = false;
  bool? _serverUserIdPresent;
  bool? _termsAccepted;
  bool? _replyAllowed;
  int _nextPage = 0;
  int _requestGeneration = 0;
  Object? _error;

  bool get _canPublish =>
      _linked &&
      _termsAccepted != false &&
      (widget.target.parentId == null || _replyAllowed != false);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    applePersistentGlassHeaderController.hide(this);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.hasClients &&
        _hasMore &&
        !_moreLoading &&
        !_initialLoading &&
        _scroll.position.extentAfter < 400) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    if (!mounted || _reactingIds.isNotEmpty) return;
    final generation = ++_requestGeneration;
    setState(() {
      _initialLoading = true;
      _moreLoading = false;
      _error = null;
      _hasMore = false;
    });
    try {
      final linked = await widget.provider.restoreAccountSession();
      var page = await widget.provider.loadComments(widget.target);
      var nextPage = 1;
      // An empty first page can still advertise further results (e.g. after
      // server-side moderation). The empty-list UI has no scroll controller,
      // so it could never reach page 1 without this bounded advance.
      while (page.items.isEmpty && page.hasMore && nextPage <= 3) {
        page = await widget.provider.loadComments(
          widget.target,
          page: nextPage++,
        );
      }
      if (!mounted || generation != _requestGeneration) return;
      _acceptServerReactions(page.items);
      setState(() {
        _linked = linked;
        _serverUserIdPresent = page.serverUserIdPresent;
        _termsAccepted = page.termsAccepted;
        _replyAllowed = page.replyAllowed;
        _comments = page.items;
        _hasMore = page.hasMore;
        _nextPage = nextPage;
        _initialLoading = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = error;
        _initialLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_moreLoading || !_hasMore || _initialLoading) return;
    final generation = _requestGeneration;
    setState(() => _moreLoading = true);
    try {
      final page = await widget.provider.loadComments(
        widget.target,
        page: _nextPage,
      );
      if (!mounted || generation != _requestGeneration) return;
      _acceptServerReactions(page.items);
      setState(() {
        final known = _comments.map((comment) => comment.id).toSet();
        _comments = [
          ..._comments,
          ...page.items.where((comment) => known.add(comment.id)),
        ];
        _hasMore = page.hasMore;
        _nextPage++;
      });
    } catch (error) {
      if (mounted && generation == _requestGeneration) _message(error);
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _moreLoading = false);
      }
    }
  }

  void _message(Object error) {
    final message = error is FormatException
        ? 'تعذر قراءة بيانات تعليقات AnimeRift.'
        : error is AnimeRiftAccessUnavailable
        ? error.toString()
        : 'تعذر إكمال العملية في AnimeRift. حاول مرة أخرى.';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _acceptServerReactions(List<AnimeRiftComment> items) {
    final account = AnimeRiftLocalAccountScope.accountHash;
    if (_reactionAccountHash != account) {
      _reactions.clear();
      _reactionAccountHash = account;
    }
    for (final comment in items) {
      final liked = comment.likedByMe;
      if (liked == null || _reactingIds.contains(comment.id)) continue;
      // Unlike a cached local guess, the original app obtains this flag from
      // `interactions` returned by /comment/all on every load.
      _reactions.remove(comment.id);
      widget.provider.rememberCommentReaction(
        widget.target,
        comment.id,
        liked: liked,
        count: comment.likes,
      );
    }
  }

  ({bool liked, int count})? _reactionFor(AnimeRiftComment comment) {
    final pending = _reactions[comment.id];
    if (pending != null) return pending;
    if (comment.likedByMe case final liked?) {
      return (liked: liked, count: comment.likes);
    }
    return widget.provider.knownCommentReaction(widget.target, comment.id);
  }

  Future<void> _publish() async {
    final text = _composer.text.trim();
    if (!_canPublish || _posting || text.isEmpty) return;
    setState(() => _posting = true);
    try {
      await widget.provider.publishComment(widget.target, text);
      if (!mounted) return;
      _composer.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أُرسل التعليق إلى AnimeRift.')),
      );
      await _reload();
    } catch (error) {
      if (mounted) _message(error);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _react(AnimeRiftComment comment) async {
    if (!_linked || !_reactingIds.add(comment.id)) return;
    final previous = _reactionFor(comment);
    final accountAtStart = AnimeRiftLocalAccountScope.accountHash;
    final liked = previous?.liked ?? false;
    final count = previous?.count ?? comment.likes;
    setState(() {
      _reactions[comment.id] = (
        liked: !liked,
        count: liked ? (count > 0 ? count - 1 : 0) : count + 1,
      );
    });
    try {
      await widget.provider.reactToComment(widget.target, comment.id);
      if (accountAtStart == AnimeRiftLocalAccountScope.accountHash) {
        final confirmed = _reactions[comment.id];
        if (confirmed != null) {
          widget.provider.rememberCommentReaction(
            widget.target,
            comment.id,
            liked: confirmed.liked,
            count: confirmed.count,
          );
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          if (previous == null) {
            _reactions.remove(comment.id);
          } else {
            _reactions[comment.id] = previous;
          }
        });
        _message(error);
      }
    } finally {
      _reactingIds.remove(comment.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openReplies(AnimeRiftComment comment) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimeRiftCommentsScreen(
          provider: widget.provider,
          target: widget.target.replies(comment.id),
        ),
      ),
    );
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
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
          ),
        );
      });
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: widget.target.parentId == null ? 'التعليقات' : 'الردود',
        onBack: () => Navigator.of(context).pop(),
      ),
      body: Column(
        children: [
          Expanded(child: _buildCommentsBody(context)),
          _buildComposer(context),
        ],
      ),
    );
  }

  Widget _buildCommentsBody(BuildContext context) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('تعذّر تحميل تعليقات AnimeRift.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _reload,
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return MouseDragRefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: appPageHeaderContentTopInset(context)),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _linked && _serverUserIdPresent == false
                    ? 'أعاد خادم AnimeRift قائمة تعليقات فارغة دون معرّف مستخدم، رغم وجود حساب مرتبط في التطبيق. جرّب إعادة ربط حساب AnimeRift ثم حدّث الصفحة.'
                    : !_linked
                    ? 'لم يعرض خادم AnimeRift تعليقات للضيف. جرّب ربط حساب AnimeRift ثم حدّث الصفحة.'
                    : 'لا توجد تعليقات منشورة بعد.',
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
      onRefresh: _reload,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          12,
          appPageHeaderContentTopInset(context) + 12,
          12,
          24,
        ),
        itemCount: _comments.length + (_hasMore || _moreLoading ? 1 : 0),
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
          return _buildCommentCard(context, _comments[index]);
        },
      ),
    );
  }

  /// Same comment-card visual structure as AnimeWitcherCommentsScreen.
  Widget _buildCommentCard(BuildContext context, AnimeRiftComment comment) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final photo = comment.photoUrl ?? '';
    final reaction = _reactionFor(comment);
    final reveal = !comment.spoiler || _revealedSpoilers.contains(comment.id);
    return Material(
      key: ValueKey('rift-comment-${comment.id}'),
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
                          comment.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatArabicRelativeTime(comment.createdAt),
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
                  onPressed: () =>
                      setState(() => _revealedSpoilers.add(comment.id)),
                  icon: const Icon(Icons.local_fire_department_rounded),
                  label: const Text('تعليق يحتوي على حرق — إظهار'),
                ),
              ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _RiftReaction(
                    icon: reaction?.liked == true
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    count: reaction?.count ?? comment.likes,
                    tooltip: 'الإعجابات',
                    active: reaction?.liked == true,
                    onTap: _linked && !_reactingIds.contains(comment.id)
                        ? () => _react(comment)
                        : null,
                  ),
                  const SizedBox(width: 14),
                  _RiftReaction(
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

  Widget _buildComposer(BuildContext context) {
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
        child: _canPublish
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('rift-comment-input'),
                      controller: _composer,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 5000,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: 'اكتب تعليقًا...',
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
                  IconButton.filled(
                    tooltip: 'نشر التعليق',
                    onPressed: _posting ? null : _publish,
                    icon: _posting
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
                        !_linked
                            ? 'اربط حساب AnimeRift من الإعدادات لإضافة تعليق.'
                            : _termsAccepted == false
                            ? 'يجب قبول إرشادات المجتمع في AnimeRift قبل التعليق.'
                            : 'الخادم لا يسمح بالرد على هذا التعليق.',
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

class _RiftReaction extends StatelessWidget {
  const _RiftReaction({
    required this.icon,
    required this.count,
    required this.tooltip,
    this.active = false,
    this.onTap,
  });

  final IconData icon;
  final int count;
  final String tooltip;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Colors.redAccent
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(width: 5),
              Text('$count', style: TextStyle(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
