import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Text artifacts that cannot be played as a standalone downloaded video.
enum LocalVideoPayloadProblem {
  hlsPlaylist(
    'hls-playlist',
    'This download contains an HLS playlist that needs separate media files. '
        'Download the episode again from a direct video source.',
  ),
  dashManifest(
    'dash-manifest',
    'This download contains a DASH manifest that needs separate media files. '
        'Download the episode again from a direct video source.',
  ),
  htmlPage(
    'html-page',
    'This download contains a web page instead of video. '
        'Download the episode again.',
  );

  const LocalVideoPayloadProblem(this.reason, this.message);

  final String reason;
  final String message;
}

/// Recognizes only unmistakable leading HLS, DASH, or HTML content.
///
/// Reads at most 4 KiB from the local file and never follows media references.
/// A null result leaves unknown formats alone; it does not establish that the
/// file is playable or self-contained. Missing or unreadable files also return
/// null, leaving ordinary filesystem failures to the verifier or player.
Future<LocalVideoPayloadProblem?> probeLocalVideoPayload(File file) {
  final path = file.path;
  // Keep both the UI isolate and Dart's shared DNS/file-I/O queue out of this read.
  return Isolate.run(() => probeLocalVideoPayloadSync(File(path)));
}

/// Bounded worker-isolate implementation, also used during integrity checks.
LocalVideoPayloadProblem? probeLocalVideoPayloadSync(File file) {
  try {
    final handle = file.openSync(mode: FileMode.read);
    try {
      final prefix = utf8.decode(handle.readSync(4096), allowMalformed: true);
      final text = _trimDocumentStart(prefix);
      if (RegExp(r'^#EXTM3U(?:[ \t]*(?:[\r\n]|$))').hasMatch(text)) {
        return LocalVideoPayloadProblem.hlsPlaylist;
      }

      final markup = _stripMarkupPreamble(text);
      if (RegExp(r'^<(?:[A-Za-z_][\w.-]*:)?MPD(?=[\s/>])').hasMatch(markup)) {
        return LocalVideoPayloadProblem.dashManifest;
      }
      if (RegExp(
        r'^(?:<!doctype\s+html(?=[\s>])|<(?:html|head|body)(?=[\s/>]))',
        caseSensitive: false,
      ).hasMatch(markup)) {
        return LocalVideoPayloadProblem.htmlPage;
      }
      return null;
    } finally {
      handle.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}

String _trimDocumentStart(String text) {
  final trimmed = text.trimLeft();
  return trimmed.startsWith('\uFEFF')
      ? trimmed.substring(1).trimLeft()
      : trimmed;
}

String _stripMarkupPreamble(String text) {
  var remaining = text;
  while (true) {
    if (RegExp(r'^<\?xml(?=[\s?])', caseSensitive: false).hasMatch(remaining)) {
      final end = remaining.indexOf('?>');
      if (end < 0) return remaining;
      remaining = remaining.substring(end + 2).trimLeft();
    } else if (remaining.startsWith('<!--')) {
      final end = remaining.indexOf('-->');
      if (end < 0) return remaining;
      remaining = remaining.substring(end + 3).trimLeft();
    } else {
      return remaining;
    }
  }
}
