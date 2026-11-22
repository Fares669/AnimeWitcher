import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/account/anime3rb_account_models.dart';
import '../../../../core/account/anime3rb_account_service.dart';
import '../../../../core/extensions/providers/anime3rb_provider.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/storage/anime3rb_library_service.dart';
import 'anime3rb_auth_webview_screen.dart';
import 'settings_widgets.dart';

class Anime3rbAccountSection extends ConsumerWidget {
  const Anime3rbAccountSection({
    super.key,
    this.returnRoute,
    this.inAppAuthLauncher,
  });

  final String? returnRoute;
  final Future<Anime3rbBrowserAuthResult?> Function(
    BuildContext context,
    Anime3rbAuthAction action,
  )?
  inAppAuthLauncher;

  Future<void> _startOfficialAuth(
    BuildContext context,
    WidgetRef ref,
    Anime3rbAuthAction action,
  ) async {
    final service = ref.read(anime3rbAccountServiceProvider);
    if (inAppAuthLauncher != null || Anime3rbAuthWebViewScreen.isSupported) {
      service.recordPendingAuthReturnRoute(returnRoute);
      final launcher =
          inAppAuthLauncher ??
          (ctx, act) => Anime3rbAuthWebViewScreen.open(ctx, action: act);
      final result = await launcher(context, action);
      if (!context.mounted || result == null) return;
      unawaited(ref.read(anime3rbLibraryServiceProvider).refreshListsFromServer());
      ref
          .read(notificationServiceProvider)
          .showSuccess('تم ربط حساب Anime3rb: ${result.profile.displayName}');
      return;
    }

    final opened = await service.beginOfficialAuth(
      action,
      returnRoute: returnRoute,
    );
    if (!context.mounted) return;
    if (!opened) {
      ref.read(notificationServiceProvider).showError('تعذر فتح موقع Anime3rb.');
      return;
    }
    await _showSessionVerificationDialog(context, ref);
  }

  Future<void> _showSessionVerificationDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final cookieController = TextEditingController();
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('تأكيد جلسة Anime3rb'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'بعد إتمام الدخول أو التسجيل في موقع Anime3rb، أدخل '
                'سلسلة كوكيز الجلسة للتحقق من الحساب وتفعيل مزامنة المكتبة والتقييم والتعليقات.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cookieController,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'جلسة Anime3rb (Cookie)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('لاحقًا'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        final result = await ref
                            .read(anime3rbAccountServiceProvider)
                            .completeBrowserAuth(
                              sessionCookie: cookieController.text,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        unawaited(
                          ref
                              .read(anime3rbLibraryServiceProvider)
                              .refreshListsFromServer(),
                        );
                        ref
                            .read(notificationServiceProvider)
                            .showSuccess(
                              'تم ربط حساب Anime3rb: ${result.profile.displayName}',
                            );
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setState(() => busy = false);
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
                  : const Text('تأكيد الربط'),
            ),
          ],
        ),
      ),
    );
    cookieController.dispose();
  }

  Future<void> _showEditProfileDialog(
    BuildContext context,
    WidgetRef ref,
    Anime3rbProfile profile,
  ) async {
    final nameController = TextEditingController(text: profile.displayName);
    final emailController = TextEditingController(text: profile.email ?? '');
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('تعديل حساب Anime3rb'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'الاسم',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: emailController,
                  enabled: !busy,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'البريد الإلكتروني',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
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
                      setState(() => busy = true);
                      try {
                        await ref
                            .read(anime3rbAccountServiceProvider)
                            .updateProfile(
                              displayName: nameController.text,
                              email: emailController.text,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        ref
                            .read(notificationServiceProvider)
                            .showSuccess('تم تحديث بيانات حساب Anime3rb.');
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setState(() => busy = false);
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
    nameController.dispose();
    emailController.dispose();
  }

  Future<void> _showChangePasswordDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final currentController = TextEditingController();
    final nextController = TextEditingController();
    final confirmController = TextEditingController();
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('تغيير كلمة مرور Anime3rb'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: currentController,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الحالية',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nextController,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الجديدة',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmController,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'تأكيد كلمة المرور الجديدة',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
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
                      setState(() => busy = true);
                      try {
                        await ref
                            .read(anime3rbAccountServiceProvider)
                            .updatePassword(
                              currentPassword: currentController.text,
                              password: nextController.text,
                              passwordConfirmation: confirmController.text,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        ref
                            .read(notificationServiceProvider)
                            .showSuccess('تم تحديث كلمة مرور Anime3rb.');
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setState(() => busy = false);
                        ref
                            .read(notificationServiceProvider)
                            .showError(error.toString());
                      }
                    },
              child: const Text('تحديث'),
            ),
          ],
        ),
      ),
    );
    currentController.dispose();
    nextController.dispose();
    confirmController.dispose();
  }

  Future<void> _showLogoutOtherSessionsDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final passwordController = TextEditingController();
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('إغلاق جلسات المتصفحات الأخرى'),
          content: TextField(
            controller: passwordController,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'تأكيد كلمة المرور',
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
                      setState(() => busy = true);
                      try {
                        await ref
                            .read(anime3rbAccountServiceProvider)
                            .logoutOtherBrowserSessions(passwordController.text);
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        ref
                            .read(notificationServiceProvider)
                            .showSuccess('تم تسجيل الخروج من الجلسات الأخرى.');
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setState(() => busy = false);
                        ref
                            .read(notificationServiceProvider)
                            .showError(error.toString());
                      }
                    },
              child: const Text('تأكيد'),
            ),
          ],
        ),
      ),
    );
    passwordController.dispose();
  }

  Future<void> _showNotificationsDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final service = ref.read(anime3rbAccountServiceProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _Anime3rbNotificationsDialog(service: service),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(anime3rbAccountServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final profile = service.profile;
        if (profile == null) {
          return SettingsGroup(
            title: 'Anime3rb',
            children: [
              SettingsTile(
                icon: Icons.login_rounded,
                title: 'تسجيل الدخول إلى Anime3rb',
                subtitle: 'مزامنة المكتبة والتقييمات والتعليقات ومتابعة المشاهدة',
                onTap: () => _startOfficialAuth(
                  context,
                  ref,
                  Anime3rbAuthAction.signIn,
                ),
              ),
              SettingsTile(
                icon: Icons.person_add_alt_1_rounded,
                title: 'إنشاء حساب Anime3rb',
                onTap: () => _startOfficialAuth(
                  context,
                  ref,
                  Anime3rbAuthAction.register,
                ),
              ),
              SettingsTile(
                icon: Icons.lock_reset_rounded,
                title: 'استعادة كلمة مرور Anime3rb',
                onTap: () => _startOfficialAuth(
                  context,
                  ref,
                  Anime3rbAuthAction.forgotPassword,
                ),
              ),
              SettingsTile(
                icon: Icons.public_rounded,
                title: 'حساب Anime3rb على الموقع',
                subtitle: Anime3rbProvider.originUrl,
                onTap: () => launchUrl(
                  Anime3rbProvider.websiteUri('/user/profile'),
                  mode: LaunchMode.externalApplication,
                ),
                isLast: true,
              ),
            ],
          );
        }

        final counts = profile.counts;
        final countsSummary =
            'أشاهده ${counts.watching} · أنهيته ${counts.completed} · '
            'لاحقًا ${counts.planToWatch} · تقييماتي ${counts.ratings}';
        return SettingsGroup(
          title: 'Anime3rb',
          children: [
            SettingsTile(
              icon: Icons.account_circle_rounded,
              title: '${profile.displayName} (@${profile.userSlug})',
              subtitle: service.usingInMemorySessionFallback
                  ? '$countsSummary (جلسة مؤقتة بالذاكرة)'
                  : countsSummary,
              trailing: const Icon(Icons.refresh_rounded, size: 18),
              onTap: () async {
                await service.refreshProfile();
                await ref
                    .read(anime3rbLibraryServiceProvider)
                    .refreshListsFromServer();
              },
            ),
            SettingsTile(
              icon: Icons.notifications_outlined,
              title: 'إشعارات Anime3rb',
              subtitle: profile.unreadNotifications > 0
                  ? '${profile.unreadNotifications} إشعار غير مقروء'
                  : 'عرض إشعارات الحساب',
              onTap: () => _showNotificationsDialog(context, ref),
            ),
            SettingsTile(
              icon: Icons.sync_rounded,
              title: 'مزامنة مكتبة وتقييمات Anime3rb',
              subtitle: profile.watchingProgress.isNotEmpty
                  ? 'يتضمن متابعة المشاهدة (${profile.watchingProgress.length} أعمال)'
                  : 'تحديث القوائم الخمس والتقييمات من الخادم',
              onTap: () async {
                await ref
                    .read(anime3rbLibraryServiceProvider)
                    .refreshListsFromServer();
                if (!context.mounted) return;
                ref
                    .read(notificationServiceProvider)
                    .showSuccess('تمت مزامنة مكتبة Anime3rb.');
              },
            ),
            SettingsTile(
              icon: Icons.edit_outlined,
              title: 'تعديل الاسم والبريد في Anime3rb',
              onTap: () => _showEditProfileDialog(context, ref, profile),
            ),
            SettingsTile(
              icon: Icons.password_rounded,
              title: 'تغيير كلمة مرور Anime3rb',
              onTap: () => _showChangePasswordDialog(context, ref),
            ),
            SettingsTile(
              icon: Icons.devices_outlined,
              title: 'إغلاق الجلسات الأخرى في Anime3rb',
              onTap: () => _showLogoutOtherSessionsDialog(context, ref),
            ),
            SettingsTile(
              icon: Icons.bookmarks_outlined,
              title: 'ملفي ومكتبتي على الموقع',
              onTap: () => launchUrl(
                Anime3rbProvider.websiteUri(
                  '/titles/${profile.userSlug}/watching',
                ),
                mode: LaunchMode.externalApplication,
              ),
            ),
            SettingsTile(
              icon: Icons.logout_rounded,
              title: 'تسجيل الخروج من Anime3rb',
              onTap: () async {
                final oldId = service.accountId;
                await service.signOut();
                if (oldId != null) {
                  await ref
                      .read(anime3rbLibraryServiceProvider)
                      .wipeLocalSessionData(oldId);
                }
              },
              isLast: true,
            ),
          ],
        );
      },
    );
  }
}

class _Anime3rbNotificationsDialog extends StatefulWidget {
  const _Anime3rbNotificationsDialog({required this.service});

  final Anime3rbAccountService service;

  @override
  State<_Anime3rbNotificationsDialog> createState() =>
      _Anime3rbNotificationsDialogState();
}

class _Anime3rbNotificationsDialogState
    extends State<_Anime3rbNotificationsDialog> {
  late Future<List<Anime3rbNotificationItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.service.fetchNotifications();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إشعارات Anime3rb'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<List<Anime3rbNotificationItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text('تعذر تحميل الإشعارات: ${snapshot.error}');
            }
            final items = snapshot.data ?? const <Anime3rbNotificationItem>[];
            if (items.isEmpty) {
              return const Text('لا توجد إشعارات حاليًا.');
            }
            return ListView.separated(
              shrinkWrap: true,
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    item.unread
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                  ),
                  title: Text(item.title),
                  onTap: item.url == null
                      ? null
                      : () {
                          final uri = Uri.tryParse(item.url!);
                          if (uri != null) {
                            unawaited(
                              launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              ),
                            );
                          }
                        },
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await widget.service.markNotificationsRead();
            if (mounted) Navigator.of(context).pop();
          },
          child: const Text('تحديد الكل كمقروء'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}
