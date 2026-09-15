import 'dart:collection';

const Duration kDownloadTelemetryWindow = Duration(seconds: 4);
const Duration kDownloadTelemetryMinimumWindow = Duration(milliseconds: 750);
const Duration kDownloadTelemetryStaleAfter = Duration(seconds: 3);

class DownloadTelemetryReading {
  const DownloadTelemetryReading({
    required this.transferredBytes,
    required this.expectedBytes,
    required this.speedBytesPerSecond,
    required this.timeRemaining,
  });

  final int transferredBytes;
  final int expectedBytes;
  final double speedBytesPerSecond;
  final Duration timeRemaining;
}

/// Sampling estimator retained for legacy/custom Range execution.
/// Plugin-owned Transfer updates must use background_downloader speed/ETA
/// directly instead of feeding them through this smoothing window.
class DownloadTelemetryEstimator {
  DownloadTelemetryEstimator({
    this.window = kDownloadTelemetryWindow,
    this.minimumWindow = kDownloadTelemetryMinimumWindow,
    this.staleAfter = kDownloadTelemetryStaleAfter,
    this.maxSamples = 32,
  });

  final Duration window;
  final Duration minimumWindow;
  final Duration staleAfter;
  final int maxSamples;

  final Map<String, _TelemetryState> _states = <String, _TelemetryState>{};

  int expectedBytesFor(String taskId) => _states[taskId]?.expectedBytes ?? -1;

  int transferredBytesFor(String taskId) =>
      _states[taskId]?.transferredBytes ?? 0;

  void seed(
    String taskId, {
    int transferredBytes = 0,
    int expectedBytes = -1,
    DateTime? now,
  }) {
    if (taskId.isEmpty) return;
    final state = _states.putIfAbsent(taskId, _TelemetryState.new);
    if (expectedBytes > 0) state.expectedBytes = expectedBytes;
    if (transferredBytes > state.transferredBytes) {
      state.transferredBytes = transferredBytes;
      final point = _BytePoint(now ?? DateTime.now(), transferredBytes);
      state.byteSamples
        ..clear()
        ..add(point);
      state.lastByteAt = point.at;
    }
  }

  DownloadTelemetryReading observeProgress({
    required String taskId,
    required double progress,
    int expectedBytes = -1,
    double fallbackSpeedBytesPerSecond = 0,
    DateTime? now,
  }) {
    final normalized = progress.clamp(0.0, 1.0).toDouble();
    final knownExpected = expectedBytes > 0
        ? expectedBytes
        : expectedBytesFor(taskId);
    final transferred = knownExpected > 0
        ? (knownExpected * normalized).round()
        : null;
    return observe(
      taskId: taskId,
      transferredBytes: transferred,
      expectedBytes: knownExpected,
      fallbackSpeedBytesPerSecond: fallbackSpeedBytesPerSecond,
      now: now,
    );
  }

  DownloadTelemetryReading observe({
    required String taskId,
    int? transferredBytes,
    int expectedBytes = -1,
    double fallbackSpeedBytesPerSecond = 0,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final state = _states.putIfAbsent(taskId, _TelemetryState.new);
    if (expectedBytes > 0) state.expectedBytes = expectedBytes;

    if (transferredBytes != null && transferredBytes >= 0) {
      final incoming = transferredBytes;
      // Progress/URLSession callbacks should be monotonic. If one late callback
      // regresses, keep the durable high-water mark instead of producing a
      // negative or absurd throughput sample.
      if (incoming >= state.transferredBytes &&
          (incoming > state.transferredBytes || state.byteSamples.isEmpty)) {
        state.transferredBytes = incoming;
        state.byteSamples.add(_BytePoint(timestamp, incoming));
        state.lastByteAt = timestamp;
      }
    }

    final fallback = _finitePositive(fallbackSpeedBytesPerSecond);
    if (fallback > 0) {
      state.reportedSpeedSamples.add(_SpeedPoint(timestamp, fallback));
    }

    _trim(state.byteSamples, timestamp, window, maxSamples);
    _trim(state.reportedSpeedSamples, timestamp, window, maxSamples);

    var speed = _byteWindowSpeed(state);
    if (speed <= 0) speed = _medianReportedSpeed(state.reportedSpeedSamples);

    final lastByteAt = state.lastByteAt;
    if (lastByteAt != null && timestamp.difference(lastByteAt) >= staleAfter) {
      speed = 0;
    }

    final expected = state.expectedBytes;
    final remainingBytes = expected > 0
        ? (expected - state.transferredBytes).clamp(0, expected)
        : 0;
    final remaining = speed > 0 && remainingBytes > 0
        ? Duration(milliseconds: ((remainingBytes / speed) * 1000).ceil())
        : Duration.zero;

    return DownloadTelemetryReading(
      transferredBytes: state.transferredBytes,
      expectedBytes: expected,
      speedBytesPerSecond: speed,
      timeRemaining: remaining,
    );
  }

  DownloadTelemetryReading current(String taskId, {DateTime? now}) {
    return observe(taskId: taskId, now: now);
  }

  bool hasRecentBytes(String taskId, {DateTime? now, Duration? maxAge}) {
    final at = _states[taskId]?.lastByteAt;
    if (at == null) return false;
    return (now ?? DateTime.now()).difference(at) < (maxAge ?? staleAfter);
  }

  void resetSpeed(String taskId) {
    final state = _states[taskId];
    if (state == null) return;
    state.byteSamples.clear();
    state.reportedSpeedSamples.clear();
    state.lastByteAt = null;
  }

  void remove(String taskId) => _states.remove(taskId);

  void clear() => _states.clear();

  double _byteWindowSpeed(_TelemetryState state) {
    if (state.byteSamples.length < 2) return 0;
    final oldest = state.byteSamples.first;
    final latest = state.byteSamples.last;
    final elapsed = latest.at.difference(oldest.at);
    // URLSession/progress callbacks arrive in bursts. A 50-300ms delta is not
    // a user-visible download speed; wait for a real observation window rather
    // than magnifying that burst into an implausible MB/s value.
    if (elapsed < minimumWindow) return 0;
    final elapsedMicros = elapsed.inMicroseconds;
    final deltaBytes = latest.bytes - oldest.bytes;
    if (elapsedMicros <= 0 || deltaBytes <= 0) return 0;
    return deltaBytes / (elapsedMicros / Duration.microsecondsPerSecond);
  }

  double _medianReportedSpeed(Iterable<_SpeedPoint> samples) {
    final values = samples
        .map((sample) => sample.bytesPerSecond)
        .where((value) => value > 0 && value.isFinite)
        .toList(growable: false);
    if (values.isEmpty) return 0;
    final sorted = List<double>.from(values)..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  void _trim<T extends _TimedPoint>(
    ListQueue<T> samples,
    DateTime now,
    Duration keep,
    int limit,
  ) {
    while (samples.isNotEmpty && now.difference(samples.first.at) > keep) {
      samples.removeFirst();
    }
    while (samples.length > limit) {
      samples.removeFirst();
    }
  }

  double _finitePositive(double value) =>
      value.isFinite && value > 0 ? value : 0;
}

abstract class _TimedPoint {
  const _TimedPoint(this.at);
  final DateTime at;
}

class _BytePoint extends _TimedPoint {
  const _BytePoint(super.at, this.bytes);
  final int bytes;
}

class _SpeedPoint extends _TimedPoint {
  const _SpeedPoint(super.at, this.bytesPerSecond);
  final double bytesPerSecond;
}

class _TelemetryState {
  int transferredBytes = 0;
  int expectedBytes = -1;
  DateTime? lastByteAt;
  final ListQueue<_BytePoint> byteSamples = ListQueue<_BytePoint>();
  final ListQueue<_SpeedPoint> reportedSpeedSamples = ListQueue<_SpeedPoint>();
}
