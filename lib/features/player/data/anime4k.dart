/// Anime4K shader pipelines for the mpv backend.
///
/// Anime4K is a set of GLSL shaders that restore and upscale anime in real
/// time on the GPU. mpv loads them through its `glsl-shaders` property, which
/// takes file paths — so the shaders themselves are files the viewer supplies,
/// downloaded once from https://github.com/bloc97/Anime4K (MIT). Nothing is
/// bundled with the app.
///
/// What this file does is decide *which* of those files to hand mpv, in what
/// order, for a chosen mode and quality — and to do it against the folder that
/// is actually there, so a partial download degrades instead of failing.
library;

/// The pipelines Anime4K documents, by what each is for.
enum Anime4kMode {
  /// Shaders off. mpv is told to clear the property.
  off,

  /// Restore then upscale. The general case for anime that has been through
  /// compression — most of what streams.
  a,

  /// A gentler restore, for sources that were downsampled rather than
  /// compressed hard, where mode A over-sharpens.
  b,

  /// Upscale with denoising and no restore pass, for material that is already
  /// clean.
  c,

  /// Mode A with a second restore after the upscale. Slower, for badly
  /// degraded sources.
  aa,

  /// Mode B doubled, the same way.
  bb,

  /// Mode C followed by a restore.
  ca,
}

/// The size of the convolutional network each shader uses.
///
/// Anime4K's own note: every step up roughly doubles the GPU time. S is meant
/// for phones and weak laptops, UL for a desktop card with headroom.
enum Anime4kQuality { s, m, l, vl, ul }

extension Anime4kQualitySuffix on Anime4kQuality {
  /// The suffix Anime4K puts on its filenames: `..._CNN_M.glsl`.
  String get suffix => switch (this) {
    Anime4kQuality.s => 'S',
    Anime4kQuality.m => 'M',
    Anime4kQuality.l => 'L',
    Anime4kQuality.vl => 'VL',
    Anime4kQuality.ul => 'UL',
  };

  static Anime4kQuality fromName(String? raw) {
    return Anime4kQuality.values.firstWhere(
      (value) => value.name == raw?.trim().toLowerCase(),
      orElse: () => Anime4kQuality.m,
    );
  }
}

extension Anime4kModeName on Anime4kMode {
  /// How Anime4K labels the mode; kept in Latin because that is what its own
  /// documentation uses and what a viewer will be reading alongside this.
  String get label => switch (this) {
    Anime4kMode.off => 'Off',
    Anime4kMode.a => 'A',
    Anime4kMode.b => 'B',
    Anime4kMode.c => 'C',
    Anime4kMode.aa => 'A + A',
    Anime4kMode.bb => 'B + B',
    Anime4kMode.ca => 'C + A',
  };

  static Anime4kMode fromName(String? raw) {
    return Anime4kMode.values.firstWhere(
      (value) => value.name == raw?.trim().toLowerCase(),
      orElse: () => Anime4kMode.off,
    );
  }
}

/// Whether this device can be offered Anime4K at all.
///
/// Anime4K needs the native media_kit/libmpv renderer because mpv applies the
/// GLSL chain in its GPU video-output stage. Android, iOS, macOS, Windows and
/// Linux are eligible; the adaptive video_view backend is not because it has
/// no mpv GLSL stage.
bool anime4kAvailableOn({
  required bool isNativePlatform,
  required bool usingAdaptiveBackend,
}) {
  return isNativePlatform && !usingAdaptiveBackend;
}

/// Whether the active renderer can execute Anime4K GPU shaders.
///
/// mpv documents custom shaders for gpu, gpu-next and libmpv. Apple can also
/// use the native Metal compute backend. Keeping this check separate lets the
/// player reject fallback/software/no-shader outputs instead of accepting the
/// setting while drawing an unchanged picture.
bool anime4kGpuRendererSupportsShaders(String currentVo) {
  final vo = currentVo.trim().toLowerCase();
  return vo == 'gpu' ||
      vo == 'gpu-next' ||
      vo == 'libmpv' ||
      vo == 'metal';
}

/// Whether the feature is on, for a setting that may predate the flag.
///
/// The mode and the feature used to be one value, so "not off" was how being
/// switched on was recorded. An install from before the split has no flag to
/// read, and its mode is the only evidence of what the viewer chose — reading
/// a missing flag as false would silently turn Anime4K off for everyone
/// already using it.
bool anime4kEnabledFrom({required bool? stored, required Anime4kMode mode}) {
  return stored ?? (mode != Anime4kMode.off);
}

/// One shader in a pipeline, as a family plus whether it takes a size.
enum _Family {
  clampHighlights,
  restore,
  restoreSoft,
  upscale,
  upscaleDenoise,
  autoDownscalePreX2,
  autoDownscalePreX4,
}

String _fileName(_Family family, Anime4kQuality quality) {
  return switch (family) {
    _Family.clampHighlights => 'Anime4K_Clamp_Highlights.glsl',
    _Family.restore => 'Anime4K_Restore_CNN_${quality.suffix}.glsl',
    _Family.restoreSoft => 'Anime4K_Restore_CNN_Soft_${quality.suffix}.glsl',
    _Family.upscale => 'Anime4K_Upscale_CNN_x2_${quality.suffix}.glsl',
    _Family.upscaleDenoise =>
      'Anime4K_Upscale_Denoise_CNN_x2_${quality.suffix}.glsl',
    _Family.autoDownscalePreX2 => 'Anime4K_AutoDownscalePre_x2.glsl',
    _Family.autoDownscalePreX4 => 'Anime4K_AutoDownscalePre_x4.glsl',
  };
}

bool _isOptionalOptimization(_Family family) =>
    family == _Family.autoDownscalePreX2 ||
    family == _Family.autoDownscalePreX4;

/// The steps of each mode, as Anime4K's optimized shader ordering describes
/// them. The AutoDownscalePre passes sit before the final upscale so a frame
/// that is already large enough for the target display is reduced before
/// another expensive CNN stage runs.
///
/// Clamp_Highlights leads every pipeline; it is what keeps the restore passes
/// from ringing around bright edges.
List<_Family> _steps(Anime4kMode mode) {
  return switch (mode) {
    Anime4kMode.off => const <_Family>[],
    Anime4kMode.a => const <_Family>[
      _Family.clampHighlights,
      _Family.restore,
      _Family.upscale,
      _Family.autoDownscalePreX2,
      _Family.autoDownscalePreX4,
      _Family.upscale,
    ],
    Anime4kMode.b => const <_Family>[
      _Family.clampHighlights,
      _Family.restoreSoft,
      _Family.upscale,
      _Family.autoDownscalePreX2,
      _Family.autoDownscalePreX4,
      _Family.upscale,
    ],
    Anime4kMode.c => const <_Family>[
      _Family.clampHighlights,
      _Family.upscaleDenoise,
      _Family.autoDownscalePreX2,
      _Family.autoDownscalePreX4,
      _Family.upscale,
    ],
    Anime4kMode.aa => const <_Family>[
      _Family.clampHighlights,
      _Family.restore,
      _Family.upscale,
      _Family.restore,
      _Family.autoDownscalePreX2,
      _Family.autoDownscalePreX4,
      _Family.upscale,
    ],
    Anime4kMode.bb => const <_Family>[
      _Family.clampHighlights,
      _Family.restoreSoft,
      _Family.upscale,
      _Family.restoreSoft,
      _Family.autoDownscalePreX2,
      _Family.autoDownscalePreX4,
      _Family.upscale,
    ],
    Anime4kMode.ca => const <_Family>[
      _Family.clampHighlights,
      _Family.upscaleDenoise,
      _Family.restore,
      _Family.autoDownscalePreX2,
      _Family.autoDownscalePreX4,
      _Family.upscale,
    ],
  };
}

/// What a mode resolved to against a real folder.
class Anime4kChain {
  const Anime4kChain({
    required this.files,
    required this.missing,
    this.optionalMissing = const <String>[],
  });

  /// The filenames to hand mpv, in order. Empty when nothing usable was
  /// found, which the caller treats as "leave the shaders off".
  final List<String> files;

  /// Required steps that had no file in the folder at any size. Shown to the
  /// viewer so a half-finished download is visible rather than silently doing
  /// less useful work.
  final List<String> missing;

  /// Optional performance-only stages that were unavailable.
  ///
  /// A chain without AutoDownscale still produces a correct picture, so these
  /// do not make [isComplete] false. Keeping them separate lets diagnostics
  /// explain why a pipeline may be heavier without falsely calling it broken.
  final List<String> optionalMissing;

  bool get isEmpty => files.isEmpty;
  bool get isComplete => missing.isEmpty && files.isNotEmpty;
}

/// The sizes to try for a step, starting at [preferred] and stepping down.
///
/// Someone who downloaded only the S shaders should still get an upscale
/// rather than nothing, and a chain that quietly runs one size smaller is a
/// better answer than a mode that refuses to start.
List<Anime4kQuality> _sizeOrder(Anime4kQuality preferred) {
  final index = Anime4kQuality.values.indexOf(preferred);
  return <Anime4kQuality>[
    preferred,
    // Down first: smaller is faster and always safe to fall back to.
    for (var i = index - 1; i >= 0; i--) Anime4kQuality.values[i],
    for (var i = index + 1; i < Anime4kQuality.values.length; i++)
      Anime4kQuality.values[i],
  ];
}

/// Builds the shader chain for [mode] from the files actually present.
///
/// [available] is the filenames in the viewer's shader folder. A step is
/// satisfied by the preferred size when it is there, by the nearest size when
/// it is not, and skipped when the family is missing entirely.
///
/// A file is never used twice: Anime4K states a shader may appear once in a
/// pipeline, so a repeated step takes the next size instead. That is also why
/// mode A's second upscale is normally a smaller network than its first.
Anime4kChain resolveAnime4kChain({
  required Anime4kMode mode,
  required Anime4kQuality quality,
  required Iterable<String> available,
}) {
  if (mode == Anime4kMode.off) {
    return const Anime4kChain(files: <String>[], missing: <String>[]);
  }

  final present = available
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet();
  final files = <String>[];
  final used = <String>{};
  final missing = <String>[];
  final optionalMissing = <String>[];

  for (final family in _steps(mode)) {
    String? chosen;
    // Whether the folder holds this family at all, separately from whether
    // an unused one is left. A step dropped because its only file is already
    // in the chain is the one-use rule working, not a download to finish —
    // telling the viewer a file they can see in the folder is "missing" would
    // send them looking for it.
    var familyPresent = false;
    for (final size in _sizeOrder(quality)) {
      final name = _fileName(family, size);
      if (!present.contains(name)) continue;
      familyPresent = true;
      if (used.contains(name)) continue;
      chosen = name;
      break;
    }
    if (chosen == null) {
      if (!familyPresent) {
        final wanted = _fileName(family, quality);
        final target = _isOptionalOptimization(family)
            ? optionalMissing
            : missing;
        if (!target.contains(wanted)) target.add(wanted);
      }
      continue;
    }
    used.add(chosen);
    files.add(chosen);
  }

  // Clamp_Highlights on its own does nothing worth a pipeline; it only makes
  // sense guarding a restore or upscale that is actually there.
  if (files.length == 1 &&
      files.first == _fileName(_Family.clampHighlights, quality)) {
    return Anime4kChain(
      files: const <String>[],
      missing: missing,
      optionalMissing: optionalMissing,
    );
  }

  return Anime4kChain(
    files: files,
    missing: missing,
    optionalMissing: optionalMissing,
  );
}

/// The character mpv splits its file-list options on.
///
/// From mpv's manual: "most path or file list options use `:` (Unix) or `;`
/// (Windows) as separator". The colon cannot be it on Windows, where every
/// absolute path carries a drive colon of its own.
String anime4kListSeparator({required bool onWindows}) => onWindows ? ';' : ':';

/// The value mpv's `glsl-shaders` property expects.
///
/// Only the separator itself is escaped — both characters are legal inside a
/// filename on their own platform. On Windows the drive colon is left exactly
/// as it is: escaping it produced `C\\:\\shaders\\...`, which is not a path any
/// system can open.
///
/// Getting this wrong does not fail loudly. mpv takes the string, finds
/// nothing it can load, and renders the picture untouched — which from the
/// sofa is indistinguishable from Anime4K simply not doing much.
String anime4kGlslShadersValue(
  Iterable<String> paths, {
  required bool onWindows,
}) {
  final separator = anime4kListSeparator(onWindows: onWindows);
  return paths
      .map((path) => path.replaceAll(separator, '\\$separator'))
      .join(separator);
}
