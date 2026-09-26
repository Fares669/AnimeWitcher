import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/shared/widgets/glass_dialog.dart';

import 'details_seasons_bar.dart';

/// Asks how the seasons bar on an anime's page should look, with a drawing
/// of each style.
///
/// On the first launch [firstRun] is set and a choice has to be made; from
/// settings the dialog can be closed without changing anything.
Future<void> showSeasonsBarStylePicker(
  BuildContext context,
  WidgetRef ref, {
  bool firstRun = false,
}) {
  final arabic =
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
  var selected = ref.read(seasonsBarStyleProvider);

  return showGlassDialog<void>(
    context: context,
    barrierDismissible: !firstRun,
    builder: (dialogContext) => PopScope(
      canPop: !firstRun,
      child: StatefulBuilder(
        builder: (context, setState) {
          final width = (MediaQuery.sizeOf(context).width - 64)
              .clamp(280.0, 620.0)
              .toDouble();
          return AlertDialog(
            surfaceTintColor: Colors.transparent,
            title: Text(arabic ? 'شكل شريط المواسم' : 'Seasons bar style'),
            content: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    arabic
                        ? 'يظهر فوق الحلقات للتنقل بين المواسم والأفلام. يمكنك تغييره لاحقًا من الإعدادات.'
                        : 'Shown above the episodes to move between seasons and movies. You can change it later in settings.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final style in SeasonsBarStyle.values)
                        SizedBox(
                          width: width >= 440 ? (width - 12) / 2 : width,
                          child: _StyleCard(
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
                  ref.read(seasonsBarStyleProvider.notifier).select(selected);
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

class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.style,
    required this.arabic,
    required this.selected,
    required this.onTap,
  });

  final SeasonsBarStyle style;
  final bool arabic;
  final bool selected;
  final VoidCallback onTap;

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
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: const Color(0xFF141412),
                  child: SizedBox(
                    height: 84,
                    child: Center(
                      child: SeasonsBarStylePreview(
                        style: style,
                        accent: colors.primary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      style.label(arabic: arabic),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// A miniature of the bar in [style], three seasons long.
class SeasonsBarStylePreview extends StatelessWidget {
  const SeasonsBarStylePreview({
    super.key,
    required this.style,
    required this.accent,
  });

  final SeasonsBarStyle style;
  final Color accent;

  static const _art = <Color>[
    Color(0xFF7A2A22),
    Color(0xFF3C3489),
    Color(0xFF085041),
  ];
  static const _labels = <String>['الموسم 1', 'الموسم 2', 'اوفا'];

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            switch (style) {
              SeasonsBarStyle.cards => Container(
                width: 64,
                height: 44,
                decoration: BoxDecoration(
                  color: _art[i],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: i == 0 ? accent : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                alignment: AlignmentDirectional.bottomStart,
                padding: const EdgeInsets.all(4),
                child: Text(
                  _labels[i],
                  style: TextStyle(
                    color: i == 0 ? accent : Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SeasonsBarStyle.pills => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: i == 0 ? accent : const Color(0xFF2C2C2A),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  _labels[i],
                  style: TextStyle(
                    color: i == 0 ? Colors.black : Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            },
          ],
        ],
      ),
    );
  }
}
