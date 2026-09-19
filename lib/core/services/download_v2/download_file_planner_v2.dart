import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/entity/multimedia_item.dart';

final class DownloadSourceMetadataV2 {
  const DownloadSourceMetadataV2({
    required this.size,
    required this.mimeType,
    required this.supportsRanges,
  });

  final int? size;
  final String? mimeType;
  final bool supportsRanges;

  String get sizeString {
    if (size == null) return 'Unknown size';
    final mb = size! / (1024 * 1024);
    if (mb > 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(2)} MB';
  }
}

Future<DownloadSourceMetadataV2?> probeDownloadSourceV2(
  Dio dio,
  String url, {
  Map<String, String>? headers,
}) async {
  try {
    int? size;
    String? mimeType;
    var supportsRanges = false;

    try {
      final response = await dio
          .head<dynamic>(
            url,
            options: Options(
              headers: {...?headers, 'Accept-Encoding': 'identity'},
              followRedirects: true,
            ),
          )
          .timeout(const Duration(seconds: 10));
      size = int.tryParse(response.headers.value('content-length') ?? '');
      mimeType = response.headers.value('content-type');
      supportsRanges =
          response.headers.value('accept-ranges')?.toLowerCase().contains(
                'bytes',
              ) ==
              true;
    } catch (_) {}

    try {
      final response = await dio
          .get<dynamic>(
            url,
            options: Options(
              headers: {
                ...?headers,
                'Range': 'bytes=0-0',
                'Accept-Encoding': 'identity',
              },
              followRedirects: true,
              responseType: ResponseType.stream,
              validateStatus: (status) =>
                  status != null && (status == 200 || status == 206),
            ),
          )
          .timeout(const Duration(seconds: 10));
      final contentRange = response.headers.value('content-range');
      if (response.statusCode == 206 && contentRange != null) {
        final match = RegExp(r'^bytes 0-0/(\d+)$').firstMatch(contentRange);
        supportsRanges = match != null;
        if (match != null) size = int.tryParse(match[1]!);
      } else {
        supportsRanges = false;
        final contentLength = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (contentLength != null && contentLength > 1) size ??= contentLength;
      }
      mimeType ??= response.headers.value('content-type');
      final body = response.data;
      if (body is ResponseBody) {
        final subscription = body.stream.listen(null);
        await subscription.cancel();
      }
    } catch (_) {}

    return DownloadSourceMetadataV2(
      size: size,
      mimeType: mimeType,
      supportsRanges: supportsRanges,
    );
  } catch (_) {
    return null;
  }
}

/// Produces the final path expected by V2. iOS keeps an app-documents-relative
/// path so it survives sandbox container relocation; all other platforms use
/// an absolute destination.
Future<String> downloadDestinationPathV2(
  MultimediaItem item, {
  Episode? episode,
  required String filename,
}) async {
  final sanitizedTitle = item.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
  var relativeDirectory = p.join(
    'AnimeWitcher',
    'Downloads',
    sanitizedTitle.isEmpty ? 'Unknown' : sanitizedTitle,
  );

  if (episode != null && item.contentType != MultimediaContentType.movie) {
    final seasonCount = item.episodes?.map((e) => e.season).toSet().length ?? 0;
    if (seasonCount > 1) {
      relativeDirectory = p.join(
        relativeDirectory,
        'Season ${episode.season}',
      );
    }
  }

  if (Platform.isIOS) return p.join(relativeDirectory, filename);
  if (Platform.isAndroid) {
    return p.join(
      '/storage/emulated/0/Download',
      relativeDirectory,
      filename,
    );
  }

  final dir =
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  return p.join(dir.path, relativeDirectory, filename);
}

Future<String> absoluteDownloadDestinationPathV2(String destinationPath) async {
  if (p.isAbsolute(destinationPath)) return destinationPath;
  final documents = await getApplicationDocumentsDirectory();
  return p.join(documents.path, destinationPath);
}
