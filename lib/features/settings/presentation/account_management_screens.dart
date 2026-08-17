import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/localized_text.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import 'account_image_crop_screen.dart';
import 'account_ui_helpers.dart';

class AnimeWitcherProfileEditScreen extends ConsumerStatefulWidget {
  const AnimeWitcherProfileEditScreen({
    super.key,
    required this.profile,
  });

  final AnimeWitcherProfile profile;

  @override
  ConsumerState<AnimeWitcherProfileEditScreen> createState() =>
      _AnimeWitcherProfileEditScreenState();
}

class _AnimeWitcherProfileEditScreenState
    extends ConsumerState<AnimeWitcherProfileEditScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _bioController;
  late final TextEditingController _countryController;
  late final TextEditingController _birthYearController;
  Uint8List? _avatarBytes;
  Uint8List? _coverBytes;
  bool _saving = false;
  bool _preparingImage = false;

  bool get _birthYearLocked =>
      (widget.profile.birthYear?.trim().isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.userName);
    _bioController = TextEditingController(text: widget.profile.bio);
    _countryController = TextEditingController(text: widget.profile.country);
    _birthYearController = TextEditingController(
      text: widget.profile.birthYear,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _countryController.dispose();
    _birthYearController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _preparingImage;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: !appleUsesPersistentLiquidGlassHeader
            ? const AppleLiquidGlassBackButton()
            : null,
        title: ApplePersistentGlassHeaderScope(
          enabled: true,
          onBack: () => Navigator.of(context).maybePop(),
          child: Text(
            appText(
              context,
              english: 'Edit profile',
              arabic: 'تعديل الملف الشخصي',
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              LayoutConstants.spacingLg,
              LayoutConstants.spacingMd,
              LayoutConstants.spacingLg,
              100,
            ),
            children: [
              _buildImages(busy),
              const SizedBox(height: LayoutConstants.spacingLg),
              _field(
                controller: _nameController,
                label: appText(
                  context,
                  english: 'User name',
                  arabic: 'اسم المستخدم',
                ),
                maxLength: 25,
                helperText: appText(
                  context,
                  english: '5–25 characters',
                  arabic: 'من 5 إلى 25 حرفًا',
                ),
                textInputAction: TextInputAction.next,
              ),
              _field(
                controller: _bioController,
                label: appText(
                  context,
                  english: 'Bio',
                  arabic: 'النبذة',
                ),
                maxLength: 200,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
              ),
              _field(
                controller: _countryController,
                label: appText(
                  context,
                  english: 'Country',
                  arabic: 'الدولة',
                ),
                maxLength: 30,
                textInputAction: TextInputAction.next,
              ),
              _field(
                controller: _birthYearController,
                label: appText(
                  context,
                  english: 'Birth year',
                  arabic: 'سنة الميلاد',
                ),
                keyboardType: TextInputType.number,
                readOnly: _birthYearLocked,
                helperText: _birthYearLocked
                    ? appText(
                        context,
                        english: 'AnimeWitcher allows this to be set once.',
                        arabic: 'يسمح AnimeWitcher بحفظها مرة واحدة فقط.',
                      )
                    : appText(
                        context,
                        english: 'Optional · 1970–2020',
                        arabic: 'اختياري · 1970–2020',
                      ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!busy) _save();
                },
              ),
              const SizedBox(height: LayoutConstants.spacingMd),
              FilledButton.icon(
                onPressed: busy ? null : _save,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded),
                label: Text(
                  appText(
                    context,
                    english: 'Save changes',
                    arabic: 'حفظ التغييرات',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImages(bool busy) {
    final colors = Theme.of(context).colorScheme;
    final coverUrl = widget.profile.coverUrl?.trim() ?? '';
    final avatarUrl = widget.profile.photoUrl?.trim() ?? '';
    final ImageProvider<Object>? avatarImage = _avatarBytes != null
        ? MemoryImage(_avatarBytes!)
        : avatarUrl.isEmpty
        ? null
        : NetworkImage(avatarUrl);

    Widget cover;
    if (_coverBytes != null) {
      cover = Image.memory(
        _coverBytes!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      );
    } else if (coverUrl.isNotEmpty) {
      cover = Image.network(
        coverUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => _coverPlaceholder(colors),
      );
    } else {
      cover = _coverPlaceholder(colors);
    }

    return SizedBox(
      height: 250,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            bottom: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover,
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.34),
                        ],
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    end: 10,
                    bottom: 10,
                    child: FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () => _pickImage(
                              AnimeWitcherProfileImageKind.cover,
                            ),
                      icon: const Icon(Icons.photo_camera_back_rounded),
                      label: Text(
                        appText(
                          context,
                          english: 'Change cover',
                          arabic: 'تغيير الغلاف',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          PositionedDirectional(
            start: 22,
            bottom: 0,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 58,
                  backgroundColor: colors.primaryContainer,
                  foregroundImage: avatarImage,
                  onForegroundImageError: avatarImage == null
                      ? null
                      : (_, _) {},
                  child: Icon(
                    Icons.person_rounded,
                    size: 54,
                    color: colors.onPrimaryContainer,
                  ),
                ),
                PositionedDirectional(
                  end: -4,
                  bottom: 2,
                  child: IconButton.filled(
                    tooltip: appText(
                      context,
                      english: 'Change account picture',
                      arabic: 'تغيير صورة الحساب',
                    ),
                    onPressed: busy
                        ? null
                        : () => _pickImage(
                            AnimeWitcherProfileImageKind.avatar,
                          ),
                    icon: const Icon(Icons.photo_camera_rounded),
                  ),
                ),
              ],
            ),
          ),
          if (_preparingImage)
            const PositionedDirectional(
              end: 18,
              bottom: 10,
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme colors) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primaryContainer, colors.secondaryContainer],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.landscape_rounded,
          size: 54,
          color: colors.onPrimaryContainer.withValues(alpha: 0.72),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    int? maxLength,
    int maxLines = 1,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    String? helperText,
    bool readOnly = false,
    ValueChanged<String>? onSubmitted,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
      child: TextField(
        controller: controller,
        maxLength: maxLength,
        maxLines: maxLines,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        readOnly: readOnly,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          border: const OutlineInputBorder(),
          prefixIcon: readOnly ? const Icon(Icons.lock_outline_rounded) : null,
        ),
      ),
    );
  }

  Future<void> _pickImage(AnimeWitcherProfileImageKind kind) async {
    setState(() => _preparingImage = true);
    try {
      final selection = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (selection == null) return;
      final raw = selection.files.single.bytes;
      if (raw == null || raw.isEmpty) {
        throw const AnimeWitcherAccountException(
          'invalid-image',
          'The selected image could not be read.',
        );
      }
      if (raw.length > 20 * 1024 * 1024) {
        throw const AnimeWitcherAccountException(
          'image-too-large',
          'Choose an image smaller than 20 MB.',
        );
      }
      if (!mounted) return;
      final prepared = await showAnimeWitcherAccountImageCropper(
        context,
        bytes: raw,
        kind: kind,
      );
      if (prepared == null) return;
      if (!mounted) return;
      setState(() {
        if (kind == AnimeWitcherProfileImageKind.avatar) {
          _avatarBytes = prepared;
        } else {
          _coverBytes = prepared;
        }
      });
    } on AnimeWitcherAccountException catch (error) {
      if (mounted) {
        showAnimeWitcherAccountMessage(
          context,
          localizedAnimeWitcherAccountError(context, error),
          isError: true,
        );
      }
    } catch (_) {
      if (mounted) {
        showAnimeWitcherAccountMessage(
          context,
          appText(
            context,
            english: 'Choose a valid JPG, PNG, or WebP image.',
            arabic: 'اختر صورة JPG أو PNG أو WebP صالحة.',
          ),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _preparingImage = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .updateProfile(
            userName: _nameController.text,
            bio: _bioController.text,
            country: _countryController.text,
            birthYear: _birthYearController.text,
            avatarBytes: _avatarBytes,
            coverBytes: _coverBytes,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        showAnimeWitcherAccountMessage(
          context,
          localizedAnimeWitcherAccountError(context, error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class AnimeWitcherChangeEmailScreen extends ConsumerStatefulWidget {
  const AnimeWitcherChangeEmailScreen({
    super.key,
    required this.profile,
  });

  final AnimeWitcherProfile profile;

  @override
  ConsumerState<AnimeWitcherChangeEmailScreen> createState() =>
      _AnimeWitcherChangeEmailScreenState();
}

class _AnimeWitcherChangeEmailScreenState
    extends ConsumerState<AnimeWitcherChangeEmailScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;

  bool get _usesPassword =>
      widget.profile.hasPasswordProvider ||
      (widget.profile.providerIds.isEmpty &&
          widget.profile.signInMethod == AnimeWitcherSignInMethod.email);

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AccountFormScaffold(
      title: appText(
        context,
        english: 'Change email',
        arabic: 'تغيير البريد الإلكتروني',
      ),
      children: [
        _AccountInfoCard(
          icon: Icons.mark_email_read_rounded,
          text: appText(
            context,
            english: _usesPassword
                ? 'Enter your current password. We will send a verification link to the new address, then sign you out.'
                : 'Confirm with the same Google account. We will send a verification link to the new address, then sign you out.',
            arabic: _usesPassword
                ? 'أدخل كلمة المرور الحالية. سنرسل رابط تحقق إلى البريد الجديد ثم نسجل خروجك.'
                : 'أكد هويتك بحساب Google نفسه. سنرسل رابط تحقق إلى البريد الجديد ثم نسجل خروجك.',
          ),
        ),
        const SizedBox(height: LayoutConstants.spacingLg),
        TextField(
          controller: _emailController,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          textInputAction: _usesPassword
              ? TextInputAction.next
              : TextInputAction.done,
          autofillHints: const [AutofillHints.newUsername],
          onSubmitted: (_) {
            if (!_usesPassword && !_submitting) _submit();
          },
          decoration: InputDecoration(
            labelText: appText(
              context,
              english: 'New email address',
              arabic: 'البريد الإلكتروني الجديد',
            ),
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            border: const OutlineInputBorder(),
          ),
        ),
        if (_usesPassword) ...[
          const SizedBox(height: LayoutConstants.spacingMd),
          TextField(
            controller: _passwordController,
            obscureText: true,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) {
              if (!_submitting) _submit();
            },
            decoration: InputDecoration(
              labelText: appText(
                context,
                english: 'Current password',
                arabic: 'كلمة المرور الحالية',
              ),
              prefixIcon: const Icon(Icons.password_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: LayoutConstants.spacingLg),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _usesPassword
                      ? Icons.send_rounded
                      : Icons.account_circle_rounded,
                ),
          label: Text(
            appText(
              context,
              english: _usesPassword
                  ? 'Send verification link'
                  : 'Confirm with Google',
              arabic: _usesPassword
                  ? 'إرسال رابط التحقق'
                  : 'التأكيد باستخدام Google',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .requestEmailChange(
            newEmail: _emailController.text,
            currentPassword: _passwordController.text,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        showAnimeWitcherAccountMessage(
          context,
          localizedAnimeWitcherAccountError(context, error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class AnimeWitcherChangePasswordScreen extends ConsumerStatefulWidget {
  const AnimeWitcherChangePasswordScreen({
    super.key,
    required this.profile,
  });

  final AnimeWitcherProfile profile;

  @override
  ConsumerState<AnimeWitcherChangePasswordScreen> createState() =>
      _AnimeWitcherChangePasswordScreenState();
}

class _AnimeWitcherChangePasswordScreenState
    extends ConsumerState<AnimeWitcherChangePasswordScreen> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _submitting = false;

  bool get _usesPassword =>
      widget.profile.hasPasswordProvider ||
      (widget.profile.providerIds.isEmpty &&
          widget.profile.signInMethod == AnimeWitcherSignInMethod.email);

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final addingPassword = !_usesPassword;
    return _AccountFormScaffold(
      title: appText(
        context,
        english: addingPassword ? 'Add password' : 'Change password',
        arabic: addingPassword ? 'إضافة كلمة مرور' : 'تغيير كلمة المرور',
      ),
      children: [
        _AccountInfoCard(
          icon: Icons.lock_reset_rounded,
          text: appText(
            context,
            english: addingPassword
                ? 'Confirm with the same Google account, then add a password so you can also sign in with email.'
                : 'Confirm your current password before choosing a new one.',
            arabic: addingPassword
                ? 'أكد هويتك بحساب Google نفسه، ثم أضف كلمة مرور لتتمكن من الدخول بالبريد أيضًا.'
                : 'أكد كلمة المرور الحالية قبل اختيار كلمة مرور جديدة.',
          ),
        ),
        const SizedBox(height: LayoutConstants.spacingLg),
        if (_usesPassword) ...[
          _passwordField(
            controller: _currentController,
            label: appText(
              context,
              english: 'Current password',
              arabic: 'كلمة المرور الحالية',
            ),
            action: TextInputAction.next,
          ),
          const SizedBox(height: LayoutConstants.spacingMd),
        ],
        _passwordField(
          controller: _newController,
          label: appText(
            context,
            english: 'New password',
            arabic: 'كلمة المرور الجديدة',
          ),
          action: TextInputAction.next,
        ),
        const SizedBox(height: LayoutConstants.spacingMd),
        _passwordField(
          controller: _confirmController,
          label: appText(
            context,
            english: 'Confirm new password',
            arabic: 'تأكيد كلمة المرور الجديدة',
          ),
          action: TextInputAction.done,
          onSubmitted: (_) {
            if (!_submitting) _submit();
          },
        ),
        const SizedBox(height: LayoutConstants.spacingSm),
        Text(
          appText(
            context,
            english: 'Use at least 6 characters.',
            arabic: 'استخدم 6 أحرف على الأقل.',
          ),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: LayoutConstants.spacingLg),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.password_rounded),
          label: Text(
            appText(
              context,
              english: addingPassword ? 'Add password' : 'Change password',
              arabic: addingPassword
                  ? 'إضافة كلمة المرور'
                  : 'تغيير كلمة المرور',
            ),
          ),
        ),
      ],
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required TextInputAction action,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: true,
      textInputAction: action,
      autofillHints: const [AutofillHints.password],
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.password_rounded),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Future<void> _submit() async {
    if (_newController.text.length < 6) {
      showAnimeWitcherAccountMessage(
        context,
        appText(
          context,
          english: 'The password must contain at least six characters.',
          arabic: 'يجب أن تحتوي كلمة المرور على 6 أحرف على الأقل.',
        ),
        isError: true,
      );
      return;
    }
    if (_newController.text != _confirmController.text) {
      showAnimeWitcherAccountMessage(
        context,
        appText(
          context,
          english: 'The two passwords do not match.',
          arabic: 'كلمتا المرور غير متطابقتين.',
        ),
        isError: true,
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .changePassword(
            currentPassword: _currentController.text,
            newPassword: _newController.text,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        showAnimeWitcherAccountMessage(
          context,
          localizedAnimeWitcherAccountError(context, error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _AccountFormScaffold extends StatelessWidget {
  const _AccountFormScaffold({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: !appleUsesPersistentLiquidGlassHeader
            ? const AppleLiquidGlassBackButton()
            : null,
        title: ApplePersistentGlassHeaderScope(
          enabled: true,
          onBack: () => Navigator.of(context).maybePop(),
          child: Text(title),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              LayoutConstants.spacingLg,
              LayoutConstants.spacingLg,
              LayoutConstants.spacingLg,
              100,
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

class _AccountInfoCard extends StatelessWidget {
  const _AccountInfoCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(LayoutConstants.spacingMd),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colors.onPrimaryContainer),
          const SizedBox(width: LayoutConstants.spacingMd),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: colors.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
