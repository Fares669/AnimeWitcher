import '../../../support/widget_completion.dart';
import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'download_v2_test_support.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/utils/download_time_remaining.dart';
import 'package:animewitcher/features/details/presentation/widgets/download_progress_dialog.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Commands extends DownloadsNotifier {
  _Commands([this.items = const []]);
  final List<DownloadItem> items;
  String? rejectedCommand;
  final List<String> calls = [];

  @override
  Future<List<DownloadItem>> build() async => items;

  Future<void> _command(String command, String taskId) async {
    calls.add('$command:$taskId');
    if (command == rejectedCommand) throw StateError('$command rejected');
  }

  @override
  Future<void> pauseDownload(String taskId) => _command('pause', taskId);
  @override
  Future<void> resumeDownload(String taskId) => _command('resume', taskId);
  @override
  Future<void> retryDownload(String taskId) => _command('retry', taskId);
}

Future<void> _openDialog(
  WidgetTester tester,
  DownloadProgressData data,
  _Commands commands,
  NotificationService notifications, {
  DownloadManagerV2? manager,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      if (manager != null) downloadManagerV2Provider.overrideWithValue(manager),
      downloadsProvider.overrideWith(() => commands),
      downloadProgressProvider.overrideWithValue({'selected-logical': data}),
      notificationServiceProvider.overrideWithValue(notifications),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => DownloadProgressDialog.show(
          context, 'Episode selected', 'selected-logical',
        ),
        child: const Text('Details route'),
      ))),
    ),
  ));
  await pumpUntil(tester, () => find.text('Details route').evaluate().isNotEmpty, 'details launch route');
  final container = ProviderScope.containerOf(tester.element(find.text('Details route')));
  await pumpUntilFuture(tester, container.read(downloadsProvider.future), 'dialog command download rows');
  await tester.tap(find.text('Details route'));
  await pumpUntil(tester, () => find.byType(Dialog).evaluate().isNotEmpty, 'selected progress dialog');
}

DownloadProgressData _progress(TaskStatus status, double progress) =>
    DownloadProgressData(
      taskId: 'selected-task', progress: progress, networkSpeed: -1,
      timeRemaining: Duration.zero, status: status,
    );

void main() {
  for (final progress in [.4, 1.0]) {
    testWidgets('failed progress $progress retains Retry and Cancel', (tester) async {
      final commands = _Commands();
      final notifications = NotificationService();
      addTearDown(notifications.dispose);
      await _openDialog(tester, _progress(TaskStatus.failed, progress), commands, notifications);

      expect(find.text('فشل التنزيل'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.text('إلغاء'), findsOneWidget);
      expect(find.text('إيقاف مؤقت'), findsNothing);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pump();
      expect(commands.calls, ['retry:selected-task']);
      expect(find.byType(DownloadProgressDialog), findsOneWidget);
    });
  }

  for (final entry in {
    TaskStatus.running: ('pause', 'إيقاف مؤقت'),
    TaskStatus.paused: ('resume', 'استئناف'),
    TaskStatus.failed: ('retry', 'إعادة المحاولة'),
  }.entries) {
    testWidgets('${entry.value.$1} rejection is caught and controls remain reusable', (tester) async {
      final commands = _Commands()..rejectedCommand = entry.value.$1;
      final notifications = NotificationService();
      addTearDown(notifications.dispose);
      await _openDialog(tester, _progress(entry.key, .4), commands, notifications);
      await tester.tap(find.text(entry.value.$2));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(notifications.toasts, hasLength(1));
      expect(notifications.toasts.single.type, ToastType.error);
      expect(notifications.toasts.single.message, contains('${entry.value.$1} rejected'));
      expect(find.byType(DownloadProgressDialog), findsOneWidget);
      commands.rejectedCommand = null;
      notifications.clearToasts();
      await tester.pump();
      await tester.tap(find.text(entry.value.$2));
      await tester.pump();
      expect(commands.calls, [
        '${entry.value.$1}:selected-task', '${entry.value.$1}:selected-task',
      ]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancel rejection leaves the dialog reusable and success closes only its route', (tester) async {
    const logical = DownloadLogicalId('selected-logical');
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(const LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logical, mediaId: 'show', unitKey: 'episode://1', variantKey: '480p',
      generation: 1, taskId: 'selected-task', intent: DownloadUserIntent.paused,
      destinationPath: '/tmp/ui-cancel.mp4', sourceDescriptor: {}, updatedAtMillis: 1,
    ));
    final handle = _CancelHandle();
    final manager = DownloadManagerV2(
      store: store, gateway: _CancelGateway(handle), sourceResolver: StaticSourceResolverV2(),
    );
    final commands = _Commands([DownloadItem(
      task: DownloadTask(taskId: 'selected-task', url: 'https://example.test/video', filename: 'video.mp4'),
      status: TaskStatus.paused, progress: .4,
      item: MultimediaItem(title: 'Show', url: 'show://1', posterUrl: ''),
      logicalId: logical.value, timestamp: 1,
    )]);
    final notifications = NotificationService();
    try {
      await pumpUntilFuture(tester, manager.initialize(), 'cancel manager initialization');
      await _openDialog(tester, _progress(TaskStatus.paused, .4), commands, notifications, manager: manager);
      await tester.tap(find.text('إلغاء'));
      await pumpUntil(tester, () => notifications.toasts.isNotEmpty, 'cancel rejection error toast');
      expect(tester.takeException(), isNull);
      expect(notifications.toasts, hasLength(1));
      expect(notifications.toasts.single.message, contains('cancel rejected'));
      expect(handle.cancelCalls, 1);
      expect(find.byType(DownloadProgressDialog), findsOneWidget);
      notifications.clearToasts();
      handle.reject = false;
      await tester.tap(find.text('إلغاء'));
      await pumpUntil(tester, () => find.byType(DownloadProgressDialog).evaluate().isEmpty, 'successful cancel dialog dismissal');
      expect(find.byType(DownloadProgressDialog), findsNothing);
      expect(find.text('Details route'), findsOneWidget);
      expect(handle.cancelCalls, 2);
    } finally {
      notifications.clearToasts();
      notifications.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpUntilFuture(tester, manager.dispose(), 'cancel manager disposal');
    }
  });

  testWidgets('failed at full byte progress is never formatted Finished', (tester) async {
    final commands = _Commands();
    final notifications = NotificationService();
    addTearDown(notifications.dispose);
    await _openDialog(tester, _progress(TaskStatus.failed, 1), commands, notifications);
    final context = tester.element(find.byType(DownloadProgressDialog));
    final l10n = AppLocalizations.of(context)!;
    expect(formatDownloadSpeed(_progress(TaskStatus.failed, 1), l10n), isNot(l10n.statusFinished));
    expect(formatDownloadTimeRemaining(_progress(TaskStatus.failed, 1), l10n), isNot(l10n.statusFinished));
  });

  testWidgets('complete status has only Close even before final progress repaint', (tester) async {
    final commands = _Commands();
    final notifications = NotificationService();
    addTearDown(notifications.dispose);
    await _openDialog(tester, _progress(TaskStatus.complete, .9), commands, notifications);
    expect(find.text('إلغاء'), findsNothing);
    expect(find.text('إيقاف مؤقت'), findsNothing);
    expect(find.text('إغلاق'), findsOneWidget);
  });
}

class _CancelGateway implements BackgroundDownloaderGateway {
  _CancelGateway(this.handle);
  final _CancelHandle handle;
  @override
  Future<void> initialize() async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async => throw StateError('not needed');
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => taskId == handle.taskId ? handle : null;
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [handle];
  @override
  Future<void> removeTracking(String taskId) async {}
}

class _CancelHandle implements DownloadTransportHandle {
  bool reject = true;
  int cancelCalls = 0;
  @override
  String get taskId => 'selected-task';
  DownloadTransportSnapshot _current = const DownloadTransportSnapshot(
    taskId: 'selected-task', status: DownloadTransportStatus.paused, progress: .4,
  );
  @override
  DownloadTransportSnapshot get current => _current;
  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();
  @override
  Future<bool> pause() async => true;
  @override
  Future<bool> resume() async => true;
  @override
  Future<bool> cancel() async {
    cancelCalls++;
    if (reject) throw StateError('cancel rejected');
    _current = const DownloadTransportSnapshot(
      taskId: 'selected-task', status: DownloadTransportStatus.canceled, progress: .4,
    );
    return true;
  }
}
