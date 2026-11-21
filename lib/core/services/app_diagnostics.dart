import 'dart:io';

import '../account/animewitcher_account_models.dart';

import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'application_log_directory.dart';
import 'download_v2/download_v2_diagnostics.dart';

/// Bounded, always-on application telemetry written locally, never uploaded.
/// Reuses the download logger's field allowlist: no exceptions, URLs, headers,
/// account IDs or arbitrary text can enter app.jsonl.
class AppDiagnostics {
  AppDiagnostics({DownloadDiagnosticsV2? sink, int Function()? clockMillis})
    : _sink =
          sink ??
          FileDownloadDiagnosticsV2(
            enabled: () => true,
            fileName: 'app.jsonl',
            maxBytes: 2 * 1024 * 1024,
            maxFiles: 3,
            directoryProvider: applicationLogDirectory,
            buildIdentityProvider: () async {
              final info = await PackageInfo.fromPlatform();
              return (version: info.version, buildNumber: info.buildNumber);
            },
          ),
      _clockMillis =
          clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final DownloadDiagnosticsV2 _sink;
  final int Function() _clockMillis;
  int? _lastJankAt;
  String _frameScreen = 'other';
  int _suppressedJankCount = 0;
  int _worstSuppressedFrameMs = 0;
  int _worstSuppressedBuildMs = 0;
  int _worstSuppressedRasterMs = 0;
  int _worstSuppressedVsyncMs = 0;
  String _worstSuppressedCause = 'other';
  String _suppressedScreen = 'other';
  static String safeScreen(String route) {
    final lower = route.toLowerCase();
    for (final section in const <String>[
      'player',
      'details',
      'search',
      'library',
      'downloads',
      'settings',
      'manga',
      'home',
      'history',
    ]) {
      if (lower == section ||
          lower.startsWith('/$section') ||
          lower.startsWith('${section}route')) {
        return section;
      }
    }
    return 'other';
  }

  void record(String event, [Map<String, Object?> fields = const {}]) {
    _sink.recordTransport(event, fields);
  }

  /// Flush diagnostics before the user exports the common log folder.
  Future<void> flush() {
    _flushSuppressedJank();
    return switch (_sink) {
      FileDownloadDiagnosticsV2 file => file.flush(),
      _ => Future<void>.value(),
    };
  }

  /// Error text/stack may contain credentials, URLs and personal content.
  /// Record only the exception type and a small allowlist of account error
  /// codes so a deferred nativeSync can be diagnosed without those secrets.
  void recordException(String source, Object error) {
    const safeAccountCodes = {
      'invalid-session',
      'account-not-found',
      'profile-not-found',
      'account-banned',
      'not-signed-in',
      'permission-denied',
      'network-error',
      'requires-recent-login',
      'unauthenticated',
      'invalid-credentials',
      'server-error',
    };
    record('app.exception', {
      'reason': source,
      'errorType': error.runtimeType.toString(),
      if (error is AnimeWitcherAccountException)
        'status': safeAccountCodes.contains(error.code) ? error.code : 'other',
    });
  }

  /// Record only a known screen category, never route arguments or IDs.
  void setCurrentScreen(String route) {
    _frameScreen = safeScreen(route);
  }

  static String _frameCause(int buildMs, int rasterMs) {
    if (buildMs >= 24 && rasterMs >= 24) return 'mixed';
    if (buildMs >= 24) return 'build';
    if (rasterMs >= 24) return 'raster';
    return 'other';
  }

  void _flushSuppressedJank() {
    if (_suppressedJankCount == 0) return;
    record('app.frame.jankSummary', {
      'status': _worstSuppressedCause,
      'action': _suppressedScreen,
      'count': _suppressedJankCount,
      'durationMs': _worstSuppressedFrameMs,
      'buildMs': _worstSuppressedBuildMs,
      'rasterMs': _worstSuppressedRasterMs,
      'vsyncMs': _worstSuppressedVsyncMs,
      'memoryBytes': ProcessInfo.currentRss,
    });
    _suppressedJankCount = 0;
    _worstSuppressedFrameMs = 0;
    _worstSuppressedBuildMs = 0;
    _worstSuppressedRasterMs = 0;
    _worstSuppressedVsyncMs = 0;
    _worstSuppressedCause = 'other';
  }

  /// Frames over ~3x a 60Hz budget are noteworthy. Build/raster breakdown
  /// identifies whether Dart/UI or GPU/compositor is the bottleneck; periodic
  /// summaries preserve stutters inside the 10s sampling window.
  void recordFrameDuration(
    Duration duration, {
    Duration? buildDuration,
    Duration? rasterDuration,
    Duration? vsyncOverhead,
  }) {
    final millis = duration.inMilliseconds;
    if (millis < 50) return;
    final now = _clockMillis();
    final buildMs = buildDuration?.inMilliseconds ?? 0;
    final rasterMs = rasterDuration?.inMilliseconds ?? 0;
    final vsyncMs = vsyncOverhead?.inMilliseconds ?? 0;
    final cause = _frameCause(buildMs, rasterMs);
    if (_lastJankAt != null &&
        now >= _lastJankAt! &&
        now - _lastJankAt! < 10000) {
      _suppressedJankCount++;
      if (millis > _worstSuppressedFrameMs) {
        _worstSuppressedFrameMs = millis;
        _worstSuppressedBuildMs = buildMs;
        _worstSuppressedRasterMs = rasterMs;
        _worstSuppressedVsyncMs = vsyncMs;
        _worstSuppressedCause = cause;
        _suppressedScreen = _frameScreen;
      }
      return;
    }
    _flushSuppressedJank();
    _lastJankAt = now;
    record('app.frame.jank', {
      'status': cause,
      'action': _frameScreen,
      'durationMs': millis,
      'buildMs': buildMs,
      'rasterMs': rasterMs,
      'vsyncMs': vsyncMs,
      'memoryBytes': ProcessInfo.currentRss,
    });
  }

  void recordFrameTimings(List<FrameTiming> timings) {
    for (final frame in timings) {
      recordFrameDuration(
        frame.totalSpan,
        buildDuration: frame.buildDuration,
        rasterDuration: frame.rasterDuration,
        vsyncOverhead: frame.vsyncOverhead,
      );
    }
  }
}

final appDiagnostics = AppDiagnostics();

/// Route names are normalized before logging: no IDs or query parameters.
class AppNavigationDiagnosticsObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    appDiagnostics.setCurrentScreen(route.settings.name ?? '');
    appDiagnostics.record('app.navigation.push', {
      'status': AppDiagnostics.safeScreen(route.settings.name ?? ''),
    });
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    appDiagnostics.setCurrentScreen(previousRoute?.settings.name ?? '');
    appDiagnostics.record('app.navigation.pop', {
      'status': AppDiagnostics.safeScreen(route.settings.name ?? ''),
    });
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    appDiagnostics.setCurrentScreen(newRoute?.settings.name ?? '');
  }
}
