import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/utils/localized_text.dart';
import '../../../core/utils/layout_constants.dart';
import 'account_ui_helpers.dart';
import 'widgets/settings_widgets.dart';

/// Account privacy is saved as one coherent `users/{id}.settings` update.
/// Content filtering applies to catalog discovery; it never deletes library,
/// history, downloads, or direct links owned by the current user.
class AnimeWitcherPrivacySettingsScreen extends ConsumerStatefulWidget {
  const AnimeWitcherPrivacySettingsScreen({
    super.key,
    required this.initialSettings,
  });

  final AnimeWitcherPrivacySettings initialSettings;

  @override
  ConsumerState<AnimeWitcherPrivacySettingsScreen> createState() =>
      _AnimeWitcherPrivacySettingsScreenState();
}

class _AnimeWitcherPrivacySettingsScreenState
    extends ConsumerState<AnimeWitcherPrivacySettingsScreen> {
  late AnimeWitcherPrivacySettings _settings;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  bool get _hasChanges =>
      _settings.showFavoritesToUsers !=
          widget.initialSettings.showFavoritesToUsers ||
      _settings.showCommentsToUsers !=
          widget.initialSettings.showCommentsToUsers ||
      _settings.showReviewsToUsers !=
          widget.initialSettings.showReviewsToUsers ||
      _settings.hideEcchiAnime != widget.initialSettings.hideEcchiAnime;

  void _update(AnimeWitcherPrivacySettings next) {
    if (_saving) return;
    setState(() => _settings = next);
  }

  Future<void> _save() async {
    if (_saving || !_hasChanges) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .updatePrivacySettings(_settings);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      showAnimeWitcherAccountMessage(
        context,
        localizedAnimeWitcherAccountError(context, error),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
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
              english: 'Privacy and content',
              arabic: 'الخصوصية والمحتوى',
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LayoutConstants.spacingLg,
              LayoutConstants.spacingMd,
              LayoutConstants.spacingLg,
              LayoutConstants.spacingSm,
            ),
            child: Text(
              appText(
                context,
                english:
                    'These choices are saved to your AnimeWitcher profile. Turning a visibility option off keeps that part of your profile private.',
                arabic:
                    'تُحفظ هذه الخيارات في ملف AnimeWitcher. إيقاف خيار الظهور يجعل هذا الجزء من ملفك خاصًا.',
              ),
              textAlign: isArabic ? TextAlign.right : TextAlign.left,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SettingsGroup(
            title: appText(
              context,
              english: 'Profile visibility',
              arabic: 'ظهور الملف الشخصي',
            ),
            children: [
              _PreferenceTile(
                icon: Icons.favorite_outline_rounded,
                title: appText(
                  context,
                  english: 'Show my favorites to users',
                  arabic: 'إظهار مفضلتي للمستخدمين',
                ),
                subtitle: appText(
                  context,
                  english: 'Allow other AnimeWitcher users to view your favorites',
                  arabic: 'السماح لمستخدمي AnimeWitcher بعرض مفضلتك',
                ),
                value: _settings.showFavoritesToUsers,
                enabled: !_saving,
                onChanged: (value) => _update(
                  _settings.copyWith(showFavoritesToUsers: value),
                ),
              ),
              _PreferenceTile(
                icon: Icons.forum_outlined,
                title: appText(
                  context,
                  english: 'Show my comments to users',
                  arabic: 'إظهار تعليقاتي للمستخدمين',
                ),
                subtitle: appText(
                  context,
                  english: 'Let other users view your comments from your profile',
                  arabic: 'السماح للمستخدمين بعرض تعليقاتك من ملفك',
                ),
                value: _settings.showCommentsToUsers,
                enabled: !_saving,
                onChanged: (value) => _update(
                  _settings.copyWith(showCommentsToUsers: value),
                ),
              ),
              _PreferenceTile(
                icon: Icons.rate_review_outlined,
                title: appText(
                  context,
                  english: 'Show my reviews to users',
                  arabic: 'إظهار مراجعاتي للمستخدمين',
                ),
                subtitle: appText(
                  context,
                  english: 'Let other users view your published reviews',
                  arabic: 'السماح للمستخدمين بعرض مراجعاتك المنشورة',
                ),
                value: _settings.showReviewsToUsers,
                enabled: !_saving,
                isLast: true,
                onChanged: (value) => _update(
                  _settings.copyWith(showReviewsToUsers: value),
                ),
              ),
            ],
          ),
          const SizedBox(height: LayoutConstants.spacingLg),
          SettingsGroup(
            title: appText(
              context,
              english: 'Content visibility',
              arabic: 'ظهور المحتوى',
            ),
            children: [
              _PreferenceTile(
                icon: Icons.visibility_off_outlined,
                title: appText(
                  context,
                  english: 'Hide ecchi anime',
                  arabic: 'إخفاء أنميات الإيتشي',
                ),
                subtitle: appText(
                  context,
                  english:
                      'Filters titles tagged Ecchi from catalog results. Your library and history are kept.',
                  arabic:
                      'يخفي الأعمال ذات وسم إيتشي من نتائج الكتالوج، مع الاحتفاظ بمكتبتك وسجلك.',
                ),
                value: _settings.hideEcchiAnime,
                enabled: !_saving,
                isLast: true,
                onChanged: (value) => _update(
                  _settings.copyWith(hideEcchiAnime: value),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(LayoutConstants.spacingLg),
            child: FilledButton.icon(
              onPressed: _saving || !_hasChanges ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(
                appText(context, english: 'Save changes', arabic: 'حفظ التغييرات'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreferenceTile extends StatelessWidget {
  const _PreferenceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.isLast = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final bool isLast;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      isLast: isLast,
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: Switch.adaptive(
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}
