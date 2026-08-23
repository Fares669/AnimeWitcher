import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/navigation/taskbar_destination.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

class GeneralSettings {
  final String defaultHomeScreen;
  final bool alwaysOnTop;
  final List<String> taskbarOrder;
  final Set<String> hiddenTaskbarItems;

  const GeneralSettings({
    this.defaultHomeScreen = '/home',
    this.alwaysOnTop = false,
    this.taskbarOrder = defaultTaskbarOrderIds,
    this.hiddenTaskbarItems = const <String>{},
  });

  GeneralSettings copyWith({
    String? defaultHomeScreen,
    bool? alwaysOnTop,
    List<String>? taskbarOrder,
    Set<String>? hiddenTaskbarItems,
  }) {
    return GeneralSettings(
      defaultHomeScreen: defaultHomeScreen ?? this.defaultHomeScreen,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      taskbarOrder: taskbarOrder ?? this.taskbarOrder,
      hiddenTaskbarItems: hiddenTaskbarItems ?? this.hiddenTaskbarItems,
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
      defaultHomeScreen: resolveInitialTaskbarRoute(
        repository.getDefaultHomeScreen(),
        order,
        hidden,
      ),
      alwaysOnTop: repository.isAlwaysOnTop(),
      taskbarOrder: order,
      hiddenTaskbarItems: hidden,
    );
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

}
