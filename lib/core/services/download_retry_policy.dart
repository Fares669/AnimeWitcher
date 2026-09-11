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
