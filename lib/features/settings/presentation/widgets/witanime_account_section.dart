import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/account/witanime_account_models.dart';
import '../../../../core/account/witanime_account_service.dart';
import '../../../../core/extensions/providers/witanime_provider.dart';
import '../../../../core/services/notification_service.dart';
import '../../../more/presentation/witanime_website_screen.dart';
import 'settings_widgets.dart';

class WitanimeAccountSection extends ConsumerWidget {
  const WitanimeAccountSection({super.key, this.returnRoute});

  final String? returnRoute;

  Future<void> _startOfficialAuth(
    BuildContext context,
    WidgetRef ref,
    WitanimeAuthAction action,
  ) async {
    final service = ref.read(witanimeAccountServiceProvider);
    final opened = await service.beginOfficialAuth(
      action,
      returnRoute: returnRoute,
    );
    if (!context.mounted) return;
    if (!opened) {
      ref.read(notificationServiceProvider).showError('تعذر فتح موقع Witanime.');
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
          title: const Text('تأكيد جلسة Witanime'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'بعد إتمام الدخول أو التسجيل في صفحة Witanime الرسمية، أدخل '
                'معرّف الجلسة للتحقق من هوية الحساب وفتح مكتبته.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cookieController,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'جلسة Witanime',
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
                            .read(witanimeAccountServiceProvider)
                            .completeBrowserAuth(
                              sessionCookie: cookieController.text,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        ref
                            .read(notificationServiceProvider)
                            .showSuccess(
                              'تم ربط حساب Witanime: ${result.profile.displayName}',
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
    WitanimeProfile profile,
  ) async {
    final nameController = TextEditingController(text: profile.displayName);
    final emailController = TextEditingController(text: profile.email ?? '');
    final avatarController = TextEditingController(
      text: profile.avatarUrl ?? '',
    );
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('تعديل حساب Witanime'),
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
                const SizedBox(height: 10),
                TextField(
                  controller: avatarController,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'رابط الصورة (اختياري)',
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
                            .read(witanimeAccountServiceProvider)
                            .updateProfile(
                              displayName: nameController.text,
                              email: emailController.text,
                              avatarUrl: avatarController.text,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        ref
                            .read(notificationServiceProvider)
                            .showSuccess('تم تحديث بيانات حساب Witanime.');
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
    avatarController.dispose();
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
          title: const Text('تغيير كلمة مرور Witanime'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: currentController,
                  obscureText: true,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الحالية',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nextController,
                  obscureText: true,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الجديدة',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmController,
                  obscureText: true,
                  enabled: !busy,
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
                            .read(witanimeAccountServiceProvider)
                            .updatePassword(
                              currentPassword: currentController.text,
                              newPassword: nextController.text,
                              confirmPassword: confirmController.text,
                            );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        ref
                            .read(notificationServiceProvider)
                            .showSuccess('تم تحديث كلمة مرور Witanime.');
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(witanimeAccountServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final profile = service.profile;
        if (profile == null) {
          return SettingsGroup(
            title: 'Witanime',
            children: [
              SettingsTile(
                icon: Icons.login_rounded,
                title: 'تسجيل الدخول إلى Witanime',
                subtitle: 'يفتح صفحة الدخول الرسمية ثم يثبّت الجلسة في التطبيق',
                onTap: () => _startOfficialAuth(
                  context,
                  ref,
                  WitanimeAuthAction.signIn,
                ),
              ),
              SettingsTile(
                icon: Icons.person_add_alt_1_rounded,
                title: 'إنشاء حساب Witanime',
                onTap: () => _startOfficialAuth(
                  context,
                  ref,
                  WitanimeAuthAction.register,
                ),
              ),
              SettingsTile(
                icon: Icons.lock_reset_rounded,
                title: 'استعادة كلمة مرور Witanime',
                onTap: () => _startOfficialAuth(
                  context,
                  ref,
                  WitanimeAuthAction.forgotPassword,
                ),
              ),
              SettingsTile(
                icon: Icons.verified_user_outlined,
                title: 'حساب Witanime على الموقع',
                subtitle: 'فتح صفحات الحساب والدعم الرسمية',
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const WitanimeWebsiteScreen(),
                  ),
                ),
                isLast: true,
              ),
            ],
          );
        }

        final counts = profile.counts;
        final countsSummary =
            'أشاهده ${counts.watching} · أكملته ${counts.completed} · '
            'أنوي مشاهدته ${counts.planToWatch} · المفضلة ${counts.favorites}';
        return SettingsGroup(
          title: 'Witanime',
          children: [
            SettingsTile(
              icon: Icons.account_circle_rounded,
              title: profile.displayName,
              subtitle: service.usingInMemorySessionFallback
                  ? '$countsSummary (جلسة مؤقتة بالذاكرة)'
                  : (profile.email?.isNotEmpty == true
                        ? '${profile.email!} · $countsSummary'
                        : countsSummary),
              trailing: const Icon(Icons.refresh_rounded, size: 18),
              onTap: () => service.refreshProfile(),
            ),
            SettingsTile(
              icon: Icons.edit_outlined,
              title: 'تعديل الاسم والبريد والصورة',
              onTap: () => _showEditProfileDialog(context, ref, profile),
            ),
            SettingsTile(
              icon: Icons.password_rounded,
              title: 'تغيير كلمة مرور Witanime',
              onTap: () => _showChangePasswordDialog(context, ref),
            ),
            SettingsTile(
              icon: Icons.bookmarks_outlined,
              title: 'حساب Witanime على الموقع',
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  builder: (_) => const WitanimeWebsiteScreen(),
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.delete_forever_outlined,
              title: 'طلب حذف حساب Witanime',
              subtitle: WitanimeProvider.websiteUri('/privacy').toString(),
              onTap: () => service.openDeleteAccountChannel(),
            ),
            SettingsTile(
              icon: Icons.logout_rounded,
              title: 'تسجيل الخروج من Witanime',
              onTap: () => service.signOut(),
              isLast: true,
            ),
          ],
        );
      },
    );
  }
}
