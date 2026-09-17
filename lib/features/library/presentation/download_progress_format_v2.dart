import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'download_progress_v2.dart';

String formatDownloadTimeRemainingV2(
  BuildContext context,
  DownloadProgressData data,
  AppLocalizations l10n,
) {
  if (data.status == TaskStatus.paused) return '---';
  if (data.progress >= 1.0) return l10n.statusFinished;
  if (data.timeRemaining.inSeconds <= 0) return l10n.calculating;

  final duration = data.timeRemaining;
  if (duration.inHours > 0) {
    final parts = <String>[
      _formatArabicUnit(
        duration.inHours,
        singular: 'ساعة',
        dual: 'ساعتان',
        plural: 'ساعات',
      ),
    ];
    final minutes = duration.inMinutes % 60;
    if (minutes > 0) {
      parts.add(
        _formatArabicUnit(
          minutes,
          singular: 'دقيقة',
          dual: 'دقيقتان',
          plural: 'دقائق',
        ),
      );
    }
    return parts.join(' و');
  }

  if (duration.inMinutes > 0) {
    final parts = <String>[
      _formatArabicUnit(
        duration.inMinutes,
        singular: 'دقيقة',
        dual: 'دقيقتان',
        plural: 'دقائق',
      ),
    ];
    final seconds = duration.inSeconds % 60;
    if (seconds > 0) {
      parts.add(
        _formatArabicUnit(
          seconds,
          singular: 'ثانية',
          dual: 'ثانيتان',
          plural: 'ثوانٍ',
        ),
      );
    }
    return parts.join(' و');
  }

  return _formatArabicUnit(
    duration.inSeconds,
    singular: 'ثانية',
    dual: 'ثانيتان',
    plural: 'ثوانٍ',
  );
}

String formatDownloadSpeedV2(
  DownloadProgressData data,
  AppLocalizations l10n,
) {
  if (data.status == TaskStatus.paused) return l10n.statusPaused;
  if (data.progress >= 1.0) return l10n.statusFinished;
  if (data.networkSpeed < 0) return l10n.calculating;
  if (data.networkSpeed == 0) return '0 MB/s';

  if (data.networkSpeed < 1.0) {
    return '${(data.networkSpeed * 1000).toStringAsFixed(2)} KB/s';
  }
  return '${data.networkSpeed.toStringAsFixed(2)} MB/s';
}

String _formatArabicUnit(
  int value, {
  required String singular,
  required String dual,
  required String plural,
}) {
  if (value == 1) return singular;
  if (value == 2) return dual;
  if (value >= 3 && value <= 10) return '$value $plural';
  return '$value $singular';
}
