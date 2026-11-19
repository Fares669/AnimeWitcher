import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'witanime_crypto.dart';
import 'witanime_transport.dart';

class MegaKeySpec {
  const MegaKeySpec({
    required this.fileId,
    required this.rawKeyToken,
    required this.aesKey16,
    required this.nonce8,
  });

  final String fileId;
  final String rawKeyToken;
  final Uint8List aesKey16;
  final Uint8List nonce8;
}

class _MegaNodeEntry {
  const _MegaNodeEntry({
    required this.fileId,
    required this.dlBaseUrl,
    required this.fileSize,
    required this.expiresAt,
  });

  final String fileId;
  final String dlBaseUrl;
  final int fileSize;
  final DateTime expiresAt;
}

typedef MegaUpstreamStreamOpener = Future<Stream<List<int>>?> Function(
  Uri upstreamUri,
);

/// Local `127.0.0.1` on-the-fly AES-128-CTR decrypting HTTP Range proxy for
/// MEGA.nz video links so `media_kit` and Download V2 can stream/seek natively.
class WitanimeMegaProxy {
  WitanimeMegaProxy({
    this.openUpstream,
    Uri? apiUri,
  }) : _apiUri = apiUri ?? Uri.https('g.api.mega.co.nz', '/cs', {'id': '1'});

  static final WitanimeMegaProxy shared = WitanimeMegaProxy();

  static final RegExp _fileEmbedRegex = RegExp(
    r'mega\.(?:nz|co\.nz)/(?:embed|file)/([A-Za-z0-9_-]+)#([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );
  static final RegExp _legacyHashRegex = RegExp(
    r'mega\.(?:nz|co\.nz)/#!([A-Za-z0-9_-]+)!([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );

  final MegaUpstreamStreamOpener? openUpstream;
  final Uri _apiUri;
  final Map<String, _MegaNodeEntry> _nodeCache = <String, _MegaNodeEntry>{};
  final Map<String, MegaKeySpec> _keyRegistry = <String, MegaKeySpec>{};
  final Map<String, WitanimeTransport> _transports =
      <String, WitanimeTransport>{};
  late final String _authToken = _generateAuthToken();

  HttpServer? _server;
  Future<HttpServer>? _starting;
  HttpClient? _httpClient;

  static String _generateAuthToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(12, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static MegaKeySpec? parseMegaUrl(String url) {
    final match =
        _fileEmbedRegex.firstMatch(url) ?? _legacyHashRegex.firstMatch(url);
    if (match == null) return null;
    final fileId = match.group(1)?.trim() ?? '';
    final keyToken =
        match.group(2)?.trim().replaceFirst(RegExp(r'/+$'), '') ?? '';
    if (fileId.isEmpty || keyToken.isEmpty) return null;

    final Uint8List raw;
    try {
      raw = decodeBase64Loose(keyToken);
    } on FormatException {
      return null;
    }

    if (raw.length >= 32) {
      final view = ByteData.sublistView(raw, 0, 32);
      final k = List<int>.generate(
        8,
        (i) => view.getUint32(i * 4, Endian.big),
      );
      final aesKey = Uint8List(16);
      final keyOut = ByteData.sublistView(aesKey);
      keyOut.setUint32(0, k[0] ^ k[4], Endian.big);
      keyOut.setUint32(4, k[1] ^ k[5], Endian.big);
      keyOut.setUint32(8, k[2] ^ k[6], Endian.big);
      keyOut.setUint32(12, k[3] ^ k[7], Endian.big);

      final nonce = Uint8List(8);
      final nonceOut = ByteData.sublistView(nonce);
      nonceOut.setUint32(0, k[4], Endian.big);
      nonceOut.setUint32(4, k[5], Endian.big);
      return MegaKeySpec(
        fileId: fileId,
        rawKeyToken: keyToken,
        aesKey16: aesKey,
        nonce8: nonce,
      );
    }
    if (raw.length >= 16) {
      return MegaKeySpec(
        fileId: fileId,
        rawKeyToken: keyToken,
        aesKey16: Uint8List.fromList(raw.sublist(0, 16)),
        nonce8: Uint8List(8),
      );
    }
    return null;
  }

  Future<_MegaNodeEntry?> _resolveNode(
    String fileId,
    WitanimeTransport transport, {
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    if (!forceRefresh) {
      final cached = _nodeCache[fileId];
      if (cached != null && cached.expiresAt.isAfter(now)) {
        return cached;
      }
    }
    try {
      final resp = await transport.post(
        _apiUri,
        body: jsonEncode([
          {'a': 'g', 'g': 1, 'ssl': 2, 'p': fileId},
        ]),
        headers: const {
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
          'Origin': 'https://mega.nz',
          'Referer': 'https://mega.nz/',
        },
        operation: 'host_mega_api',
      );
      if (!resp.isSuccess) return null;
      final decoded = jsonDecode(resp.body.trim());
      if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
        return null;
      }
      final nodeMap = decoded.first as Map;
      final rawDl = nodeMap['g']?.toString().trim() ?? '';
      final rawSize = nodeMap['s'];
      final size = rawSize is num
          ? rawSize.toInt()
          : int.tryParse(rawSize?.toString() ?? '') ?? -1;
      if (rawDl.isEmpty || size <= 0) return null;
      final httpsDl = rawDl
          .replaceFirst(RegExp(r'^http://', caseSensitive: false), 'https://')
          .replaceFirst(RegExp(r'/+$'), '');
      final entry = _MegaNodeEntry(
        fileId: fileId,
        dlBaseUrl: httpsDl,
        fileSize: size,
        expiresAt: now.add(const Duration(minutes: 15)),
      );
      _nodeCache[fileId] = entry;
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final inflight = _starting;
    if (inflight != null) return inflight;
    final future = HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((srv) {
      _server = srv;
      _starting = null;
      srv.listen(
        _handleRequest,
        onError: (_) {},
        cancelOnError: false,
      );
      return srv;
    });
    _starting = future;
    return future;
  }

  /// Validates [megaUrl] against MEGA's API and returns a local
  /// `http://127.0.0.1:<port>/mega/.../video.mp4` stream URL.
  Future<String?> registerStream(
    String megaUrl,
    WitanimeTransport transport,
  ) async {
    final spec = parseMegaUrl(megaUrl);
    if (spec == null) return null;
    final node = await _resolveNode(spec.fileId, transport);
    if (node == null || node.fileSize <= 0) return null;

    final keyPrefix = spec.rawKeyToken.length > 12
        ? spec.rawKeyToken.substring(0, 12)
        : spec.rawKeyToken;
    final slotId = '${spec.fileId}_$keyPrefix';
    _keyRegistry[slotId] = spec;
    _transports[slotId] = transport;

    final server = await _ensureServer();
    return 'http://127.0.0.1:${server.port}/mega/$_authToken/$slotId/video.mp4';
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      final method = request.method.toUpperCase();
      if (method != 'GET' && method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.length < 4 ||
          segments[0] != 'mega' ||
          segments[1] != _authToken) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }

      final slotId = segments[2];
      final keySpec = _keyRegistry[slotId];
      final transport = _transports[slotId];
      if (keySpec == null || transport == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      var node = await _resolveNode(keySpec.fileId, transport);
      if (node == null) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }

      final totalSize = node.fileSize;
      var hasRange = false;
      var startByte = 0;
      var endByte = totalSize - 1;

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null &&
          rangeHeader.toLowerCase().startsWith('bytes=')) {
        final spec = rangeHeader.substring(6).split(',').first.trim();
        final dash = spec.indexOf('-');
        if (dash >= 0) {
          final left = spec.substring(0, dash).trim();
          final right = spec.substring(dash + 1).trim();
          if (left.isEmpty && right.isNotEmpty) {
            final suffix = int.tryParse(right) ?? 0;
            if (suffix > 0) {
              startByte = (totalSize - suffix).clamp(0, totalSize - 1);
              endByte = totalSize - 1;
              hasRange = true;
            }
          } else if (left.isNotEmpty) {
            final parsedStart = int.tryParse(left);
            if (parsedStart != null && parsedStart >= totalSize) {
              response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
              response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes */$totalSize',
              );
              await response.close();
              return;
            }
            if (parsedStart != null && parsedStart >= 0) {
              startByte = parsedStart;
              final parsedEnd = int.tryParse(right);
              endByte = parsedEnd != null
                  ? parsedEnd.clamp(startByte, totalSize - 1)
                  : totalSize - 1;
              hasRange = true;
            }
          }
        }
      }

      final contentLength = endByte - startByte + 1;
      response.statusCode = hasRange
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentLengthHeader, contentLength);
      if (hasRange) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $startByte-$endByte/$totalSize',
        );
      }

      if (method == 'HEAD') {
        await response.close();
        return;
      }

      final alignedStart = (startByte ~/ 16) * 16;
      final skipBytes = startByte - alignedStart;
      final blockIndex = alignedStart ~/ 16;

      var upstream = await _openUpstreamRange(node, alignedStart, endByte);
      if (upstream == null) {
        node = await _resolveNode(
          keySpec.fileId,
          transport,
          forceRefresh: true,
        );
        if (node != null) {
          upstream = await _openUpstreamRange(node, alignedStart, endByte);
        }
      }
      if (upstream == null) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }

      final iv16 = Uint8List(16);
      iv16.setRange(0, 8, keySpec.nonce8);
      _writeBigEndianUint64(iv16, 8, blockIndex);
      final cipher = Aes128CtrCipher(key: keySpec.aesKey16, iv16: iv16);

      var toSkip = skipBytes;
      var remaining = contentLength;
      await for (final chunk in upstream) {
        if (remaining <= 0) break;
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        if (bytes.isEmpty) continue;
        final decrypted = cipher.process(bytes);
        var offset = 0;
        var available = decrypted.length;
        if (toSkip > 0) {
          if (available <= toSkip) {
            toSkip -= available;
            continue;
          }
          offset = toSkip;
          available -= toSkip;
          toSkip = 0;
        }
        final toWrite = available < remaining ? available : remaining;
        if (toWrite > 0) {
          response.add(
            offset == 0 && toWrite == decrypted.length
                ? decrypted
                : Uint8List.sublistView(decrypted, offset, offset + toWrite),
          );
          remaining -= toWrite;
        }
      }
      await response.flush();
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<Stream<List<int>>?> _openUpstreamRange(
    _MegaNodeEntry node,
    int alignedStart,
    int endByte,
  ) async {
    final uri = Uri.parse('${node.dlBaseUrl}/$alignedStart-$endByte');
    final custom = openUpstream;
    if (custom != null) return custom(uri);

    final client = _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(
        HttpHeaders.userAgentHeader,
        DioWitanimeTransport.defaultUserAgent,
      );
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        unawaited(resp.drain<void>().catchError((_) {}));
        return null;
      }
      return resp;
    } catch (_) {
      return null;
    }
  }

  static void _writeBigEndianUint64(Uint8List out, int offset, int value) {
    var v = value;
    for (var i = 7; i >= 0; i--) {
      out[offset + i] = v & 0xff;
      v >>= 8;
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    _starting = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    if (server != null) {
      await server.close(force: true);
    }
  }
}
