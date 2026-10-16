import 'dart:io' show HttpDate, HttpException;
import 'dart:math' as math;

const Duration kDownloadRetryBaseDelay = Duration(milliseconds: 250);
const Duration kDownloadRetryMaxDelay = Duration(seconds: 30);

final math.Random _downloadRetryRandom = math.Random();
final RegExp _retryAfterSecondsPattern = RegExp(r'^\d+$');
final RegExp _rfc850DatePattern = RegExp(
  r'^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), '
  r'(\d{2})-([A-Za-z]{3})-(\d{2}|\d{4}) (\d{2}:\d{2}:\d{2}) GMT$',
);
final RegExp _asctimeDatePattern = RegExp(
  r'^([A-Za-z]{3}) ([A-Za-z]{3}) ([ \d]\d) (\d{2}:\d{2}:\d{2}) (\d{4})$',
);
const int _maxDurationMicroseconds = 0x7FFFFFFFFFFFFFFF;

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
  String? responseDate,
  Duration baseDelay = kDownloadRetryBaseDelay,
  DateTime? now,
  double? jitterUnit,
}) {
  final header = retryAfter?.trim() ?? '';
  if (_retryAfterSecondsPattern.hasMatch(header)) {
    final seconds = BigInt.parse(header);
    final maxSeconds = BigInt.from(
      _maxDurationMicroseconds ~/ Duration.microsecondsPerSecond,
    );
    return seconds > maxSeconds
        ? const Duration(microseconds: _maxDurationMicroseconds)
        : Duration(seconds: seconds.toInt());
  }

  if (header.isNotEmpty) {
    final referenceTime = now ?? DateTime.now();
    final deadline = _parseRetryAfterDate(header, referenceTime.toUtc());
    if (deadline != null) {
      var delay = deadline.difference(referenceTime);
      final serverTime = responseDate == null
          ? null
          : _parseRetryAfterDate(responseDate.trim(), referenceTime.toUtc());
      if (serverTime != null) {
        // A fast device clock must not shorten the server-requested interval.
        final serverDelay = deadline.difference(serverTime);
        if (serverDelay > delay) delay = serverDelay;
      }
      return delay.isNegative ? Duration.zero : delay;
    }
  }

  final maxMicros = kDownloadRetryMaxDelay.inMicroseconds;
  final baseMicros = baseDelay.inMicroseconds.clamp(0, maxMicros);
  // Even a one-microsecond base reaches the cap after 25 doublings.
  final shift = retryIndex.clamp(0, 25);
  final backoffMicros = math.min(baseMicros * (1 << shift), maxMicros);
  final clampedUnit = (jitterUnit ?? _downloadRetryRandom.nextDouble()).clamp(
    0.0,
    1.0,
  );
  // ±20% jitter prevents several multipart children from retrying in lockstep.
  final factor = 0.8 + (clampedUnit * 0.4);
  final jitteredMicros = (backoffMicros * factor).round();
  return Duration(microseconds: math.min(jitteredMicros, maxMicros));
}

DateTime? _parseRetryAfterDate(String value, DateTime now) {
  try {
    final rfc850 = _rfc850DatePattern.firstMatch(value);
    final asctime = _asctimeDatePattern.firstMatch(value);
    if (rfc850 != null) {
      String withYear(int year) =>
          '${rfc850[1]!.substring(0, 3)}, ${rfc850[2]} ${rfc850[3]} '
          '${year.toString().padLeft(4, '0')} ${rfc850[5]} GMT';
      var year = int.parse(rfc850[4]!);
      if (rfc850[4]!.length == 2) {
        // RFC 9110: a two-digit year cannot be more than 50 years ahead.
        final cutoff = DateTime.utc(
          now.year + 50,
          now.month,
          now.day,
          now.hour,
          now.minute,
          now.second,
          now.millisecond,
          now.microsecond,
        );
        year += (cutoff.year ~/ 100) * 100;
        if (HttpDate.parse(withYear(year)).isAfter(cutoff)) year -= 100;
      }
      value = withYear(year);
    } else if (asctime != null) {
      value =
          '${asctime[1]}, ${asctime[3]!.trim().padLeft(2, '0')} '
          '${asctime[2]} ${asctime[5]} ${asctime[4]} GMT';
    }
    final parsed = HttpDate.parse(value);
    // Round-tripping rejects normalized invalid fields and wrong weekdays.
    return HttpDate.format(parsed) == value ? parsed : null;
  } on HttpException {
    return null;
  } on FormatException {
    return null;
  }
}

DownloadRetryDecision planDownloadFailure({
  int? statusCode,
  bool connectionFailure = false,
  bool noSpaceLeft = false,
  bool canRefreshUrl = false,
  bool refreshOn404 = true,
  int retryIndex = 0,
  String? retryAfter,
  String? responseDate,
  Duration baseDelay = kDownloadRetryBaseDelay,
  DateTime? now,
  double? jitterUnit,
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
        responseDate: responseDate,
        baseDelay: baseDelay,
        now: now,
        jitterUnit: jitterUnit,
      ),
    );
  }
  return const DownloadRetryDecision(DownloadFailureAction.park);
}
