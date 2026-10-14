import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/stream_source_preferences.dart';
import '../../../core/logger/app_diagnostics.dart';
import '../../../core/logger/app_diagnostic_observers.dart';
import '../../../core/navigation/taskbar_destination.dart';
import '../../../core/services/download_concurrency.dart';
import '../../../core/services/download_continued_processing_service.dart';
import '../../../core/services/download_parallel.dart';
import '../../../core/services/download_v2/background_downloader_gateway.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

final appDiagnosticsProvider = Provider<AppDiagnostics>(
  (ref) => appDiagnostics,
);

class GeneralSettings {
  final bool appDiagnosticLog;
  final bool downloadDiagnosticLog;
  final String defaultHomeScreen;
  final bool alwaysOnTop;
  final List<String> taskbarOrder;
  final Set<String> hiddenTaskbarItems;
  final int downloadConcurrency;
  final int downloadParallelParts;
  final DownloadNotificationPrefs downloadNotifications;
  final bool autoSelectStreamSource;
  final List<String> streamServerPriority;
  final List<String> streamQualityPriority;

  const GeneralSettings({
    this.appDiagnosticLog = false,
    this.downloadDiagnosticLog = false,
    this.defaultHomeScreen = '/home',
    this.alwaysOnTop = false,
    this.taskbarOrder = defaultTaskbarOrderIds,
    this.hiddenTaskbarItems = const <String>{'manga'},
    this.downloadConcurrency = kDownloadConcurrencyDefault,
    this.downloadParallelParts = kDownloadPartsAuto,
    this.downloadNotifications = const DownloadNotificationPrefs(),
    this.autoSelectStreamSource = false,
    this.streamServerPriority = defaultStreamServerPriority,
    this.streamQualityPriority = defaultStreamQualityPriority,
  });

  GeneralSettings copyWith({
    bool? appDiagnosticLog,
    bool? downloadDiagnosticLog,
    String? defaultHomeScreen,
    bool? alwaysOnTop,
    List<String>? taskbarOrder,
    Set<String>? hiddenTaskbarItems,
    int? downloadConcurrency,
    int? downloadParallelParts,
    DownloadNotificationPrefs? downloadNotifications,
    bool? autoSelectStreamSource,
    List<String>? streamServerPriority,
    List<String>? streamQualityPriority,
  }) {
    return GeneralSettings(
      appDiagnosticLog: appDiagnosticLog ?? this.appDiagnosticLog,
      downloadDiagnosticLog:
          downloadDiagnosticLog ?? this.downloadDiagnosticLog,
      defaultHomeScreen: defaultHomeScreen ?? this.defaultHomeScreen,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      taskbarOrder: taskbarOrder ?? this.taskbarOrder,
      hiddenTaskbarItems: hiddenTaskbarItems ?? this.hiddenTaskbarItems,
      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
      downloadParallelParts:
          downloadParallelParts ?? this.downloadParallelParts,
      downloadNotifications:
          downloadNotifications ?? this.downloadNotifications,
      autoSelectStreamSource:
          autoSelectStreamSource ?? this.autoSelectStreamSource,
      streamServerPriority:
          streamServerPriority ?? this.streamServerPriority,
      streamQualityPriority:
          streamQualityPriority ?? this.streamQualityPriority,
    );
  }
}

@Riverpod(keepAlive: true)
class GeneralSettingsNotifier extends _$GeneralSettingsNotifier {
  @override
  GeneralSettings build() {
    final repository = ref.watch(settingsRepositoryProvider);
    final order = normalizeTaskbarOrder(repository.getTaskbarOrder())
        .map((destination) => destination.id)
        .toList(growable: false);
    final hidden = normalizeHiddenTaskbarItems(
      repository.getHiddenTaskbarItems(),
    );

    final storedServers = repository.getPlayerSetting<dynamic>(
      'stream_source_server_priority',
    );
    final storedQualities = repository.getPlayerSetting<dynamic>(
      'stream_source_quality_priority',
    );

    return GeneralSettings(
      appDiagnosticLog: repository.getAppDiagnosticLog(),
      downloadDiagnosticLog: repository.getDownloadDiagnosticLog(),
      defaultHomeScreen: resolveInitialTaskbarRoute(
        repository.getDefaultHomeScreen(),
        order,
        hidden,
      ),
      alwaysOnTop: repository.isAlwaysOnTop(),
      taskbarOrder: order,
      hiddenTaskbarItems: hidden,
      downloadConcurrency: repository.getDownloadConcurrency(),
      downloadParallelParts: repository.getDownloadParallelParts(),
      downloadNotifications: repository.getDownloadNotificationPrefs(),
      autoSelectStreamSource:
          repository.getPlayerSetting<bool>(
            'stream_source_auto_select',
            defaultValue: false,
          ) ??
          false,
      streamServerPriority: normalizeStreamPriority(
        storedServers is Iterable ? storedServers : null,
        defaultStreamServerPriority,
      ),
      streamQualityPriority: normalizeStreamPriority(
        storedQualities is Iterable ? storedQualities : null,
        defaultStreamQualityPriority,
      ),
    );
  }

  Future<void> setAppDiagnosticLog(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    if (!enabled) {
      await ref.read(appDiagnosticsProvider).setEnabled(false);
      state = state.copyWith(appDiagnosticLog: false);
      await repository.setAppDiagnosticLog(false);
      return;
    }
    final previous = state.appDiagnosticLog;
    await repository.setAppDiagnosticLog(enabled);
    try {
      await ref.read(appDiagnosticsProvider).setEnabled(enabled);
    } catch (_) {
      await repository.setAppDiagnosticLog(previous);
      rethrow;
    }
    state = state.copyWith(appDiagnosticLog: enabled);
    unawaited(
      recordAppDiagnosticMetadata(
        diagnostics: ref.read(appDiagnosticsProvider),
      ),
    );
  }

  Future<void> setDownloadDiagnosticLog(bool enabled) async {
    await ref.read(settingsRepositoryProvider).setDownloadDiagnosticLog(enabled);
    await configureNativeDownloadDiagnosticLog(enabled);
    state = state.copyWith(downloadDiagnosticLog: enabled);
  }

  Future<void> setDefaultHomeScreen(String path) async {
    final repository = ref.read(settingsRepositoryProvider);
    final resolved = resolveInitialTaskbarRoute(
      path,
      state.taskbarOrder,
      state.hiddenTaskbarItems,
    );
    await repository.setDefaultHomeScreen(resolved);
    state = state.copyWith(defaultHomeScreen: resolved);
  }

  Future<void> setTaskbarPreferences(
    List<String> order,
    Set<String> hidden,
  ) async {
    final repository = ref.read(settingsRepositoryProvider);
    final normalizedOrder = normalizeTaskbarOrder(order)
        .map((destination) => destination.id)
        .toList(growable: false);
    final normalizedHidden = normalizeHiddenTaskbarItems(hidden);
    final resolvedDefault = resolveInitialTaskbarRoute(
      state.defaultHomeScreen,
      normalizedOrder,
      normalizedHidden,
    );

    await Future.wait<void>([
      repository.setTaskbarOrder(normalizedOrder),
      repository.setHiddenTaskbarItems(normalizedHidden),
      if (resolvedDefault != state.defaultHomeScreen)
        repository.setDefaultHomeScreen(resolvedDefault),
    ]);

    state = state.copyWith(
      taskbarOrder: normalizedOrder,
      hiddenTaskbarItems: normalizedHidden,
      defaultHomeScreen: resolvedDefault,
    );
  }

  /// Whether manga has a tab of its own in the navigation.
  bool get mangaHasOwnTab =>
      !state.hiddenTaskbarItems.contains(TaskbarDestination.manga.id);

  /// Gives manga its own tab, after search, or takes it away again. Saving
  /// the order with manga in it is what keeps the tab once shown.
  Future<void> setMangaTab(bool show) {
    final order = List<String>.of(state.taskbarOrder);
    // The loaded order always has manga, appended at the end when it was
    // never saved; only a saved place for it is the viewer's own.
    final placed = ref
        .read(settingsRepositoryProvider)
        .getTaskbarOrder()
        .contains(TaskbarDestination.manga.id);
    if (!placed) {
      order.remove(TaskbarDestination.manga.id);
      final searchAt = order.indexOf(TaskbarDestination.search.id);
      order.insert(
        searchAt < 0 ? order.length : searchAt + 1,
        TaskbarDestination.manga.id,
      );
    }
    final hidden = Set<String>.of(state.hiddenTaskbarItems);
    if (show) {
      hidden.remove(TaskbarDestination.manga.id);
    } else {
      hidden.add(TaskbarDestination.manga.id);
    }
    return setTaskbarPreferences(order, hidden);
  }

  Future<void> setAutoSelectStreamSource(bool enabled) async {
    await ref
        .read(settingsRepositoryProvider)
        .setPlayerSetting('stream_source_auto_select', enabled);
    state = state.copyWith(autoSelectStreamSource: enabled);
  }

  Future<void> setStreamServerPriority(List<String> order) async {
    final normalized = normalizeStreamPriority(
      order,
      defaultStreamServerPriority,
    );
    await ref
        .read(settingsRepositoryProvider)
        .setPlayerSetting('stream_source_server_priority', normalized);
    state = state.copyWith(streamServerPriority: normalized);
  }

  Future<void> setStreamQualityPriority(List<String> order) async {
    final normalized = normalizeStreamPriority(
      order,
      defaultStreamQualityPriority,
    );
    await ref
        .read(settingsRepositoryProvider)
        .setPlayerSetting('stream_source_quality_priority', normalized);
    state = state.copyWith(streamQualityPriority: normalized);
  }

  Future<void> setAlwaysOnTop(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setAlwaysOnTop(enabled);
    state = state.copyWith(alwaysOnTop: enabled);
  }

  /// Persists the logical episode cap without constructing the legacy
  /// downloader. Download Manager V2 owns applying this preference to V2
  /// admission; the package remains the transport authority for admitted work.
  Future<void> setDownloadConcurrency(int value) async {
    final normalized = clampDownloadConcurrency(value);
    await ref
        .read(settingsRepositoryProvider)
        .setDownloadConcurrency(normalized);
    state = state.copyWith(downloadConcurrency: normalized);
  }

  Future<void> setDownloadParallelParts(int value) async {
    final normalized = normalizeDownloadPartPreference(value);
    await ref
        .read(settingsRepositoryProvider)
        .setDownloadParallelParts(normalized);
    state = state.copyWith(downloadParallelParts: normalized);
  }

  Future<void> setDownloadNotificationPrefs(
    DownloadNotificationPrefs prefs,
  ) async {
    await ref
        .read(settingsRepositoryProvider)
        .setDownloadNotificationPrefs(prefs);
    await configurePackageNotificationsV2(FileDownloader(), prefs);
    state = state.copyWith(downloadNotifications: prefs);
  }
}

/// Whether manga has a tab of its own, for screens that move manga there.
/// Settings that cannot load (a screen shown on its own, in a test) mean no
/// tab, which is also the default.
final mangaHasOwnTabProvider = Provider<bool>((ref) {
  try {
    return !ref
        .watch(generalSettingsProvider)
        .hiddenTaskbarItems
        .contains(TaskbarDestination.manga.id);
  } catch (_) {
    return false;
  }
});
