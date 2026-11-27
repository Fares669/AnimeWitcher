import 'dart:async';

/// One bounded wait for the actual duration used by all skip sources.
final class SkipDurationWait {
  Timer? _timer;
  Completer<int?>? _pending;
  int? _durationSeconds;
  bool _timedOut = false;
  bool _cancelled = false;

  Future<int?> wait() {
    if (_cancelled || _timedOut || _durationSeconds != null) {
      return Future.value(_durationSeconds);
    }
    if (_pending case final pending?) return pending.future;

    final pending = _pending = Completer<int?>();
    _timer = Timer(const Duration(seconds: 4), () {
      _timedOut = true;
      _complete(null);
    });
    return pending.future;
  }

  /// Returns true once if a lookup may already have used a catalog fallback.
  bool report(int seconds) {
    if (_cancelled || seconds <= 0) return false;
    final refresh = _timedOut && _durationSeconds == null;
    _durationSeconds = seconds;
    _complete(seconds);
    return refresh;
  }

  void cancel() {
    _cancelled = true;
    _complete(null);
  }

  void _complete(int? seconds) {
    _timer?.cancel();
    _timer = null;
    _pending?.complete(seconds);
    _pending = null;
  }
}
