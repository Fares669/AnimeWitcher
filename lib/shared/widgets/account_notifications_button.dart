import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/account/account_providers.dart';
import '../../features/notifications/presentation/animewitcher_notifications_screen.dart';

final accountNotificationCountProvider = FutureProvider.autoDispose<int>((ref) {
  final lifecycle = AppLifecycleListener(onResume: ref.invalidateSelf);
  ref.onDispose(lifecycle.dispose);
  final account = ref
      .watch(animeWitcherAccountControllerProvider)
      .asData
      ?.value;
  ref.watch(accountDataRevisionProvider);
  if (account?.isSignedIn != true) return 0;
  return ref.watch(animeWitcherAccountServiceProvider).loadNotificationCount();
});

class AccountNotificationsButton extends ConsumerWidget {
  const AccountNotificationsButton({
    super.key,
    this.foregroundColor,
    this.beforeOpen,
  });
  final Color? foregroundColor;
  final VoidCallback? beforeOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref
        .watch(animeWitcherAccountControllerProvider)
        .asData
        ?.value
        .profile;
    if (profile == null) return const SizedBox.shrink();
    final count =
        ref.watch(accountNotificationCountProvider).asData?.value ?? 0;
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      key: const ValueKey('account-notifications-button'),
      tooltip: count > 0 ? 'الإشعارات، $count غير مشاهدة' : 'الإشعارات',
      color: foregroundColor,
      onPressed: () async {
        final navigator = Navigator.of(context, rootNavigator: true);
        beforeOpen?.call();
        await navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const AnimeWitcherNotificationsScreen(),
          ),
        );
        if (context.mounted) ref.invalidate(accountNotificationCountProvider);
      },
      icon: Badge.count(
        count: count,
        isLabelVisible: count > 0,
        backgroundColor: colors.primary,
        textColor: colors.onPrimary,
        child: const Icon(Icons.notifications_none_rounded),
      ),
    );
  }
}
