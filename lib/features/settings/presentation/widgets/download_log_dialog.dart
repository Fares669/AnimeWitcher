import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/download_v2/download_v2_provider.dart';
import '../general_settings_provider.dart';

class DownloadLogDialog extends ConsumerStatefulWidget {
  const DownloadLogDialog({super.key});
  @override
  ConsumerState<DownloadLogDialog> createState() => _DownloadLogDialogState();
}

class _DownloadLogDialogState extends ConsumerState<DownloadLogDialog> {
  bool _busy = false;
  String? _error;
  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';
  String text(String ar, String en) => _ar ? ar : en;

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        _error = text(
          'تعذّر الوصول لملفات السجل أو حفظ الإعداد.',
          'Could not access log files or save the setting.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(generalSettingsProvider).downloadDiagnosticLog;
    final log = ref.read(downloadDiagnosticsFileV2Provider);
    return AlertDialog(
      title: Text(text('سجل التنزيلات (Log)', 'Download log')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(text('تفعيل التتبع', 'Enable tracing')),
                value: enabled,
                onChanged: _busy
                    ? null
                    : (value) => run(
                        () => ref
                            .read(generalSettingsProvider.notifier)
                            .setDownloadDiagnosticLog(value),
                      ),
              ),
              Text(
                text(
                  'فعّل السجل ثم أعد حدوث المشكلة. تُحفظ أحداث مدير التنزيل V2 أولًا بأول في مجلد log بصيغة JSONL، دون الروابط أو بيانات الدخول. إيقاف التتبع لا يحذف الملفات الموجودة.',
                  'Enable logging, then reproduce the issue. Download Manager V2 events are flushed to the log folder as JSONL without URLs or credentials. Disabling logging preserves existing files.',
                ),
              ),
              if (_error != null || log.lastError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error ??
                        text(
                          'تعذّرت كتابة السجل. تحقق من مساحة التخزين.',
                          'Log write failed. Check available storage.',
                        ),
                  ),
                ),
              FutureBuilder(
                future: log.directory(),
                builder: (context, snapshot) {
                  final path = snapshot.data?.path;
                  return path == null
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(path),
                            TextButton(
                              onPressed: () =>
                                  Clipboard.setData(ClipboardData(text: path)),
                              child: Text(text('نسخ المسار', 'Copy path')),
                            ),
                          ],
                        );
                },
              ),
              FutureBuilder(
                future: log.flush().then((_) => log.listFiles()),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Text(
                      text('تعذّر قراءة مجلد log', 'Cannot read log folder'),
                    );
                  }
                  final files = snapshot.data;
                  if (files == null) return const LinearProgressIndicator();
                  if (files.isEmpty) {
                    return Text(text('لا توجد سجلات بعد.', 'No logs yet.'));
                  }
                  return Column(
                    children: files
                        .map(
                          (file) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(file.uri.pathSegments.last),
                            trailing: const Icon(Icons.save_alt),
                            onTap: _busy
                                ? null
                                : () => run(() async {
                                    await log.flush();
                                    final bytes = await file.readAsBytes();
                                    await FilePicker.saveFile(
                                      fileName: file.uri.pathSegments.last,
                                      bytes: bytes,
                                    );
                                  }),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => setState(() {}),
          child: Text(text('تحديث', 'Refresh')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(text('إغلاق', 'Close')),
        ),
      ],
    );
  }
}
