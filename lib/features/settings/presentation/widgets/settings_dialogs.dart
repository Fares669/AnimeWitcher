import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../../../../core/services/external_player_service.dart';
import '../../../../core/navigation/taskbar_destination.dart';
import '../../../../core/storage/settings_repository.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/utils/app_utils.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../player_settings_provider.dart';
import '../general_settings_provider.dart';
import '../../../../core/providers/locale_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import '../cache_provider.dart';

import 'package:skystream/core/utils/localized_text.dart';
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
  final options = visibleTaskbarDestinations(
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

  showDialog<void>(
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

/// Shows a dialog to pick the seek duration.
void showDurationDialog(BuildContext context, WidgetRef ref, int current) {
  final l10n = AppLocalizations.of(context)!;
  final options = <int>[5, 10, 15, 20, 30, 60, 120];

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.selectSeekDuration),
      content: RadioGroup<int>(
        groupValue: current,
        onChanged: (val) {
          if (val == null) return;
          ref.read(playerSettingsProvider.notifier).setSeekDuration(val);
          Navigator.pop<void>(context);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((sec) {
              return ListTile(
                title: Text(formatSeekDuration(sec, l10n)),
                leading: Radio<int>(value: sec),
                onTap: () {
                  ref
                      .read(playerSettingsProvider.notifier)
                      .setSeekDuration(sec);
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

/// Shows a dialog to pick the default resize mode.
void showResizeDialog(BuildContext context, WidgetRef ref, String current) {
  final l10n = AppLocalizations.of(context)!;
  final options = <Map<String, String>>[
    {'label': l10n.fit, 'value': 'Fit'},
    {'label': l10n.zoom, 'value': 'Zoom'},
    {'label': l10n.stretch, 'value': 'Stretch'},
  ];
  showDialog<void>(
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

/// Shows a dialog to pick the readahead duration (5-10 min).
void showReadaheadDialog(BuildContext context, WidgetRef ref, int current) {
  final l10n = AppLocalizations.of(context)!;
  // 1 to 20 minutes in 1-minute steps
  final options = List.generate(20, (i) => (1 + i) * 60);

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.selectBufferDepth),
      content: RadioGroup<int>(
        groupValue: current,
        onChanged: (val) {
          if (val == null) return;
          ref.read(playerSettingsProvider.notifier).setReadaheadSeconds(val);
          Navigator.pop<void>(context);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((sec) {
              return ListTile(
                title: Text(formatReadahead(sec, l10n)),
                leading: Radio<int>(value: sec),
                onTap: () {
                  ref
                      .read(playerSettingsProvider.notifier)
                      .setReadaheadSeconds(sec);
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

/// Shows a dialog for subtitle size + background settings.
void showSubtitleDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  double size = settings.subtitleSize;
  bool showBackground = settings.subtitleBackgroundColor != 0;

  showDialog<void>(
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

  showDialog<void>(
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
  showDialog<void>(
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
  showDialog<void>(
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
            // Deep Clean (Extensions, Prefs, Hive)
            await ref.read(settingsRepositoryProvider).deleteAllData();

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
  showDialog<void>(
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
              ScaffoldMessenger.of(callerContext).showSnackBar(
                SnackBar(content: Text(l10n.cacheCleared)),
              );
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

/// Shows a dialog to pick the application language.
void showLanguageDialog(
  BuildContext context,
  WidgetRef ref,
  Locale currentLocale,
) {
  final l10n = AppLocalizations.of(context)!;

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.selectLanguage),
      content: FutureBuilder<List<Map<String, dynamic>>>(
        future: Future.wait(
          AppLocalizations.supportedLocales.map((locale) async {
            final localL10n = await AppLocalizations.delegate.load(locale);
            return {'label': localL10n.languageName, 'locale': locale};
          }),
        ),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const SizedBox(
              height: 100,
              child: Center(child: AppLoadingIndicator()),
            );
          }

          final options = snapshot.data!;

          return RadioGroup<Locale>(
            groupValue: currentLocale,
            onChanged: (val) {
              if (val == null) return;
              ref.read(localeProvider.notifier).setLocale(val);
              Navigator.pop<void>(context);
            },
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: options.map((opt) {
                  final locale = opt['locale'] as Locale;
                  return ListTile(
                    title: Text(opt['label'] as String),
                    leading: Radio<Locale>(value: locale),
                    onTap: () {
                      ref.read(localeProvider.notifier).setLocale(locale);
                      Navigator.pop<void>(context);
                    },
                  );
                }).toList(),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _SocialButton extends StatelessWidget {
  final String svgUrl;
  final Color color;
  final VoidCallback onTap;

  const _SocialButton({
    required this.svgUrl,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: color.withValues(alpha: 0.15),
      shape: const CircleBorder(),
      child: IconButton(
        icon: SvgPicture.network(
          svgUrl,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          width: 24,
          height: 24,
          placeholderBuilder: (context) => AppLoadingIndicator(
            color: color.withValues(alpha: 0.5),
            constraints: BoxConstraints.tight(const Size(24, 24)),
          ),
        ),
        onPressed: onTap,
        tooltip: l10n.openLink,
      ),
    );
  }
}

/// Shows a dialog to toggle the visibility of individual player control
/// buttons. Changes apply live via the player settings notifier.
void showPlayerControlsDialog(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(playerSettingsProvider.notifier);
  final settings =
      ref.read(playerSettingsProvider).asData?.value ?? const PlayerSettings();

  final metadata = [
    (icon: Icons.picture_in_picture_alt_rounded, label: l10n.showPip),
    (icon: Icons.aspect_ratio_rounded, label: l10n.showResize),
    (icon: Icons.screen_rotation_rounded, label: l10n.showRotate),
    (icon: Icons.speed_rounded, label: l10n.showPlaybackSpeed),
    (icon: Icons.playlist_play_rounded, label: l10n.showEpisodes),
  ];
  final setters = [
    notifier.setShowPip,
    notifier.setShowResize,
    notifier.setShowRotate,
    notifier.setShowPlaybackSpeed,
    notifier.setShowEpisodes,
  ];
  final values = [
    settings.showPip,
    settings.showResize,
    settings.showRotate,
    settings.showPlaybackSpeed,
    settings.showEpisodes,
  ];

  showDialog<void>(
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


