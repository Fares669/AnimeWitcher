import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/utils/local_video_payload_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('local-video-payload-');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  final textArtifacts = <String, (String, LocalVideoPayloadProblem)>{
    'HLS media playlist': (
      '#EXTM3U\n#EXTINF:5,\nhttps://example.invalid/segment.ts\n',
      LocalVideoPayloadProblem.hlsPlaylist,
    ),
    'HLS master playlist with BOM and whitespace': (
      '\uFEFF \r\n\t#EXTM3U\r\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo.m3u8',
      LocalVideoPayloadProblem.hlsPlaylist,
    ),
    'HLS with whitespace before BOM': (
      '\n \uFEFF\t#EXTM3U\n',
      LocalVideoPayloadProblem.hlsPlaylist,
    ),
    'DASH root': (
      '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period/></MPD>',
      LocalVideoPayloadProblem.dashManifest,
    ),
    'DASH XML declaration and comment': (
      '\uFEFF \n<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!-- generated manifest -->\n<MPD type="static"></MPD>',
      LocalVideoPayloadProblem.dashManifest,
    ),
    'DASH namespace-qualified root': (
      '<dash:MPD xmlns:dash="urn:mpeg:dash:schema:mpd:2011"/>',
      LocalVideoPayloadProblem.dashManifest,
    ),
    'HTML login page': (
      '<!DOCTYPE HTML>\n<html><body>Sign in to continue</body></html>',
      LocalVideoPayloadProblem.htmlPage,
    ),
    'HTML captive portal with BOM and comment': (
      '\uFEFF\n<!-- portal -->\n<HTML lang="en"><body>Connect</body></HTML>',
      LocalVideoPayloadProblem.htmlPage,
    ),
    'HTML body error response': (
      '<body>Access denied</body>',
      LocalVideoPayloadProblem.htmlPage,
    ),
  };

  for (final entry in textArtifacts.entries) {
    test('recognizes ${entry.key} without changing its bytes', () async {
      final bytes = utf8.encode(entry.value.$1);
      final file = File('${temp.path}/download.mp4');
      await file.writeAsBytes(bytes);

      final problem = await probeLocalVideoPayload(file);

      expect(problem, entry.value.$2);
      expect(problem?.reason, isNotEmpty);
      expect(problem?.message, contains('Download the episode again'));
      expect(await file.readAsBytes(), bytes);
    });
  }

  final allowedBytes = <String, List<int>>{
    'tiny mock': [1, 2, 3, 4],
    'one unknown byte': [0xff],
    'MP4': [0, 0, 0, 24, ...ascii.encode('ftypisom'), 0, 0, 0, 0],
    'Matroska': [0x1a, 0x45, 0xdf, 0xa3, 0x93, 0x42, 0x82],
    'MPEG transport stream': [0x47, 0x40, 0x11, 0x10, 0, 0, 0],
    'AVI': [...ascii.encode('RIFF'), 4, 0, 0, 0, ...ascii.encode('AVI ')],
    'HLS near-match': utf8.encode('#EXTM3U-extra\n'),
    'DASH near-match': utf8.encode('<MPDownload/>'),
    'HTML near-match': utf8.encode('<htmlVideo/>'),
    'unrecognized XML root': utf8.encode('<root><MPD/></root>'),
    'binary with embedded HTML': [0, 1, ...utf8.encode('<html>error</html>')],
    'plain error text': utf8.encode('Access denied'),
  };

  for (final entry in allowedBytes.entries) {
    test('leaves ${entry.key} alone regardless of filename', () async {
      final file = File('${temp.path}/download.m3u8');
      await file.writeAsBytes(entry.value);

      expect(await probeLocalVideoPayload(file), isNull);
      expect(await file.readAsBytes(), entry.value);
    });
  }

  test('preserves the document-leading ASCII character rules', () {
    final file = File('${temp.path}/ascii-prefix.mp4');
    final marker = utf8.encode('#EXTM3U\nlocal.ts\n');
    for (var first = 0; first < 0x80; first++) {
      file.writeAsBytesSync([first, ...marker]);
      final isWhitespace = String.fromCharCode(first).trimLeft().isEmpty;
      expect(
        probeLocalVideoPayloadSync(file),
        isWhitespace ? LocalVideoPayloadProblem.hlsPlaylist : isNull,
        reason: 'first ASCII byte 0x${first.toRadixString(16)}',
      );
    }
  });

  test('preserves non-ASCII whitespace, BOM, and malformed UTF-8', () {
    final file = File('${temp.path}/utf8-prefix.mp4');
    file.writeAsStringSync(
      '\u00a0\u2003\uFEFF\n\u2028<?xml version="1.0"?><MPD/>',
    );
    expect(
      probeLocalVideoPayloadSync(file),
      LocalVideoPayloadProblem.dashManifest,
    );

    file.writeAsBytesSync([0xff, ...utf8.encode('<html>')]);
    expect(probeLocalVideoPayloadSync(file), isNull);
    file.writeAsBytesSync([...utf8.encode('#EXTM3U\n'), 0xff]);
    expect(
      probeLocalVideoPayloadSync(file),
      LocalVideoPayloadProblem.hlsPlaylist,
    );
  });

  test('does not scan beyond its bounded prefix', () async {
    final file = File('${temp.path}/large.mp4');
    await file.writeAsString('${' ' * 4096}#EXTM3U\nremote.ts\n');

    expect(await probeLocalVideoPayload(file), isNull);
  });

  test('missing, empty, or non-file paths remain ordinary I/O cases', () async {
    expect(await probeLocalVideoPayload(File('${temp.path}/missing')), isNull);
    final empty = await File('${temp.path}/empty').create();
    expect(await probeLocalVideoPayload(empty), isNull);
    expect(await probeLocalVideoPayload(File(temp.path)), isNull);
  });
}
