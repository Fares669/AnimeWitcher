import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/logger/app_diagnostics.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/features/settings/presentation/app_version_provider.dart';
import 'package:animewitcher/features/settings/presentation/settings_screen.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/features/settings/presentation/widgets/app_log_dialog.dart';
import 'package:file_picker/src/platform/file_picker_method_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _StalledDiagnostics extends AppDiagnostics {
  final gate = Completer<void>();

  @override
  Future<void> flush() => gate.future;
}

class _FailingDisableStorage extends MemoryStorageService {
  @override
  Future<void> setAppDiagnosticLog(bool value) async {
    if (!value) throw const FileSystemException('storage unavailable');
    return super.setAppDiagnosticLog(value);
  }
}

class _UnreadableAfterClearDiagnostics extends AppDiagnostics {
  _UnreadableAfterClearDiagnostics(Directory folder)
    : super(
        directoryProvider: () async => folder,
        exportDirectoryProvider: () async => Directory('${folder.path}/export'),
      );

  bool cleared = false;

  @override
  Future<void> clear() async {
    await super.clear();
    cleared = true;
  }

  @override
  Future<Directory> directory() async {
    if (cleared) throw const FileSystemException('private path unavailable');
    return super.directory();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const pickerChannel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    MethodChannelFilePicker.registerWith();
    directory = await Directory.systemTemp.createTemp('aw-app-log-dialog-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => directory.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await directory.delete(recursive: true);
  });

  Future<void> showDialog(
    WidgetTester tester,
    AppDiagnostics log,
    MemoryStorageService storage, {
    Locale locale = const Locale('en'),
    bool settingsScreen = false,
    bool settle = true,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            appDiagnosticsProvider.overrideWithValue(log),
            appVersionProvider.overrideWith((ref) async => 'test'),
            deviceProfileProvider.overrideWith(
              (ref) async => const DeviceProfile(),
            ),
          ],
          child: MaterialApp(
            locale: locale,
            localizationsDelegates: settingsScreen
                ? AppLocalizations.localizationsDelegates
                : const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
            supportedLocales: const [Locale('ar'), Locale('en')],
            home: settingsScreen
                ? const SettingsScreen()
                : const Scaffold(body: AppLogDialog()),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    if (settle) await tester.pumpAndSettle();
  }

  Future<void> flushLog(WidgetTester tester, AppDiagnostics log) async {
    var flushed = false;
    final draining = log.flush().whenComplete(() => flushed = true);
    for (var i = 0; i < 100 && !flushed; i++) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(flushed, isTrue);
    await draining;
  }

  Future<void> confirmClear(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Clear log'));
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (find.widgetWithText(FilledButton, 'Clear log').evaluate().isEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('general settings open the app diagnostic log separately', (
    tester,
  ) async {
    final log = AppDiagnostics(directoryProvider: () async => directory);
    await showDialog(
      tester,
      log,
      MemoryStorageService(),
      locale: const Locale('ar'),
      settingsScreen: true,
    );
    await tester.dragUntilVisible(
      find.text('سجل التطبيق'),
      find.byType(Scrollable).first,
      const Offset(0, -250),
    );
    await tester.ensureVisible(find.text('سجل التطبيق'));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 150));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('سجل التطبيق'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AppLogDialog), findsOneWidget);
    expect(find.text('تفعيل سجل التطبيق'), findsOneWidget);
  });

  testWidgets(
    'Arabic dialog explains local bounded diagnostics and is opt-in',
    (tester) async {
      final storage = MemoryStorageService();
      final log = AppDiagnostics(
        directoryProvider: () async => directory,
        exportDirectoryProvider: () async =>
            Directory('${directory.path}/export'),
      );
      await showDialog(tester, log, storage, locale: const Locale('ar'));

      expect(find.text('سجل التطبيق'), findsOneWidget);
      expect(find.textContaining('محليًا'), findsOneWidget);
      expect(find.textContaining('محدودة'), findsOneWidget);
      expect(find.textContaining('بيانات الدخول'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(find.text('تصدير السجل'), findsOneWidget);
      expect(find.text('مسح السجل'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byType(SwitchListTile));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(storage.getAppDiagnosticLog(), isTrue);
      expect(log.enabled, isTrue);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.runAsync(() async {
        await log.setEnabled(false);
        await log.flush();
      });
    },
  );

  testWidgets(
    'export uses the bounded sanitized log and disables busy actions',
    (tester) async {
      final storage = MemoryStorageService();
      await storage.setAppDiagnosticLog(true);
      final log = AppDiagnostics(
        directoryProvider: () async => Directory('${directory.path}/logs'),
        exportDirectoryProvider: () async =>
            Directory('${directory.path}/export'),
        maxBytes: 512,
        maxFiles: 2,
      );
      final expected = <int>[];
      await tester.runAsync(() async {
        await log.setEnabled(true);
        for (var i = 0; i < 100; i++) {
          log.record(
            'lifecycle',
            fields: {'count': i, 'state': 'resumed', 'password': 'secret'},
          );
          await log.flush();
        }
        final retained = await log.listFiles();
        expect(retained, hasLength(2));
        for (final file in retained.reversed) {
          expected.addAll(await file.readAsBytes());
        }
        expect(expected.length, lessThanOrEqualTo(1024));
      });
      final called = Completer<MethodCall>();
      final completion = Completer<String?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pickerChannel, (call) {
            called.complete(call);
            return completion.future;
          });
      await showDialog(tester, log, storage);
      MethodChannelFilePicker.registerWith();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Export log'))
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Export log'));
        for (var i = 0; i < 100 && !called.isCompleted; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(called.isCompleted, isTrue);
      });
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      for (final label in ['Export log', 'Clear log', 'Refresh']) {
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, label))
              .onPressed,
          isNull,
        );
      }
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed,
        isNotNull,
      );
      final call = await called.future;
      expect(call.method, 'save');
      expect(call.arguments['fileName'], 'app-diagnostics.jsonl');
      final bytes = List<int>.from(call.arguments['bytes'] as List);
      expect(bytes, expected);
      expect(utf8.decode(bytes), isNot(contains('secret')));

      await tester.runAsync(() async {
        completion.complete('/selected/app-diagnostics.jsonl');
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(find.text('Log exported.'), findsOneWidget);
      await tester.runAsync(() async {
        await log.setEnabled(false);
        await log.flush();
      });
    },
  );

  testWidgets('canceling clear leaves logs, export and preference unchanged', (
    tester,
  ) async {
    final storage = MemoryStorageService();
    final log = AppDiagnostics(
      directoryProvider: () async => Directory('${directory.path}/logs'),
      exportDirectoryProvider: () async =>
          Directory('${directory.path}/export'),
    );
    late File active;
    late File exported;
    late String before;
    await tester.runAsync(() async {
      await log.setEnabled(true);
      await log.setEnabled(false);
      exported = await log.export();
      active = (await log.listFiles()).single;
      before = await active.readAsString();
    });
    await showDialog(tester, log, storage);

    await tester.tap(find.text('Clear log'));
    await tester.pumpAndSettle();
    expect(find.text('Clear app log?'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      expect(await active.readAsString(), before);
      expect(await exported.readAsString(), before);
    });
    expect(log.enabled, isFalse);
    expect(storage.getAppDiagnosticLog(), isFalse);
    expect(find.text('Log cleared.'), findsNothing);
  });

  for (final enabled in [false, true]) {
    testWidgets('confirmed clear preserves logging setting: $enabled', (
      tester,
    ) async {
      final storage = MemoryStorageService();
      await storage.setAppDiagnosticLog(enabled);
      final log = AppDiagnostics(
        directoryProvider: () async => Directory('${directory.path}/logs'),
        exportDirectoryProvider: () async =>
            Directory('${directory.path}/export'),
      );
      late File exported;
      await tester.runAsync(() async {
        await log.setEnabled(true);
        if (!enabled) await log.setEnabled(false);
        exported = await log.export();
      });
      await showDialog(tester, log, storage);
      await tester.tap(find.text('Clear log'));
      await tester.pumpAndSettle();
      await confirmClear(tester);

      expect(find.text('No app logs yet.'), findsOneWidget);
      expect(find.textContaining('Log cleared.'), findsOneWidget);
      expect(storage.getAppDiagnosticLog(), enabled);
      expect(log.enabled, enabled);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        enabled,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Export log'))
            .onPressed,
        isNull,
      );
      await tester.runAsync(() async {
        expect(await log.listFiles(), isEmpty);
        expect(await exported.exists(), isFalse);
        if (enabled) {
          log.record('navigation', fields: {'route': 'home'});
          await flushLog(tester, log);
          final file = (await log.listFiles()).single;
          expect(await file.readAsString(), contains('home'));
          await log.setEnabled(false);
          await flushLog(tester, log);
        }
      });
    });
  }

  testWidgets('clear failure is safe and allows retry', (tester) async {
    final log = AppDiagnostics(
      directoryProvider: () async => Directory('${directory.path}/logs'),
      exportDirectoryProvider: () async =>
          Directory('${directory.path}/export'),
    );
    late File active;
    await tester.runAsync(() async {
      await log.setEnabled(true);
      await log.setEnabled(false);
      await log.flush();
      active = (await log.listFiles()).single;
    });
    await showDialog(tester, log, MemoryStorageService());
    await tester.runAsync(() async {
      await active.delete();
      await Directory(active.path).create();
    });
    await tester.tap(find.text('Clear log'));
    await tester.pumpAndSettle();
    await confirmClear(tester);

    expect(find.text('Could not clear app logs. Try again.'), findsOneWidget);
    expect(find.textContaining('Log cleared.'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Clear log'))
          .onPressed,
      isNotNull,
    );
    await tester.runAsync(() => Directory(active.path).delete());
    await tester.tap(find.text('Clear log'));
    await tester.pumpAndSettle();
    await confirmClear(tester);
    expect(find.text('Log cleared.'), findsOneWidget);
    expect(find.text('Could not clear app logs. Try again.'), findsNothing);
  });

  testWidgets('successful clear does not require another storage read', (
    tester,
  ) async {
    final log = _UnreadableAfterClearDiagnostics(directory);
    final active = File('${directory.path}/app-diagnostics.jsonl');
    await tester.runAsync(() => active.writeAsString('old log'));
    await showDialog(tester, log, MemoryStorageService());
    await tester.tap(find.text('Clear log'));
    await tester.pumpAndSettle();
    await confirmClear(tester);

    expect(log.cleared, isTrue);
    expect(find.text('Log cleared.'), findsOneWidget);
    expect(find.text('No app logs yet.'), findsOneWidget);
    expect(find.textContaining('Could not'), findsNothing);
    await tester.runAsync(() async => expect(await active.exists(), isFalse));
  });

  testWidgets('refresh surfaces safe storage errors and allows retry', (
    tester,
  ) async {
    var fail = true;
    final log = AppDiagnostics(
      directoryProvider: () async {
        if (fail) throw const FileSystemException('private secret path');
        return directory;
      },
    );
    await showDialog(tester, log, MemoryStorageService());
    expect(
      find.text('Could not access app log files or save the setting.'),
      findsOneWidget,
    );
    expect(find.textContaining('private secret'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    fail = false;
    await tester.runAsync(() async {
      await tester.tap(find.text('Refresh'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(find.text('No app logs yet.'), findsOneWidget);
    expect(
      find.text('Could not access app log files or save the setting.'),
      findsNothing,
    );
  });

  testWidgets('export failure is visible without leaking platform details', (
    tester,
  ) async {
    final storage = MemoryStorageService();
    await storage.setAppDiagnosticLog(true);
    final log = AppDiagnostics(
      directoryProvider: () async => directory,
      exportDirectoryProvider: () async =>
          Directory('${directory.path}/export'),
    );
    await tester.runAsync(() async {
      await log.setEnabled(true);
      log.record('lifecycle', fields: {'state': 'resumed'});
      await log.flush();
    });
    final called = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (_) async {
          called.complete();
          throw PlatformException(code: 'private_secret');
        });
    await showDialog(tester, log, storage);
    MethodChannelFilePicker.registerWith();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Export log'))
          .onPressed,
      isNotNull,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Export log'));
      for (var i = 0; i < 100 && !called.isCompleted; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(called.isCompleted, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(
      find.text('Could not access app log files or save the setting.'),
      findsOneWidget,
    );
    expect(find.textContaining('private_secret'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.runAsync(() async {
      await log.setEnabled(false);
      await log.flush();
    });
  });

  testWidgets(
    'stalled refresh times out and still lets the user disable logging',
    (tester) async {
      final storage = MemoryStorageService();
      await storage.setAppDiagnosticLog(true);
      final log = _StalledDiagnostics();
      await showDialog(tester, log, storage, settle: false);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed,
        isNotNull,
      );

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        find.text('Could not access app log files or save the setting.'),
        findsOneWidget,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNotNull,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(storage.getAppDiagnosticLog(), isFalse);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'failed off persistence says recording stopped for this session',
    (tester) async {
      final storage = _FailingDisableStorage();
      await storage.setAppDiagnosticLog(true);
      final log = AppDiagnostics(directoryProvider: () async => directory);
      await tester.runAsync(() => log.setEnabled(true));
      await showDialog(tester, log, storage);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(log.enabled, isFalse);
      expect(storage.getAppDiagnosticLog(), isTrue);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(
        find.text(
          'Recording stopped for this session, but the setting could not be saved. Logging may resume on the next launch.',
        ),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        var flushed = false;
        final drain = log.flush().whenComplete(() => flushed = true);
        for (var i = 0; i < 100 && !flushed; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(flushed, isTrue);
        await drain;
      });
    },
  );
}
