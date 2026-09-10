
import 'package:flutter/material.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'hotstar_player_style.dart';
import 'player_ltr.dart';


class PlayerBottomSheets {
  static void showSpeedSelection({
    required BuildContext context,
    required double currentSpeed,
    required double maxSpeed,
    required void Function(double) onSpeedSelected,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final sliderMax = maxSpeed < 3.0 ? maxSpeed : 3.0;
    final speeds = [
      0.25,
      1.0,
      1.25,
      1.5,
      2.0,
    ].where((speed) => speed <= sliderMax + 0.001).toList();
    final sliderDivisions = ((sliderMax - 0.25) / 0.05).round();
    double selectedSpeed = currentSpeed.clamp(0.25, sliderMax).toDouble();

    showPlayerDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            void setSpeed(double value) {
              final next = value.clamp(0.25, sliderMax).toDouble();
              setState(() => selectedSpeed = next);
              onSpeedSelected(next);
            }

            final size = MediaQuery.sizeOf(context);
            final isCompact = size.shortestSide < 600;
            final compactWidth = (size.width - 32)
                .clamp(280.0, 360.0)
                .toDouble();
            final maxWidth = isCompact
                ? compactWidth
                : (size.width >= 900 ? 520.0 : compactWidth);
            final verticalInsets = isCompact ? 32.0 : 48.0;
            final availableHeight = (size.height - verticalInsets)
                .clamp(120.0, isCompact ? 340.0 : 420.0)
                .toDouble();
            final compactHeight = (size.height * (isCompact ? 0.58 : 0.68))
                .clamp(120.0, availableHeight)
                .toDouble();

            return Dialog(
              backgroundColor: HotstarPlayerStyle.background,
              insetPadding: EdgeInsets.symmetric(
                horizontal: isCompact ? 14 : 16,
                vertical: isCompact ? 16 : 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(isCompact ? 14 : 20),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: compactHeight,
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    brightness: Brightness.dark,
                    colorScheme: const ColorScheme.dark(
                      primary: HotstarPlayerStyle.accent,
                      surface: HotstarPlayerStyle.background,
                      onSurface: HotstarPlayerStyle.primaryText,
                    ),
                    chipTheme: ChipThemeData(
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      selectedColor: HotstarPlayerStyle.accent.withValues(
                        alpha: 0.22,
                      ),
                      disabledColor: Colors.white.withValues(alpha: 0.04),
                      labelStyle: const TextStyle(
                        color: HotstarPlayerStyle.secondaryText,
                      ),
                      secondaryLabelStyle: const TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                      ),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      isCompact ? 16 : 24,
                      isCompact ? 12 : 18,
                      isCompact ? 16 : 24,
                      isCompact ? 16 : 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.playbackSpeed,
                                style: TextStyle(
                                  color: HotstarPlayerStyle.primaryText,
                                  fontSize: isCompact ? 15 : 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(ctx),
                              icon: const Icon(Icons.close),
                              color: HotstarPlayerStyle.secondaryText,
                              autofocus: true,
                            ),
                          ],
                        ),
                        SizedBox(height: isCompact ? 10 : 20),
                        Text(
                          _formatSpeed(selectedSpeed),
                          style: TextStyle(
                            color: HotstarPlayerStyle.primaryText,
                            fontSize: isCompact ? 23 : 28,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: isCompact ? 14 : 24),
                        Row(
                          children: [
                            _speedStepButton(
                              icon: Icons.remove,
                              onPressed: () => setSpeed(selectedSpeed - 0.1),
                              compact: isCompact,
                            ),
                            SizedBox(width: isCompact ? 10 : 18),
                            Expanded(
                              child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: isCompact ? 10 : 18,
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white.withValues(
                                    alpha: 0.08,
                                  ),
                                  thumbColor: Colors.white,
                                  overlayColor: HotstarPlayerStyle.accent
                                      .withValues(alpha: 0.12),
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 4,
                                  ),
                                  trackShape:
                                      const RoundedRectSliderTrackShape(),
                                ),
                                child: CustomSlider(
                                  value: selectedSpeed,
                                  min: 0.25,
                                  max: sliderMax,
                                  step: 0.05,
                                  divisions: sliderDivisions > 0
                                      ? sliderDivisions
                                      : null,
                                  // Pure visual indicator on TV — the −/+
                                  // buttons adjust it. Keeping it out of focus
                                  // traversal means D-pad Up/Down isn't trapped
                                  // and moves between the buttons and presets.
                                  focusable: false,
                                  onChanged: setSpeed,
                                ),
                              ),
                            ),
                            SizedBox(width: isCompact ? 10 : 18),
                            _speedStepButton(
                              icon: Icons.add,
                              onPressed: () => setSpeed(selectedSpeed + 0.1),
                              compact: isCompact,
                            ),
                          ],
                        ),
                        SizedBox(height: isCompact ? 14 : 24),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: isCompact ? 7 : 10,
                          runSpacing: isCompact ? 7 : 10,
                          children: speeds.map((speed) {
                            final isSelected =
                                (selectedSpeed - speed).abs() < 0.01;
                            return _SpeedPresetChip(
                              speed: speed,
                              isSelected: isSelected,
                              isCompact: isCompact,
                              onTap: () => setSpeed(speed),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  static String _formatSpeed(double speed) {
    return '${speed.toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '')}x';
  }

  static Widget _speedStepButton({
    required IconData icon,
    required VoidCallback? onPressed,
    bool compact = false,
  }) {
    return _SpeedStepButton(icon: icon, onPressed: onPressed, compact: compact);
  }

}

class _SpeedPresetChip extends StatefulWidget {
  final double speed;
  final bool isSelected;
  final bool isCompact;
  final VoidCallback onTap;

  const _SpeedPresetChip({
    required this.speed,
    required this.isSelected,
    required this.isCompact,
    required this.onTap,
  });

  @override
  State<_SpeedPresetChip> createState() => _SpeedPresetChipState();
}

class _SpeedPresetChipState extends State<_SpeedPresetChip> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final showHighlight = _isHovered || _isFocused;
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedScale(
          scale: _isFocused ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: HotstarPlayerStyle.fastMotionDuration,
            width: widget.isCompact ? 76 : 104,
            padding: EdgeInsets.symmetric(vertical: widget.isCompact ? 10 : 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? HotstarPlayerStyle.accent.withValues(alpha: 0.22)
                  : (showHighlight
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.06)),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _isFocused
                    ? HotstarPlayerStyle.accent
                    : Colors.transparent,
                width: 1.5,
              ),
              boxShadow: _isFocused
                  ? [
                      BoxShadow(
                        color: HotstarPlayerStyle.accent.withValues(
                          alpha: 0.25,
                        ),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              PlayerBottomSheets._formatSpeed(widget.speed),
              textAlign: TextAlign.center,
              maxLines: 1,
              style: TextStyle(
                color: widget.isSelected
                    ? HotstarPlayerStyle.primaryText
                    : HotstarPlayerStyle.secondaryText,
                fontSize: widget.isCompact ? 13 : 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeedStepButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool compact;

  const _SpeedStepButton({
    required this.icon,
    required this.onPressed,
    required this.compact,
  });

  @override
  State<_SpeedStepButton> createState() => _SpeedStepButtonState();
}

class _SpeedStepButtonState extends State<_SpeedStepButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      child: AnimatedScale(
        scale: _isFocused ? 1.08 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: IconButton(
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: widget.compact ? 20 : 24),
          color: HotstarPlayerStyle.primaryText,
          style: IconButton.styleFrom(
            backgroundColor: _isFocused
                ? HotstarPlayerStyle.accent.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.06),
            fixedSize: Size(widget.compact ? 42 : 56, widget.compact ? 42 : 56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(widget.compact ? 10 : 14),
              side: BorderSide(
                color: _isFocused
                    ? HotstarPlayerStyle.accent
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
