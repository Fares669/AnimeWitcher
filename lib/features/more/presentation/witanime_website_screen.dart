import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/extensions/providers/witanime_provider.dart';
import '../../../core/extensions/providers/witanime_support_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../shared/widgets/app_page_header.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';
import 'more_sidebar_shell.dart';

class WitanimeWebsiteScreen extends StatelessWidget {
  const WitanimeWebsiteScreen({super.key, this.openLink});

  final Future<bool> Function(Uri)? openLink;

  static const _account = [
    (Icons.login_rounded, 'تسجيل الدخول', '/login'),
    (Icons.person_add_alt_1_rounded, 'إنشاء حساب', '/register'),
    (Icons.lock_reset_rounded, 'استعادة كلمة المرور', '/forgot-password'),
    (Icons.person_outline_rounded, 'الملف الشخصي', '/profile'),
    (Icons.bookmarks_outlined, 'القوائم والمفضلة', '/profile/lists'),
  ];
  static const _support = [
    (Icons.add_to_queue_rounded, 'طلب أنمي', '/request'),
    (Icons.mail_outline_rounded, 'التواصل', '/contact'),
    (Icons.description_outlined, 'شروط الاستخدام', '/terms'),
    (Icons.privacy_tip_outlined, 'سياسة الخصوصية', '/privacy'),
    (Icons.copyright_rounded, 'حقوق الملكية', '/dmca'),
  ];

  Future<void> _open(BuildContext context, String path) async {
    final uri = WitanimeProvider.websiteUri(path);
    try {
      final opened =
          await (openLink?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (opened) return;
    } on Exception {
      // The platform may be unable to launch a browser.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تعذر فتح موقع Witanime.')));
  }

  Future<void> _openSupportForm(
    BuildContext context, {
    required String path,
    required String title,
    required String primaryLabel,
    required String primaryKey,
  }) async {
    ProviderContainer? container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      await _open(context, path);
      return;
    }
    final activeContainer = container;
    await showDialog<void>(
      context: context,
      builder: (_) => _WitanimeSupportFormDialog(
        title: title,
        primaryLabel: primaryLabel,
        onSubmit: (primary, message) async {
          final result = await activeContainer
              .read(witanimeSupportServiceProvider)
              .submitSupportForm(
                path: path,
                fields: {
                  primaryKey: primary,
                  if (message.isNotEmpty) 'message': message,
                },
              );
          if (result.accepted) {
            activeContainer
                .read(notificationServiceProvider)
                .showSuccess(result.message);
            return true;
          }
          if (result.requiresBrowserVerification) {
            if (context.mounted) await _open(context, path);
            return true;
          }
          activeContainer
              .read(notificationServiceProvider)
              .showError(result.message);
          return false;
        },
      ),
    );
  }

  Widget _group(
    BuildContext context,
    String title,
    List<(IconData, String, String)> actions,
  ) => SettingsGroup(
    title: title,
    children: [
      for (var i = 0; i < actions.length; i++)
        SettingsTile(
          icon: actions[i].$1,
          title: actions[i].$2,
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => _open(context, actions[i].$3),
          isLast: i == actions.length - 1,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final embedded = MorePaneScope.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: 'Witanime',
        canPop: !embedded && Navigator.of(context).canPop(),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          appPageHeaderContentTopInset(context) + 12,
          16,
          100,
        ),
        children: [
          _group(context, 'حساب Witanime على الموقع', _account),
          const SizedBox(height: 16),
          _group(context, 'الدعم', _support),
          const SizedBox(height: 16),
          SettingsGroup(
            title: 'نماذج الدعم داخل التطبيق',
            children: [
              SettingsTile(
                icon: Icons.add_to_queue_rounded,
                title: 'طلب أنمي من التطبيق',
                onTap: () => _openSupportForm(
                  context,
                  path: '/request',
                  title: 'طلب أنمي',
                  primaryLabel: 'اسم الأنمي',
                  primaryKey: 'title',
                ),
              ),
              SettingsTile(
                icon: Icons.support_agent_rounded,
                title: 'مراسلة الدعم من التطبيق',
                onTap: () => _openSupportForm(
                  context,
                  path: '/contact',
                  title: 'التواصل مع Witanime',
                  primaryLabel: 'الموضوع',
                  primaryKey: 'subject',
                ),
                isLast: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WitanimeSupportFormDialog extends StatefulWidget {
  const _WitanimeSupportFormDialog({
    required this.title,
    required this.primaryLabel,
    required this.onSubmit,
  });

  final String title;
  final String primaryLabel;
  final Future<bool> Function(String primary, String message) onSubmit;

  @override
  State<_WitanimeSupportFormDialog> createState() =>
      _WitanimeSupportFormDialogState();
}

class _WitanimeSupportFormDialogState
    extends State<_WitanimeSupportFormDialog> {
  final _primaryController = TextEditingController();
  final _messageController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _primaryController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _primaryController,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: widget.primaryLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _messageController,
              enabled: !_submitting,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'تفاصيل إضافية',
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
          onPressed: _submitting
              ? null
              : () async {
                  final primary = _primaryController.text.trim();
                  if (primary.isEmpty) return;
                  setState(() => _submitting = true);
                  final close = await widget.onSubmit(
                    primary,
                    _messageController.text.trim(),
                  );
                  if (!context.mounted) return;
                  if (close) {
                    Navigator.of(context).pop();
                  } else {
                    setState(() => _submitting = false);
                  }
                },
          child: const Text('إرسال'),
        ),
      ],
    );
  }
}
