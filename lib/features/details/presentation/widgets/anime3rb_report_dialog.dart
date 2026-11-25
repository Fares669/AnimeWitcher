import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/account/anime3rb_account_models.dart';
import '../../../../core/account/anime3rb_account_service.dart';
import '../../../../core/services/notification_service.dart';

Future<void> showAnime3rbReportDialog(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String episodeUrl,
}) async {
  final accountService = ref.read(anime3rbAccountServiceProvider);
  if (!accountService.isSignedIn) {
    ref
        .read(notificationServiceProvider)
        .showInfo('سجّل الدخول إلى حساب Anime3rb للإبلاغ عن مشكلة في الحلقة.');
    return;
  }
  final uri = Uri.tryParse(episodeUrl.trim());
  if (uri == null) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _Anime3rbReportDialog(title: title, episodeUri: uri),
  );
}

class _Anime3rbReportDialog extends ConsumerStatefulWidget {
  const _Anime3rbReportDialog({
    required this.title,
    required this.episodeUri,
  });

  final String title;
  final Uri episodeUri;

  @override
  ConsumerState<_Anime3rbReportDialog> createState() =>
      _Anime3rbReportDialogState();
}

class _Anime3rbReportDialogState extends ConsumerState<_Anime3rbReportDialog> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _episodesController = TextEditingController();

  bool _loading = true;
  bool _submitting = false;
  String? _loadError;
  bool _blocked = false;
  String? _blockedMessage;
  List<Anime3rbReportIssueOption> _issues = const <Anime3rbReportIssueOption>[];
  List<Anime3rbReportScopeOption> _scopes = Anime3rbReportScopeOption.defaults;

  Anime3rbReportIssueOption? _selectedGroup;
  Anime3rbReportIssueOption? _selectedLeaf;
  String _scope = 'single';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _episodesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final form = await ref
          .read(anime3rbAccountServiceProvider)
          .fetchReportForm(widget.episodeUri);
      if (!mounted) return;
      final firstGroup = form.issues.isNotEmpty ? form.issues.first : null;
      final firstLeaf = firstGroup != null && firstGroup.children.isNotEmpty
          ? firstGroup.children.first
          : firstGroup;
      setState(() {
        _issues = form.issues;
        _scopes = form.scopes;
        _blocked = form.blocked;
        _blockedMessage = form.blockedMessage;
        _selectedGroup = firstGroup;
        _selectedLeaf = firstLeaf;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.toString();
        _loading = false;
      });
    }
  }

  bool get _requiresDetails =>
      (_selectedGroup?.requiresAdditionalDetails ?? false) ||
      (_selectedLeaf?.requiresAdditionalDetails ?? false);

  Future<void> _submit() async {
    final issue = _selectedLeaf ?? _selectedGroup;
    if (issue == null || _submitting) return;
    final message = _messageController.text.trim();
    if (_requiresDetails && message.isEmpty) {
      ref
          .read(notificationServiceProvider)
          .showInfo('يرجى كتابة تفاصيل إضافية لهذه المشكلة.');
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref
          .read(anime3rbAccountServiceProvider)
          .submitEpisodeReport(
            episodeUri: widget.episodeUri,
            issueId: issue.id,
            scope: _scope,
            videosNumbers: _scope == 'multiple'
                ? _episodesController.text.trim()
                : null,
            message: message,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ref
          .read(notificationServiceProvider)
          .showSuccess('تم إرسال البلاغ إلى إدارة Anime3rb.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ref.read(notificationServiceProvider).showError(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeLeaf = _selectedLeaf ?? _selectedGroup;
    final children = _selectedGroup?.children ?? const <Anime3rbReportIssueOption>[];
    return AlertDialog(
      title: Text('الإبلاغ عن مشكلة · ${widget.title}'),
      content: SizedBox(
        width: 440,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            : _loadError != null
            ? Text('تعذر تحميل نموذج الإبلاغ: $_loadError')
            : _blocked
            ? Text(_blockedMessage ?? 'الإبلاغ متوقف مؤقتًا لهذا الحساب.')
            : _issues.isEmpty
            ? const Text('الإبلاغ غير متاح حاليًا لهذه الحلقة.')
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<Anime3rbReportIssueOption>(
                      initialValue: _selectedGroup,
                      decoration: const InputDecoration(
                        labelText: 'تصنيف المشكلة',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final g in _issues)
                          DropdownMenuItem(value: g, child: Text(g.label)),
                      ],
                      onChanged: _submitting
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() {
                                _selectedGroup = value;
                                _selectedLeaf = value.children.isNotEmpty
                                    ? value.children.first
                                    : value;
                              });
                            },
                    ),
                    if (children.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<Anime3rbReportIssueOption>(
                        initialValue: _selectedLeaf,
                        decoration: const InputDecoration(
                          labelText: 'نوع المشكلة',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final leaf in children)
                            DropdownMenuItem(
                              value: leaf,
                              child: Text(leaf.label),
                            ),
                        ],
                        onChanged: _submitting
                            ? null
                            : (value) => setState(() => _selectedLeaf = value),
                      ),
                    ],
                    if (activeLeaf?.note?.isNotEmpty == true) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          activeLeaf!.note!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _scope,
                      decoration: const InputDecoration(
                        labelText: 'نطاق المشكلة',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final scope in _scopes)
                          DropdownMenuItem(
                            value: scope.value,
                            child: Text(scope.label),
                          ),
                      ],
                      onChanged: _submitting
                          ? null
                          : (value) {
                              if (value != null) setState(() => _scope = value);
                            },
                    ),
                    if (_scope == 'multiple') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _episodesController,
                        enabled: !_submitting,
                        decoration: const InputDecoration(
                          labelText: 'أرقام الحلقات المتأثرة',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _messageController,
                      enabled: !_submitting,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: _requiresDetails
                            ? 'تفاصيل إضافية (مطلوب)'
                            : 'تفاصيل إضافية (اختياري)',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        if (!_loading && _loadError == null && !_blocked && _issues.isNotEmpty)
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
