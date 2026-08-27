import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_config.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/localized_text.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../shared/widgets/custom_widgets.dart';
import '../../comments/presentation/animewitcher_my_comments_screen.dart';
import 'account_management_screens.dart';
import 'account_privacy_settings_screen.dart';
import 'account_ui_helpers.dart';
import 'widgets/settings_widgets.dart';

enum _AccountFormMode { signIn, createAccount }

class AnimeWitcherAccountScreen extends ConsumerStatefulWidget {
  const AnimeWitcherAccountScreen({super.key});

  @override
  ConsumerState<AnimeWitcherAccountScreen> createState() =>
      _AnimeWitcherAccountScreenState();
}

class _AnimeWitcherAccountScreenState
    extends ConsumerState<AnimeWitcherAccountScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  _AccountFormMode _mode = _AccountFormMode.signIn;
  bool _submitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(animeWitcherAccountControllerProvider);
    final snapshot = account.asData?.value;
    final profile = snapshot?.profile;
    final configured = AnimeWitcherAccountConfig.firebaseConfigured;
    final busy = _submitting || account.isLoading || !configured;
    final asyncError = account.when<Object?>(
      data: (_) => null,
      error: (error, _) => error,
      loading: () => null,
    );

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
          child: Text(
            appText(
              context,
              english: 'AnimeWitcher account',
              arabic: 'حساب AnimeWitcher',
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 100),
            children: [
              const SizedBox(height: LayoutConstants.spacingMd),
              if (profile != null)
                _buildSignedIn(profile, busy)
              else
                _buildSignedOut(busy, asyncError),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSignedOut(bool busy, Object? asyncError) {
    final colors = Theme.of(context).colorScheme;
    final isCreate = _mode == _AccountFormMode.createAccount;
    return Column(
      children: [
        if (!AnimeWitcherAccountConfig.firebaseConfigured)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LayoutConstants.spacingLg,
              LayoutConstants.spacingMd,
              LayoutConstants.spacingLg,
              0,
            ),
            child: _ErrorBanner(
              message: appText(
                context,
                english:
                    'Account sync is not configured in this build. Add the AnimeWitcher Firebase values through build secrets.',
                arabic:
                    'مزامنة الحساب غير مهيأة في هذه النسخة. أضف إعدادات Firebase الخاصة بـ AnimeWitcher من أسرار البناء.',
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LayoutConstants.spacingLg,
            vertical: LayoutConstants.spacingMd,
          ),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.13),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_sync_rounded,
                  size: 36,
                  color: colors.primary,
                ),
              ),
              const SizedBox(height: LayoutConstants.spacingMd),
              Text(
                appText(
                  context,
                  english: 'Keep your anime progress with you',
                  arabic: 'خلي تقدمك وقوائمك معك دائمًا',
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: LayoutConstants.spacingSm),
              Text(
                appText(
                  context,
                  english:
                      'Sync watched episodes, resume positions, and all AnimeWitcher lists across devices.',
                  arabic:
                      'زامن الحلقات المشاهدة ومكان إكمال الحلقة وكل قوائم AnimeWitcher بين أجهزتك.',
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        SettingsGroup(
          title: appText(
            context,
            english: isCreate ? 'Create a new account' : 'Sign in',
            arabic: isCreate ? 'إنشاء حساب جديد' : 'تسجيل الدخول',
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(LayoutConstants.spacingMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<_AccountFormMode>(
                    segments: [
                      ButtonSegment<_AccountFormMode>(
                        value: _AccountFormMode.signIn,
                        icon: const Icon(Icons.login_rounded),
                        label: Text(
                          appText(
                            context,
                            english: 'Sign in',
                            arabic: 'دخول',
                          ),
                        ),
                      ),
                      ButtonSegment<_AccountFormMode>(
                        value: _AccountFormMode.createAccount,
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: Text(
                          appText(
                            context,
                            english: 'New account',
                            arabic: 'حساب جديد',
                          ),
                        ),
                      ),
                    ],
                    selected: <_AccountFormMode>{_mode},
                    onSelectionChanged: busy
                        ? null
                        : (selection) {
                            setState(() => _mode = selection.first);
                          },
                  ),
                  const SizedBox(height: LayoutConstants.spacingLg),
                  if (isCreate) ...[
                    CustomTextField(
                      controller: _nameController,
                      hintText: appText(
                        context,
                        english: 'User name',
                        arabic: 'اسم المستخدم',
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: LayoutConstants.spacingMd),
                  ],
                  CustomTextField(
                    controller: _emailController,
                    hintText: appText(
                      context,
                      english: 'Email address',
                      arabic: 'البريد الإلكتروني',
                    ),
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: LayoutConstants.spacingMd),
                  CustomTextField(
                    controller: _passwordController,
                    hintText: appText(
                      context,
                      english: 'Password',
                      arabic: 'كلمة المرور',
                    ),
                    obscureText: true,
                    textInputAction: isCreate
                        ? TextInputAction.next
                        : TextInputAction.done,
                    onSubmitted: (_) {
                      if (!isCreate && !busy) _submitEmail();
                    },
                  ),
                  if (isCreate) ...[
                    const SizedBox(height: LayoutConstants.spacingMd),
                    CustomTextField(
                      controller: _confirmController,
                      hintText: appText(
                        context,
                        english: 'Confirm password',
                        arabic: 'تأكيد كلمة المرور',
                      ),
                      obscureText: true,
                      onSubmitted: (_) {
                        if (!busy) _submitEmail();
                      },
                    ),
                  ],
                  if (asyncError != null) ...[
                    const SizedBox(height: LayoutConstants.spacingMd),
                    _ErrorBanner(message: _localizedError(asyncError)),
                  ],
                  const SizedBox(height: LayoutConstants.spacingLg),
                  FilledButton.icon(
                    onPressed: busy ? null : _submitEmail,
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isCreate
                                ? Icons.person_add_alt_1_rounded
                                : Icons.login_rounded,
                          ),
                    label: Text(
                      appText(
                        context,
                        english: isCreate ? 'Create account' : 'Sign in',
                        arabic: isCreate ? 'إنشاء الحساب' : 'تسجيل الدخول',
                      ),
                    ),
                  ),
                  if (!isCreate)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(
                        onPressed: busy ? null : _showPasswordResetDialog,
                        child: Text(
                          appText(
                            context,
                            english: 'Forgot password?',
                            arabic: 'نسيت كلمة المرور؟',
                          ),
                        ),
                      ),
                    ),
                  if (!isCreate) ...[
                    const SizedBox(height: LayoutConstants.spacingSm),
                    Row(
                      children: [
                        Expanded(child: Divider(color: colors.outlineVariant)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            appText(
                              context,
                              english: 'or',
                              arabic: 'أو',
                            ),
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ),
                        Expanded(child: Divider(color: colors.outlineVariant)),
                      ],
                    ),
                    const SizedBox(height: LayoutConstants.spacingMd),
                    OutlinedButton.icon(
                      onPressed:
                          busy || !AnimeWitcherAccountConfig.googleConfigured
                          ? null
                          : _submitGoogle,
                      icon: Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: colors.outline),
                        ),
                        child: const Text(
                          'G',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      label: Text(
                        appText(
                          context,
                          english: 'Continue with Google',
                          arabic: 'المتابعة باستخدام Google',
                        ),
                      ),
                    ),
                    if (!AnimeWitcherAccountConfig.googleConfigured) ...[
                      const SizedBox(height: LayoutConstants.spacingSm),
                      Text(
                        appText(
                          context,
                          english:
                              'Google sign-in needs the iOS OAuth client in this build. Email sign-in is ready.',
                          arabic:
                              'دخول Google يحتاج إعداد OAuth الخاص بـ iOS في نسخة البناء. الدخول بالبريد جاهز.',
                        ),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSignedIn(
    AnimeWitcherProfile profile,
    bool busy,
  ) {
    final colors = Theme.of(context).colorScheme;
    final photoUrl = profile.photoUrl?.trim() ?? '';
    final coverUrl = profile.coverUrl?.trim() ?? '';
    final bio = profile.bio?.trim() ?? '';
    final country = profile.country?.trim() ?? '';
    final birthYear = profile.birthYear?.trim() ?? '';
    final hasPassword =
        profile.hasPasswordProvider ||
        (profile.providerIds.isEmpty &&
            profile.signInMethod == AnimeWitcherSignInMethod.email);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LayoutConstants.spacingLg,
            LayoutConstants.spacingMd,
            LayoutConstants.spacingLg,
            LayoutConstants.spacingLg,
          ),
          child: Column(
            children: [
              SizedBox(
                height: 214,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      bottom: 46,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: coverUrl.isEmpty
                            ? DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      colors.primaryContainer,
                                      colors.secondaryContainer,
                                    ],
                                  ),
                                ),
                                child: Icon(
                                  Icons.landscape_rounded,
                                  size: 56,
                                  color: colors.onPrimaryContainer.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              )
                            : Image.network(
                                coverUrl,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                errorBuilder: (_, _, _) => DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                  ),
                                  child: Icon(
                                    Icons.landscape_rounded,
                                    size: 56,
                                    color: colors.onPrimaryContainer,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Center(
                        child: CircleAvatar(
                          radius: 55,
                          backgroundColor: colors.primaryContainer,
                          foregroundImage: photoUrl.isEmpty
                              ? null
                              : NetworkImage(photoUrl),
                          onForegroundImageError: photoUrl.isEmpty
                              ? null
                              : (_, _) {},
                          child: Icon(
                            Icons.person_rounded,
                            size: 52,
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: LayoutConstants.spacingSm),
              Text(
                profile.userName ?? profile.email ?? 'AnimeWitcher',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (profile.email != null) ...[
                const SizedBox(height: 4),
                Text(
                  profile.email!,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
              if (bio.isNotEmpty) ...[
                const SizedBox(height: LayoutConstants.spacingSm),
                Text(
                  bio,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              if (country.isNotEmpty || birthYear.isNotEmpty) ...[
                const SizedBox(height: LayoutConstants.spacingMd),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: LayoutConstants.spacingSm,
                  runSpacing: LayoutConstants.spacingSm,
                  children: [
                    if (country.isNotEmpty)
                      Chip(
                        avatar: const Icon(Icons.public_rounded, size: 18),
                        label: Text(country),
                      ),
                    if (birthYear.isNotEmpty)
                      Chip(
                        avatar: const Icon(Icons.cake_rounded, size: 18),
                        label: Text(birthYear),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        SettingsGroup(
          title: appText(
            context,
            english: 'Manage account',
            arabic: 'إدارة الحساب',
          ),
          children: [
            SettingsTile(
              icon: Icons.manage_accounts_rounded,
              title: appText(
                context,
                english: 'Edit profile',
                arabic: 'تعديل الملف الشخصي',
              ),
              subtitle: appText(
                context,
                english: 'Picture, cover, name, bio, country, and birth year',
                arabic: 'الصورة والغلاف والاسم والنبذة والدولة وسنة الميلاد',
              ),
              onTap: busy ? null : () => _openProfileEditor(profile),
            ),
            SettingsTile(
              icon: Icons.privacy_tip_outlined,
              title: appText(
                context,
                english: 'Privacy and content',
                arabic: 'الخصوصية والمحتوى',
              ),
              subtitle: appText(
                context,
                english: 'Profile visibility and ecchi content filtering',
                arabic: 'ظهور الملف الشخصي وفلترة محتوى الإيتشي',
              ),
              onTap: busy ? null : () => _openPrivacySettings(profile),
            ),
            SettingsTile(
              icon: Icons.forum_rounded,
              title: appText(
                context,
                english: 'My comments',
                arabic: 'تعليقاتي',
              ),
              subtitle: appText(
                context,
                english: 'Edit, delete, or disable replies',
                arabic: 'تعديل التعليقات أو حذفها أو منع الردود',
              ),
              onTap: busy ? null : _openMyComments,
            ),
            SettingsTile(
              icon: Icons.alternate_email_rounded,
              title: appText(
                context,
                english: 'Change email',
                arabic: 'تغيير البريد الإلكتروني',
              ),
              subtitle: appText(
                context,
                english: 'The new address must be verified',
                arabic: 'يجب التحقق من البريد الجديد',
              ),
              onTap: busy ? null : () => _openEmailEditor(profile),
            ),
            SettingsTile(
              icon: Icons.password_rounded,
              title: appText(
                context,
                english: hasPassword ? 'Change password' : 'Add password',
                arabic: hasPassword
                    ? 'تغيير كلمة المرور'
                    : 'إضافة كلمة مرور',
              ),
              subtitle: appText(
                context,
                english: hasPassword
                    ? 'Confirm your current password first'
                    : 'Also sign in with email after Google verification',
                arabic: hasPassword
                    ? 'أكد كلمة المرور الحالية أولًا'
                    : 'استخدم الدخول بالبريد بعد تأكيد Google',
              ),
              onTap: busy ? null : () => _openPasswordEditor(profile),
            ),
            SettingsTile(
              icon: Icons.logout_rounded,
              title: appText(
                context,
                english: 'Sign out',
                arabic: 'تسجيل الخروج',
              ),
              subtitle: appText(
                context,
                english: 'Local data will stay on this device',
                arabic: 'ستبقى البيانات المحلية محفوظة على هذا الجهاز',
              ),
              isLast: true,
              onTap: busy ? null : _signOut,
            ),
          ],
        ),
        const SizedBox(height: LayoutConstants.spacingLg),
        SettingsGroup(
          title: appText(
            context,
            english: 'Danger zone',
            arabic: 'منطقة حساسة',
          ),
          children: [
            SettingsTile(
              icon: Icons.delete_forever_rounded,
              title: appText(
                context,
                english: 'Delete account',
                arabic: 'حذف الحساب',
              ),
              subtitle: appText(
                context,
                english: 'Request permanent deletion from AnimeWitcher',
                arabic: 'طلب حذف الحساب نهائيًا من AnimeWitcher',
              ),
              isLast: true,
              onTap: busy ? null : () => _deleteAccount(profile),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openProfileEditor(AnimeWitcherProfile profile) async {
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AnimeWitcherProfileEditScreen(profile: profile),
      ),
    );
    if (updated == true && mounted) {
      _showMessage(
        appText(
          context,
          english: 'Your account profile was updated.',
          arabic: 'تم تحديث الملف الشخصي للحساب.',
        ),
      );
    }
  }

  Future<void> _openMyComments() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const AnimeWitcherMyCommentsScreen(),
      ),
    );
  }

  Future<void> _openPrivacySettings(AnimeWitcherProfile profile) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AnimeWitcherPrivacySettingsScreen(
          initialSettings: profile.privacySettings,
        ),
      ),
    );
    if (saved == true && mounted) {
      _showMessage(
        appText(
          context,
          english: 'Privacy and content preferences were updated.',
          arabic: 'تم تحديث تفضيلات الخصوصية والمحتوى.',
        ),
      );
    }
  }

  Future<void> _openEmailEditor(AnimeWitcherProfile profile) async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AnimeWitcherChangeEmailScreen(profile: profile),
      ),
    );
    if (sent == true && mounted) {
      _showMessage(
        appText(
          context,
          english:
              'Verification link sent to the new email. Confirm it, then sign in again.',
          arabic:
              'أُرسل رابط التحقق إلى البريد الجديد. أكده ثم سجل الدخول مرة ثانية.',
        ),
      );
    }
  }

  Future<void> _openPasswordEditor(AnimeWitcherProfile profile) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AnimeWitcherChangePasswordScreen(profile: profile),
      ),
    );
    if (changed == true && mounted) {
      _showMessage(
        appText(
          context,
          english: profile.hasPasswordProvider
              ? 'Your password was changed.'
              : 'A password was added to your account.',
          arabic: profile.hasPasswordProvider
              ? 'تم تغيير كلمة المرور.'
              : 'تمت إضافة كلمة مرور إلى حسابك.',
        ),
      );
    }
  }

  Future<void> _deleteAccount(AnimeWitcherProfile profile) async {
    final displayName = profile.userName ?? profile.email ?? 'AnimeWitcher';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          color: Theme.of(dialogContext).colorScheme.error,
        ),
        title: Text(
          appText(
            dialogContext,
            english: 'Delete $displayName?',
            arabic: 'حذف حساب $displayName؟',
          ),
        ),
        content: Text(
          appText(
            dialogContext,
            english:
                'AnimeWitcher will receive a permanent deletion request. You will be signed out immediately.',
            arabic:
                'سيتلقى AnimeWitcher طلب حذف نهائي للحساب، وسيتم تسجيل خروجك فورًا.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              appText(dialogContext, english: 'Cancel', arabic: 'إلغاء'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              appText(
                dialogContext,
                english: 'Delete account',
                arabic: 'حذف الحساب',
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _submitting = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .deleteAccount();
      if (mounted) {
        _showMessage(
          appText(
            context,
            english: 'The account deletion request was sent.',
            arabic: 'تم إرسال طلب حذف الحساب.',
          ),
        );
      }
    } catch (error) {
      if (mounted) _showMessage(_localizedError(error), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final isCreate = _mode == _AccountFormMode.createAccount;
    if (email.isEmpty || password.isEmpty) {
      _showMessage(
        appText(
          context,
          english: 'Enter your email address and password.',
          arabic: 'أدخل البريد الإلكتروني وكلمة المرور.',
        ),
        isError: true,
      );
      return;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      _showMessage(
        appText(
          context,
          english: 'Enter a valid email address.',
          arabic: 'أدخل بريدًا إلكترونيًا صحيحًا.',
        ),
        isError: true,
      );
      return;
    }
    if (isCreate) {
      final userName = _nameController.text.trim();
      if (userName.length < 5 || userName.length > 25) {
        _showMessage(
          appText(
            context,
            english: 'The user name must contain 5 to 25 characters.',
            arabic: 'يجب أن يتكون اسم المستخدم من 5 إلى 25 حرفًا.',
          ),
          isError: true,
        );
        return;
      }
      if (!AnimeWitcherAccountConfig.isTrustedRegistrationEmail(email)) {
        _showMessage(
          appText(
            context,
            english: 'Use a Gmail, Outlook, or Yahoo email address.',
            arabic: 'استخدم بريد Gmail أو Outlook أو Yahoo.',
          ),
          isError: true,
        );
        return;
      }
      if (password.length < 6) {
        _showMessage(
          appText(
            context,
            english: 'The password must contain at least six characters.',
            arabic: 'يجب أن تحتوي كلمة المرور على 6 أحرف على الأقل.',
          ),
          isError: true,
        );
        return;
      }
      if (password != _confirmController.text) {
        _showMessage(
          appText(
            context,
            english: 'The two passwords do not match.',
            arabic: 'كلمتا المرور غير متطابقتين.',
          ),
          isError: true,
        );
        return;
      }
    }

    setState(() => _submitting = true);
    try {
      final controller = ref.read(
        animeWitcherAccountControllerProvider.notifier,
      );
      if (isCreate) {
        await controller.createEmailAccount(
          userName: _nameController.text.trim(),
          email: email,
          password: password,
        );
        if (!mounted) return;
        setState(() => _mode = _AccountFormMode.signIn);
        _passwordController.clear();
        _confirmController.clear();
        _showMessage(
          appText(
            context,
            english:
                'Account created. Open the verification link sent to your email, then sign in.',
            arabic:
                'تم إنشاء الحساب. افتح رابط التحقق المرسل إلى بريدك ثم سجل الدخول.',
          ),
        );
      } else {
        await controller.signInWithEmail(email: email, password: password);
      }
    } catch (error) {
      if (!mounted) return;
      _showMessage(_localizedError(error), isError: true);
      if (error is AnimeWitcherAccountException &&
          error.code == 'email-not-verified') {
        _offerVerificationResend(email, password);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitGoogle() async {
    setState(() => _submitting = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .signInWithGoogle();
    } catch (error) {
      if (mounted) _showMessage(_localizedError(error), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          appText(
            dialogContext,
            english: 'Sign out?',
            arabic: 'تسجيل الخروج؟',
          ),
        ),
        content: Text(
          appText(
            dialogContext,
            english:
                'Synced data stays in AnimeWitcher and local data stays on this device.',
            arabic:
                'ستبقى البيانات المزامنة في AnimeWitcher والبيانات المحلية على هذا الجهاز.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              appText(dialogContext, english: 'Cancel', arabic: 'إلغاء'),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              appText(dialogContext, english: 'Sign out', arabic: 'خروج'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _submitting = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .signOut();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showPasswordResetDialog() async {
    final controller = TextEditingController(text: _emailController.text);
    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          appText(
            dialogContext,
            english: 'Reset password',
            arabic: 'استعادة كلمة المرور',
          ),
        ),
        content: CustomTextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          hintText: appText(
            dialogContext,
            english: 'Email address',
            arabic: 'البريد الإلكتروني',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              appText(dialogContext, english: 'Cancel', arabic: 'إلغاء'),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(
              appText(dialogContext, english: 'Send', arabic: 'إرسال'),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (email == null || email.trim().isEmpty || !mounted) return;
    setState(() => _submitting = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .sendPasswordResetEmail(email.trim());
      if (mounted) {
        _showMessage(
          appText(
            context,
            english: 'Password reset email sent.',
            arabic: 'تم إرسال رابط استعادة كلمة المرور.',
          ),
        );
      }
    } catch (error) {
      if (mounted) _showMessage(_localizedError(error), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _offerVerificationResend(String email, String password) {
    ref.read(notificationServiceProvider).showToast(
      message: appText(
        context,
        english: 'Verify your email before signing in.',
        arabic: 'تحقق من بريدك الإلكتروني قبل تسجيل الدخول.',
      ),
      type: ToastType.info,
      actionLabel: appText(
        context,
        english: 'Resend',
        arabic: 'إعادة الإرسال',
      ),
      onAction: () async {
        try {
          await ref
              .read(animeWitcherAccountControllerProvider.notifier)
              .resendEmailVerification(email: email, password: password);
          if (mounted) {
            _showMessage(
              appText(
                context,
                english: 'Verification email sent again.',
                arabic: 'تم إرسال رسالة التحقق مرة ثانية.',
              ),
            );
          }
        } catch (error) {
          if (mounted) {
            _showMessage(_localizedError(error), isError: true);
          }
        }
      },
    );
  }

  String _localizedError(Object error) {
    return localizedAnimeWitcherAccountError(context, error);
  }

  void _showMessage(String message, {bool isError = false}) {
    showAnimeWitcherAccountMessage(context, message, isError: isError);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
