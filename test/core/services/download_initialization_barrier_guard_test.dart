import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String methodBody(String source, String signature, String nextSignature) {
  final start = source.indexOf(signature);
  final end = source.indexOf(nextSignature, start + signature.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
  expect(end, greaterThan(start), reason: 'missing boundary $nextSignature');
  return source.substring(start, end);
}

void main() {
      ,
  );

  test(
    'startup V2 init failure is explicitly observed while commands can retry',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final callback = methodBody(
        source,
        'WidgetsBinding.instance.addPostFrameCallback((_) {',
        '  @override\n  void dispose()',
      );
      expect(callback, contains('unawaited('));
      expect(callback, contains('downloadManagerV2Provider'));
      expect(callback, contains('.initialize()'));
      expect(callback, contains('.catchError((Object error)'));
    },
  );
}
