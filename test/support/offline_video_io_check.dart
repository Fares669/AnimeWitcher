import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_integrity_verifier_v2.dart';
import 'package:animewitcher/core/utils/local_video_payload_probe.dart';

Future<void> main(List<String> args) async {
  final root = args.single;
  final video = File('$root/video.mp4')..writeAsBytesSync([1, 2, 3, 4]);
  final playlist = File('$root/playlist.mp4')
    ..writeAsStringSync('#EXTM3U\npart.ts\n');
  final empty = File('$root/empty.mp4')..createSync();
  final missing = File('$root/missing.mp4');
  final lookups = List.generate(
    32,
    (i) =>
        InternetAddress.lookup('offline-check-$i.invalid')
            .then<Object?>((_) => null, onError: (Object _) => null),
  );
  var ticks = 0;
  final timer = Timer.periodic(
    const Duration(milliseconds: 20),
    (_) => ticks++,
  );
  try {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    var poolBlocked = false;
    try {
      await video.exists().timeout(const Duration(milliseconds: 300));
    } on TimeoutException {
      poolBlocked = true;
    }
    if (!poolBlocked) {
      throw StateError('The control file operation did not stall');
    }

    const verifier = DownloadIntegrityVerifierV2();
    final results = await Future.wait([
      verifier.verify(video, expectedBytes: 4),
      verifier.verify(video, expectedBytes: 5),
      verifier.verify(empty),
      verifier.verify(missing),
      verifier.verify(playlist, rejectNonVideoPayload: true),
    ]).timeout(const Duration(seconds: 2));
    if (!results[0].isValid ||
        results[0].bytes != 4 ||
        results[1].reason != 'size-mismatch' ||
        results[2].reason != 'empty' ||
        results[3].reason != 'missing' ||
        results[4].reason != 'hls-playlist') {
      throw StateError('Integrity semantics changed');
    }
    final payload = await probeLocalVideoPayload(playlist)
        .timeout(const Duration(seconds: 2));
    if (payload != LocalVideoPayloadProblem.hlsPlaylist) {
      throw StateError('The player payload probe lost manifest protection');
    }
    if (ticks < 2 || video.lengthSync() != 4 || playlist.lengthSync() == 0) {
      throw StateError(
        'Checks blocked the event loop or changed downloaded bytes',
      );
    }
    stdout.writeln('PASS: offline video checks bypass stalled DNS');
  } finally {
    timer.cancel();
    await Future.wait(lookups);
  }
}
