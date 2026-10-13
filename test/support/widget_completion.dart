import 'package:flutter_test/flutter_test.dart';

/// Wait for the operation under test, rather than unrelated infinite animations.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() completed,
  String description, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  const step = Duration(milliseconds: 50);
  for (var elapsed = Duration.zero; elapsed < timeout; elapsed += step) {
    await tester.pump(step);
    if (completed()) return;
    // File IO and image decoding need the real event loop in widget tests.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  fail('Timed out waiting for $description after $timeout');
}

Future<T> pumpUntilFuture<T>(
  WidgetTester tester,
  Future<T> future,
  String description,
) async {
  var completed = false;
  late T result;
  Object? error;
  StackTrace? stackTrace;
  future.then((value) {
    result = value;
    completed = true;
  }, onError: (Object caught, StackTrace stack) {
    error = caught;
    stackTrace = stack;
    completed = true;
  });
  await pumpUntil(tester, () => completed, description);
  if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
  return result;
}
