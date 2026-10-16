/// When the next episode arrives, said in one line.
///
/// The page used to carry four boxes counting days, hours, minutes and
/// seconds. Nobody reads a page for the seconds, and four numbers took a
/// band of the page to say one thing. This says it the way a person would:
/// six days, or eighteen hours, or forty minutes — whichever unit the wait
/// is actually measured in.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/localized_text.dart';
import 'details_hero_actions.dart';
import '../../../../shared/widgets/apple_liquid_glass.dart';

const Key kNextAiringChipKey = Key('next-airing-chip');

/// The wait, in the largest unit that still has a whole number in it.
///
/// Arabic counts in more than two forms — one thing, two things, a few, many
/// — so the unit is chosen by the count rather than by adding an 's'.
String formatNextAiringWait(BuildContext context, Duration remaining) {
  if (remaining <= Duration.zero) {
    return 'الآن';
  }

  if (remaining.inDays >= 1) {
    final days = remaining.inDays;

    return switch (days) {
      1 => 'يوم',
      2 => 'يومين',
      >= 3 && <= 10 => '$days أيام',
      _ => '$days يومًا',
    };
  }

  if (remaining.inHours >= 1) {
    final hours = remaining.inHours;

    return switch (hours) {
      1 => 'ساعة',
      2 => 'ساعتين',
      >= 3 && <= 10 => '$hours ساعات',
      _ => '$hours ساعة',
    };
  }

  final minutes = remaining.inMinutes;
  if (minutes < 1) {
    return 'أقل من دقيقة';
  }

  return switch (minutes) {
    1 => 'دقيقة',
    2 => 'دقيقتين',
    >= 3 && <= 10 => '$minutes دقائق',
    _ => '$minutes دقيقة',
  };
}

/// One line saying when the next episode lands.
class NextAiringChip extends StatefulWidget {
  const NextAiringChip({super.key, required this.nextAiring});

  final NextAiring nextAiring;

  @override
  State<NextAiringChip> createState() => _NextAiringChipState();
}

class _NextAiringChipState extends State<NextAiringChip> {
  Timer? _timer;
  late Duration _remaining;

  DateTime get _airingDate => DateTime.fromMillisecondsSinceEpoch(
    widget.nextAiring.unixTime * 1000,
    isUtc: true,
  );

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant NextAiringChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nextAiring.unixTime != widget.nextAiring.unixTime) _start();
  }

  Duration _calculateRemaining() {
    final difference = _airingDate.difference(DateTime.now().toUtc());
    return difference.isNegative ? Duration.zero : difference;
  }

  void _start() {
    _timer?.cancel();
    _remaining = _calculateRemaining();
    if (_remaining == Duration.zero) return;

    // A line that says "six days" has nothing to show a second later. It is
    // read once a minute, and only in the last minute is there a second hand
    // worth following.
    void schedule() {
      final interval = _remaining.inMinutes >= 1
          ? const Duration(seconds: 30)
          : const Duration(seconds: 1);
      _timer = Timer(interval, () {
        if (!mounted) return;
        setState(() => _remaining = _calculateRemaining());
        if (_remaining == Duration.zero) return;
        schedule();
      });
    }

    schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final wait = formatNextAiringWait(context, _remaining);

    // The episode number is left out: the catalog does not always carry one
    // for the episode still to come, and "الحلقة 0" is worse than saying
    // plainly that the next one is on its way.
    final label = _remaining == Duration.zero
        ? appText(
            context,
            english: 'Next episode is out',
            arabic: 'الحلقة القادمة متاحة',
          )
        : appText(
            context,
            english: 'Next episode in $wait',
            arabic: 'الحلقة القادمة بعد $wait',
          );

    return KeyedSubtree(
      key: kNextAiringChipKey,
      child: AppleLiquidGlassSurface(
        borderRadius: BorderRadius.circular(kDetailsHeroActionHeight / 2),
        // The same glass as the buttons above it, so the line reads as part
        // of the same row of controls rather than a notice pinned to them.
        // Matches the pills above it — which is to say, no blur either.
        fallbackBlur: false,
        fallbackColor: kDetailsHeroGlassFallback,
        fallbackBorder: BorderSide(
          color: colors.onSurfaceVariant.withValues(alpha: 0.12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.schedule_rounded, size: 17, color: colors.onSurface),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
