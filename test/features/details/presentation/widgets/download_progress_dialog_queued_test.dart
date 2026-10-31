import 'package:animewitcher/core/utils/download_progress_data.dart';
import 'package:animewitcher/features/details/presentation/widgets/download_progress_dialog.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _EmptyDownloadsNotifier extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const <DownloadItem>[];
}

Widget _dialogApp(DownloadProgressData data) {
  return ProviderScope(
    overrides: [
      downloadsProvider.overrideWith(() => _EmptyDownloadsNotifier()),
      downloadProgressProvider.overrideWith(
        (ref) => <String, DownloadProgressData>{'tracking-1': data},
      ),
    ],
    child: const MaterialApp(
      locale: Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DownloadProgressDialog(
          title: 'الحلقة 9',
          trackingUrl: 'tracking-1',
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'queued download hides the calculating speed and remaining rows',
    (tester) async {
      await tester.pumpWidget(
        _dialogApp(
          const DownloadProgressData(
            taskId: 'task-1',
            progress: 0,
            status: TaskStatus.enqueued,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('جارٍ الحساب…'), findsNothing);
      expect(find.text('السرعة'), findsNothing);
      expect(find.text('المتبقي'), findsNothing);
      // A queued download is labelled as waiting, not as downloading.
      expect(find.text('في الانتظار...'), findsOneWidget);
      // The episode label sits on the right, fully RTL.
      final subtitle = tester.widget<Text>(find.text('الحلقة 9'));
      expect(subtitle.textDirection, TextDirection.rtl);
    },
  );

  testWidgets('running download shows no speed or remaining rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _dialogApp(
        const DownloadProgressData(
          taskId: 'task-1',
          progress: 0.4,
          totalSize: 1000,
          status: TaskStatus.running,
        ),
      ),
    );
    await tester.pump();

    // Per-download speed/ETA were removed from the dialog entirely.
    expect(find.textContaining('KB/s'), findsNothing);
    expect(find.text('السرعة'), findsNothing);
    expect(find.text('المتبقي'), findsNothing);
    expect(find.text('جارٍ التنزيل'), findsOneWidget);
  });
}
