import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/extensions/providers/witanime_support_service.dart';
import '../../../../core/services/notification_service.dart';

Future<void> showWitanimeReportDialog(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String targetUrl,
  Future<bool> Function(Uri)? openLink,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _WitanimeReportDialog(
      title: title,
      targetUrl: targetUrl,
      openLink: openLink,
    ),
  );
}

class _WitanimeReportDialog extends ConsumerStatefulWidget {
  const _WitanimeReportDialog({
    required this.title,
    required this.targetUrl,
    this.openLink,
  });

  final String title;
  final String targetUrl;
  final Future<bool> Function(Uri)? openLink;

  @override
  ConsumerState<_WitanimeReportDialog> createState() =>
      _WitanimeReportDialogState();
}

class _WitanimeReportDialogState extends ConsumerState<_WitanimeReportDialog> {
  WitanimeReportReason _reason = WitanimeReportReason.brokenStream;
  final TextEditingController _detailsController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final result = await ref
        .read(witanimeSupportServiceProvider)
        .submitEpisodeReport(
          targetUrl: widget.targetUrl,
          reason: _reason,
          details: _detailsController.text,
        );
    if (!mounted) return;
    final notifications = ref.read(notificationServiceProvider);
    if (result.accepted) {
      Navigator.of(context).pop();
      notifications.showSuccess(result.message);
      return;
    }
    if (result.requiresBrowserVerification && result.fallbackUri != null) {
      final opened =
          await (widget.openLink?.call(result.fallbackUri!) ??
              launchUrl(
                result.fallbackUri!,
                mode: LaunchMode.externalApplication,
              ));
      if (!mounted) return;
      Navigator.of(context).pop();
      if (!opened) {
        notifications.showError('تعذر فتح موقع Witanime.');
      } else {
        notifications.showInfo(result.message);
      }
      return;
    }
    setState(() => _submitting = false);
    notifications.showError(result.message);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('الإبلاغ عن مشكلة · ${widget.title}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioGroup<WitanimeReportReason>(
              groupValue: _reason,
              onChanged: (value) {
                if (!_submitting && value != null) {
                  setState(() => _reason = value);
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in WitanimeReportReason.values)
                    RadioListTile<WitanimeReportReason>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: option,
                      title: Text(option.label),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _detailsController,
              enabled: !_submitting,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'تفاصيل إضافية (اختياري)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('إرسال البلاغ'),
        ),
      ],
    );
  }
}
