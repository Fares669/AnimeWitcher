import 'dart:io';

import 'package:flutter/material.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';

import 'widgets/download_log_dialog.dart';
import '../../../shared/widgets/account_avatar_button.dart';

import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/providers/anime_data_source_settings_provider.dart';
import '../../../core/theme/theme_provider.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/taskbar_customization_dialog.dart';
import 'widgets/stream_source_priority_dialog.dart';
import 'player_settings_provider.dart';
import 'general_settings_provider.dart';
import '../../manga/reader/manga_reader_settings_screen.dart';
import 'app_version_provider.dart';

import 'package:animewitcher/l10n/generated/app_localizations.dart';

import 'cache_provider.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

import '../../../core/navigation/app_layout_style.dart';
import '../../details/presentation/widgets/details_seasons_bar.dart';
import '../../details/presentation/widgets/seasons_bar_style_picker.dart';
import '../../home/presentation/latest_episodes_provider.dart';
import '../../../shared/widgets/app_layout_picker.dart';
import '../../player/data/anime4k.dart';
import 'widgets/anime4k_dialog.dart';

/// Turns Anime4K on or off from its row. Turning it on with no shaders yet
/// opens the dialog, which is where they are downloaded; turning it on with
/// no model chosen picks A, the general-purpose one.
Future<void> _setAnime4k(BuildContext context, WidgetRef ref, bool on) async {
  final notifier = ref.read(playerSettingsProvider.notifier);
  final settings =
      ref.read(playerSettingsProvider).asData?.value ?? const PlayerSettings();
  await notifier.setAnime4kEnabled(on);
  if (!on) return;
  if (settings.anime4kMode == Anime4kMode.off) {
    await notifier.setAnime4kMode(Anime4kMode.a);
  }
  if (settings.anime4kShaderDirectory.trim().isEmpty && context.mounted) {
    showAnime4kDialog(context, ref);
  }
}

/// The same ordered, localized groups for the full Settings list and the
/// desktop More sidebar, without building the rows to get their titles.
enum SettingsSection {
  general,
  player,
  reader,
  downloads,
  images,
  appData,
  about;

  String title(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return switch (this) {
      SettingsSection.general => l10n.general,
      SettingsSection.player => l10n.player,
      SettingsSection.reader => appText(
        context,
        english: 'Reader',
        arabic: 'القارئ',
      ),
      SettingsSection.downloads => l10n.downloads,
      SettingsSection.images => appText(
        context,
        english: 'Images',
        arabic: 'الصور',
      ),
      SettingsSection.appData => l10n.appData,
      SettingsSection.about => l10n.about,
    };
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPop = Navigator.of(context).canPop();
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(title: l10n.settings, canPop: canPop),
      body: _buildSettingsList(context, ref),
    );
  }

  Widget _buildSettingsList(BuildContext context, WidgetRef ref) {
    // Preserve the full Settings list on the standalone route.
    return Center(
      child: ConstrainedBox(
        // Settings rows are single-column text; letting them stretch across a
        // 3440px ultrawide would put the label and its trailing control on
        // opposite ends of the desk. Clamp to the shared reading measure.
        constraints: const BoxConstraints(
          maxWidth: LayoutConstants.contentMaxWidth,
        ),
        child: ListView(
          padding: EdgeInsets.only(
            top: appPageHeaderContentTopInset(context),
            bottom: 100,
          ),
          children: [
            const SizedBox(height: LayoutConstants.spacingXs),
            for (final section in SettingsSection.values) ...[
              if (section != SettingsSection.general)
                const SizedBox(height: LayoutConstants.spacingLg),
              buildSection(context, ref, section),
            ],
          ],
        ),
      ),
    );
  }

  /// Marks the reader group, whose one row opens a screen of its own. A pane
  /// wide enough to show a group alone shows that screen's options in it
  /// instead, rather than a link to them.
  static const readerGroupKey = ValueKey<String>('settings-reader-group');

  /// A section starts building its rows and watching its providers only when
  /// the list mounts it near the viewport. More mounts only its selected one.
  static Widget buildSection(
    BuildContext context,
    WidgetRef ref,
    SettingsSection section,
  ) => _SettingsSectionView(
    section: section,
    routeContext: context,
    routeRef: ref,
  );
}

class _SettingsSectionView extends ConsumerWidget {
  const _SettingsSectionView({
    required this.section,
    required this.routeContext,
    required this.routeRef,
  });

  final SettingsSection section;

  // Action callbacks keep their route/pane lifetime. A list section can get
  // evicted while an already opened dialog is still awaiting a choice.
  final BuildContext routeContext;
  final WidgetRef routeRef;

  @override
  Widget build(BuildContext context, WidgetRef sectionRef) {
    final ref = routeRef;
    final l10n = AppLocalizations.of(context)!;

    SettingsGroup general() {
      final settings = sectionRef.watch(
        generalSettingsProvider.select(
          (s) => (
            autoSelectStreamSource: s.autoSelectStreamSource,
            streamServerPriority: s.streamServerPriority,
            streamQualityPriority: s.streamQualityPriority,
            defaultHomeScreen: s.defaultHomeScreen,
            taskbarOrder: s.taskbarOrder,
            hiddenTaskbarItems: s.hiddenTaskbarItems,
          ),
        ),
      );
      final activeCatalog = sectionRef.watch(activeProviderProvider);
      final installedProviders = sectionRef.watch(extensionManagerProvider);
      final latestEpisodes = sectionRef.watch(latestEpisodesSettingsProvider);
      return SettingsGroup(
        title: SettingsSection.general.title(context),
        children: [
          SettingsTile(
            icon: Icons.dark_mode_rounded,
            title: l10n.appTheme,
            // Picked on the row, each theme with its colour, no dialog in
            // between.
            trailing: const SizedBox.shrink(),
            below: SettingsChoices<AppThemeStyle>(
              values: AppThemeStyle.values,
              selected: sectionRef.watch(appThemeStyleProvider),
              label: (style) => style.label(),
              swatch: (style) => style.swatch,
              onSelected: (style) =>
                  ref.read(appThemeStyleProvider.notifier).select(style),
            ),
          ),
          SettingsTile(
            key: const ValueKey('settings-witcher-account'),
            icon: Icons.account_circle_outlined,
            title: 'حساب AnimeWitcher',
            onTap: () => openAccountScreen(routeContext),
          ),
          SettingsTile(
            key: const ValueKey('settings-active-anime-provider'),
            icon: Icons.video_library_outlined,
            title: 'مصدر الأنمي النشط',
            subtitle:
                activeCatalog != null &&
                    activeCatalog is! AnimeWitcherNativeProvider
                ? '${activeCatalog.name} · المانجا على AnimeWitcher'
                : '${activeCatalog?.name ?? 'AnimeWitcher'} (${installedProviders.length} مزوّد)',
            trailing: installedProviders.length > 1
                ? const SizedBox.shrink()
                : null,
            below: installedProviders.length > 1
                ? SettingsChoices<AnimeWitcherProvider>(
                    values: installedProviders,
                    selected: activeCatalog ?? installedProviders.first,
                    label: (p) => p.name,
                    onSelected: (p) =>
                        ref.read(activeProviderProvider.notifier).set(p),
                  )
                : null,
            onTap: installedProviders.length <= 1
                ? null
                : () async {
                    final currentIndex = installedProviders.indexWhere(
                      (p) => p.packageName == activeCatalog?.packageName,
                    );
                    final next =
                        installedProviders[(currentIndex + 1) %
                            installedProviders.length];
                    await ref.read(activeProviderProvider.notifier).set(next);
                  },
          ),
          ...installedProviders
              .where(
                (source) => source.supportedTypes.contains(ProviderType.anime),
              )
              .map((source) {
                final id = source.packageName;
                final active = id == activeCatalog?.packageName;
                final enabled = active || latestEpisodes.contains(id);
                Future<void> toggle(bool value) => ref
                    .read(latestEpisodesSettingsProvider.notifier)
                    .setEnabled(id, value);
                return SettingsTile(
                  key: ValueKey('settings-latest-episodes-$id'),
                  icon: Icons.new_releases_outlined,
                  title: 'أحدث الحلقات (${source.name})',
                  subtitle: active ? 'المصدر النشط' : null,
                  trailing: Switch(
                    value: enabled,
                    onChanged: active ? null : toggle,
                  ),
                  onTap: active ? null : () => toggle(!enabled),
                );
              }),
          SettingsTile(
            icon: Icons.view_carousel_rounded,
            title: 'شريط المواسم',
            subtitle: sectionRef.watch(seasonsBarStyleProvider).label(),
            onTap: () => showSeasonsBarStylePicker(routeContext, ref),
          ),
          SettingsTile(
            key: const ValueKey<String>('settings-auto-source-selection'),
            icon: Icons.auto_awesome_rounded,
            title: appText(
              context,
              english: 'Automatic server selection',
              arabic: 'الاختيار التلقائي للسيرفر',
            ),
            subtitle: appText(
              context,
              english:
                  'Automatically picks a source for playback and downloads. '
                  'Quality priority is always applied before server priority.',
              arabic:
                  'يختار المصدر تلقائيًا للتشغيل والتنزيل. أولوية الجودة '
                  'تُطبق دائمًا قبل أولوية السيرفر.',
            ),
            trailing: Switch(
              value: settings.autoSelectStreamSource,
              onChanged: (value) => ref
                  .read(generalSettingsProvider.notifier)
                  .setAutoSelectStreamSource(value),
            ),
            onTap: () => ref
                .read(generalSettingsProvider.notifier)
                .setAutoSelectStreamSource(!settings.autoSelectStreamSource),
          ),
          if (settings.autoSelectStreamSource) ...[
            SettingsTile(
              key: const ValueKey<String>('settings-quality-priority'),
              icon: Icons.high_quality_rounded,
              title: appText(
                context,
                english: 'Quality priority',
                arabic: 'أولوية الجودة',
              ),
              subtitle: settings.streamQualityPriority.join(' ← '),
              onTap: () => showStreamQualityPriorityDialog(
                routeContext,
                ref,
                settings.streamQualityPriority,
              ),
            ),
            SettingsTile(
              key: const ValueKey<String>('settings-server-priority'),
              icon: Icons.dns_rounded,
              title: appText(
                context,
                english: 'Server priority',
                arabic: 'أولوية السيرفرات',
              ),
              subtitle: settings.streamServerPriority.join(' ← '),
              onTap: () => showStreamServerPriorityDialog(
                routeContext,
                ref,
                settings.streamServerPriority,
              ),
            ),
          ],
          SettingsTile(
            icon: Icons.home_rounded,
            title: l10n.defaultHomeScreen,
            subtitle: getHomeScreenLabel(settings.defaultHomeScreen, l10n),
            onTap: () => showDefaultHomeScreenDialog(
              routeContext,
              ref,
              settings.defaultHomeScreen,
            ),
          ),
          SettingsTile(
            key: const ValueKey<String>('settings-manga-tab'),
            icon: Icons.menu_book_rounded,
            title: 'قسم المانجا منفصل',
            subtitle: 'المانجا في الشريط بقسم خاص بدل الصفحة الرئيسية',
            trailing: Switch(
              value: !settings.hiddenTaskbarItems.contains(
                TaskbarDestination.manga.id,
              ),
              onChanged: (show) =>
                  ref.read(generalSettingsProvider.notifier).setMangaTab(show),
            ),
            onTap: () => ref
                .read(generalSettingsProvider.notifier)
                .setMangaTab(
                  settings.hiddenTaskbarItems.contains(
                    TaskbarDestination.manga.id,
                  ),
                ),
          ),
          SettingsTile(
            icon: Icons.dashboard_customize_rounded,
            title: 'تخصيص شريط المهام',
            subtitle: 'ترتيب العناصر وإخفاؤها أو إظهارها',
            onTap: () => showTaskbarCustomizationDialog(
              routeContext,
              ref,
              settings.taskbarOrder,
              settings.hiddenTaskbarItems,
            ),
            isLast: !appLayoutsAvailable(context),
          ),
          if (appLayoutsAvailable(context))
            SettingsTile(
              icon: Icons.view_quilt_rounded,
              title: 'شكل التطبيق',
              subtitle:
                  (sectionRef.watch(appLayoutStyleProvider) ??
                          AppLayoutStyle.dock)
                      .label(),
              onTap: () => showAppLayoutPicker(routeContext, ref),
              isLast: true,
            ),
        ],
      );
    }

    SettingsGroup player() {
      final playerSettings =
          sectionRef.watch(playerSettingsProvider).asData?.value ??
          const PlayerSettings();
      return SettingsGroup(
        title: SettingsSection.player.title(context),
        children: [
          SettingsTile(
            icon: Icons.smart_display_rounded,
            title: l10n.defaultPlayer,
            subtitle: getPlayerDisplayName(
              playerSettings.preferredPlayer,
              l10n,
            ),
            onTap: () => showDefaultPlayerDialog(
              routeContext,
              ref,
              playerSettings.preferredPlayer,
            ),
          ),
          SettingsTile(
            icon: Icons.av_timer_rounded,
            title: l10n.seekDuration,
            subtitle: formatSeekDuration(playerSettings.seekDuration, l10n),
            onTap: () => showDurationDialog(
              routeContext,
              ref,
              playerSettings.seekDuration,
            ),
          ),
          SettingsTile(
            icon: Icons.timer_outlined,
            title: l10n.bufferDepth,
            subtitle: formatReadahead(playerSettings.readaheadSeconds, l10n),
            onTap: () => showReadaheadDialog(
              routeContext,
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
              routeContext,
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
                .setSkipSegmentsEnabled(!playerSettings.skipSegmentsEnabled),
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
            icon: Icons.fast_forward_rounded,
            title: appText(
              context,
              english: 'Skip filler episodes',
              arabic: 'تخطي حلقات الفلر',
            ),
            subtitle: switch (playerSettings.fillerBehaviour) {
              FillerBehaviour.skip => appText(
                context,
                english: 'Skipped',
                arabic: 'يتم تخطيها',
              ),
              FillerBehaviour.note => appText(
                context,
                english: 'A note with a skip button',
                arabic: 'تنبيه مع زر تخطي',
              ),
              FillerBehaviour.off => appText(
                context,
                english: 'Played like any other',
                arabic: 'تشغيلها كغيرها',
              ),
            },
            onTap: () => showFillerBehaviourDialog(routeContext, ref),
          ),
          SettingsTile(
            icon: Icons.bolt_rounded,
            title: appText(
              context,
              english: 'Prepare the next episode',
              arabic: 'تحضير الحلقة التالية',
            ),
            subtitle: appText(
              context,
              english: playerSettings.prefetchNextEpisode
                  ? 'Its sources are fetched while this one plays, so '
                        '"next" opens without a wait'
                  : 'Its sources are fetched only when you ask for them',
              arabic: playerSettings.prefetchNextEpisode
                  ? 'تُجلب مصادرها أثناء تشغيل الحالية، فتفتح "التالية" '
                        'بلا انتظار'
                  : 'تُجلب مصادرها عند طلبها فقط',
            ),
            trailing: Switch(
              value: playerSettings.prefetchNextEpisode,
              onChanged: (val) => ref
                  .read(playerSettingsProvider.notifier)
                  .setPrefetchNextEpisode(val),
            ),
            onTap: () => ref
                .read(playerSettingsProvider.notifier)
                .setPrefetchNextEpisode(!playerSettings.prefetchNextEpisode),
          ),
          // Native media_kit/libmpv platforms can run Anime4K through
          // mpv's GPU shader stage. The adaptive backend is rejected at playback.
          if (Platform.isWindows ||
              Platform.isMacOS ||
              Platform.isLinux ||
              Platform.isAndroid ||
              Platform.isIOS)
            SettingsTile(
              icon: Icons.auto_awesome_rounded,
              title: 'Anime4K',
              subtitle: appText(
                context,
                english: 'Upscales anime as it plays',
                arabic: 'يرفع جودة الأنمي أثناء التشغيل',
              ),
              // On and off on the row, and the model under it once on. The
              // dialog keeps the rest: the shader download and the size.
              trailing: Switch(
                value: playerSettings.anime4kEnabled,
                onChanged: (on) => _setAnime4k(routeContext, ref, on),
              ),
              onTap: () => showAnime4kDialog(routeContext, ref),
              below: !playerSettings.anime4kEnabled
                  ? null
                  : SettingsChoices<Anime4kMode>(
                      values: [
                        for (final mode in Anime4kMode.values)
                          if (mode != Anime4kMode.off) mode,
                      ],
                      selected: playerSettings.anime4kMode,
                      label: (mode) => mode.label,
                      onSelected: (mode) => ref
                          .read(playerSettingsProvider.notifier)
                          .setAnime4kMode(mode),
                    ),
            ),
          SettingsTile(
            icon: Icons.tune_rounded,
            title: l10n.playerControls,
            subtitle: l10n.playerControlsSubtitle,
            isLast: true,
            onTap: () => showPlayerControlsDialog(routeContext, ref),
          ),
        ],
      );
    }

    SettingsGroup reader() {
      return SettingsGroup(
        key: SettingsScreen.readerGroupKey,
        title: SettingsSection.reader.title(context),
        children: [
          SettingsTile(
            icon: Icons.chrome_reader_mode_rounded,
            title: appText(
              context,
              english: 'Manga Reader',
              arabic: 'قارئ المانجا',
            ),
            subtitle: appText(
              context,
              english: 'Reading modes, display, navigation and color filters',
              arabic: 'أوضاع القراءة والعرض والتنقل وفلاتر الألوان',
            ),
            isLast: true,
            onTap: () => Navigator.of(routeContext).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const MangaReaderSettingsScreen(),
              ),
            ),
          ),
        ],
      );
    }

    SettingsGroup downloads() {
      final settings = sectionRef.watch(
        generalSettingsProvider.select(
          (s) => (
            concurrency: s.downloadConcurrency,
            parts: s.downloadParallelParts,
            notifications: s.downloadNotifications,
          ),
        ),
      );
      return SettingsGroup(
        title: SettingsSection.downloads.title(context),
        children: [
          SettingsTile(
            icon: Icons.low_priority_rounded,
            title: downloadConcurrencyTitle(),
            subtitle: downloadConcurrencySubtitle(settings.concurrency),
            onTap: () => showDownloadConcurrencyDialog(
              routeContext,
              ref,
              settings.concurrency,
            ),
          ),
          SettingsTile(
            icon: Icons.call_split_rounded,
            title: downloadPartsTitle(),
            subtitle: downloadPartsSubtitle(settings.parts),
            onTap: () =>
                showDownloadPartsDialog(routeContext, ref, settings.parts),
          ),
          SettingsTile(
            icon: Icons.notifications_rounded,
            title: downloadNotificationsTitle(),
            subtitle: downloadNotificationsSubtitle(settings.notifications),
            onTap: () => showDownloadNotificationsDialog(routeContext, ref),
          ),
          SettingsTile(
            icon: Icons.bug_report_outlined,
            title: appText(
              context,
              english: 'Download log',
              arabic: 'سجل التنزيلات (Log)',
            ),
            subtitle: appText(
              context,
              english: 'Track downloads in the log folder. Tap to manage and export.',
              arabic: 'تتبّع التنزيلات في مجلد log. اضغط للتفعيل وعرض الملفات وتصديرها.',
            ),
            isLast: true,
            onTap: () => showDialog<void>(
              context: routeContext,
              builder: (_) => const DownloadLogDialog(),
            ),
          ),
        ],
      );
    }

    SettingsGroup images() {
      final animeDataSettings = sectionRef.watch(
        animeDataSourceSettingsProvider,
      );
      return SettingsGroup(
        title: SettingsSection.images.title(context),
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
              english: 'Off loads the standard posters and uses less memory',
              arabic: 'عند التعطيل يتم تحميل البوسترات العادية باستهلاك أقل',
            ),
            trailing: Switch(
              value: animeDataSettings.highQualityPosters,
              onChanged: (value) => ref
                  .read(animeDataSourceSettingsProvider.notifier)
                  .setHighQualityPosters(value),
            ),
            onTap: () => ref
                .read(animeDataSourceSettingsProvider.notifier)
                .setHighQualityPosters(!animeDataSettings.highQualityPosters),
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
      );
    }

    SettingsGroup appData() {
      return SettingsGroup(
        title: SettingsSection.appData.title(context),
        children: [
          if (!kIsWeb)
            _ClearCacheTile(
              onTap: () => showClearCacheDialog(routeContext, ref),
            ),
          SettingsTile(
            icon: Icons.delete_forever_rounded,
            title: l10n.factoryReset,
            subtitle: l10n.factoryResetSubtitle,
            isLast: true,
            onTap: () => showFactoryResetDialog(routeContext, ref),
          ),
        ],
      );
    }

    SettingsGroup about() {
      final versionAsync = sectionRef.watch(appVersionProvider);
      return SettingsGroup(
        title: SettingsSection.about.title(context),
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
      );
    }

    return switch (section) {
      SettingsSection.general => general(),
      SettingsSection.player => player(),
      SettingsSection.reader => reader(),
      SettingsSection.downloads => downloads(),
      SettingsSection.images => images(),
      SettingsSection.appData => appData(),
      SettingsSection.about => about(),
    };
  }
}

class _ClearCacheTile extends ConsumerStatefulWidget {
  const _ClearCacheTile({required this.onTap});

  final VoidCallback onTap;

  @override
  ConsumerState<_ClearCacheTile> createState() => _ClearCacheTileState();
}

class _ClearCacheTileState extends ConsumerState<_ClearCacheTile>
    with AutomaticKeepAliveClientMixin<_ClearCacheTile> {
  // Once reached, keep the cache size for this visit even if the App Data
  // group scrolls away. Leaving Settings still releases the subscription.
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    return SettingsTile(
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
      onTap: widget.onTap,
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
