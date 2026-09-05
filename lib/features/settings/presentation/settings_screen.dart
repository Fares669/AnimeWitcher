import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../core/providers/anime_data_source_settings_provider.dart';
import '../../../core/theme/theme_provider.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/taskbar_customization_dialog.dart';
import 'player_settings_provider.dart';
import 'general_settings_provider.dart';
import 'app_version_provider.dart';

import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'cache_provider.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;
    final canPop = Navigator.of(context).canPop();
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final showFlutterBack = !appleUsesPersistentLiquidGlassHeader && canPop;

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            // Inline header matching other widescreen screens
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                height: LayoutConstants.dashboardHeaderHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.dashboardContentPadding,
                ),
                alignment: Alignment.centerLeft,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Row(
                    children: [
                      if (canPop) ...[
                        AppleLiquidGlassBackButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        AppLocalizations.of(context)!.settings,
                        textDirection: isRtl
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: _buildSettingsList(context, ref, isTv)),
          ],
        ),
      );
    }

    // Mobile layout
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: showFlutterBack && !isRtl
            ? const AppleLiquidGlassBackButton()
            : null,
        title: ApplePersistentGlassHeaderScope(
          enabled: canPop,
          onBack: () => Navigator.of(context).maybePop(),
          child: Text(l10n.settings),
        ),
        actions: showFlutterBack && isRtl
            ? const <Widget>[
                Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: AppleLiquidGlassBackButton(),
                ),
              ]
            : const <Widget>[],
      ),
      body: _buildSettingsList(context, ref, isTv),
    );
  }

  Widget _buildSettingsList(BuildContext context, WidgetRef ref, bool isTv) {
    final versionAsync = ref.watch(appVersionProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    final generalSettings = ref.watch(generalSettingsProvider);
    final animeDataSettings = ref.watch(animeDataSourceSettingsProvider);

    final playerSettings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();

    final l10n = AppLocalizations.of(context)!;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    return Center(
      child: ConstrainedBox(
        // Settings rows are single-column text; letting them stretch across a
        // 3440px ultrawide would put the label and its trailing control on
        // opposite ends of the desk. Clamp to the shared reading measure.
        constraints: const BoxConstraints(
          maxWidth: LayoutConstants.contentMaxWidth,
        ),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            const SizedBox(height: LayoutConstants.spacingXs),
            SettingsGroup(
              title: l10n.general,
              children: [
                SettingsTile(
                  icon: Icons.dark_mode_rounded,
                  title: l10n.appTheme,
                  subtitle: themeMode == ThemeMode.system
                      ? l10n.system
                      : (themeMode == ThemeMode.dark ? l10n.dark : l10n.light),
                  onTap: () => showThemeDialog(context, ref, themeMode),
                ),
                SettingsTile(
                  icon: Icons.home_rounded,
                  title: l10n.defaultHomeScreen,
                  subtitle: getHomeScreenLabel(
                    generalSettings.defaultHomeScreen,
                    l10n,
                  ),
                  onTap: () => showDefaultHomeScreenDialog(
                    context,
                    ref,
                    generalSettings.defaultHomeScreen,
                  ),
                ),
                SettingsTile(
                  icon: Icons.dashboard_customize_rounded,
                  title: isArabic ? 'تخصيص شريط المهام' : 'Customize taskbar',
                  subtitle: isArabic
                      ? 'ترتيب العناصر وإخفاؤها أو إظهارها'
                      : 'Reorder, hide, or show taskbar items',
                  onTap: () => showTaskbarCustomizationDialog(
                    context,
                    ref,
                    generalSettings.taskbarOrder,
                    generalSettings.hiddenTaskbarItems,
                  ),
                  isLast: true,
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),
            SettingsGroup(
              title: l10n.player,
              children: [
                SettingsTile(
                  icon: Icons.smart_display_rounded,
                  title: l10n.defaultPlayer,
                  subtitle: getPlayerDisplayName(
                    playerSettings.preferredPlayer,
                    l10n,
                  ),
                  onTap: () => showDefaultPlayerDialog(
                    context,
                    ref,
                    playerSettings.preferredPlayer,
                  ),
                ),
                SettingsTile(
                  icon: Icons.av_timer_rounded,
                  title: l10n.seekDuration,
                  subtitle: formatSeekDuration(
                    playerSettings.seekDuration,
                    l10n,
                  ),
                  onTap: () => showDurationDialog(
                    context,
                    ref,
                    playerSettings.seekDuration,
                  ),
                ),
                SettingsTile(
                  icon: Icons.timer_outlined,
                  title: l10n.bufferDepth,
                  subtitle: formatReadahead(
                    playerSettings.readaheadSeconds,
                    l10n,
                  ),
                  onTap: () => showReadaheadDialog(
                    context,
                    ref,
                    playerSettings.readaheadSeconds,
                  ),
                ),
                SettingsTile(
                  icon: Icons.aspect_ratio_rounded,
                  title: l10n.defaultResizeMode,
                  subtitle: getResizeModeLabel(
                    playerSettings.defaultResizeMode,
                    l10n,
                  ),
                  onTap: () => showResizeDialog(
                    context,
                    ref,
                    playerSettings.defaultResizeMode,
                  ),
                ),
                SettingsTile(
                  icon: Icons.high_quality_rounded,
                  title: l10n.hardwareDecoding,
                  subtitle: playerSettings.hardwareDecoding
                      ? '${l10n.enabled} (${l10n.recommended})'
                      : l10n.disabled,
                  trailing: Switch(
                    value: playerSettings.hardwareDecoding,
                    onChanged: (val) => ref
                        .read(playerSettingsProvider.notifier)
                        .setHardwareDecoding(val),
                  ),
                  onTap: () => ref
                      .read(playerSettingsProvider.notifier)
                      .setHardwareDecoding(!playerSettings.hardwareDecoding),
                ),
                SettingsTile(
                  icon: Icons.fast_forward_rounded,
                  title: appText(
                    context,
                    english: 'Skip intro and credits',
                    arabic: 'تخطي المقدمة والنهاية',
                  ),
                  subtitle: appText(
                    context,
                    english: playerSettings.skipSegmentsEnabled
                        ? 'A skip button appears when the episode has known '
                              'times. The times are community-submitted '
                              '(AniSkip), so some episodes have none.'
                        : 'Disabled',
                    arabic: playerSettings.skipSegmentsEnabled
                        ? 'يظهر زر التخطي عند توفر توقيتات للحلقة. التوقيتات '
                              'من مساهمات المستخدمين (AniSkip)، لذا لا تتوفر '
                              'لكل الحلقات.'
                        : 'معطل',
                  ),
                  trailing: Switch(
                    value: playerSettings.skipSegmentsEnabled,
                    onChanged: (val) => ref
                        .read(playerSettingsProvider.notifier)
                        .setSkipSegmentsEnabled(val),
                  ),
                  onTap: () => ref
                      .read(playerSettingsProvider.notifier)
                      .setSkipSegmentsEnabled(
                        !playerSettings.skipSegmentsEnabled,
                      ),
                ),
                // Only meaningful once the skip button itself is on.
                if (playerSettings.skipSegmentsEnabled) ...[
                  SettingsTile(
                    icon: Icons.skip_next_rounded,
                    title: appText(
                      context,
                      english: 'Skip the opening automatically',
                      arabic: 'تخطي المقدمة تلقائيًا',
                    ),
                    subtitle: appText(
                      context,
                      english: playerSettings.autoSkipIntro
                          ? 'Openings and recaps are skipped without asking'
                          : 'A skip button is shown instead',
                      arabic: playerSettings.autoSkipIntro
                          ? 'يتم تخطي المقدمة والملخص تلقائيًا دون الضغط على الزر'
                          : 'يظهر زر التخطي بدلاً من ذلك',
                    ),
                    trailing: Switch(
                      value: playerSettings.autoSkipIntro,
                      onChanged: (val) => ref
                          .read(playerSettingsProvider.notifier)
                          .setAutoSkipIntro(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setAutoSkipIntro(!playerSettings.autoSkipIntro),
                  ),
                  SettingsTile(
                    icon: Icons.playlist_play_rounded,
                    title: appText(
                      context,
                      english: 'Skip the credits automatically',
                      arabic: 'تخطي النهاية تلقائيًا',
                    ),
                    subtitle: appText(
                      context,
                      english: playerSettings.autoSkipCredits
                          ? 'The credits run to the end, so the episode '
                                'finishes and the next one is offered'
                          : 'A skip button is shown instead',
                      arabic: playerSettings.autoSkipCredits
                          ? 'النهاية تمتد حتى آخر الحلقة، لذا تنتهي الحلقة '
                                'ويتم عرض الحلقة التالية'
                          : 'يظهر زر التخطي بدلاً من ذلك',
                    ),
                    trailing: Switch(
                      value: playerSettings.autoSkipCredits,
                      onChanged: (val) => ref
                          .read(playerSettingsProvider.notifier)
                          .setAutoSkipCredits(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setAutoSkipCredits(!playerSettings.autoSkipCredits),
                  ),
                ],
                SettingsTile(
                  icon: Icons.tune_rounded,
                  title: l10n.playerControls,
                  subtitle: l10n.playerControlsSubtitle,
                  isLast: true,
                  onTap: () => showPlayerControlsDialog(context, ref),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),

            SettingsGroup(
              title: l10n.downloads,
              children: [
                SettingsTile(
                  icon: Icons.low_priority_rounded,
                  title: downloadConcurrencyTitle(),
                  subtitle: downloadConcurrencySubtitle(
                    generalSettings.downloadConcurrency,
                  ),
                  onTap: () => showDownloadConcurrencyDialog(
                    context,
                    ref,
                    generalSettings.downloadConcurrency,
                  ),
                ),
                SettingsTile(
                  icon: Icons.notifications_rounded,
                  title: downloadNotificationsTitle(),
                  subtitle: downloadNotificationsSubtitle(
                    generalSettings.downloadNotifications,
                  ),
                  isLast: true,
                  onTap: () => showDownloadNotificationsDialog(context, ref),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),
            SettingsGroup(
              title: appText(context, english: 'Images', arabic: 'الصور'),
              children: [
                SettingsTile(
                  icon: Icons.image_rounded,
                  title: appText(
                    context,
                    english: 'Episode images',
                    arabic: 'صور الحلقات',
                  ),
                  subtitle: appText(
                    context,
                    english: 'Use episode images from AniZip',
                    arabic: 'استخدام صور الحلقات من AniZip',
                  ),
                  trailing: Switch(
                    value: animeDataSettings.episodeImagesFromAniZip,
                    onChanged: (value) => ref
                        .read(animeDataSourceSettingsProvider.notifier)
                        .setEpisodeImagesFromAniZip(value),
                  ),
                  onTap: () => ref
                      .read(animeDataSourceSettingsProvider.notifier)
                      .setEpisodeImagesFromAniZip(
                        !animeDataSettings.episodeImagesFromAniZip,
                      ),
                ),
                SettingsTile(
                  icon: Icons.hd_rounded,
                  title: appText(
                    context,
                    english: 'High quality posters',
                    arabic: 'بوسترات بجودة عالية',
                  ),
                  subtitle: appText(
                    context,
                    english:
                        'Off loads the standard posters and uses less memory',
                    arabic:
                        'عند التعطيل يتم تحميل البوسترات العادية باستهلاك أقل',
                  ),
                  trailing: Switch(
                    value: animeDataSettings.highQualityPosters,
                    onChanged: (value) => ref
                        .read(animeDataSourceSettingsProvider.notifier)
                        .setHighQualityPosters(value),
                  ),
                  onTap: () => ref
                      .read(animeDataSourceSettingsProvider.notifier)
                      .setHighQualityPosters(
                        !animeDataSettings.highQualityPosters,
                      ),
                ),
                SettingsTile(
                  icon: Icons.image_search_rounded,
                  title: appText(
                    context,
                    english: 'Find posters elsewhere',
                    arabic: 'البحث عن البوسترات من مصدر آخر',
                  ),
                  subtitle: appText(
                    context,
                    english:
                        'Turn on only if posters do not load: looks them up '
                        'on AniList when the usual host is blocked',
                    arabic:
                        'فعّله فقط إذا كانت البوسترات لا تظهر: يبحث عنها في '
                        'AniList عند حجب المصدر المعتاد',
                  ),
                  trailing: Switch(
                    value: animeDataSettings.artworkFallback,
                    onChanged: (value) => ref
                        .read(animeDataSourceSettingsProvider.notifier)
                        .setArtworkFallback(value),
                  ),
                  isLast: true,
                  onTap: () => ref
                      .read(animeDataSourceSettingsProvider.notifier)
                      .setArtworkFallback(!animeDataSettings.artworkFallback),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),
            SettingsGroup(
              title: l10n.appData,
              children: [
                if (!kIsWeb)
                  SettingsTile(
                    icon: Icons.cleaning_services_rounded,
                    title: l10n.clearCache,
                    subtitle: ref
                        .watch(cacheSizeProvider)
                        .when(
                          data: (bytes) =>
                              '${l10n.clearCacheSubtitle} • ${_formatBytes(bytes)}',
                          loading: () => l10n.calculating,
                          error: (_, _) => l10n.clearCacheSubtitle,
                        ),
                    onTap: () => showClearCacheDialog(context, ref),
                  ),
                SettingsTile(
                  icon: Icons.delete_forever_rounded,
                  title: l10n.factoryReset,
                  subtitle: l10n.factoryResetSubtitle,
                  isLast: true,
                  onTap: () => showFactoryResetDialog(context, ref),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),
            SettingsGroup(
              title: l10n.about,
              children: [
                SettingsTile(
                  icon: Icons.language_rounded,
                  title: appText(
                    context,
                    english: 'AnimeWitcher Website',
                    arabic: 'موقع AnimeWitcher',
                  ),
                  subtitle: 'animewitcher.com',
                  onTap: () => launchUrl(
                    Uri.parse('https://www.animewitcher.com'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                SettingsTile(
                  icon: Icons.support_agent_rounded,
                  title: appText(
                    context,
                    english: 'Technical Support',
                    arabic: 'الدعم الفني',
                  ),
                  subtitle: 't.me/animewitcher_support',
                  onTap: () => launchUrl(
                    Uri.parse('https://t.me/animewitcher_support'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                SettingsTile(
                  icon: Icons.email_outlined,
                  title: appText(
                    context,
                    english: 'Email Support',
                    arabic: 'التواصل عبر البريد',
                  ),
                  subtitle: 'animewitcher1@gmail.com',
                  onTap: () => launchUrl(
                    Uri.parse(
                      'mailto:animewitcher1@gmail.com?subject=${Uri.encodeComponent('AnimeWitcher Support')}',
                    ),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                SettingsTile(
                  icon: Icons.send_rounded,
                  title: appText(
                    context,
                    english: 'Telegram Channel',
                    arabic: 'قناة التلجرام',
                  ),
                  subtitle: 't.me/AnimeWitcherUpdates',
                  onTap: () => launchUrl(
                    Uri.parse('https://t.me/AnimeWitcherUpdates'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: l10n.version,
                  subtitle: versionAsync.when(
                    data: (v) => v,
                    loading: () => l10n.loading,
                    error: (err, stack) => l10n.unknown,
                  ),
                  trailing: const SizedBox.shrink(),
                  isLast: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final value = unitIndex == 0
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$value ${units[unitIndex]}';
}
