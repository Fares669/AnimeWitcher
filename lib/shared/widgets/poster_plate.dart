// Ported from Harbor (src/components/poster.tsx: posterPlate, gradient,
// hash; src/components/poster-retry.ts).
// Harbor: Copyright (c) 2026 Harbor, MIT License — see THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

typedef _PosterDecorations = ({
  BoxDecoration base,
  BoxDecoration outerGlow,
  BoxDecoration innerGlow,
});

/// A poster's own colour while its picture loads: two soft glows over a dark
/// diagonal, their hue taken from the title, so a row that is still loading
/// reads as a row of different things rather than a block of grey.
class PosterPlate extends StatelessWidget {
  const PosterPlate({super.key, required this.seed, this.child});

  /// What the colour is taken from — the title — so a card keeps its colour.
  final String seed;
  final Widget? child;

  /// Harbor's string hash: the same title always gives the same hue.
  static int hueOf(String seed) {
    var h = 0;
    for (final unit in seed.codeUnits) {
      h = (((h << 5).toSigned(32)) - h + unit).toSigned(32);
    }
    return h.abs() % 360;
  }

  // At most 360 palettes, regardless of how many titles are displayed.
  static final _decorations = List<_PosterDecorations?>.filled(360, null);

  static _PosterDecorations _decorationFor(int hue) {
    final a = hue.toDouble();
    final b = (a + 140) % 360;
    final c = (a + 60) % 360;
    // Harbor writes these in OKLCH; these HSL values are near enough.
    Color tone(double hue, double saturation, double lightness) =>
        HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
    final outerTone = tone(b, 0.40, 0.27);
    final innerTone = tone(a, 0.45, 0.40);
    return (
      base: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone(c, 0.30, 0.15), tone(b, 0.25, 0.07)],
        ),
      ),
      outerGlow: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0.5, 0.5),
          radius: 0.8,
          colors: [outerTone, outerTone.withAlpha(0)],
        ),
      ),
      innerGlow: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.5, -0.4),
          radius: 0.8,
          colors: [innerTone, innerTone.withAlpha(0)],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hue = hueOf(seed);
    final (:base, :outerGlow, :innerGlow) = _decorations[hue] ??=
        _decorationFor(hue);
    return DecoratedBox(
      decoration: base,
      child: DecoratedBox(
        decoration: outerGlow,
        child: DecoratedBox(
          decoration: innerGlow,
          child: child ?? const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// When a poster that failed is tried again: after 1.2 s, then twice as long
/// each time, five times; then the address rests for ten minutes before it
/// is asked again. A slow or briefly unreachable image host often answers on
/// a second try, and a card that gives up at once stays blank for the visit.
class PosterRetryPolicy {
  PosterRetryPolicy._();

  static final PosterRetryPolicy instance = PosterRetryPolicy._();

  static const int limit = 5;
  static const Duration base = Duration(milliseconds: 1200);
  static const Duration cooldown = Duration(minutes: 10);
  static const int _maxCooling = 1024;

  final Map<String, DateTime> _cooling = <String, DateTime>{};

  bool isCooling(String url, [DateTime? now]) {
    final until = _cooling[url];
    if (until == null) return false;
    if (until.isAfter(now ?? DateTime.now())) return true;
    _cooling.remove(url);
    return false;
  }

  void cool(String url, [DateTime? now]) {
    final stamp = now ?? DateTime.now();
    // Cooldown entries are ordered by when they were last cooled. Expired
    // URLs need not be seen again to be released, and a prolonged outage
    // cannot grow this history for the lifetime of the app.
    _cooling.remove(url);
    _cooling[url] = stamp.add(cooldown);
    while (_cooling.isNotEmpty) {
      final oldest = _cooling.keys.first;
      if (_cooling.length <= _maxCooling && _cooling[oldest]!.isAfter(stamp)) {
        break;
      }
      _cooling.remove(oldest);
    }
  }

  void clear(String url) => _cooling.remove(url);

  /// The wait before retry number [retry] (from 0), or null past the limit.
  Duration? delayFor(int retry) {
    if (retry >= limit) return null;
    return base * (1 << retry);
  }

  bool canRetry(String url, int retry) =>
      delayFor(retry) != null && !isCooling(url);
}
