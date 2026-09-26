/// Live pictures of parts of the app, drawn from the settings they show.
///
/// Used by the first-launch setup and by the settings pages, so the two show
/// the same thing: home in a layout and theme, an anime page with its
/// seasons bar, and the player with Anime4K and the skip button.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/theme/app_theme.dart';
import 'package:animewitcher/core/theme/theme_provider.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_seasons_bar.dart';
import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_control_components.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_settings_panel.dart';
import 'package:animewitcher/features/player/presentation/widgets/skip_segment_overlay.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';

class LivePreviewFrame extends StatelessWidget {
  const LivePreviewFrame({
    super.key,
    required this.caption,
    required this.child,
    this.note,
    this.followTheme = false,
    this.designSize,
  });

  /// An upright phone screen, for a preview of the phone's own layout.
  static const phoneSize = Size(390, 780);

  final String caption;
  final Widget child;

  /// The size the preview is drawn at before scaling; a wide window unless
  /// given.
  final Size? designSize;

  /// A line under the frame for what a still picture cannot show.
  final String? note;

  /// Caption and border in the app theme's colours, for a settings page;
  /// off for the setup screen, which is always dark.
  final bool followTheme;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = followTheme
        ? colors.onSurfaceVariant
        : Colors.white.withValues(alpha: 0.6);
    final edge = followTheme
        ? colors.outlineVariant
        : Colors.white.withValues(alpha: 0.12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(caption, style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 8),
        Expanded(
          child: Center(
            // Every preview is drawn at one fixed size and scaled to fit, so
            // it keeps the proportions of a real window at any screen size.
            child: FittedBox(
              fit: BoxFit.contain,
              child: Container(
                width: designSize?.width ?? _designWidth,
                height: designSize?.height ?? _designHeight,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(
                    designSize == null ? 14 : 36,
                  ),
                  border: Border.all(color: edge, width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                child: child,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 36,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: note == null ? 0 : 1,
            child: Center(
              child: Text(
                note ?? '',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

const double _designWidth = 960;
const double _designHeight = 600;
const _sample = AssetImage('assets/images/anime4k_sample.jpg');

/// The preview's colours, one set per theme.
class _Palette {
  const _Palette({
    required this.screen,
    required this.chrome,
    required this.banner,
    required this.poster,
    required this.line,
    required this.icon,
    required this.wide,
  });

  final Color screen;
  final Color chrome;
  final Color banner;
  final Color poster;
  final Color line;
  final Color icon;
  final List<Color> wide;

  static _Palette of(AppThemeStyle theme) => switch (theme) {
    AppThemeStyle.dark => dark,
    AppThemeStyle.light => light,
    AppThemeStyle.amber => amber,
    _ => _Palette.fromDark(AppTheme.paletteFor(theme)!),
  };

  /// A tinted dark theme's colours, as the preview draws them.
  factory _Palette.fromDark(AppDarkPalette p) => _Palette(
    screen: p.background,
    chrome: p.surfaceHigh,
    banner: p.selected,
    poster: p.surfaceHighest,
    line: p.outline,
    icon: Colors.white60,
    wide: <Color>[
      p.surfaceHighest,
      p.selected,
      p.surfaceHigh,
      p.surfaceHighest,
    ],
  );

  /// Black, like the app's dark theme.
  static const dark = _Palette(
    screen: Color(0xFF0B0B0D),
    chrome: Color(0xFF1E1E26),
    banner: Color(0xFF6E2A24),
    poster: Color(0xFF3A3A44),
    line: Color(0xFF55555F),
    icon: Colors.white60,
    wide: [
      Color(0xFF2E2E38),
      Color(0xFF0F5A45),
      Color(0xFF3C3489),
      Color(0xFF2E2E38),
    ],
  );

  /// Warm charcoal, like the amber theme.
  static const amber = _Palette(
    screen: Color(0xFF141412),
    chrome: Color(0xFF232322),
    banner: Color(0xFF7A2A22),
    poster: Color(0xFF5F5E5A),
    line: Color(0xFF6B6A66),
    icon: Colors.white60,
    wide: [
      Color(0xFF4A4A47),
      Color(0xFF0F5A45),
      Color(0xFF3C3489),
      Color(0xFF4A4A47),
    ],
  );

  static const light = _Palette(
    screen: Color(0xFFF4F3EF),
    chrome: Color(0xFFE2E0D9),
    banner: Color(0xFFE3A89E),
    poster: Color(0xFFC9C7BF),
    line: Color(0xFFB4B2A9),
    icon: Colors.black54,
    wide: [
      Color(0xFFD6D4CC),
      Color(0xFF9FD8C3),
      Color(0xFFC3BEF0),
      Color(0xFFD6D4CC),
    ],
  );
}

Widget _block(Color color, {double radius = 10}) => DecoratedBox(
  decoration: BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
  ),
);

Widget _bar(Color color, double width, {double height = 12}) => Container(
  width: width,
  height: height,
  decoration: BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(99),
  ),
);

/// Home in [layout], drawn as plain shapes — a banner, a row of wide cards,
/// a row of posters — so the only thing that changes between the choices is
/// where the navigation sits, and the colours of the chosen theme.
class HomeLayoutPreview extends StatelessWidget {
  const HomeLayoutPreview({
    super.key,
    required this.layout,
    required this.theme,
    this.phone = false,
  });

  final AppLayoutStyle layout;

  /// The theme to draw in.
  final AppThemeStyle theme;

  /// Drawn as an upright phone: fewer cards to a row. Pair it with
  /// [LivePreviewFrame.phoneSize].
  final bool phone;

  static const _icons = <IconData>[
    Icons.home_rounded,
    Icons.search_rounded,
    Icons.video_library_rounded,
    Icons.download_rounded,
    Icons.more_horiz_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final p = _Palette.of(theme);

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: p.screen,
      padding: EdgeInsets.fromLTRB(
        22,
        layout == AppLayoutStyle.topBar ? 64 : 22,
        22,
        layout == AppLayoutStyle.dock ? 80 : 22,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: _block(p.banner)),
          const SizedBox(height: 14),
          Expanded(
            flex: 2,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < (phone ? 2 : p.wide.length); i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: _block(p.wide[i])),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            flex: 3,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < (phone ? 3 : 6); i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: _block(p.poster)),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    Widget icon(IconData data, {bool selected = false}) => Container(
      width: 48,
      height: 36,
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.22) : null,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Icon(data, color: selected ? accent : p.icon, size: 22),
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: switch (layout) {
        AppLayoutStyle.dock => Stack(
          children: [
            Positioned.fill(child: content),
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: p.chrome,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < _icons.length; i++)
                        icon(_icons[i], selected: i == 0),
                      icon(Icons.newspaper_rounded),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        AppLayoutStyle.sideRail => Row(
          children: [
            Container(
              width: 72,
              color: p.chrome,
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: Column(
                children: [
                  for (var i = 0; i < _icons.length; i++) ...[
                    icon(_icons[i], selected: i == 0),
                    const SizedBox(height: 14),
                  ],
                  const Spacer(),
                  icon(Icons.newspaper_rounded),
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
                height: 50,
                color: p.chrome,
                child: Stack(
                  children: [
                    // The app's name, as a mark, and the news beside it.
                    Positioned(
                      left: 20,
                      top: 0,
                      bottom: 0,
                      child: Row(
                        textDirection: TextDirection.ltr,
                        children: [
                          _bar(accent, 90, height: 10),
                          const SizedBox(width: 8),
                          icon(Icons.newspaper_rounded),
                        ],
                      ),
                    ),
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < _icons.length; i++) ...[
                            if (i > 0) const SizedBox(width: 8),
                            icon(_icons[i], selected: i == 0),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      },
    );
  }
}

/// An anime's page drawn as plain shapes, with the seasons bar — what this
/// step sets — drawn for real and outlined.
class SeasonsBarPagePreview extends StatelessWidget {
  const SeasonsBarPagePreview({
    super.key,
    required this.style,
    required this.theme,
  });

  final SeasonsBarStyle style;

  /// The theme to draw in.
  final AppThemeStyle theme;

  static const _seasons = <String>[
    'الموسم 1',
    'الموسم 2',
    'الموسم 2 - الجزء 2',
    'فيلم',
    'اوفا',
  ];

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final p = _Palette.of(theme);
    final text = theme == AppThemeStyle.light ? Colors.black87 : Colors.white;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        color: p.screen,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Banner with the title, the particulars and the play button
            // standing in as bars.
            SizedBox(
              height: 200,
              child: Stack(
                children: [
                  Positioned.fill(child: _block(p.banner)),
                  PositionedDirectional(
                    start: 24,
                    bottom: 22,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(text.withValues(alpha: 0.9), 300, height: 22),
                        const SizedBox(height: 10),
                        _bar(text.withValues(alpha: 0.5), 200, height: 10),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            _bar(Colors.white, 130, height: 34),
                            const SizedBox(width: 10),
                            for (var i = 0; i < 3; i++) ...[
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: text.withValues(alpha: 0.4),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: accent.withValues(alpha: 0.7),
                  width: 1.5,
                ),
              ),
              child: SizedBox(
                height: style == SeasonsBarStyle.cards ? 84 : 34,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < _seasons.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      style == SeasonsBarStyle.cards
                          ? SizedBox(width: 150, child: _card(i, accent, p))
                          : _pill(i, accent, p, text),
                    ],
                    if (style == SeasonsBarStyle.pills) ...[
                      const SizedBox(width: 10),
                      Center(
                        child: Text(
                          '${_seasons.length} أجزاء',
                          style: TextStyle(
                            color: text.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            _bar(text.withValues(alpha: 0.85), 90, height: 16),
            const SizedBox(height: 12),
            Expanded(
              child: Column(
                children: [
                  for (var i = 0; i < 3; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AspectRatio(
                              aspectRatio: 16 / 9,
                              child: _block(p.poster, radius: 8),
                            ),
                            const SizedBox(width: 14),
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _bar(p.line, 110, height: 12),
                                const SizedBox(height: 8),
                                _bar(
                                  p.line.withValues(alpha: 0.6),
                                  180,
                                  height: 9,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(int i, Color accent, _Palette p) {
    final current = i == 0;
    final colors = [p.banner, ...p.wide];
    return Container(
      decoration: BoxDecoration(
        color: colors[i % colors.length],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: current ? accent : Colors.transparent,
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(8),
      alignment: AlignmentDirectional.bottomStart,
      child: Text(
        _seasons[i],
        style: TextStyle(
          color: current ? accent : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
        ),
      ),
    );
  }

  Widget _pill(int i, Color accent, _Palette p, Color text) {
    final current = i == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: current ? accent : p.chrome,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        _seasons[i],
        style: TextStyle(
          color: current ? Colors.black : text,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The player: a frame, its controls, what Anime4K does to the picture, and
/// the skip button the player really shows.
class PlayerSettingsPreview extends StatefulWidget {
  const PlayerSettingsPreview({
    required this.anime4k,
    required this.mode,
    required this.skipSegments,
    required this.skipIntro,
    required this.skipCredits,
    this.buttons = const PlayerSettings(),
  });

  final bool anime4k;
  final Anime4kMode mode;
  final bool skipSegments;
  final bool skipIntro;
  final bool skipCredits;

  /// Which of the player's buttons are switched on; the rest are left out.
  final PlayerSettings buttons;

  @override
  State<PlayerSettingsPreview> createState() => _PlayerSettingsPreviewState();
}

class _PlayerSettingsPreviewState extends State<PlayerSettingsPreview> {
  final FocusNode _skipFocus = FocusNode(skipTraversal: true);

  /// The frame as a stream arrives: the same picture decoded small and
  /// stretched back up, which is the softness Anime4K is there to remove.
  static const _lowRes = ResizeImage(_sample, width: 150);

  @override
  void dispose() {
    _skipFocus.dispose();
    super.dispose();
  }

  Widget _hinted(Widget button, String keyName) => !widget.buttons.showKeyHints
      ? button
      : Column(
          mainAxisSize: MainAxisSize.min,
          children: [button, const SizedBox(height: 3), PlayerKeyHint(keyName)],
        );

  Widget _controlIcon(IconData icon, {double size = 24, Color? color}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(icon, color: color ?? Colors.white, size: size),
      );

  @override
  Widget build(BuildContext context) {
    final b = widget.buttons;
    final accent = Theme.of(context).colorScheme.primary;
    // With automatic skipping the playhead is already past the opening.
    final autoSkipped = widget.skipSegments && widget.skipIntro;
    final showButton = widget.skipSegments && !widget.skipIntro;

    return Directionality(
      // The player is always drawn left to right, as the real one is.
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // One picture, upscaled when Anime4K is on — not a comparison.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            // Both pictures fill the frame. The default layout centres them
            // at their own size, which drew the small decoded source as a
            // thumbnail in the middle.
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: widget.anime4k
                ? const ColorFiltered(
                    key: ValueKey('upscaled'),
                    // A touch more contrast: the restored lines read crisper.
                    colorFilter: ColorFilter.matrix(<double>[
                      1.12, 0, 0, 0, -12, //
                      0, 1.12, 0, 0, -12, //
                      0, 0, 1.12, 0, -12, //
                      0, 0, 0, 1, 0, //
                    ]),
                    child: Image(
                      image: _sample,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                    ),
                  )
                : ImageFiltered(
                    key: const ValueKey('source'),
                    imageFilter: ImageFilter.blur(sigmaX: 1.6, sigmaY: 1.6),
                    child: const Image(
                      image: _lowRes,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: widget.anime4k ? 1 : 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '✦ Anime4K · ${widget.mode.label}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
          // Controls.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 30, 20, 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.85),
                  ],
                ),
              ),
              // Laid out as the real player draws it on a desktop, left to
              // right: the time over the timeline, then volume on the left,
              // back / play / forward in the middle, and the buttons on the
              // right in the player's own order.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6),
                    child: Text(
                      autoSkipped ? '02:40 / 24:10' : '01:32 / 24:10',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      return SizedBox(
                        height: 4,
                        child: Stack(
                          children: [
                            Container(color: Colors.white24),
                            // The opening, marked on the timeline.
                            if (widget.skipSegments)
                              Positioned(
                                left: width * 0.03,
                                width: width * 0.07,
                                top: 0,
                                bottom: 0,
                                child: Container(
                                  color: accent.withValues(alpha: 0.7),
                                ),
                              ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              width: width * (autoSkipped ? 0.11 : 0.06),
                              color: accent,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  // Only the buttons switched on in "player controls", so
                  // hiding one there hides it here.
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Row(
                        children: [
                          _controlIcon(LucideIcons.volume2200),
                          Container(
                            width: 70,
                            height: 3,
                            alignment: Alignment.centerLeft,
                            color: Colors.white24,
                            child: FractionallySizedBox(
                              widthFactor: 0.7,
                              child: Container(color: Colors.white),
                            ),
                          ),
                          if (b.showKeyHints) ...const [
                            SizedBox(width: 6),
                            PlayerKeyHint('M'),
                          ],
                          const Spacer(),
                          // Speed, Anime4K and size live in the ⚙ panel.
                          if (b.showEpisodes)
                            _hinted(
                              _controlIcon(LucideIcons.listVideo200),
                              'E',
                            ),
                          if (b.showPlaybackSpeed ||
                              b.showResize ||
                              (widget.anime4k && b.showAnime4kButton))
                            _hinted(_controlIcon(LucideIcons.settings200), 'S'),
                          if (b.showFullscreen)
                            _hinted(_controlIcon(LucideIcons.maximize200), 'F'),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (b.showSeekButtons)
                            _hinted(
                              const SeekIcon(
                                forward: false,
                                seconds: 10,
                                size: 26,
                                color: Colors.white,
                              ),
                              '←',
                            ),
                          const SizedBox(width: 18),
                          _hinted(
                            _controlIcon(LucideIcons.pause200, size: 30),
                            'Space',
                          ),
                          const SizedBox(width: 18),
                          if (b.showSeekButtons)
                            _hinted(
                              const SeekIcon(
                                forward: true,
                                seconds: 10,
                                size: 26,
                                color: Colors.white,
                              ),
                              '→',
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ), // The player's own skip button, where the player puts it.
          PositionedDirectional(
            bottom: 96,
            end: 24,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: showButton
                  ? SkipPill(
                      key: const ValueKey('skip'),
                      label: 'تخطي المقدمة',
                      focusNode: _skipFocus,
                      isTv: false,
                      isCompact: false,
                      controlsVisible: false,
                      onPressed: () {},
                    )
                  : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ),
        ],
      ),
    );
  }
}
