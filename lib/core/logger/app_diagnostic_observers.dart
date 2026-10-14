import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'app_diagnostics.dart';

/// Restore consent off the launch path; no pre-consent events are buffered.
Future<void> restoreAppDiagnosticPreference(
  bool enabled, {
  required Stopwatch startupTimer,
  AppDiagnostics? diagnostics,
}) async {
  final log = diagnostics ?? appDiagnostics;
  final storageReadyMs = startupTimer.elapsedMilliseconds;
  try {
    await log.setEnabled(enabled);
    unawaited(recordAppDiagnosticMetadata(diagnostics: log));
    log.record(
      'startup_phase',
      fields: {'phase': 'storage_ready', 'duration_ms': storageReadyMs},
    );
  } catch (_) {
    // Optional log storage cannot prevent the app from becoming ready.
  }
}

/// Build metadata only; package names and device identifiers stay out of logs.
Future<void> recordAppDiagnosticMetadata({AppDiagnostics? diagnostics}) async {
  final log = diagnostics ?? appDiagnostics;
  if (!log.enabled) return;
  try {
    final info = await PackageInfo.fromPlatform().timeout(
      const Duration(seconds: 2),
    );
    final version = info.version.split('.');
    log.record(
      'app_metadata',
      fields: {
        if (version.isNotEmpty) 'version_major': int.tryParse(version[0]),
        if (version.length > 1) 'version_minor': int.tryParse(version[1]),
        if (version.length > 2) 'version_patch': int.tryParse(version[2]),
        'build': int.tryParse(info.buildNumber),
        'platform': switch (defaultTargetPlatform) {
          TargetPlatform.android => 'android',
          TargetPlatform.iOS => 'ios',
          TargetPlatform.macOS => 'macos',
          TargetPlatform.windows => 'windows',
          TargetPlatform.linux => 'linux',
          TargetPlatform.fuchsia => 'fuchsia',
        },
        'build_mode': kReleaseMode
            ? 'release'
            : (kProfileMode ? 'profile' : 'debug'),
      },
    );
  } catch (_) {
    // Plugin metadata is optional and must never delay app startup or opt-in.
  }
}

/// Adds diagnostics in the binding's existing zone without handling a crash.
void installAppDiagnosticErrorHandlers({AppDiagnostics? diagnostics}) {
  final log = diagnostics ?? appDiagnostics;
  final flutterReporter = FlutterError.onError;
  FlutterError.onError = (details) {
    log.recordError('flutter_error', details.exception, details.stack);
    flutterReporter?.call(details);
  };
  final platformReporter = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    log.recordError('platform_error', error, stack);
    return platformReporter?.call(error, stack) ?? false;
  };
}

/// Families can include private arguments in their names and toString output.
final class AppDiagnosticProviderObserver extends ProviderObserver {
  AppDiagnosticProviderObserver({AppDiagnostics? diagnostics})
    : _diagnostics = diagnostics ?? appDiagnostics;

  final AppDiagnostics _diagnostics;

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    _diagnostics.recordError(
      'provider_error',
      error,
      stackTrace,
      fields: const {'provider': 'riverpod'},
    );
  }
}

/// Observe caught errors without copying Talker's messages or storage keys.
class AppDiagnosticTalkerObserver extends TalkerObserver {
  AppDiagnosticTalkerObserver({AppDiagnostics? diagnostics})
    : _diagnostics = diagnostics ?? appDiagnostics;

  final AppDiagnostics _diagnostics;

  void _record(TalkerData data) {
    final error = data.error ?? data.exception;
    if (error != null) {
      _diagnostics.recordError('service_error', error, data.stackTrace);
    }
  }

  @override
  void onError(TalkerError err) => _record(err);

  @override
  void onException(TalkerException err) => _record(err);

  @override
  void onLog(TalkerData log) {
    if (log.logLevel == LogLevel.error || log.logLevel == LogLevel.critical) {
      _record(log);
    }
  }
}

String _routeCategory(String routePattern) => switch (routePattern) {
  '/home' => 'home',
  '/search' => 'search',
  '/library' => 'library',
  '/downloads' => 'downloads',
  '/settings' => 'settings',
  '/manga' => 'manga',
  '/details' => 'details',
  '/manga-details' => 'manga_details',
  '/manga-reader' => 'manga_reader',
  '/player' => 'player',
  '/view-all' => 'view_all',
  _ => 'other',
};

/// Reads only the configured route pattern, never the URI or route extras.
VoidCallback observeDiagnosticNavigation(
  GoRouter router, {
  AppDiagnostics? diagnostics,
}) {
  final log = diagnostics ?? appDiagnostics;
  String? previousCategory;
  void recordRoute() {
    final configuration = router.routerDelegate.currentConfiguration;
    if (configuration.isEmpty) return;
    final category = _routeCategory(configuration.last.route.path);
    if (category == previousCategory) return;
    previousCategory = category;
    log.record('navigation', fields: {'route': category});
  }

  router.routerDelegate.addListener(recordRoute);
  recordRoute();
  return () => router.routerDelegate.removeListener(recordRoute);
}
