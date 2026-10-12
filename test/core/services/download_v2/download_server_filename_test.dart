import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Future<DownloadSourceMetadataV2?> _probe({
  String url = 'https://cdn.test/fallback.mp4',
  String? head,
  String? get,
  List<String>? getValues,
  String? finalUrl,
}) async {
  final methods = <String>[];
  var bodyCanceled = false;
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          methods.add(options.method);
          final disposition = options.method == 'HEAD' ? head : get;
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              redirects: [
                if (finalUrl != null)
                  RedirectRecord(302, options.method, Uri.parse(finalUrl)),
              ],
              statusCode: options.method == 'HEAD' ? 200 : 206,
              headers: Headers.fromMap({
                'content-length': ['100'],
                'content-range': ['bytes 0-0/100'],
                'content-type': ['video/mp4'],
                if (options.method != 'HEAD' && getValues != null)
                  'content-disposition': getValues
                else if (disposition != null)
                  'content-disposition': [disposition],
              }),
              data: options.method == 'HEAD'
                  ? null
                  : ResponseBody(
                      Stream<Uint8List>.multi((controller) {
                        controller.onCancel = () {
                          bodyCanceled = true;
                        };
                      }),
                      206,
                    ),
            ),
          );
        },
      ),
    );
  try {
    final metadata = await probeDownloadSourceV2(dio, url);
    expect(methods, [
      'HEAD',
      'GET',
    ], reason: 'filename selection reuses existing probes');
    expect(
      bodyCanceled,
      isTrue,
      reason: 'the range probe body is always canceled',
    );
    return metadata;
  } finally {
    dio.close();
  }
}

void main() {
  test(
    'GET filename preserves server Unicode, spaces, semicolon and extension',
    () async {
      const name = 'One  Piece; الحلقة 0100 1080p.mkv';
      final metadata = await _probe(
        head: 'attachment; filename="head.mp4"',
        get: 'attachment; filename="$name"',
      );
      expect(metadata!.filename, name);
      expect(metadata.size, 100);
      expect(metadata.supportsRanges, isTrue);
    },
  );

  test('extended UTF-8 filename wins without decoding ordinary filename twice', () async {
    const name = 'حلقة 0100 + %20.webm';
    final metadata = await _probe(
      get:
          "attachment; filename=old.mp4; filename*=UTF-8'ar'${Uri.encodeComponent(name)}",
    );
    expect(metadata!.filename, name);
    expect(
      (await _probe(get: 'attachment; filename="literal%20name.mp4"'))!
          .filename,
      'literal%20name.mp4',
    );
  });

  test(
    'valid plain filename survives malformed or unsupported extended filename',
    () async {
      for (final extended in <String>["UTF-8''bad%ZZ", "unknown''wrong.mp4"]) {
        expect(
          (await _probe(
            get: 'attachment; filename="plain.mkv"; filename*=$extended',
          ))!.filename,
          'plain.mkv',
        );
      }
    },
  );

  test(
    'malformed quoted disposition falls back and still cancels the probe body',
    () async {
      expect(
        (await _probe(get: 'attachment; filename="unterminated'))!.filename,
        'fallback.mp4',
      );
    },
  );

  test(
    'multiple disposition values use the first name and cancel the probe body',
    () async {
      final metadata = await _probe(
        getValues: [
          'attachment; filename="first.mkv"',
          'attachment; filename="second.mp4"',
        ],
      );
      expect(metadata!.filename, 'first.mkv');
    },
  );

  test('HEAD disposition remains useful when GET has no name', () async {
    expect(
      (await _probe(head: 'attachment; filename="head name.mkv"'))!.filename,
      'head name.mkv',
    );
  });

  test('final response URL leaf is decoded once and keeps plus and extensionless names', () async {
    for (final name in <String>['one piece 0100 1080p', 'a+b %20.mkv']) {
      final metadata = await _probe(
        finalUrl:
            'https://redirect.test/${Uri.encodeComponent(name)}?token=ignored',
      );
      expect(metadata!.filename, name);
    }
  });

  test(
    'non-UTF8 URL name keeps usable metadata and permits generated fallback',
    () async {
      final metadata = await _probe(url: 'https://cdn.test/%FF.mp4');
      expect(metadata, isNotNull);
      expect(metadata!.size, 100);
      expect(metadata.filename, isNull);
    },
  );

  test(
    'a trailing slash endpoint has no filename and permits generated fallback',
    () async {
      expect((await _probe(url: 'https://cdn.test/stream/'))!.filename, isNull);
    },
  );

  for (final name in <String>[
    '.',
    '..',
    '../escape.mp4',
    r'..\escape.mp4',
    'bad\u0000.mp4',
    'bad\n.mp4',
    'CON.mp4',
    'bad?.mp4',
    'trailing. ',
    '${List.filled(245, 'a').join()}',
  ]) {
    test('rejects unsafe server leaf ${jsonEncode(name)}', () async {
      final metadata = await _probe(
        url: 'https://cdn.test/',
        get: "attachment; filename*=UTF-8''${Uri.encodeComponent(name)}",
      );
      expect(metadata!.filename, isNull);
      final urlMetadata = await _probe(
        url: 'https://cdn.test/${Uri.encodeComponent(name)}',
      );
      expect(urlMetadata!.filename, isNull);
    });
  }

  test('server leaf leaves room for existing staging suffixes', () async {
    final name = '${List.filled(240, 'a').join()}.mkv';
    final metadata = await _probe(get: 'attachment; filename="$name"');
    expect(metadata!.filename, name);
    final directory = await Directory.systemTemp.createTemp(
      'server-name-limit-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/$name.assembling').writeAsBytes([1]);
    expect(utf8.encode('$name.assembling').length, lessThanOrEqualTo(255));
  });
}
