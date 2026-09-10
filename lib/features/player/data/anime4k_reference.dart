/// Where the two halves of the reference comparison live inside one image.
///
/// The Anime4K project publishes its comparisons as a single grid — six
/// panels of the same frame, each run through a different upscaler, with the
/// method named underneath. Two of those panels are the before and after this
/// setting is about: bicubic, which is what a player does with no help, and
/// Anime4K.
///
/// Taking both from one picture means one download for the pair, and it means
/// the two halves are guaranteed to be the same frame — which is the whole
/// point of a comparison and the easiest thing to get wrong when assembling
/// one from separate files.
library;

import 'dart:ui';

/// The published grid: mode A on a real frame, beside the alternatives.
const String anime4kReferenceImageUrl =
    'https://raw.githubusercontent.com/bloc97/Anime4K/master/'
    'results/Comparisons/Cropped_Screenshots/Slime.png';

/// Which panel of the grid to read.
enum Anime4kReferencePanel {
  /// Top left: plain bicubic upscaling, the picture without any of this.
  bicubic,

  /// Middle of the second row: Anime4K itself.
  anime4k,
}

/// The rectangle [panel] occupies in a grid of [source] pixels.
///
/// The grid is three panels across. Each row is a band of pictures with a
/// band of labels under it, so the pictures sit in the top third and in the
/// half-to-five-sixths band rather than in even thirds — measuring the labels
/// as part of a row would slice a caption into the comparison.
Rect anime4kReferenceRect(Size source, Anime4kReferencePanel panel) {
  final third = source.width / 3;
  final bandHeight = source.height / 3;
  return switch (panel) {
    Anime4kReferencePanel.bicubic => Rect.fromLTWH(0, 0, third, bandHeight),
    Anime4kReferencePanel.anime4k => Rect.fromLTWH(
      third,
      source.height * 0.5,
      third,
      bandHeight,
    ),
  };
}

/// Where to draw [source] so it covers [box] without distorting it.
///
/// The panels are square and the preview is wide, so something has to be
/// given up; the faces are centred in these frames, so the sides go.
Rect anime4kReferenceCover(Size panel, Size box) {
  final scale = box.width / panel.width > box.height / panel.height
      ? box.width / panel.width
      : box.height / panel.height;
  final width = panel.width * scale;
  final height = panel.height * scale;
  return Rect.fromLTWH(
    (box.width - width) / 2,
    (box.height - height) / 2,
    width,
    height,
  );
}
