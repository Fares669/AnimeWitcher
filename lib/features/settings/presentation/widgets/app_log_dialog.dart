import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../general_settings_provider.dart';

class AppLogDialog extends ConsumerStatefulWidget {
  const AppLogDialog({super.key});

  @override
  ConsumerState<AppLogDialog> createState() => _AppLogDialogState();
}

class _AppLogDialogState extends ConsumerState<AppLogDialog> {
  bool _busy = false;
  String? _error;
  String? _status;
  Directory? _directory;
  List<File> _files = const [];

  String _text(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _readFiles() async {
    final log = ref.read(appDiagnosticsProvider);
    final snapshot = await (() async {
      await log.flush();
      final directory = await log.directory();
      final files = await log.listFiles();
      return (directory, files);
    })().timeout(const Duration(seconds: 3));
    if (mounted) {
      _directory = snapshot.$1;
      _files = snapshot.$2;
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool refresh = true,
    String? failureMessage,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      await action();
      if (refresh && mounted) await _readFiles();
    } catch (_) {
      if (mounted) {
        _error =
            failureMessage ??
            _text(
              'تعذّر الوصول لملفات سجل التطبيق أو حفظ الإعداد.',
              'Could not access app log files or save the setting.',
            );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run(_readFiles, refresh: false);

  Future<void> _export() => _run(() async {
    final log = ref.read(appDiagnosticsProvider);
    final export = await (() async {
      final file = await log.export();
      return (file.uri.pathSegments.last, await file.readAsBytes());
    })().timeout(const Duration(seconds: 3));
    if (!mounted) return;
    final saved = await FilePicker.saveFile(
      fileName: export.$1,
      bytes: export.$2,
    );
    if (saved != null && mounted) {
      _status = _text('تم تصدير السجل.', 'Log exported.');
    }
  });

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(generalSettingsProvider).appDiagnosticLog;
    final log = ref.read(appDiagnosticsProvider);
    final path = _directory?.path;
    return AlertDialog(
      title: Text(_text('سجل التطبيق', 'App diagnostic log')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_text('تفعيل سجل التطبيق', 'Enable app logging')),
                value: enabled,
                onChanged: _busy
                    ? null
                    : (value) => _run(
                        () => ref
                            .read(generalSettingsProvider.notifier)
                            .setAppDiagnosticLog(value),
                        refresh: value,
                        failureMessage: value
                            ? null
                            : _text(
                                'توقف التسجيل لهذه الجلسة، لكن تعذّر حفظ الإعداد. قد يُفعّل التسجيل عند تشغيل التطبيق مجددًا.',
                                'Recording stopped for this session, but the setting could not be saved. Logging may resume on the next launch.',
                              ),
                      ),
              ),
              Text(
                _text(
                  'فعّل السجل ثم أعد حدوث المشكلة. تُحفظ أحداث وأخطاء التطبيق محليًا بصيغة JSONL في ملفات محدودة الحجم تُستبدل تلقائيًا، دون الروابط أو بيانات الدخول. راجع الملف قبل مشاركته. إيقاف التتبع لا يحذف الملفات الموجودة.',
                  'Enable logging, then reproduce the issue. App events and errors are stored locally as JSONL in bounded rotating files, without URLs or credentials. Review the file before sharing it. Disabling logging preserves existing files.',
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null || log.lastError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error ??
                        _text(
                          'تعذّرت كتابة سجل التطبيق. تحقق من مساحة التخزين.',
                          'App log write failed. Check available storage.',
                        ),
                  ),
                ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_status!),
                ),
              if (path != null) ...[
                const SizedBox(height: 8),
                SelectableText(path),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => Clipboard.setData(ClipboardData(text: path)),
                          refresh: false,
                        ),
                  child: Text(_text('نسخ المسار', 'Copy path')),
                ),
              ],
              if (!_busy && _files.isEmpty)
                Text(_text('لا توجد سجلات للتطبيق بعد.', 'No app logs yet.')),
              for (final file in _files)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(file.uri.pathSegments.last),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy || _files.isEmpty ? null : _export,
          child: Text(_text('تصدير السجل', 'Export log')),
        ),
        TextButton(
          onPressed: _busy ? null : _refresh,
          child: Text(_text('تحديث', 'Refresh')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_text('إغلاق', 'Close')),
        ),
      ],
    );
  }
}
