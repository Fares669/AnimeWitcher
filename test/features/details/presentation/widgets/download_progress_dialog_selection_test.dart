import 'package:animewitcher/core/utils/download_progress_data.dart';
import 'package:animewitcher/features/details/presentation/widgets/download_progress_dialog.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCommands extends DownloadsNotifier {
  final paused = <String>[];

  @override
  Future<List<DownloadItem>> build() async => const [];

  @override
  Future<void> pauseDownload(String taskId) async => paused.add(taskId);
}

DownloadProgressData _running(String taskId, double progress) =>
    DownloadProgressData(
      taskId: taskId,
      progress: progress,
      status: TaskStatus.running,
      totalSize: 9000000,
    );

void main() {
  testWidgets('dialog ignores a sibling update but retargets a task-only change', (
    tester,
  ) async {
    const selected = 'selected-logical';
    const sibling = 'unrelated-logical';
    const oldTask = 'selected-task-2';
    const newTask = 'selected-task-3';
    var rows = {
      selected: _running(oldTask, .52),
      sibling: _running('unrelated-task', .3),
    };
    final notifier = _RecordingCommands();
    final container = ProviderContainer(
      overrides: [
        downloadProgressProvider.overrideWith((_) => rows),
        downloadsProvider.overrideWith(() => notifier),
      ],
    );

    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => DownloadProgressDialog.show(
                    context,
                    'Selected episode',
                    selected,
                  ),
                  child: const Text('Open progress'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open progress'));
      await tester.pumpAndSettle();
      final dialog = find.byType(DownloadProgressDialog);
      final meter = find.descendant(
        of: dialog,
        matching: find.byType(LinearProgressIndicator),
      );
      final route = ModalRoute.of(tester.element(dialog));
      final originalMeter = tester.widget<LinearProgressIndicator>(meter);
      expect(originalMeter.value, .52);

      rows = {
        selected: _running(oldTask, .52),
        sibling: _running('unrelated-task', .6),
      };
      container.invalidate(downloadProgressProvider);
      await tester.pumpAndSettle();
      expect(container.read(downloadProgressProvider)[sibling]?.progress, .6);
      expect(tester.widget<LinearProgressIndicator>(meter), same(originalMeter));

      rows = {...rows, selected: _running(newTask, .52)};
      container.invalidate(downloadProgressProvider);
      await tester.pumpAndSettle();
      expect(container.read(downloadProgressProvider)[selected]?.taskId, newTask);
      expect(ModalRoute.of(tester.element(dialog)), same(route));
      expect(tester.widget<LinearProgressIndicator>(meter).value, .52);
      expect(tester.widget<LinearProgressIndicator>(meter), isNot(same(originalMeter)));

      await tester.tap(find.widgetWithText(TextButton, 'إيقاف مؤقت'));
      await tester.pumpAndSettle();
      expect(notifier.paused, [newTask]);
      expect(ModalRoute.of(tester.element(dialog)), same(route));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    }
  });
}
