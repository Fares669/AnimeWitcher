// Adapted from Mangayomi reader image-file utilities (Apache-2.0).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart';
import 'package:path/path.dart' as p;

Future<File> cacheImageBytesToTempFile({
  required Directory tempDir,
  required String baseName,
  required String extension,
  required FutureOr<Uint8List> Function() bytesProvider,
}) async {
  final file = File(p.join(tempDir.path, '$baseName$extension'));
  if (!await file.exists()) {
    await file.writeAsBytes(await bytesProvider(), flush: true);
  }
  return file;
}

String detectImageExtension(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return '.jpg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return '.png';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return '.webp';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return '.gif';
  }
  if (isAvifImage(bytes)) return '.avif';
  return '.jpg';
}

bool isAvifImage(Uint8List bytes) {
  if (bytes.length < 12 ||
      bytes[4] != 0x66 ||
      bytes[5] != 0x74 ||
      bytes[6] != 0x79 ||
      bytes[7] != 0x70) {
    return false;
  }
  final boxSize = ByteData.sublistView(bytes, 0, 4).getUint32(0);
  final end = boxSize == 0 || boxSize > bytes.length ? bytes.length : boxSize;
  bool isBrand(int offset) =>
      offset + 4 <= end &&
      bytes[offset] == 0x61 &&
      bytes[offset + 1] == 0x76 &&
      bytes[offset + 2] == 0x69 &&
      (bytes[offset + 3] == 0x66 || bytes[offset + 3] == 0x73);
  if (isBrand(8)) return true;
  for (var offset = 16; offset + 4 <= end; offset += 4) {
    if (isBrand(offset)) return true;
  }
  return false;
}

Future<Uint8List> decodeAvifToPng(Uint8List bytes) async {
  final frame = await FlutterAvifPlatform.api.decodeSingleFrameImage(
    avifBytes: bytes,
  );
  if (frame.width == 0 || frame.height == 0) {
    throw StateError('libavif returned an empty frame');
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    frame.data is Uint8List ? frame.data as Uint8List : Uint8List.fromList(frame.data),
    frame.width,
    frame.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Failed to encode decoded AVIF as PNG');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}
