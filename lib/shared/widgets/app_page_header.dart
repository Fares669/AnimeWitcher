import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/utils/window_controls_inset.dart';
import 'app_back_button.dart';
import 'apple_liquid_glass.dart';

/// A compact translucent header backdrop.
///
/// One fixed BackdropFilter keeps scrolling cheap. A transparent surface
/// gradient softens the lower edge so the header blends into content instead
/// of ending as an obvious tinted line.
class AppProgressiveHeaderBackdrop extends StatelessWidget {
  const AppProgressiveHeaderBackdrop({super.key});

  static const double _sigma = 12;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma),
              child: const SizedBox.expand(),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  surface.withValues(alpha: 0.22),
                  surface.withValues(alpha: 0.12),
                  surface.withValues(alpha: 0.04),
                  surface.withValues(alpha: 0),
                ],
                stops: const [0, 0.52, 0.82, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Top padding that keeps initial scroll content below [AppPageAppBar]
/// while still allowing it to move underneath the translucent header.
double appPageHeaderContentTopInset(BuildContext context) =>
    MediaQuery.paddingOf(context).top + kToolbarHeight;

/// Standard conventional page chrome.
///
/// The title is physically centred in the viewport rather than centred in the
/// space left over by navigation/actions. Back is always on the physical left.
class AppPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageAppBar({
    super.key,
    required this.title,
    this.canPop = true,
    this.onBack,
    this.actions = const <Widget>[],
    this.titleKey,
  });

  final String title;
  final bool canPop;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Key? titleKey;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final theme = Theme.of(context);
    final appBarTitleStyle =
        (theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge)
            ?.copyWith(
              color:
                  theme.appBarTheme.foregroundColor ??
                  theme.colorScheme.onSurface,
              fontWeight: FontWeight.bold,
            );
    final pop = onBack ?? () => Navigator.of(context).maybePop();
    final leadingInset = windowControlsLeadingInset;
    final titleClearance =
        windowControlsSymmetricInset + (actions.isEmpty ? 72.0 : 120.0);
    final hasWindowControlsGap = actions.any((action) => action is WindowControlsGap);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            flexibleSpace: const AppProgressiveHeaderBackdrop(),
            leadingWidth:
                canPop && !appleUsesPersistentLiquidGlassHeader
                    ? 56 + leadingInset
                    : null,
            leading: canPop && !appleUsesPersistentLiquidGlassHeader
                ? Padding(
                    padding: EdgeInsets.only(left: leadingInset),
                    child: AppBackButton(onPressed: pop),
                  )
                : null,
            actions: <Widget>[
              ...actions,
              if (!hasWindowControlsGap) const WindowControlsGap(),
            ],
          ),
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: IgnorePointer(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: titleClearance),
                  child: Center(
                    child: ApplePersistentGlassHeaderScope(
                      enabled: canPop,
                      onBack: pop,
                      child: Directionality(
                        textDirection:
                            isArabic ? TextDirection.rtl : TextDirection.ltr,
                        child: Text(
                          title,
                          key: titleKey,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: appBarTitleStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
