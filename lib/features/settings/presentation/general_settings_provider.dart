import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/navigation/taskbar_destination.dart';
import '../../../core/services/download_concurrency.dart';
import '../../../core/services/download_parallel.dart';
import '../../../core/services/download_service.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

class GeneralSettings {
  final bool downloadDiagnosticLog;
  final String defaultHomeScreen;
  final bool alwaysOnTop;
  final List<String> taskbarOrder;
  final Set<String> hiddenTaskbarItems;
  final int downloadConcurrency;
  final int downloadParallelParts;
  final DownloadNotificationPrefs downloadNotifications;

  const GeneralSettings({
    this.downloadDiagnosticLog = false,
    this.defaultHomeScreen = '/home',
    this.alwaysOnTop = false,
    this.taskbarOrder = defaultTaskbarOrderIds,
    this.hiddenTaskbarItems = const <String>{},
    this.downloadConcurrency = kDownloadConcurrencyDefault,
    this.downloadParallelParts = kDownloadPartsAuto,
    this.downloadNotifications = const DownloadNotificationPrefs(),
  });

  GeneralSettings copyWith({
    bool? downloadDiagnosticLog,
    String? defaultHomeScreen,
    bool? alwaysOnTop,
    List<String>? taskbarOrder,
    Set<String>? hiddenTaskbarItems,
    int? downloadConcurrency,
    int? downloadParallelParts,
    DownloadNotificationPrefs? downloadNotifications,
  }) {
    return GeneralSettings(
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

    return GeneralSettings(
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
    );
  }

  Future<void> setDownloadDiagnosticLog(bool enabled) async {
    await ref.read(settingsRepositoryProvider).setDownloadDiagnosticLog(enabled);
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

  Future<void> setAlwaysOnTop(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setAlwaysOnTop(enabled);
    state = state.copyWith(alwaysOnTop: enabled);
  }

  /// Writes the 1–10 cap and reconfigures the live downloader immediately.
  Future<void> setDownloadConcurrency(int value) async {
    await ref
        .read(downloadServiceProvider)
        .applyQueueSettings(maxConcurrent: value);
    state = state.copyWith(
      downloadConcurrency: clampDownloadConcurrency(value),
    );
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
    await ref.read(downloadServiceProvider).applyNotificationSettings(prefs);
    state = state.copyWith(downloadNotifications: prefs);
  }
}
