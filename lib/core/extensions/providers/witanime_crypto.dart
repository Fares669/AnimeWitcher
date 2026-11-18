import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Pure-Dart cryptographic and script-unpacking utilities used by Witanime's
/// hosted stream resolvers (Yonaplay AES-256-GCM, Videa RC4, Hgcloud packed JS).

const List<int> _aesSbox = <int>[
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

int _xtime(int b) => ((b << 1) ^ ((b & 0x80) != 0 ? 0x1b : 0)) & 0xff;

int _gmul(int a, int b) {
  var p = 0;
  var x = a & 0xff;
  var y = b & 0xff;
  for (var i = 0; i < 8; i++) {
    if ((y & 1) != 0) p ^= x;
    x = _xtime(x);
    y >>= 1;
  }
  return p;
}

List<Uint8List> _expandAes256Key(Uint8List key) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key.length', 'AES-256 key must be 32 bytes');
  }
  final words = List<List<int>>.generate(60, (_) => List<int>.filled(4, 0));
  for (var i = 0; i < 8; i++) {
    final p = i * 4;
    words[i] = [key[p], key[p + 1], key[p + 2], key[p + 3]];
  }
  var rcon = 1;
  for (var i = 8; i < 60; i++) {
    var temp = List<int>.of(words[i - 1]);
    if (i % 8 == 0) {
      temp = [
        _aesSbox[temp[1]] ^ rcon,
        _aesSbox[temp[2]],
        _aesSbox[temp[3]],
        _aesSbox[temp[0]],
      ];
      rcon = _xtime(rcon);
    } else if (i % 8 == 4) {
      temp = [
        _aesSbox[temp[0]],
        _aesSbox[temp[1]],
        _aesSbox[temp[2]],
        _aesSbox[temp[3]],
      ];
    }
    final prev = words[i - 8];
    words[i] = [
      prev[0] ^ temp[0],
      prev[1] ^ temp[1],
      prev[2] ^ temp[2],
      prev[3] ^ temp[3],
    ];
  }
  return [
    for (var round = 0; round <= 14; round++)
      Uint8List.fromList([
        ...words[round * 4],
        ...words[round * 4 + 1],
        ...words[round * 4 + 2],
        ...words[round * 4 + 3],
      ]),
  ];
}

Uint8List aes256EncryptBlock(List<Uint8List> roundKeys, Uint8List input) {
  final s = Uint8List.fromList(input);
  void addRoundKey(Uint8List rk) {
    for (var i = 0; i < 16; i++) {
      s[i] ^= rk[i];
    }
  }

  addRoundKey(roundKeys[0]);
  for (var round = 1; round <= 14; round++) {
    for (var i = 0; i < 16; i++) {
      s[i] = _aesSbox[s[i]];
    }
    // ShiftRows (column-major layout: col c, row r => index c*4 + r)
    final r1 = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = r1;

    final r2a = s[2];
    final r2b = s[6];
    s[2] = s[10];
    s[6] = s[14];
    s[10] = r2a;
    s[14] = r2b;

    final r3 = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = r3;

    if (round < 14) {
      for (var c = 0; c < 4; c++) {
        final o = c * 4;
        final a0 = s[o];
        final a1 = s[o + 1];
        final a2 = s[o + 2];
        final a3 = s[o + 3];
        s[o] = _gmul(a0, 2) ^ _gmul(a1, 3) ^ a2 ^ a3;
        s[o + 1] = a0 ^ _gmul(a1, 2) ^ _gmul(a2, 3) ^ a3;
        s[o + 2] = a0 ^ a1 ^ _gmul(a2, 2) ^ _gmul(a3, 3);
        s[o + 3] = _gmul(a0, 3) ^ a1 ^ a2 ^ _gmul(a3, 2);
      }
    }
    addRoundKey(roundKeys[round]);
  }
  return s;
}

Uint8List _gf128Mul(Uint8List x, Uint8List y) {
  final z = Uint8List(16);
  final v = Uint8List.fromList(y);
  for (var byte = 0; byte < 16; byte++) {
    final xb = x[byte];
    for (var bit = 7; bit >= 0; bit--) {
      if ((xb & (1 << bit)) != 0) {
        for (var k = 0; k < 16; k++) {
          z[k] ^= v[k];
        }
      }
      final lsb = (v[15] & 1) != 0;
      for (var k = 15; k > 0; k--) {
        v[k] = ((v[k] >> 1) | ((v[k - 1] & 1) << 7)) & 0xff;
      }
      v[0] = (v[0] >> 1) & 0xff;
      if (lsb) v[0] ^= 0xe1;
    }
  }
  return z;
}

Uint8List _ghash(Uint8List h, Uint8List ciphertext) {
  final y = Uint8List(16);
  for (var offset = 0; offset < ciphertext.length; offset += 16) {
    final end = (offset + 16).clamp(0, ciphertext.length);
    for (var i = 0; i < end - offset; i++) {
      y[i] ^= ciphertext[offset + i];
    }
    final next = _gf128Mul(y, h);
    y.setAll(0, next);
  }
  // 64-bit AAD bit-length (0) || 64-bit ciphertext bit-length
  final bitLen = ciphertext.length * 8;
  final lenBlock = Uint8List(16);
  var value = bitLen;
  for (var i = 15; i >= 8 && value > 0; i--) {
    lenBlock[i] = value & 0xff;
    value >>= 8;
  }
  for (var i = 0; i < 16; i++) {
    y[i] ^= lenBlock[i];
  }
  return _gf128Mul(y, h);
}

Uint8List _inc32(Uint8List counter) {
  final out = Uint8List.fromList(counter);
  for (var i = 15; i >= 12; i--) {
    final next = (out[i] + 1) & 0xff;
    out[i] = next;
    if (next != 0) break;
  }
  return out;
}

/// Decrypts `iv (12 bytes) || tag (16 bytes) || ciphertext` using
/// AES-256-GCM with `key = SHA-256(utf8(passphrase))`, or returns null on tag
/// mismatch.
String? decryptYonaplayPayload(String passphrase, String base64Payload) {
  final raw = base64Decode(base64Payload.trim());
  if (raw.length < 28) return null;
  final iv = Uint8List.sublistView(raw, 0, 12);
  final tag = Uint8List.sublistView(raw, 12, 28);
  final ciphertext = Uint8List.sublistView(raw, 28);

  final keyBytes = Uint8List.fromList(
    crypto.sha256.convert(utf8.encode(passphrase)).bytes,
  );
  final roundKeys = _expandAes256Key(keyBytes);
  final h = aes256EncryptBlock(roundKeys, Uint8List(16));

  final j0 = Uint8List(16)..setAll(0, iv)..[15] = 1;
  final expectedTag = _ghash(h, ciphertext);
  final j0Mask = aes256EncryptBlock(roundKeys, j0);
  var diff = 0;
  for (var i = 0; i < 16; i++) {
    diff |= (expectedTag[i] ^ j0Mask[i]) ^ tag[i];
  }
  if (diff != 0) return null;

  final plaintext = Uint8List(ciphertext.length);
  var counter = _inc32(j0);
  for (var offset = 0; offset < ciphertext.length; offset += 16) {
    final keystream = aes256EncryptBlock(roundKeys, counter);
    final chunk = (ciphertext.length - offset).clamp(0, 16);
    for (var i = 0; i < chunk; i++) {
      plaintext[offset + i] = ciphertext[offset + i] ^ keystream[i];
    }
    counter = _inc32(counter);
  }
  return utf8.decode(plaintext, allowMalformed: false);
}

/// RC4 stream cipher used by Videa's encrypted XML response.
Uint8List rc4Crypt(List<int> key, List<int> data) {
  if (key.isEmpty) return Uint8List.fromList(data);
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xff;
    final tmp = s[i];
    s[i] = s[j];
    s[j] = tmp;
  }
  final out = Uint8List(data.length);
  var i = 0;
  j = 0;
  for (var k = 0; k < data.length; k++) {
    i = (i + 1) & 0xff;
    j = (j + s[i]) & 0xff;
    final tmp = s[i];
    s[i] = s[j];
    s[j] = tmp;
    out[k] = data[k] ^ s[(s[i] + s[j]) & 0xff];
  }
  return out;
}

/// Unpacks Dean Edwards `eval(function(p,a,c,k,e,d){...}('...',radix,count,'...'.split('|')))`
/// blocks when present in host embed HTML.
String unpackPackedJs(String body) {
  if (!body.contains('p,a,c,k,e,d')) return '';
  final match =
      RegExp(
        r"}\('(.*?)',(\d+),(\d+),'([^']*)'\.split\('\|'\)",
        dotAll: true,
      ).firstMatch(body) ??
      RegExp(
        r"\('(.*?)',(\d+),(\d+),'([^']*)'\.split\('\|'\)",
        dotAll: true,
      ).firstMatch(body);
  if (match == null) return '';
  final payload = match.group(1) ?? '';
  final radix = int.tryParse(match.group(2) ?? '');
  if (radix == null || radix < 2 || radix > 62) return '';
  final dict = (match.group(4) ?? '').split('|');

  int? decodeBaseN(String token) {
    var value = 0;
    for (var i = 0; i < token.length; i++) {
      final code = token.codeUnitAt(i);
      int digit;
      if (code >= 48 && code <= 57) {
        digit = code - 48;
      } else if (code >= 97 && code <= 122) {
        digit = code - 87;
      } else if (code >= 65 && code <= 90) {
        digit = code - 29;
      } else {
        return null;
      }
      if (digit >= radix) return null;
      value = value * radix + digit;
    }
    return value;
  }

  return payload.replaceAllMapped(RegExp(r'\b[0-9a-zA-Z]+\b'), (m) {
    final token = m.group(0)!;
    final index = decodeBaseN(token);
    if (index != null && index < dict.length && dict[index].isNotEmpty) {
      return dict[index];
    }
    return token;
  });
}
