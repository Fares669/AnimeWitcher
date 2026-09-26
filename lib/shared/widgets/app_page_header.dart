import 'package:flutter/material.dart';

import '../../core/utils/window_controls_inset.dart';
import 'app_back_button.dart';
import 'apple_liquid_glass.dart';

/// Standard page chrome: route title on the content side and Back on the
/// physical left. Arabic keeps the title on the physical right.
class AppPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageAppBar({
    super.key,
    required this.title,
    this.canPop = true,
  });

  final String title;
  final bool canPop;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    return Directionality(
      textDirection: TextDirection.ltr,
      child: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        titleSpacing: 16,
        leading: canPop && !appleUsesPersistentLiquidGlassHeader
            ? const AppBackButton()
            : null,
        actions: const <Widget>[WindowControlsGap()],
        title: ApplePersistentGlassHeaderScope(
          enabled: canPop,
          onBack: () => Navigator.of(context).maybePop(),
          child: Align(
            alignment:
                isArabic ? Alignment.centerRight : Alignment.centerLeft,
            child: Directionality(
              textDirection:
                  isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
