import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/account/animewitcher_notification_models.dart';
import '../../../core/account/firestore_rest_client.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/request_generation.dart';
import '../../../core/utils/avatar_image.dart';
import '../../../core/utils/relative_time.dart';
import '../../../shared/widgets/account_notifications_button.dart';
import '../../../shared/widgets/app_page_header.dart';
import '../../../shared/widgets/mouse_drag_refresh_indicator.dart';
import '../../comments/presentation/animewitcher_replies_screen.dart';

class AnimeWitcherNotificationsScreen extends ConsumerStatefulWidget {
  const AnimeWitcherNotificationsScreen({super.key});

  @override
  ConsumerState<AnimeWitcherNotificationsScreen> createState() =>
      _NotificationsState();
}

class _NotificationsState
    extends ConsumerState<AnimeWitcherNotificationsScreen> {
  final _scroll = ScrollController();
  final _generation = RequestGeneration();
  final _pending = <String>{};
  List<AnimeWitcherNotification> _items = [];
  FirestoreDocument? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  Object? _error;

  String? get _accountId =>
      ref.read(animeWitcherAccountServiceProvider).snapshot.profile?.documentId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _current(int generation, String? accountId) =>
      mounted && _generation.isCurrent(generation) && _accountId == accountId;

  void _onScroll() {
    if (_scroll.position.extentAfter < 300 &&
        !_loading &&
        !_loadingMore &&
        _hasMore &&
        _error == null) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false}) async {
    if (!mounted ||
        _pending.isNotEmpty ||
        (more && (_loading || _loadingMore || !_hasMore))) {
      return;
    }
    final generation = more ? _generation.current : _generation.begin();
    final accountId = _accountId;
    setState(() {
      _error = null;
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        _cursor = null;
        _hasMore = false;
        _items = [];
        _pending.clear();
      }
    });
    if (accountId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final page = await ref
          .read(animeWitcherAccountServiceProvider)
          .loadNotifications(cursor: more ? _cursor : null);
      if (!_current(generation, accountId)) return;
      setState(() {
        final paths = _items.map((item) => item.path).toSet();
        _items = more
            ? [..._items, ...page.items.where((item) => paths.add(item.path))]
            : page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
        _loadingMore = false;
      });
      if (!more) {
        // A successful fetch is not yet a displayed inbox.
        await WidgetsBinding.instance.endOfFrame;
        if (_current(generation, accountId)) {
          await _markSeen(generation, accountId);
        }
      }
    } catch (error) {
      if (!_current(generation, accountId)) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error;
      });
    }
  }

  Future<void> _markSeen(int generation, String accountId) async {
    if (!_current(generation, accountId)) return;
    try {
      await ref
          .read(animeWitcherAccountServiceProvider)
          .markNotificationsSeen(accountId);
      if (_current(generation, accountId)) {
        ref.invalidate(accountNotificationCountProvider);
      }
    } catch (_) {
      if (!_current(generation, accountId)) return;
      ref
          .read(notificationServiceProvider)
          .showToast(
            message: 'تعذر تحديث عداد الإشعارات',
            type: ToastType.error,
            actionLabel: 'إعادة المحاولة',
            onAction: () => _markSeen(generation, accountId),
            duration: const Duration(seconds: 4),
          );
    }
  }

  Future<void> _act(AnimeWitcherNotification item, String action) async {
    if (_pending.contains(item.path)) return;
    final generation = _generation.current;
    final accountId = _accountId;
    setState(() => _pending.add(item.path));
    final navigator = Navigator.of(context);
    try {
      final service = ref.read(animeWitcherAccountServiceProvider);
      if (action == 'delete') {
        await service.deleteNotification(item.path);
        if (!_current(generation, accountId)) return;
        setState(
          () => _items = _items
              .where((value) => value.path != item.path)
              .toList(),
        );
      } else {
        final target = action == 'open'
            ? await service.loadNotificationTarget(item)
            : null;
        if (!_current(generation, accountId)) return;
        if (action == 'open' && target == null) {
          _showError('المحتوى غير متاح أو تم حذفه');
          return;
        }
        await service.markNotificationClicked(item.path);
        if (!_current(generation, accountId)) return;
        setState(
          () => _items = _items
              .map(
                (value) => value.path == item.path
                    ? value.copyWith(clicked: true)
                    : value,
              )
              .toList(),
        );
        if (target != null) {
          await navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => AnimeWitcherRepliesScreen(
                parentComment: target,
                showParent: true,
              ),
            ),
          );
        }
      }
    } catch (error) {
      if (_current(generation, accountId)) {
        final code = error is AnimeWitcherAccountException ? error.code : null;
        _showError(switch (code) {
          'notification-target-reference' =>
            'رابط الإشعار غير صالح أو غير مدعوم',
          'notification-target-hidden' => 'هذا المحتوى غير متاح للعرض حالياً',
          'notification-target-content' =>
            'تعذر قراءة محتوى التعليق أو المراجعة',
          _ => 'تعذر تنفيذ العملية، حاول مرة أخرى',
        });
      }
    } finally {
      if (_current(generation, accountId)) {
        setState(() => _pending.remove(item.path));
      }
    }
  }

  void _showError(String message) {
    ref.read(notificationServiceProvider).showError(message);
  }

  @override
  Widget build(BuildContext context) {
    final account = ref
        .watch(animeWitcherAccountControllerProvider)
        .asData
        ?.value
        .profile;
    ref.listen(animeWitcherAccountControllerProvider, (previous, next) {
      final old = previous?.asData?.value.profile;
      final current = next.asData?.value.profile;
      if (old?.documentId != current?.documentId || old?.uid != current?.uid) {
        // Clear private rows immediately; fetch the replacement account next frame.
        _generation.begin();
        _pending.clear();
        _items = [];
        _loading = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    });
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: 'الإشعارات',
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _loading || _pending.isNotEmpty ? null : () => _load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: MouseDragRefreshIndicator(
          onRefresh: () => _load(),
          child: ListView.builder(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              appPageHeaderContentTopInset(context) + 16,
              16,
              32,
            ),
            itemCount: _items.length + 1,
            itemBuilder: (context, index) {
              if (index < _items.length) return _row(_items[index]);
              if (account == null && !_loading) {
                return _status('سجل الدخول لعرض الإشعارات');
              }
              if (_loading || _loadingMore) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (_error != null) {
                return Column(
                  children: [
                    _status('تعذر تحميل الإشعارات'),
                    TextButton(
                      onPressed: () => _load(more: _items.isNotEmpty),
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                );
              }
              if (_items.isEmpty) return _status('لا يوجد إشعارات');
              if (_hasMore) {
                return TextButton(
                  onPressed: () => _load(more: true),
                  child: const Text('تحميل المزيد'),
                );
              }
              return const SizedBox(height: 24);
            },
          ),
        ),
      ),
    );
  }

  Widget _status(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
    child: Center(child: Text(text, textAlign: TextAlign.center)),
  );

  Widget _row(AnimeWitcherNotification item) {
    final colors = Theme.of(context).colorScheme;
    final busy = _pending.contains(item.path);
    return Card(
      key: ValueKey(item.path),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: item.clicked
          ? colors.surfaceContainerLow
          : colors.primaryContainer.withValues(alpha: 0.25),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : () => _act(item, 'open'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 23,
                backgroundColor: colors.surfaceContainerHighest,
                foregroundColor: colors.onSurfaceVariant,
                child: item.actorPhotoUrl == null
                    ? const Icon(Icons.person_outline_rounded)
                    : ClipOval(
                        child: Image(
                          image: avatarImage(
                            context,
                            item.actorPhotoUrl,
                            radius: 23,
                          )!,
                          width: 46,
                          height: 46,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.person_outline_rounded),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: item.actionText == null
                            ? [TextSpan(text: item.message)]
                            : [
                                TextSpan(
                                  text: item.actorName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(text: ' ${item.actionText}'),
                                if (item.contextName != null)
                                  TextSpan(
                                    text: ' • ${item.contextName}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                              ],
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      formatArabicRelativeTime(item.date),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: 'خيارات الإشعار',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (action) => _act(item, action),
                  itemBuilder: (_) => [
                    if (!item.clicked)
                      const PopupMenuItem(
                        value: 'viewed',
                        child: Text('تمت المشاهدة'),
                      ),
                    const PopupMenuItem(value: 'delete', child: Text('حذف')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
