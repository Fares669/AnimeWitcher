import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const bool mangaReaderDiagnosticsEnabled = bool.fromEnvironment(
  'MANGA_READER_DIAGNOSTICS',
  defaultValue: false,
);

final MangaReaderDiagnosticLog mangaReaderDiagnostics =
    MangaReaderDiagnosticLog();


String mangaReaderDiagnosticErrorClass(String message) {
  final text = message.toLowerCase();
  if (text.contains('403')) return 'http_403';
  if (text.contains('401')) return 'http_401';
  if (text.contains('404')) return 'http_404';
  if (text.contains('429')) return 'http_429';
  if (text.contains('500') || text.contains('502') || text.contains('503')) {
    return 'http_5xx';
  }
  if (text.contains('handshake')) return 'tls_handshake';
  if (text.contains('socket')) return 'socket';
  if (text.contains('timeout')) return 'timeout';
  if (text.contains('codec') || text.contains('decode')) return 'decode';
  if (text.contains('format')) return 'format';
  if (text.contains('certificate')) return 'certificate';
  return 'other';
}

final class MangaReaderDiagnosticLog {
  MangaReaderDiagnosticLog();

  Future<void> _tail = Future<void>.value();
  int _sequence = 0;
  final Stopwatch _elapsed = Stopwatch()..start();
  static const int _maxBytes = 5 * 1024 * 1024;

  Future<Directory> directory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}log',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> file() async => File(
    '${(await directory()).path}${Platform.pathSeparator}manga_reader_debug.jsonl',
  );

  void record(String event, [Map<String, Object?> fields = const {}]) {
    if (!mangaReaderDiagnosticsEnabled) return;
    final payload = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'sequence': ++_sequence,
      'elapsedMs': _elapsed.elapsedMilliseconds,
      'event': event,
      ..._sanitize(fields),
    };
    _tail = _tail.then<void>((_) async {
      try {
        final active = await file();
        final line = '${jsonEncode(payload)}\n';
        if (await active.exists() &&
            await active.length() + utf8.encode(line).length > _maxBytes) {
          final rotated = File('${active.path}.1');
          if (await rotated.exists()) await rotated.delete();
          await active.rename(rotated.path);
        }
        await active.writeAsString(line, mode: FileMode.append, flush: true);
      } catch (_) {
        // Diagnostics must never affect reader behavior.
      }
    });
  }

  Map<String, Object?> urlFields(String prefix, String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) {
      return <String, Object?>{'${prefix}Parsed': false};
    }
    final queryKeys = uri.queryParametersAll.keys.toList()..sort();
    return <String, Object?>{
      '${prefix}Parsed': true,
      '${prefix}Scheme': uri.scheme,
      '${prefix}Host': uri.host,
      '${prefix}Path': uri.path,
      '${prefix}HasQuery': uri.hasQuery,
      '${prefix}QueryKeys': queryKeys.join(','),
    };
  }

  Map<String, Object?> headerFields(
    String prefix,
    Map<String, String> headers,
  ) {
    final names = headers.keys.map((value) => value.toLowerCase()).toList()
      ..sort();
    String? referer;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'referer') {
        referer = entry.value;
        break;
      }
    }
    final refererUri = referer == null ? null : Uri.tryParse(referer);
    return <String, Object?>{
      '${prefix}HeaderNames': names.join(','),
      '${prefix}HasReferer': referer != null && referer.isNotEmpty,
      '${prefix}RefererHost': refererUri?.host ?? '',
      '${prefix}RefererPath': refererUri?.path ?? '',
      '${prefix}HasCookie': names.contains('cookie'),
      '${prefix}HasAuthorization': names.contains('authorization'),
      '${prefix}HasUserAgent': names.contains('user-agent'),
    };
  }

  Future<void> probeImage({
    required String url,
    required Map<String, String> headers,
    required int pageIndex,
    required String reason,
  }) async {
    if (!mangaReaderDiagnosticsEnabled) return;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = false;
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      final sentUserAgent =
          request.headers.value(HttpHeaders.userAgentHeader) ??
          client.userAgent ??
          '';
      final response = await request.close().timeout(const Duration(seconds: 12));
      final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
      final contentType = response.headers.contentType?.mimeType ?? '';
      final contentLength = response.contentLength;
      record('image.probe.response', <String, Object?>{
        'pageIndex': pageIndex,
        'reason': reason,
        'status': response.statusCode,
        'contentType': contentType,
        'contentLength': contentLength,
        'probeUserAgent': request.headers.value(HttpHeaders.userAgentHeader) ?? '',
        ...urlFields('url', url),
        ...urlFields('redirect', location),
        ...headerFields('request', headers),
      });
      final socket = await response.detachSocket();
      socket.destroy();
    } catch (error) {
      record('image.probe.error', <String, Object?>{
        'pageIndex': pageIndex,
        'reason': reason,
        'errorType': error.runtimeType.toString(),
        ...urlFields('url', url),
        ...headerFields('request', headers),
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<void> flush() => _tail;

  Map<String, Object?> _sanitize(Map<String, Object?> fields) {
    final result = <String, Object?>{};
    for (final entry in fields.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value == null || value is bool || value is num) {
        result[key] = value;
        continue;
      }
      if (value is String) {
        var text = value;
        if (text.length > 500) text = text.substring(0, 500);
        result[key] = text;
      }
    }
    return result;
  }
}
