import 'dart:math' as math;

const Duration kDownloadRetryBaseDelay = Duration(milliseconds: 250);
const Duration kDownloadRetryMaxDelay = Duration(seconds: 30);

enum DownloadFailureAction {
  retry,
  waitForNetwork,
  refreshUrl,
  reconcileRange,
  stopNoSpace,
  park,
}

class DownloadRetryDecision {
  const DownloadRetryDecision(this.action, {this.delay = Duration.zero});

  final DownloadFailureAction action;
  final Duration delay;

  bool get shouldRetry => action == DownloadFailureAction.retry;
}

/// Application action to take when the transfer itself is plugin-owned.
///
/// Generic transport failures deliberately have no AnimeWitcher retry action:
/// background_downloader owns its retry/backoff/reconnect lifecycle. Only
/// application-specific boundaries escape the plugin executor.
enum PluginTransportAction {
  leaveToPlugin,
  waitForNetwork,
  refreshUrl,
  reconcileRange,
  stopNoSpace,
  park,
}

class PluginFailureDecision {
  const PluginFailureDecision(this.transportAction);

  final PluginTransportAction transportAction;
}

bool isRetryableDownloadStatus(int? statusCode) {
  if (statusCode == null) return false;
  if (statusCode == 408 || statusCode == 425 || statusCode == 429) return true;
  return statusCode >= 500 && statusCode <= 599;
}

bool isDownloadUrlRefreshStatus(int? statusCode, {bool include404 = true}) =>
    statusCode == 401 || statusCode == 403 || (include404 && statusCode == 404);

Duration downloadRetryDelay({
  required int retryIndex,
  String? retryAfter,
  double jitterUnit = 0.5,
}) {
  final retryAfterSeconds = int.tryParse(retryAfter?.trim() ?? '');
  if (retryAfterSeconds != null && retryAfterSeconds >= 0) {
    return Duration(
      seconds: retryAfterSeconds.clamp(0, kDownloadRetryMaxDelay.inSeconds),
    );
  }

  final shift = retryIndex.clamp(0, 6);
  final baseMicros = kDownloadRetryBaseDelay.inMicroseconds * (1 << shift);
  final clampedUnit = jitterUnit.clamp(0.0, 1.0);
  // ±20% jitter prevents several multipart children from retrying in lockstep.
  final factor = 0.8 + (clampedUnit * 0.4);
  final jitteredMicros = (baseMicros * factor).round();
  return Duration(
    microseconds: math.min(
      jitteredMicros,
      kDownloadRetryMaxDelay.inMicroseconds,
    ),
  );
}

/// Planner for background_downloader-owned transfers.
///
/// 5xx/408/425/429 and transient connection errors are intentionally left to
/// the plugin while connectivity still exists. AnimeWitcher intervenes only
/// for source refresh, resource/range reconciliation, storage exhaustion,
/// explicit offline parking, and permanent application-level failures.
PluginFailureDecision planPluginFailure({
  int? statusCode,
  bool connectionFailure = false,
  bool networkAvailable = true,
  bool noSpaceLeft = false,
  bool canRefreshUrl = false,
  bool refreshOn404 = true,
}) {
  if (noSpaceLeft) {
    return const PluginFailureDecision(PluginTransportAction.stopNoSpace);
  }
  if (statusCode == 416) {
    return const PluginFailureDecision(PluginTransportAction.reconcileRange);
  }
  if (canRefreshUrl &&
      isDownloadUrlRefreshStatus(statusCode, include404: refreshOn404)) {
    return const PluginFailureDecision(PluginTransportAction.refreshUrl);
  }
  if (connectionFailure && !networkAvailable) {
    return const PluginFailureDecision(PluginTransportAction.waitForNetwork);
  }
  if (connectionFailure || isRetryableDownloadStatus(statusCode)) {
    return const PluginFailureDecision(PluginTransportAction.leaveToPlugin);
  }
  return const PluginFailureDecision(PluginTransportAction.park);
}

/// Legacy/exceptional Range retry planner.
///
/// New plugin-owned tasks must use [planPluginFailure]. This backoff remains
/// only for PR #231 legacy multipart workers and the verified changed-source
/// Range fallback where AnimeWitcher still owns the HTTP connection itself.
DownloadRetryDecision planDownloadFailure({
  int? statusCode,
  bool connectionFailure = false,
  bool noSpaceLeft = false,
  bool canRefreshUrl = false,
  bool refreshOn404 = true,
  int retryIndex = 0,
  String? retryAfter,
  double jitterUnit = 0.5,
}) {
  if (noSpaceLeft) {
    return const DownloadRetryDecision(DownloadFailureAction.stopNoSpace);
  }
  if (statusCode == 416) {
    return const DownloadRetryDecision(DownloadFailureAction.reconcileRange);
  }
  if (canRefreshUrl &&
      isDownloadUrlRefreshStatus(statusCode, include404: refreshOn404)) {
    return const DownloadRetryDecision(DownloadFailureAction.refreshUrl);
  }
  if (connectionFailure) {
    return const DownloadRetryDecision(DownloadFailureAction.waitForNetwork);
  }
  if (isRetryableDownloadStatus(statusCode)) {
    return DownloadRetryDecision(
      DownloadFailureAction.retry,
      delay: downloadRetryDelay(
        retryIndex: retryIndex,
        retryAfter: retryAfter,
        jitterUnit: jitterUnit,
      ),
    );
  }
  return const DownloadRetryDecision(DownloadFailureAction.park);
}
