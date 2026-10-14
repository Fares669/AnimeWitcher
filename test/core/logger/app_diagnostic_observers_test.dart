import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:animewitcher/core/logger/app_diagnostics.dart';
import 'package:animewitcher/core/logger/app_diagnostic_observers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:talker_flutter/talker_flutter.dart';

void main() {
  late Directory directory;
  late AppDiagnostics diagnostics;

  Future<List<Map<String, dynamic>>> events() async {
    await diagnostics.flush();
    final rows = <Map<String, dynamic>>[];
    for (final file in await diagnostics.listFiles()) {
      rows.addAll(
        (await file.readAsLines()).map(
          (line) => jsonDecode(line) as Map<String, dynamic>,
        ),
      );
    }
    return rows;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-observers-test-');
    diagnostics = AppDiagnostics(directoryProvider: () async => directory);
    await diagnostics.setEnabled(true);
  });

  tearDown(() async {
    await diagnostics.setEnabled(false);
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  testWidgets('stalled log setup does not prevent the application frame', (
    tester,
  ) async {
    late Completer<Directory> pendingDirectory;
    late AppDiagnostics slowLog;
    late Future<void> restoration;
    await tester.runAsync(() async {
      pendingDirectory = Completer<Directory>();
      slowLog = AppDiagnostics(
        directoryProvider: () => pendingDirectory.future,
      );
      restoration = restoreAppDiagnosticPreference(
        true,
        startupTimer: Stopwatch()..start(),
        diagnostics: slowLog,
      );
    });
    await tester.pumpWidget(const MaterialApp(home: Text('app ready')));
    expect(find.text('app ready'), findsOneWidget);
    expect(slowLog.enabled, isFalse);
    await tester.runAsync(() async {
      pendingDirectory.complete(directory);
      await restoration;
      await slowLog.setEnabled(false);
      await slowLog.flush();
    });
  });

  test('failed log setup does not escape or enable diagnostics', () async {
    final failedLog = AppDiagnostics(
      directoryProvider: () async =>
          throw const FileSystemException('secret filesystem'),
    );
    await restoreAppDiagnosticPreference(
      true,
      startupTimer: Stopwatch()..start(),
      diagnostics: failedLog,
    );
    await Future<void>.delayed(Duration.zero);
    expect(failedLog.enabled, isFalse);
  });

  test(
    'app metadata includes numeric version and no device or package data',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'secret app',
        packageName: 'secret.package',
        version: '1.6.3',
        buildNumber: '5',
        buildSignature: 'secret signing signature',
      );
      await recordAppDiagnosticMetadata(diagnostics: diagnostics);
      final rows = await events();
      final metadata = rows.singleWhere(
        (row) => row['event'] == 'app_metadata',
      );
      expect(metadata, containsPair('version_major', 1));
      expect(metadata, containsPair('version_minor', 6));
      expect(metadata, containsPair('version_patch', 3));
      expect(metadata, containsPair('build', 5));
      expect(metadata, containsPair('build_mode', 'debug'));
      expect(
        metadata['platform'],
        isIn(['android', 'ios', 'macos', 'windows', 'linux', 'fuchsia']),
      );
      expect(jsonEncode(rows), isNot(contains('secret')));
    },
  );

  test(
    'Flutter errors preserve the exact existing reporter and throw',
    () async {
      final original = FlutterError.onError;
      addTearDown(() => FlutterError.onError = original);
      FlutterErrorDetails? reported;
      final thrownByReporter = StateError('reporter failed');
      FlutterError.onError = (details) {
        reported = details;
        throw thrownByReporter;
      };
      final originalPlatform = PlatformDispatcher.instance.onError;
      addTearDown(() => PlatformDispatcher.instance.onError = originalPlatform);
      installAppDiagnosticErrorHandlers(diagnostics: diagnostics);
      final details = FlutterErrorDetails(
        exception: StateError('private secret'),
      );
      expect(
        () => FlutterError.onError!(details),
        throwsA(same(thrownByReporter)),
      );
      expect(reported, same(details));
      final rows = await events();
      expect(
        rows.where((row) => row['event'] == 'flutter_error'),
        hasLength(1),
      );
      expect(jsonEncode(rows), isNot(contains('private secret')));
    },
  );

  test('platform errors preserve handled and unhandled results', () async {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });
    final error = StateError('secret token');
    final stack = StackTrace.current;
    Object? reported;
    PlatformDispatcher.instance.onError = (value, trace) {
      reported = value;
      expect(trace, same(stack));
      return true;
    };
    installAppDiagnosticErrorHandlers(diagnostics: diagnostics);
    expect(PlatformDispatcher.instance.onError!(error, stack), isTrue);
    expect(reported, same(error));

    PlatformDispatcher.instance.onError = null;
    FlutterError.onError = null;
    installAppDiagnosticErrorHandlers(diagnostics: diagnostics);
    expect(PlatformDispatcher.instance.onError!(error, stack), isFalse);
    FlutterError.onError!(FlutterErrorDetails(exception: error));
    expect(jsonEncode(await events()), isNot(contains('secret token')));
  });

  test('provider failures omit family arguments, names, and state', () async {
    final container = ProviderContainer(
      observers: [AppDiagnosticProviderObserver(diagnostics: diagnostics)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final provider = Provider.family<int, String>(
      (ref, argument) => throw StateError('secret error $argument'),
      name: 'secret provider name',
    );
    expect(
      () => container.read(provider('secret family argument')),
      throwsA(anything),
    );
    final rows = await events();
    final failures = rows.where((row) => row['event'] == 'provider_error');
    expect(failures, hasLength(1));
    expect(failures.single, containsPair('provider', 'riverpod'));
    expect(jsonEncode(rows), isNot(contains('secret')));
  });

  test('caught Talker errors omit message, keys, and exception text', () async {
    final logger = TalkerFlutter.init(
      observer: AppDiagnosticTalkerObserver(diagnostics: diagnostics),
      settings: TalkerSettings(useConsoleLogs: false),
    );
    logger.info('secret routine message');
    logger.error('secret token storage key', StateError('secret credential'));
    final rows = await events();
    expect(rows.where((row) => row['event'] == 'service_error'), hasLength(1));
    expect(jsonEncode(rows), isNot(contains('secret')));
  });

  testWidgets('navigation stores static categories without query or extras', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        for (final path in ['/home', '/details', '/search'])
          GoRoute(path: path, builder: (_, _) => const SizedBox.shrink()),
      ],
    );
    final detach = observeDiagnosticNavigation(
      router,
      diagnostics: diagnostics,
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/details?token=secret-query', extra: 'secret-extra');
    await tester.pumpAndSettle();
    router.go('/search?query=secret-search');
    await tester.pumpAndSettle();
    final rows = (await tester.runAsync(events))!;
    final routes = rows
        .where((row) => row['event'] == 'navigation')
        .map((row) => row['route']);
    expect(routes, ['home', 'details', 'search']);
    expect(jsonEncode(rows), isNot(contains('secret')));
    detach();
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
  });
}
