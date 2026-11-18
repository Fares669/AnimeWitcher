import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/extensions/providers/witanime_provider.dart';
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
        ],
      ),
    );
  }
}
