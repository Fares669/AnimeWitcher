import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('ios/Runner/DownloadContinuedProcessingManager.swift')
      .readAsStringSync();

  test('continued-processing request asks iOS to start immediately', () {
    expect(
      source,
      contains('request.strategy = .fail'),
      reason:
          'a user-started download must get immediate acceptance/rejection instead of silently queueing forever',
    );
    expect(source, isNot(contains('request.strategy = .queue')));
  });

  test('submitted request cannot masquerade forever as an active iOS task', () {
    expect(source, contains('private var submittedAt: Date?'));
    expect(source, contains('private let attachmentGraceInterval: TimeInterval'));
    expect(
      source,
      isNot(
        contains(
          'if let existingIdentifier = identifier {\n      return existingIdentifier\n    }',
        ),
      ),
      reason:
          'an identifier only proves submission; it does not prove that iOS attached BGContinuedProcessingTask',
    );
    expect(
      source,
      contains('cancelPendingRequest()'),
      reason: 'stale submitted requests must be cleared before retrying',
    );
  });

  test('each new continued-processing session uses a fresh task identifier', () {
    expect(
      source,
      contains('UUID().uuidString'),
      reason:
          'BGContinuedProcessingTask identifiers are per-job; pause then resume must submit a fresh identifier instead of reusing download.session',
    );
    expect(
      source,
      contains('private var registeredIdentifiers: Set<String> = []'),
      reason:
          'every fresh identifier must be registered once without re-registering the same identifier',
    );
    expect(
      source,
      isNot(contains('return "\\(bundleId).download.\\(Self.sessionKey)"')),
      reason:
          'a fixed identifier makes the resumed continued-processing task stale after the previous session completes',
    );
  });

  test('update reports lost session after attachment grace expires', () {
    final start = source.indexOf('  func update(');
    final end = source.indexOf('  func finish(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('if let task = activeTask'));
    expect(body, contains('submittedAt'));
    expect(body, contains('identifier = nil'));
    expect(
      body,
      isNot(contains('return activeTask != nil || identifier != nil')),
      reason:
          'Dart must be told to retry when iOS never attached the submitted task',
    );
  });
}
