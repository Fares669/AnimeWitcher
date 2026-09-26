import 'dart:ui' as ui;

import '../ffi_image_decoder.dart';

/// Represents an image tile in the grid
class Tile {
  final ui.Rect sRect;
  final int sampleSize;
  bool visible = false;
  bool loading = false;
  ui.Image? image;

  Tile({required this.sRect, required this.sampleSize});

  /// Releases the graphical memory of the tile
  void dispose() {
    image?.dispose();
    image = null;
    if (loading) {
      ffiImageDecoder.cancel(this);
      loading = false;
    }
  }
}

/// Manages tiling partition and memory recycling
class TilingEngine {
  Map<int, List<Tile>> tileMap = {};
  int fullImageSampleSize = 1;
  List<int> sortedKeys = [];

  /// Initializes the tile grid for different sampleSizes (powers of 2)
  void initialiseTileMap({
    required int sWidth,
    required int sHeight,
    required double maxTileWidth,
    required double maxTileHeight,
    required int baseSampleSize,
    required double viewWidth,
    required double viewHeight,
  }) {
    // Clears the old grid
    dispose();

    tileMap = {};
    sortedKeys = [];
    fullImageSampleSize = baseSampleSize;
    int sampleSize = fullImageSampleSize;

    while (true) {
      // A grid of tiles, none decoding to more than the maximum tile size.
      // One tile for the whole image made a tall webtoon page — 800 by
      // 15,000 pixels — a single texture taller than the graphics card
      // takes, and the page stayed black in the long-strip modes.
      final tileWidth = maxTileWidth * sampleSize;
      final tileHeight = maxTileHeight * sampleSize;
      final tiles = <Tile>[];
      for (var top = 0.0; top < sHeight; top += tileHeight) {
        for (var left = 0.0; left < sWidth; left += tileWidth) {
          tiles.add(
            Tile(
              sRect: ui.Rect.fromLTRB(
                left,
                top,
                (left + tileWidth).clamp(0, sWidth).toDouble(),
                (top + tileHeight).clamp(0, sHeight).toDouble(),
              ),
              sampleSize: sampleSize,
            )..visible = sampleSize == fullImageSampleSize,
          );
        }
      }
      tileMap[sampleSize] = tiles;

      if (sampleSize == 1) {
        break;
      } else {
        sampleSize = sampleSize ~/ 2;
      }
    }
    sortedKeys = tileMap.keys.toList()..sort((a, b) => b.compareTo(a));
  }

  /// Updates visibility and loads tiles.
  /// Keeps loaded tiles visible without disposing them on scroll to ensure 0 FFI overhead during panning.
  void refreshRequiredTiles({
    required double scale,
    required ui.Offset vTranslate,
    required ui.Size viewSize,
    required int rotation,
    required int sWidth,
    required int sHeight,
    required int targetSampleSize,
    required void Function(Tile tile) loadTileCallback,
  }) {
    for (final entry in tileMap.entries) {
      final tiles = entry.value;

      for (final tile in tiles) {
        if (tile.sampleSize == targetSampleSize) {
          tile.visible = true;
          if (!tile.loading && tile.image == null) {
            loadTileCallback(tile);
          }
        } else if (tile.sampleSize != fullImageSampleSize) {
          tile.visible = false;
          tile.dispose();
        }
      }
    }
  }

  /// Determines if the base layer is completely loaded
  bool isBaseLayerReady() {
    final baseGrid = tileMap[fullImageSampleSize];
    if (baseGrid == null || baseGrid.isEmpty) return false;
    for (final tile in baseGrid) {
      if (tile.image == null) return false;
    }
    return true;
  }

  /// Disposes of all tiles
  void dispose() {
    for (final grid in tileMap.values) {
      for (final tile in grid) {
        tile.dispose();
      }
    }
    tileMap.clear();
    sortedKeys.clear();
  }
}
