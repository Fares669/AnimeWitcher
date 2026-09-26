import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/app_layout_style.dart';
import 'glass_dialog.dart';

/// Asks which layout to use, with a small drawing of each.
///
/// On the first launch [firstRun] is set: the dialog cannot be dismissed
/// without a choice, and says why it is being asked. From settings it is an
/// ordinary dialog that can be closed without changing anything.
Future<void> showAppLayoutPicker(
  BuildContext context,
  WidgetRef ref, {
  bool firstRun = false,
}) {
  final arabic =
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
  // A desktop or a tablet picks from three, a phone from the dock and the
  // side menu.
  final wide = appLayoutsAvailable(context);
  final choices = appLayoutChoices(wide: wide);
  var selected = effectiveAppLayout(
    stored: ref.read(appLayoutStyleProvider),
    isDesktopPlatform: wide,
  );

  return showGlassDialog<void>(
    context: context,
    barrierDismissible: !firstRun,
    builder: (dialogContext) => PopScope(
      canPop: !firstRun,
      child: StatefulBuilder(
        builder: (context, setState) {
          final width = (MediaQuery.sizeOf(context).width - 64)
              .clamp(280.0, 760.0)
              .toDouble();
          return AlertDialog(
            surfaceTintColor: Colors.transparent,
            // A short phone scrolls rather than running the cards into the
            // buttons.
            scrollable: true,
            title: Text(
              firstRun
                  ? (arabic ? 'اختر شكل التطبيق' : 'Choose a layout')
                  : (arabic ? 'شكل التطبيق' : 'App layout'),
            ),
            content: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    arabic
                        ? 'مكان قائمة التنقل. يمكنك تغييره لاحقًا من الإعدادات.'
                        : 'Where the navigation sits. You can change it later in settings.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  // A phone's two side by side, each an upright phone: a row
                  // shares the width out exactly, where two halves in a wrap
                  // could round over and fold onto a second line.
                  if (!wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < choices.length; i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          Expanded(
                            child: AppLayoutOptionCard(
                              style: choices[i],
                              arabic: arabic,
                              selected: choices[i] == selected,
                              phone: true,
                              onTap: () =>
                                  setState(() => selected = choices[i]),
                            ),
                          ),
                        ],
                      ],
                    )
                  else
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final style in choices)
                          SizedBox(
                            width: width >= 600 ? (width - 24) / 3 : width,
                            child: AppLayoutOptionCard(
                              style: style,
                              arabic: arabic,
                              selected: style == selected,
                              onTap: () => setState(() => selected = style),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            actions: [
              if (!firstRun)
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(arabic ? 'إلغاء' : 'Cancel'),
                ),
              FilledButton(
                onPressed: () {
                  ref.read(appLayoutStyleProvider.notifier).select(selected);
                  Navigator.of(dialogContext).pop();
                },
                child: Text(arabic ? 'تطبيق' : 'Apply'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// One choice in the picker: a drawing of the layout, its name, and a line
/// on what it is for.
class AppLayoutOptionCard extends StatelessWidget {
  const AppLayoutOptionCard({
    super.key,
    required this.style,
    required this.arabic,
    required this.selected,
    required this.onTap,
    this.phone = false,
  });

  final AppLayoutStyle style;
  final bool arabic;
  final bool selected;
  final VoidCallback onTap;

  /// Drawn as an upright phone.
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? colors.primary
                  : colors.outlineVariant.withValues(alpha: 0.5),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: phone ? 10 / 16 : 16 / 10,
                child: AppLayoutPreview(
                  style: style,
                  accent: colors.primary,
                  phone: phone,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      style.label(arabic: arabic),
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: colors.primary,
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                style.description(arabic: arabic),
                // A phone's card is narrow: room for the whole line.
                maxLines: phone ? 3 : 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A miniature of the app in [style]: banner, rows of posters, and the
/// navigation where that layout puts it.
class AppLayoutPreview extends StatelessWidget {
  const AppLayoutPreview({
    super.key,
    required this.style,
    required this.accent,
    this.phone = false,
  });

  final AppLayoutStyle style;
  final Color accent;

  /// Drawn upright, with fewer posters to a row.
  final bool phone;

  static const _screen = Color(0xFF141412);
  static const _chrome = Color(0xFF2A2927);
  static const _banner = Color(0xFF7A2A22);
  static const _poster = Color(0xFF5F5E5A);

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: _block(_banner)),
          const SizedBox(height: 4),
          Expanded(flex: 2, child: _row(phone ? 2 : 4)),
          const SizedBox(height: 4),
          Expanded(flex: 3, child: _row(phone ? 3 : 6)),
        ],
      ),
    );

    final Widget body = switch (style) {
      AppLayoutStyle.dock => Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            bottom: 6,
            left: 0,
            right: 0,
            child: Center(child: _dock()),
          ),
        ],
      ),
      AppLayoutStyle.sideRail => Row(
        children: [
          Container(
            width: 16,
            color: _chrome,
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              children: [
                for (var i = 0; i < 5; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: _dot(i == 0 ? accent : Colors.white38),
                  ),
              ],
            ),
          ),
          Expanded(child: content),
        ],
      ),
      AppLayoutStyle.topBar => Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 12,
              color: Colors.black.withValues(alpha: 0.55),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  _bar(accent, 14),
                  for (var i = 0; i < 3; i++) ...[
                    const SizedBox(width: 4),
                    _bar(Colors.white38, 10),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(color: _screen, child: body),
    );
  }

  Widget _block(Color color) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(4),
    ),
  );

  // Stretched: an empty DecoratedBox takes no height of its own, so without
  // it every poster in the row drew as nothing.
  Widget _row(int count) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < count; i++) ...[
        if (i > 0) const SizedBox(width: 3),
        Expanded(child: _block(_poster)),
      ],
    ],
  );

  Widget _dot(Color color) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  Widget _bar(Color color, double width) => Container(
    width: width,
    height: 3,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );

  Widget _dock() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    decoration: BoxDecoration(
      color: _chrome,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++) ...[
          if (i > 0) const SizedBox(width: 5),
          _dot(i == 4 ? accent : Colors.white38),
        ],
      ],
    ),
  );
}
