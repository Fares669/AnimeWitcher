import 'package:flutter/material.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import '../../data/anime4k.dart';
import 'hotstar_player_style.dart';
import 'player_ltr.dart';

/// Picks the Anime4K mode, and nothing else.
///
/// Everything about setting the feature up — the shader folder, the network
/// size, the before-and-after — lives in settings. Mid-episode the only
/// question worth a panel is which mode is running, so this is a list of
/// modes and a line saying what the chosen one is for.
class Anime4kPlayerSheet {
  const Anime4kPlayerSheet._();

  static void show({
    required BuildContext context,
    required Anime4kMode currentMode,
    required ValueChanged<Anime4kMode> onModeSelected,
  }) {
    showPlayerDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            var mode = currentMode;
            final size = MediaQuery.sizeOf(context);
            final isCompact = size.shortestSide < 600;
            final maxWidth = isCompact
                ? (size.width - 32).clamp(260.0, 340.0).toDouble()
                : 360.0;

            return Dialog(
              backgroundColor: HotstarPlayerStyle.background,
              insetPadding: EdgeInsets.symmetric(
                horizontal: isCompact ? 14 : 16,
                vertical: isCompact ? 16 : 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(isCompact ? 14 : 16),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: size.height * 0.8,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ANIME4K',
                              style: TextStyle(
                                color: HotstarPlayerStyle.secondaryText,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              anime4kModeHint(context, mode),
                              style: const TextStyle(
                                color: HotstarPlayerStyle.secondaryText,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final value in Anime4kMode.values)
                                _ModeRow(
                                  label: value == Anime4kMode.off
                                      ? appText(
                                          context,
                                          english: 'Off',
                                          arabic: 'إيقاف',
                                        )
                                      : '${appText(context, english: 'Mode', arabic: 'النمط')} ${value.label}',
                                  selected: mode == value,
                                  onTap: () {
                                    setState(() => mode = value);
                                    onModeSelected(value);
                                    Navigator.pop<void>(ctx);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// One row of the list, highlighted when it is the running mode.
class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: HotstarPlayerStyle.primaryText,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What each mode is for, in one line.
String anime4kModeHint(BuildContext context, Anime4kMode mode) {
  return switch (mode) {
    Anime4kMode.off => appText(
      context,
      english: 'The picture is left as the source made it.',
      arabic: 'تُترك الصورة كما هي من المصدر.',
    ),
    Anime4kMode.a => appText(
      context,
      english: 'Restore + upscale. The best all-rounder for most anime.',
      arabic: 'ترميم وتكبير. الأنسب لأغلب الأنميات.',
    ),
    Anime4kMode.b => appText(
      context,
      english: 'Softer restore. Kinder to compressed or noisy sources.',
      arabic: 'ترميم أخف. ألطف مع المصادر المضغوطة أو المشوّشة.',
    ),
    Anime4kMode.c => appText(
      context,
      english: 'Denoise while upscaling, for sources already clean.',
      arabic: 'إزالة تشويش مع التكبير، للمصادر النظيفة أصلًا.',
    ),
    Anime4kMode.aa => appText(
      context,
      english: 'Mode A run twice. Slower, for badly degraded sources.',
      arabic: 'النمط A مرتين. أبطأ، للمصادر السيئة جدًا.',
    ),
    Anime4kMode.bb => appText(
      context,
      english: 'Mode B run twice.',
      arabic: 'النمط B مرتين.',
    ),
    Anime4kMode.ca => appText(
      context,
      english: 'Mode C followed by a restore pass.',
      arabic: 'النمط C يتبعه ترميم.',
    ),
  };
}
