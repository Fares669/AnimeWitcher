import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/utils/window_controls_inset.dart';
import 'app_back_button.dart';
import 'apple_liquid_glass.dart';

/// A compact Apple-style backdrop: blur is strongest at the system edge and
/// progressively fades toward the content edge.
///
/// A few native BackdropFilter bands keep this cheap and dependency-free while
/// avoiding a full-screen blur.
class AppProgressiveHeaderBackdrop extends StatelessWidget {
  const AppProgressiveHeaderBackdrop({super.key});

  static const List<double> _sigmas = <double>[18, 14, 10, 7, 4, 2];

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bandHeight = constraints.maxHeight / _sigmas.length;
          return Stack(
            fit: StackFit.expand,
            children: [
              for (var i = 0; i < _sigmas.length; i++)
                Positioned(
                  left: 0,
                  right: 0,
                  top: bandHeight * i,
                  height: bandHeight + 1,
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: _sigmas[i],
                        sigmaY: _sigmas[i],
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: 0.26),
                      surface.withValues(alpha: 0.14),
                      surface.withValues(alpha: 0.05),
                      surface.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.42, 0.76, 1],
                  ),
                ),
              ),
            ],
          );
        },
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
                          style: const TextStyle(fontWeight: FontWeight.bold),
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
