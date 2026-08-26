import 'dart:async';

/// Hard cap for fetching the next-episode airing time.
///
/// The details shell used to wait for this request before showing play
/// controls. Offline, Dio can sit until connect/receive timeout (15s) or
/// longer, so a downloaded episode could not start. Two seconds is enough
/// when the server is reachable and fails fast when it is not.
const Duration nextAiringFetchTimeout = Duration(seconds: 2);

/// Completes with the fetch result, or `null` if [timeout] elapses first.
///
/// The underlying request is not cancelled; callers should treat a null
/// result as "no countdown" and continue.
Future<T?> awaitWithTimeout<T>(
  Future<T?> future, {
  Duration timeout = nextAiringFetchTimeout,
}) async {
  try {
    return await future.timeout(timeout);
  } on TimeoutException {
    return null;
  }
}
