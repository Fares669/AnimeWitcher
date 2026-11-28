// Shared by Manga reader paths adapted from Mangayomi (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'dart:typed_data';

bool hasJpegSignature(Uint8List bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xff &&
    bytes[1] == 0xd8 &&
    bytes[2] == 0xff;

bool hasWebPSignature(Uint8List bytes) =>
    bytes.length >= 12 &&
    bytes[0] == 0x52 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x46 &&
    bytes[8] == 0x57 &&
    bytes[9] == 0x45 &&
    bytes[10] == 0x42 &&
    bytes[11] == 0x50;

bool hasGifSignature(Uint8List bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 0x47 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x38 &&
    (bytes[4] == 0x37 || bytes[4] == 0x39) &&
    bytes[5] == 0x61;
