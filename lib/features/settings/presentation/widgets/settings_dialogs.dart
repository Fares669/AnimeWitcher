import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../../../../shared/widgets/glass_dialog.dart';
import '../../../../core/account/account_providers.dart';
import '../../../../core/storage/secure_token_storage.dart';
import '../../../../core/services/external_player_service.dart';
import '../../../../core/navigation/taskbar_destination.dart';
import '../../../../core/storage/settings_repository.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/utils/app_utils.dart';
import '../../../../core/utils/factory_reset.dart';
import '../player_settings_provider.dart';
import '../general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/core/utils/localized_text.dart';
import '../cache_provider.dart';
import '../../../../core/services/download_concurrency.dart';
import '../../../../core/services/download_parallel.dart';

import 'package:animewitcher/core/services/notification_service.dart';

/// Returns a localized label for a resize mode string.
String getResizeModeLabel(String mode, AppLocalizations l10n) {
  switch (mode.toLowerCase()) {
    case 'fit':
      return l10n.fit;
    case 'zoom':
      return l10n.zoom;
    case 'stretch':
      return l10n.stretch;
    default:
      return mode;
  }
}

/// Returns a human-readable label for a home screen route.
String getHomeScreenLabel(String route, AppLocalizations l10n) {
  return taskbarDestinationForRoute(route)?.label(l10n) ?? l10n.home;
}

/// Shows a dialog to pick the default home screen.
void showDefaultHomeScreenDialog(
  BuildContext context,
  WidgetRef ref,
  String current,
) {
  final l10n = AppLocalizations.of(context)!;
  final settings = ref.read(generalSettingsProvider);
  final options =
      visibleTaskbarDestinations(
            settings.taskbarOrder,
            settings.hiddenTaskbarItems,
          )
          .map(
            (destination) => <String, String>{
              'label': destination.label(l10n),
              'route': destination.route,
            },
          )
          .toList(growable: false);

  showGlassDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.defaultHomeScreen),
      content: RadioGroup<String>(
        groupValue: current,
        onChanged: (val) {
          if (val == null) return;
          ref.read(generalSettingsProvider.notifier).setDefaultHomeScreen(val);
          Navigator.pop<void>(context);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((opt) {
              return ListTile(
                title: Text(opt['label']!),
                leading: Radio<String>(value: opt['route']!),
                onTap: () {
                  ref
                      .read(generalSettingsProvider.notifier)
                      .setDefaultHomeScreen(opt['route']!);
                  Navigator.pop<void>(context);
                },
              );
            }).toList(),
          ),
        ),
      ),
    ),
  );
}

// Must be used inside a RadioGroup<ThemeMode> ancestor.
Widget _buildThemeOption(String title, ThemeMode value, VoidCallback onSelect) {
  return ListTile(
    title: Text(title),
    leading: Radio<ThemeMode>(value: value),
    onTap: onSelect,
  );
}

/// Formats seek duration for display (e.g. "10 sec", "2 min").
String formatSeekDuration(int seconds, AppLocalizations l10n) {
  if (seconds >= 60) {
    return '${seconds ~/ 60} ${l10n.min}';
  }
  return '$seconds ${l10n.sec}';
}

/// Formats readahead seconds for display (e.g. "5 min", "10 min").
String formatReadahead(int seconds, AppLocalizations l10n) {
  return '${seconds ~/ 60} ${l10n.min}';
}

/// Returns a human-readable name for a player ID.
String getPlayerDisplayName(String? playerId, AppLocalizations l10n) {
  if (playerId == null) return l10n.internalPlayer;
  final player = ExternalPlayerService.instance.getPlayerById(playerId);
  return player?.displayName ?? playerId;
}

const List<int> kSeekDurationOptions = <int>[5, 10, 15, 20, 30, 60, 120];

int _closestSeekDurationIndex(int current) {
  var bestIndex = 0;
  var bestDistance = (kSeekDurationOptions.first - current).abs();
  for (var i = 1; i < kSeekDurationOptions.length; i++) {
    final distance = (kSeekDurationOptions[i] - current).abs();
    if (distance < bestDistance) {
      bestIndex = i;
      bestDistance = distance;
    }
  }
  return bestIndex;
}

/// Shows a discrete slider for the seek duration. Moving the thumb is only a
/// preview; the setting is committed when Save is pressed.
void showDurationDialog(BuildContext context, WidgetRef ref, int current) {
  final l10n = AppLocalizations.of(context)!;
  var selectedIndex = _closestSeekDurationIndex(current);

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) {
        final selected = kSeekDurationOptions[selectedIndex];
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(l10n.selectSeekDuration),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatSeekDuration(selected, l10n),
                  key: const ValueKey('seek-duration-value'),
                  style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                CustomSlider(
                  key: const ValueKey('seek-duration-slider'),
                  value: selectedIndex.toDouble(),
                  min: 0,
                  max: (kSeekDurationOptions.length - 1).toDouble(),
                  divisions: kSeekDurationOptions.length - 1,
                  step: 1.0,
                  onChanged: (value) =>
                      setState(() => selectedIndex = value.round()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop<void>(ctx),
              child: Text(
                l10n.cancel,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            CustomButton(
              isPrimary: true,
              onPressed: () async {
                await ref
                    .read(playerSettingsProvider.notifier)
                    .setSeekDuration(kSeekDurationOptions[selectedIndex]);
                if (ctx.mounted) Navigator.pop<void>(ctx);
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ),
  );
}

/// Shows a dialog to pick the default resize mode.
void showResizeDialog(BuildContext context, WidgetRef ref, String current) {
  final l10n = AppLocalizations.of(context)!;
  final options = <Map<String, String>>[
    {'label': l10n.fit, 'value': 'Fit'},
    {'label': l10n.zoom, 'value': 'Zoom'},
    {'label': l10n.stretch, 'value': 'Stretch'},
  ];
  showGlassDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.defaultResizeMode),
      content: RadioGroup<String>(
        groupValue: current,
        onChanged: (val) {
          if (val == null) return;
          ref.read(playerSettingsProvider.notifier).setDefaultResizeMode(val);
          Navigator.pop<void>(ctx);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((e) {
              return ListTile(
                title: Text(e['label']!),
                leading: Radio<String>(value: e['value']!),
                onTap: () {
                  ref
                      .read(playerSettingsProvider.notifier)
                      .setDefaultResizeMode(e['value']!);
                  Navigator.pop<void>(ctx);
                },
              );
            }).toList(),
          ),
        ),
      ),
    ),
  );
}

/// Arabic label for the concurrent-download setting (app ships Arabic-only).
String downloadConcurrencyTitle() => 'عدد التحميلات المتزامنة';

/// Subtitle/value shown on the Settings tile, e.g. "1 في نفس الوقت".
String downloadConcurrencySubtitle(int count) =>
    '${clampDownloadConcurrency(count)} في نفس الوقت';

String _downloadConcurrencyDialogValue(int count) {
  final normalized = clampDownloadConcurrency(count);
  return normalized == 1
      ? 'تحميل واحد في نفس الوقت'
      : '$normalized تحميلات في نفس الوقت';
}

/// Pick how many episode downloads may transfer at once. The setting is only
/// committed when Save is pressed, matching SkyStream's slider interaction.
void showDownloadConcurrencyDialog(
  BuildContext context,
  WidgetRef ref,
  int current,
) {
  final l10n = AppLocalizations.of(context)!;
  var selected = clampDownloadConcurrency(current);

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(downloadConcurrencyTitle()),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _downloadConcurrencyDialogValue(selected),
                key: const ValueKey('download-concurrency-value'),
                style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              CustomSlider(
                key: const ValueKey('download-concurrency-slider'),
                value: selected.toDouble(),
                min: kDownloadConcurrencyMin.toDouble(),
                max: kDownloadConcurrencyMax.toDouble(),
                divisions: kDownloadConcurrencyMax - kDownloadConcurrencyMin,
                step: 1.0,
                onChanged: (value) =>
                    setState(() => selected = value.round()),
              ),
              const SizedBox(height: 4),
              Text(
                'يحدد عدد الحلقات التي يمكن تنزيلها معًا قبل وضع البقية في الانتظار.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop<void>(ctx),
            child: Text(
              l10n.cancel,
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          CustomButton(
            isPrimary: true,
            onPressed: () async {
              await ref
                  .read(generalSettingsProvider.notifier)
                  .setDownloadConcurrency(selected);
              if (ctx.mounted) Navigator.pop<void>(ctx);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    ),
  );
}

String downloadPartsTitle() => 'اتصالات التنزيل';

String downloadPartsSubtitle(int value) {
  final normalized = normalizeDownloadPartPreference(value);
  if (normalized == kDownloadPartsAuto) return 'تلقائي';
  if (normalized == 1) return 'اتصال واحد';
  return '$normalized اتصالات';
}

String _downloadPartsDialogValue(int value) {
  final normalized = normalizeDownloadPartPreference(value);
  if (normalized == kDownloadPartsAuto) return 'تلقائي';
  if (normalized == 1) return 'اتصال واحد';
  return '$normalized اتصالات متوازية';
}

/// 0 is Auto, followed by every manual connection count from 1 through 16.
/// The backend already uses the same range; this changes only the picker UX.
void showDownloadPartsDialog(BuildContext context, WidgetRef ref, int current) {
  final l10n = AppLocalizations.of(context)!;
  var selected = normalizeDownloadPartPreference(current);

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(downloadPartsTitle()),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _downloadPartsDialogValue(selected),
                key: const ValueKey('download-parts-value'),
                style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              CustomSlider(
                key: const ValueKey('download-parts-slider'),
                value: selected.toDouble(),
                min: kDownloadPartsAuto.toDouble(),
                max: kDownloadPartsMax.toDouble(),
                divisions: kDownloadPartsMax - kDownloadPartsAuto,
                step: 1.0,
                onChanged: (value) =>
                    setState(() => selected = value.round()),
              ),
              const SizedBox(height: 4),
              Text(
                selected == kDownloadPartsAuto
                    ? 'تلقائي يختار عدد الاتصالات حسب حجم الملف ودعم الخادم لطلبات Range.'
                    : 'يحدد الحد الأقصى لاتصالات الحلقة الواحدة. التقسيم يعمل فقط عندما يدعم الخادم Range.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop<void>(ctx),
            child: Text(
              l10n.cancel,
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          CustomButton(
            isPrimary: true,
            onPressed: () async {
              await ref
                  .read(generalSettingsProvider.notifier)
                  .setDownloadParallelParts(selected);
              if (ctx.mounted) Navigator.pop<void>(ctx);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    ),
  );
}

String downloadNotificationsTitle() => 'إشعارات التنزيل';

String downloadNotificationsSubtitle(DownloadNotificationPrefs prefs) {
  if (prefs.noneEnabled) return 'معطّلة';
  if (prefs.allEnabled) return 'مفعّلة';
  return 'مخصصة';
}

void showDownloadNotificationsDialog(BuildContext context, WidgetRef ref) {
  var prefs = ref.read(generalSettingsProvider).downloadNotifications;
  final l10n = AppLocalizations.of(context)!;

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> apply(DownloadNotificationPrefs next) async {
          await ref
              .read(generalSettingsProvider.notifier)
              .setDownloadNotificationPrefs(next);
          setState(() => prefs = next);
        }

        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(downloadNotificationsTitle()),
          content: RepaintBoundary(
            key: const ValueKey('download-notifications-dialog'),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_active_rounded),
                    title: const Text('كل الإشعارات'),
                    value: prefs.allEnabled,
                    onChanged: (val) => apply(prefs.copyAll(val)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.play_arrow_rounded),
                    title: const Text('البدء'),
                    value: prefs.running,
                    onChanged: (val) => apply(prefs.copyWith(running: val)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.check_circle_rounded),
                    title: const Text('الانتهاء'),
                    value: prefs.complete,
                    onChanged: (val) => apply(prefs.copyWith(complete: val)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.pause_rounded),
                    title: const Text('الإيقاف'),
                    value: prefs.paused,
                    onChanged: (val) => apply(prefs.copyWith(paused: val)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.cancel_rounded),
                    title: const Text('الإلغاء'),
                    value: prefs.canceled,
                    onChanged: (val) => apply(prefs.copyWith(canceled: val)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.error_outline_rounded),
                    title: const Text('التوقف أو الفشل'),
                    value: prefs.error,
                    onChanged: (val) => apply(prefs.copyWith(error: val)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop<void>(ctx),
              child: Text(
                l10n.close,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Shows a slider to pick the readahead duration from 1 to 20 minutes. Moving
/// the thumb is provisional until Save, matching the other numeric settings.
void showReadaheadDialog(BuildContext context, WidgetRef ref, int current) {
  final l10n = AppLocalizations.of(context)!;
  var selectedMinutes = (current / 60).round().clamp(1, 20).toInt();

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) {
        final selectedSeconds = selectedMinutes * 60;
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(l10n.selectBufferDepth),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatReadahead(selectedSeconds, l10n),
                  key: const ValueKey('buffer-depth-value'),
                  style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                CustomSlider(
                  key: const ValueKey('buffer-depth-slider'),
                  value: selectedMinutes.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  step: 1.0,
                  onChanged: (value) =>
                      setState(() => selectedMinutes = value.round()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop<void>(ctx),
              child: Text(
                l10n.cancel,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            CustomButton(
              isPrimary: true,
              onPressed: () async {
                await ref
                    .read(playerSettingsProvider.notifier)
                    .setReadaheadSeconds(selectedMinutes * 60);
                if (ctx.mounted) Navigator.pop<void>(ctx);
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ),
  );
}

/// Shows a dialog for subtitle size + background settings.
void showSubtitleDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  double size = settings.subtitleSize;
  bool showBackground = settings.subtitleBackgroundColor != 0;

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(l10n.subtitleSettings),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.size(size.toInt())),
                CustomSlider(
                  value: size,
                  min: 10,
                  max: 80,
                  divisions: 70,
                  step: 1.0,
                  onChanged: (v) => setState(() => size = v),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: Text(l10n.background),
                  value: showBackground,
                  onChanged: (v) => setState(() => showBackground = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop<void>(ctx),
              child: Text(
                l10n.cancel,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            CustomButton(
              isPrimary: true,
              onPressed: () {
                final bg = showBackground ? 0x99000000 : 0x00000000;
                ref
                    .read(playerSettingsProvider.notifier)
                    .setSubtitleSettings(size, settings.subtitleColor, bg);
                Navigator.pop<void>(ctx);
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ),
  );
}

/// Shows a dialog to pick the default player (internal or external).
void showDefaultPlayerDialog(
  BuildContext context,
  WidgetRef ref,
  String? currentPlayerId,
) {
  final l10n = AppLocalizations.of(context)!;
  final platformPlayers = ExternalPlayerService.instance
      .getPlayersForPlatform();

  showGlassDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.defaultPlayer),
      content: SingleChildScrollView(
        child: RadioGroup<String?>(
          groupValue: currentPlayerId,
          onChanged: (val) {
            ref.read(playerSettingsProvider.notifier).setPreferredPlayer(val);
            Navigator.pop<void>(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(l10n.internalPlayer),
                subtitle: Text(l10n.builtInPlayer),
                leading: const Radio<String?>(value: null),
                trailing: const Icon(Icons.play_circle_filled_rounded),
                onTap: () {
                  ref
                      .read(playerSettingsProvider.notifier)
                      .setPreferredPlayer(null);
                  Navigator.pop<void>(context);
                },
              ),
              const Divider(),
              ...platformPlayers.map((player) {
                return ListTile(
                  title: Text(player.displayName),
                  leading: Radio<String?>(value: player.id),
                  trailing: Icon(player.icon),
                  onTap: () {
                    ref
                        .read(playerSettingsProvider.notifier)
                        .setPreferredPlayer(player.id);
                    Navigator.pop<void>(context);
                  },
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop<void>(context),
          child: Text(
            l10n.cancel,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Shows a dialog to pick the app theme mode.
void showThemeDialog(
  BuildContext context,
  WidgetRef ref,
  ThemeMode currentTheme,
) {
  final l10n = AppLocalizations.of(context)!;
  showGlassDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.chooseTheme),
      content: RadioGroup<ThemeMode>(
        groupValue: currentTheme,
        onChanged: (val) {
          if (val == null) return;
          ref.read(appThemeModeProvider.notifier).setThemeMode(val);
          Navigator.pop<void>(context);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildThemeOption(l10n.system, ThemeMode.system, () {
                ref
                    .read(appThemeModeProvider.notifier)
                    .setThemeMode(ThemeMode.system);
                Navigator.pop<void>(context);
              }),
              _buildThemeOption(l10n.dark, ThemeMode.dark, () {
                ref
                    .read(appThemeModeProvider.notifier)
                    .setThemeMode(ThemeMode.dark);
                Navigator.pop<void>(context);
              }),
              _buildThemeOption(l10n.light, ThemeMode.light, () {
                ref
                    .read(appThemeModeProvider.notifier)
                    .setThemeMode(ThemeMode.light);
                Navigator.pop<void>(context);
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop<void>(context),
          child: Text(
            l10n.cancel,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Shows a dialog to factory reset.
void showFactoryResetDialog(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final callerContext = context;
  showGlassDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.factoryResetDialogTitle),
      content: Text(l10n.factoryResetDialogContent),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop<void>(dialogContext),
          child: Text(
            l10n.cancel,
            style: TextStyle(
              color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop<void>(dialogContext);
            await runFactoryReset(
              // Clear OAuth credentials (including platform-secure storage)
              // before wiping Hive and preferences. A factory reset must not
              // restore a prior account after the app restarts.
              clearAccountSession: () => ref
                  .read(animeWitcherAccountControllerProvider.notifier)
                  .signOut(),
              clearSecureTokens: () =>
                  ref.read(secureTokenStorageProvider).clearAll(),
              // Deep clean extensions, preferences, and Hive databases.
              clearLocalData: () =>
                  ref.read(settingsRepositoryProvider).deleteAllData(),
            );

            // Restart App - use caller's context; dialog context may be disposed after pop
            if (callerContext.mounted) {
              await AppUtils.restartApp(callerContext);
            }
          },
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          child: Text(l10n.factoryReset),
        ),
      ],
    ),
  );
}

/// Shows a dialog to clear the image & video cache.
void showClearCacheDialog(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final callerContext = context;
  showGlassDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.clearCacheDialogTitle),
      content: Text(l10n.clearCacheDialogContent),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop<void>(dialogContext),
          child: Text(
            l10n.cancel,
            style: TextStyle(
              color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop<void>(dialogContext);
            await ref.read(settingsRepositoryProvider).clearImageVideoCache();
            ref.invalidate(cacheSizeProvider);
            if (callerContext.mounted) {
              ref
                  .read(notificationServiceProvider)
                  .showSuccess(l10n.cacheCleared);
            }
          },
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          child: Text(l10n.clearCacheNow),
        ),
      ],
    ),
  );
}

/// Shows a dialog to toggle the visibility of individual player control
/// buttons. Changes apply live via the player settings notifier.
///
/// The Picture-in-Picture switch ([AppLocalizations.showPip]) is Android-only:
/// it shows or hides the in-player PiP control and gates system PiP auto-enter.
void showPlayerControlsDialog(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(playerSettingsProvider.notifier);
  final settings =
      ref.read(playerSettingsProvider).asData?.value ?? const PlayerSettings();
  final includePip = defaultTargetPlatform == TargetPlatform.android;

  final metadata = [
    if (includePip)
      (icon: Icons.picture_in_picture_alt_rounded, label: l10n.showPip),
    (icon: Icons.aspect_ratio_rounded, label: l10n.showResize),
    (icon: Icons.screen_rotation_rounded, label: l10n.showRotate),
    (icon: Icons.speed_rounded, label: l10n.showPlaybackSpeed),
    (icon: Icons.playlist_play_rounded, label: l10n.showEpisodes),
  ];
  final setters = [
    if (includePip) notifier.setShowPip,
    notifier.setShowResize,
    notifier.setShowRotate,
    notifier.setShowPlaybackSpeed,
    notifier.setShowEpisodes,
  ];
  final values = [
    if (includePip) settings.showPip,
    settings.showResize,
    settings.showRotate,
    settings.showPlaybackSpeed,
    settings.showEpisodes,
  ];

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(l10n.playerControls),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < metadata.length; i++)
                  SwitchListTile(
                    secondary: Icon(metadata[i].icon),
                    title: Text(metadata[i].label),
                    value: values[i],
                    onChanged: (val) {
                      setters[i](val);
                      setState(() => values[i] = val);
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop<void>(ctx),
              child: Text(
                l10n.close,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Picks what playback does when the next episode is filler.
void showFillerBehaviourDialog(BuildContext context, WidgetRef ref) {
  final current =
      ref.read(playerSettingsProvider).asData?.value.fillerBehaviour ??
      FillerBehaviour.note;

  showGlassDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(
        appText(
          context,
          english: 'Skip filler episodes',
          arabic: 'تخطي حلقات الفلر',
        ),
      ),
      content: RadioGroup<FillerBehaviour>(
        groupValue: current,
        onChanged: (value) {
          if (value == null) return;
          ref.read(playerSettingsProvider.notifier).setFillerBehaviour(value);
          Navigator.pop<void>(context);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in FillerBehaviour.values)
              ListTile(
                title: Text(switch (option) {
                  FillerBehaviour.off => appText(
                    context,
                    english: 'Play them',
                    arabic: 'تشغيلها',
                  ),
                  FillerBehaviour.note => appText(
                    context,
                    english: 'Tell me, with a skip button',
                    arabic: 'تنبيهي مع زر تخطي',
                  ),
                  FillerBehaviour.skip => appText(
                    context,
                    english: 'Skip them',
                    arabic: 'تخطيها',
                  ),
                }),
                subtitle: Text(switch (option) {
                  FillerBehaviour.off => appText(
                    context,
                    english: 'Filler is played like any other episode',
                    arabic: 'تُشغّل حلقات الفلر كغيرها',
                  ),
                  FillerBehaviour.note => appText(
                    context,
                    english: 'The next-episode card says so and offers the episode after it',
                    arabic:
                        'تظهر ملاحظة على بطاقة الحلقة التالية مع الانتقال إلى ما بعدها',
                  ),
                  FillerBehaviour.skip => appText(
                    context,
                    english: 'Playback continues at the next story episode',
                    arabic: 'يكمل التشغيل عند أول حلقة من القصة',
                  ),
                }),
                leading: Radio<FillerBehaviour>(value: option),
                onTap: () {
                  ref
                      .read(playerSettingsProvider.notifier)
                      .setFillerBehaviour(option);
                  Navigator.pop<void>(context);
                },
              ),
          ],
        ),
      ),
    ),
  );
}
