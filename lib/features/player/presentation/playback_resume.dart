/// Hold playback until a saved resume position has been seeked.
///
/// Opening the stream and then seeking a second later flashes the start of
/// the episode. Callers look up the saved position first, open paused, seek,
/// and only then reveal video / start playback.
class PlaybackResume {
  PlaybackResume._();

  /// Ignore tiny saved offsets so a 1-second tap does not hold startup.
  static const int minPositionMs = 2000;

  /// Consider the engine "at" the resume point once it is this close.
  /// HLS often lands on the nearest keyframe, so this is wider than a
  /// frame-accurate seek.
  static const int settleToleranceMs = 5000;

  /// How long to wait for the engine to report the seeked position.
  static const Duration seekSettleTimeout = Duration(seconds: 8);

  static bool shouldHoldUntilSeeked(int savedPositionMs) =>
      savedPositionMs >= minPositionMs;

  /// Open only while the route/source that requested the bookmark is active.
  /// Check after each async gap so Back or an episode switch cannot restart
  /// a source that is no longer active.
  static Future<bool> openWhenReady({
    required bool Function() isActive,
    required Future<int> Function() resolvePosition,
    required Future<void> Function(int positionMs) open,
  }) async {
    if (!isActive()) return false;
    final position = await resolvePosition();
    if (!isActive()) return false;
    await open(position);
    return isActive();
  }

  static bool isNear({
    required int currentMs,
    required int targetMs,
    int toleranceMs = settleToleranceMs,
  }) {
    return (currentMs - targetMs).abs() <= toleranceMs;
  }

  /// Keep the startup overlay up while a resume seek is still outstanding
  /// and the playhead is still at the beginning of the file.
  static bool canRevealVideo({
    required int? pendingResumeMs,
    required bool applyingResume,
    required int currentMs,
  }) {
    if (applyingResume) return false;
    if (pendingResumeMs != null && pendingResumeMs >= minPositionMs) {
      return isNear(currentMs: currentMs, targetMs: pendingResumeMs);
    }
    return currentMs > 0;
  }
}
