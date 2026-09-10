import 'dart:ui';

import 'package:animewitcher/features/player/data/anime4k_reference.dart';
import 'package:flutter_test/flutter_test.dart';

/// The grid the project publishes, at its real size.
const _grid = Size(1536, 1536);

void main() {
  group('reading a panel out of the grid', () {
    test('bicubic is the top left picture', () {
      final rect = anime4kReferenceRect(_grid, Anime4kReferencePanel.bicubic);
      expect(rect, const Rect.fromLTWH(0, 0, 512, 512));
    });

    test('anime4k is the middle of the second row of pictures', () {
      // Verified against the published grid: the second row of pictures
      // starts halfway down, because the first row's captions sit between
      // them. Measuring in even thirds would slice a caption into the
      // comparison.
      final rect = anime4kReferenceRect(_grid, Anime4kReferencePanel.anime4k);
      expect(rect, const Rect.fromLTWH(512, 768, 512, 512));
    });

    test('both panels are square and the same size', () {
      final before = anime4kReferenceRect(_grid, Anime4kReferencePanel.bicubic);
      final after = anime4kReferenceRect(_grid, Anime4kReferencePanel.anime4k);
      expect(before.size, after.size);
      expect(before.width, before.height);
    });

    test('both stay inside the picture', () {
      for (final panel in Anime4kReferencePanel.values) {
        final rect = anime4kReferenceRect(_grid, panel);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(_grid.width));
        expect(rect.bottom, lessThanOrEqualTo(_grid.height));
      }
    });

    test('they do not overlap, or it would not be a comparison', () {
      final before = anime4kReferenceRect(_grid, Anime4kReferencePanel.bicubic);
      final after = anime4kReferenceRect(_grid, Anime4kReferencePanel.anime4k);
      expect(before.overlaps(after), isFalse);
    });

    test('the maths follows the image rather than assuming its size', () {
      final half = anime4kReferenceRect(
        const Size(768, 768),
        Anime4kReferencePanel.anime4k,
      );
      expect(half, const Rect.fromLTWH(256, 384, 256, 256));
    });
  });

  group('fitting a square panel into a wide box', () {
    test('covers it, losing the sides rather than distorting', () {
      final box = anime4kReferenceCover(
        const Size(512, 512),
        const Size(400, 180),
      );
      // Scaled to the wider ratio, so the height matches and the width spills.
      expect(box.width, closeTo(400, 0.01));
      expect(box.height, closeTo(400, 0.01));
      expect(box.left, closeTo(0, 0.01));
      expect(box.top, closeTo(-110, 0.01));
    });

    test('centres what it crops', () {
      final box = anime4kReferenceCover(
        const Size(512, 512),
        const Size(180, 400),
      );
      expect(box.center.dx, closeTo(90, 0.01));
      expect(box.center.dy, closeTo(200, 0.01));
    });

    test('a box the same shape needs no crop at all', () {
      final box = anime4kReferenceCover(
        const Size(512, 512),
        const Size(200, 200),
      );
      expect(box, const Rect.fromLTWH(0, 0, 200, 200));
    });
  });

  test('the reference is the project\'s own published comparison', () {
    expect(anime4kReferenceImageUrl, startsWith('https://'));
    expect(anime4kReferenceImageUrl, contains('bloc97/Anime4K'));
  });
}
