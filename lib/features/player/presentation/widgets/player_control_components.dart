
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/services.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import 'hotstar_player_style.dart';

/// A ±N second seek glyph: lucide's rotate arrows with the configured
/// duration inside them, the way Harbor draws its seek buttons.
///
/// The two directions are separate glyphs rather than one mirrored: lucide
/// puts the arrowhead at the top of both, and mirroring moved it to the
/// wrong side of the circle.
///
/// The number is drawn rather than baked in because Material only ships
/// replay_5/10/30 — not every value the seek-duration setting allows.
class SeekIcon extends StatelessWidget {
  final bool forward;
  final int seconds;
  final double size;
  final Color color;

  const SeekIcon({
    super.key,
    required this.forward,
    required this.seconds,
    this.size = 24,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final arrow = Icon(
      forward ? LucideIcons.rotateCw200 : LucideIcons.rotateCcw200,
      size: size,
      color: color,
    );
    final label = seconds.toString();
    final double fontSize = size * (label.length >= 3 ? 0.26 : 0.34);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          arrow,
          Padding(
            // Sits a touch below centre: the arrowhead takes the top of the
            // ring, so centring the number in the box reads as high.
            padding: EdgeInsets.only(top: size * 0.08),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                height: 1.0,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A phone with an arrow turning around it: the button that flips the player
/// between portrait and landscape.
///
/// Lucide has no single glyph for this, and the mark this replaces —
/// `rotate-3d` — is a cube tumbling in space, which named the verb without
/// naming what it turns. Two of lucide's own glyphs stacked say both, and
/// keep the stroke weight of the row they sit in, which a Material icon
/// borrowed for the purpose would not.
class RotateScreenIcon extends StatelessWidget {
  const RotateScreenIcon({
    super.key,
    this.size = 24,
    this.color = Colors.white,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(LucideIcons.rotateCw200, size: size, color: color),
          // Half the box: the ring's clear middle is about seven tenths of
          // it, so the phone sits inside without its corners meeting the
          // stroke.
          Icon(LucideIcons.smartphone200, size: size * 0.5, color: color),
        ],
      ),
    );
  }
}

/// Top zone: back button + title/subtitle. Paints its own top scrim so the
/// chrome no longer needs a separate fixed-height Positioned gradient.
class PlayerTopBar extends StatelessWidget {
  final String title;
  final String? episodeLabel;
  final VoidCallback? onBack;
  final bool isTv;
  final FocusNode? backFocusNode;

  const PlayerTopBar({
    super.key,
    required this.title,
    this.episodeLabel,
    this.onBack,
    this.isTv = false,
    this.backFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;
    final double leftPadding = isTv
        ? edge
        : (padding.left > edge ? padding.left : edge);
    final double rightPadding = isTv
        ? edge
        : (padding.right > edge ? padding.right : edge);
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: HotstarPlayerStyle.topGradient),
      child: SafeArea(
        left: false,
        right: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(leftPadding, 4, rightPadding, 14),
          child: Row(
            children: [
              if (appleUsesPersistentLiquidGlassHeader)
                // Preserve the title's original clearance while the actual
                // back control lives in the route-independent overlay.
                const SizedBox(width: 60)
              else ...[
                // The glyph alone, with no pill behind it: the top scrim
                // already separates it from the picture, and a blurred disc
                // over artwork read as a smudge.
                PlayerIconButton(
                  icon: LucideIcons.chevronLeft200,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: onBack,
                  isTv: isTv,
                  focusNode: backFocusNode,
                  iconSize: isTv ? 34 : 30,
                  foregroundColor: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.start,
                      style: TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: isTv ? 22 : 18,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (episodeLabel != null && episodeLabel!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        episodeLabel!,
                        style: TextStyle(
                          color: HotstarPlayerStyle.secondaryText,
                          fontSize: isTv ? 16 : 13,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom zone shell: scrubber row on top, then a single flat controls row â
/// [leading] (playback) pinned left, a [Spacer], then [actions] (everything
/// else) on the right. All buttons are direct siblings of one [Row].
///
/// The [leading] group is pinned left; the [actions] group lives in a
/// horizontal scroll view that is right-anchored when it fits and scrolls to
/// reveal overflow when there are more buttons than fit (otherwise the extras
/// were simply clipped and unreachable).
///
/// On TV, Left/Right are driven explicitly by reading-order focus traversal
/// ([FocusNode.nextFocus]/[previousFocus]) within the row's own
/// [FocusTraversalGroup]; the handler consumes the arrows *before* the inner
/// [Scrollable] sees them, so focus moves cleanly across the whole row (and the
/// scroll view follows focus via the framework's ensureVisible) with no scroll
/// trap. Up/Down still bubble out to move between the scrubber / controls /
/// top-bar rows. (Off TV the handler is null, so desktop keyboard arrows keep
/// their seek/volume behaviour and touch just scrolls.) Paints its own scrim.
///
/// An optional [center] group overlays the row at its true horizontal
/// midpoint (see [_buildRow]) — used for the desktop seek trio.
class PlayerBottomBar extends StatelessWidget {
  final Widget progressBar;
  final List<Widget> leading;
  final List<Widget> actions;
  final bool isTv;

  /// On touch the [actions] go in a finger-scrollable strip (so a long list is
  /// reachable); on TV/desktop they stay a fixed right-aligned group navigated
  /// by D-pad. A keyboard [Scrollable] would re-introduce the focus trap, so it
  /// is used only where there's no directional focus (touch).
  final bool isTouch;

  /// Optional group pinned to the true horizontal center of the bar
  /// (overlaid via [Stack], independent of how wide [leading]/[actions] are)
  /// instead of sitting inline in the [leading] row. Used for the desktop
  /// seek trio so it lines up under the middle of the video regardless of
  /// the volume control's width on one side or the action icons' count on
  /// the other.
  final Widget? center;

  const PlayerBottomBar({
    super.key,
    required this.progressBar,
    this.leading = const [],
    this.actions = const [],
    this.isTv = false,
    this.isTouch = false,
    this.center,
  });

  KeyEventResult _handleRowKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      primary?.nextFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      primary?.previousFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;
    final double leftPadding = isTv
        ? edge
        : (padding.left > edge ? padding.left : edge);
    final double rightPadding = isTv
        ? edge
        : (padding.right > edge ? padding.right : edge);
    return SafeArea(
      left: false,
      right: false,
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(leftPadding, 2, rightPadding, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [progressBar, _buildRow()],
        ),
      ),
    );
  }

  Widget _buildRow() {
    final row = FocusTraversalGroup(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: isTv ? _handleRowKey : null,
        child: Row(
          children: [
            // Left group: play/pause, lock, next, volume - always visible.
            ...leading,
            if (isTouch)
              // Touch: right-anchored finger-scroll strip so a long action
              // list is never clipped out of reach.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              )
            else ...[
              // TV/desktop: fixed right-aligned group (D-pad nav).
              const Spacer(),
              ...actions,
            ],
          ],
        ),
      ),
    );
    if (center == null) return row;
    // Overlaid rather than inlined so it lands at the bar's true horizontal
    // center regardless of how wide leading/actions are on either side.
    return Stack(
      alignment: Alignment.center,
      children: [
        row,
        Center(child: center!),
      ],
    );
  }
}

/// Compact icon-only button for utilities (resize, PiP, fullscreen) and the
/// top-bar back button. Tooltip doubles as the semantics label.
class PlayerIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isTv;
  final bool highlight;
  final FocusNode? focusNode;

  /// Optional icon-size override (the tap target grows to match). Used by the
  /// top-bar back button so it reads at the same weight as the title.
  final double? iconSize;
  final Color? foregroundColor;

  /// When set, replaces the plain [icon] glyph with a custom-built one (e.g.
  /// [SeekIcon]) that still gets this button's hover/highlight color and
  /// sizing. [icon] is still required as the semantic fallback value.
  final Widget Function(Color color, double size)? iconBuilder;

  const PlayerIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isTv = false,
    this.highlight = false,
    this.focusNode,
    this.iconSize,
    this.foregroundColor,
    this.iconBuilder,
  });

  @override
  State<PlayerIconButton> createState() => _PlayerIconButtonState();
}

class _PlayerIconButtonState extends State<PlayerIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final double glyph = widget.iconSize ?? (widget.isTv ? 28 : 26);
    final double box = glyph + (widget.isTv ? 20 : 18);

    Color iconColor;
    if (widget.foregroundColor != null) {
      iconColor = widget.foregroundColor!;
    } else if (_hovered) {
      iconColor = HotstarPlayerStyle.accent;
    } else if (widget.highlight) {
      iconColor = HotstarPlayerStyle.accent;
    } else {
      iconColor = Colors.white;
    }

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: CustomButton(
          onPressed: widget.onPressed,
          showFocusHighlight: widget.isTv,
          focusNode: widget.focusNode,
          shape: const CircleBorder(),
          child: SizedBox(
            width: box,
            height: box,
            child: widget.iconBuilder != null
                ? widget.iconBuilder!(iconColor, glyph)
                : Icon(widget.icon, color: iconColor, size: glyph),
          ),
        ),
      ),
    );
  }
}

/// Labelled icon button for the controls row (Sources, Subtitles, Speed, â¦).
/// Activates on tap and on D-pad/keyboard select/enter/space when focused;
/// directional navigation between buttons is handled natively by the
/// enclosing traversal group â this widget never moves focus itself.
class PlayerActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;
  final bool isTv;
  final FocusNode? focusNode;

  const PlayerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlight = false,
    this.isTv = false,
    this.focusNode,
  });

  @override
  State<PlayerActionButton> createState() => _PlayerActionButtonState();
}

class _PlayerActionButtonState extends State<PlayerActionButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final showBg = (widget.highlight || _focused || _pressed) && !_hovered;
    final color = (widget.highlight || _hovered || _focused || _pressed)
        ? HotstarPlayerStyle.accent
        : Colors.white;
    final showTvFocusRing = widget.isTv && _focused;

    return Semantics(
      button: true,
      selected: widget.highlight,
      label: widget.label,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: widget.onTap,
              onHighlightChanged: _setPressed,
              borderRadius: BorderRadius.circular(8),
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              child: AnimatedContainer(
                duration: HotstarPlayerStyle.fastMotionDuration,
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: showBg
                      ? HotstarPlayerStyle.accent.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: showTvFocusRing
                      ? Border.all(color: HotstarPlayerStyle.accent, width: 2)
                      : null,
                  boxShadow: showTvFocusRing
                      ? [
                          BoxShadow(
                            color: HotstarPlayerStyle.accent.withValues(
                              alpha: 0.2,
                            ),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, color: color, size: 20),
                    const SizedBox(width: 6),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
