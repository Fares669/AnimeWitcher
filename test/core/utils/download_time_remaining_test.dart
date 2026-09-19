import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/utils/download_time_remaining.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/l10n/generated/app_localizations_ar.dart';

DownloadProgressData _data({
  TaskStatus status = TaskStatus.running,
  double progress = 0.4,
  double networkSpeed = -1,
  Duration timeRemaining = Duration.zero,
}) {
  return DownloadProgressData(
    taskId: 'task',
    progress: progress,
    networkSpeed: networkSpeed,
    timeRemaining: timeRemaining,
    status: status,
  );
}

void main() {
  final l10n = AppLocalizationsAr();

  test('supported locales are Arabic only', () {
    expect(AppLocalizations.supportedLocales, [const Locale('ar')]);
    expect(AppLocalizations.delegate.isSupported(const Locale('ar')), isTrue);
    expect(AppLocalizations.delegate.isSupported(const Locale('en')), isFalse);
  });

  test('calculating is Arabic', () {
    expect(l10n.calculating, 'جارٍ الحساب…');
  });

  test('formatDownloadSpeed uses Arabic status words', () {
    expect(formatDownloadSpeed(_data(), l10n), l10n.calculating);
    expect(
      formatDownloadSpeed(_data(status: TaskStatus.paused), l10n),
      l10n.statusPaused,
    );
    expect(
      formatDownloadSpeed(_data(progress: 1, networkSpeed: 2), l10n),
      l10n.statusFinished,
    );
    expect(
      formatDownloadSpeed(_data(networkSpeed: 1.5), l10n),
      '1.50 MB/s',
    );
  });

  testWidgets('formatDownloadTimeRemaining uses Arabic units', (tester) async {
    late String remaining;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            remaining = formatDownloadTimeRemaining(
              context,
              _data(timeRemaining: const Duration(minutes: 2, seconds: 5)),
              AppLocalizations.of(context)!,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    expect(remaining, 'دقيقتان و5 ثوانٍ');
  });

  testWidgets('unknown remaining time shows calculating', (tester) async {
    late String remaining;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            remaining = formatDownloadTimeRemaining(
              context,
              _data(),
              AppLocalizations.of(context)!,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    expect(remaining, 'جارٍ الحساب…');
  });
}
