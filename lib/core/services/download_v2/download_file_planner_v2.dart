import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/entity/manga.dart';
import '../../domain/entity/multimedia_item.dart';
import '../../utils/episode_label.dart';
import '../download_parallel.dart';
import 'download_v2_identity.dart';
import 'manga_chapter_manifest_v2.dart';

final class DownloadSourceMetadataV2 {
  const DownloadSourceMetadataV2({
    required this.size,
    required this.mimeType,
    required this.supportsRanges,
    this.filename,
  });

  final int? size;
  final String? mimeType;
  final bool supportsRanges;

  /// Safe server-supplied leaf, kept exactly as provided after HTTP decoding.
  final String? filename;

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
    String? filename;
    var finalUri = Uri.tryParse(url);
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
      filename = _dispositionFilenameV2(
        response.headers['content-disposition']?.firstOrNull,
      );
      finalUri = response.realUri;
      supportsRanges =
          response.headers
              .value('accept-ranges')
              ?.toLowerCase()
              .contains('bytes') ==
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
        final total = parseRangeProbeTotalBytesV2(contentRange);
        supportsRanges = total != null;
        if (total != null) size = total;
      } else {
        supportsRanges = false;
        final contentLength = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (contentLength != null && contentLength > 1) size ??= contentLength;
      }
      mimeType ??= response.headers.value('content-type');
      filename =
          _dispositionFilenameV2(
            response.headers['content-disposition']?.firstOrNull,
          ) ??
          filename;
      finalUri = response.realUri;
      final body = response.data;
      if (body is ResponseBody) {
        final subscription = body.stream.listen(null);
        await subscription.cancel();
      }
    } catch (_) {}

    if (filename == null) {
      try {
        filename = _safeServerFilenameV2(finalUri?.pathSegments.lastOrNull);
      } on FormatException {
        // A non-UTF8 URL leaf cannot become a filename, but size stays useful.
      }
    }
    return DownloadSourceMetadataV2(
      size: size,
      mimeType: mimeType,
      supportsRanges: supportsRanges,
      filename: filename,
    );
  } catch (_) {
    return null;
  }
}

String? _dispositionFilenameV2(String? disposition) {
  if (disposition == null) return null;
  try {
    final parameters = HeaderValue.parse(
      disposition,
      preserveBackslash: true,
    ).parameters;
    final extended = parameters['filename*'];
    if (extended != null) {
      final match = RegExp(r"^([^']*)'[^']*'(.*)$").firstMatch(extended);
      final encoding = switch (match?.group(1)?.toLowerCase()) {
        'utf-8' => utf8,
        'iso-8859-1' => latin1,
        _ => null,
      };
      if (match != null && encoding != null) {
        try {
          final filename = _safeServerFilenameV2(
            Uri.decodeQueryComponent(
              match.group(2)!.replaceAll('+', '%2B'),
              encoding: encoding,
            ),
          );
          if (filename != null) return filename;
        } catch (_) {
          // A malformed extended value can still have a valid plain filename.
        }
      }
    }
    return _safeServerFilenameV2(parameters['filename']);
  } on HttpException {
    return null;
  }
}

String? _safeServerFilenameV2(String? value) {
  if (value == null ||
      value.isEmpty ||
      value == '.' ||
      value == '..' ||
      RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f-\x9f]').hasMatch(value) ||
      RegExp(r'[. ]$').hasMatch(value) ||
      RegExp(
        r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(value))
    return null;
  final bytes = utf8.encode(value);
  // Existing staging paths append ".assembling" to this leaf (11 bytes).
  if (bytes.length > 244 || utf8.decode(bytes) != value) return null;
  return value;
}

String _downloadFolderName(String value, {required String fallback}) {
  final sanitized = sanitizeDownloadFileName(value);
  return sanitized.isEmpty ? fallback : sanitized;
}

String _mangaChapterLabelV2(MangaChapter chapter) {
  final number = chapter.number;
  if (number == null) return chapter.name;
  final value = number == number.truncateToDouble()
      ? number.toInt().toString()
      : number.toString();
  return 'الفصل $value';
}

String _legacyDownloadFolderNameV2(String value, {required String fallback}) {
  final stem = normalizeDownloadText(value)
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return stem.isEmpty ? fallback : stem;
}

bool _safeLegacyDownloadLeafV2(String value) =>
    value.isNotEmpty && value != '.' && value != '..' &&
    !value.contains('/') && !value.contains('\\') &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value) &&
    p.windows.basename(value) == value &&
    utf8.encode(value).length <= 255 &&
    utf8.decode(utf8.encode(value)) == value;

/// Keep the preferred location when it permits actual writes. Scoped Android
/// storage can expose a public directory while refusing new files within it.
Future<String> firstWritableDownloadDirectoryV2(
  Iterable<Directory> directories,
) async {
  for (final directory in directories) {
    Directory? probe;
    try {
      await directory.create(recursive: true);
      probe = await directory.createTemp('.aw-write-');
      await File(p.join(probe.path, 'probe')).writeAsBytes([0], flush: true);
      return directory.path;
    } on FileSystemException {
      // Try the next app-specific location without changing existing downloads.
    } finally {
      if (probe != null) {
        try {
          await probe.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
  throw const FileSystemException(
    'No writable download directory is available',
  );
}

String _pathBelowDownloadDirectoryV2(String directory, List<String> segments) {
  final result = p.joinAll(<String>[directory, ...segments]);
  if (!p.isWithin(p.normalize(directory), p.normalize(result))) {
    throw ArgumentError.value(segments, 'segments', 'Path escapes media directory');
  }
  return result;
}

Future<List<String>> _downloadMediaRootsV2(String mediaType) async {
  if (Platform.isIOS) return <String>[p.join('Downloads', mediaType)];
  if (Platform.isAndroid) {
    final roots = <String>[p.join('/storage/emulated/0/Download', mediaType)];
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) roots.add(p.join(external.path, mediaType));
    } catch (_) {}
    try {
      final documents = await getApplicationDocumentsDirectory();
      roots.add(p.join(documents.path, 'Downloads', mediaType));
    } catch (_) {}
    return roots;
  }
  final downloads = await getDownloadsDirectory();
  final root = downloads?.path ??
      p.join((await getApplicationDocumentsDirectory()).path, 'Downloads');
  return <String>[p.join(root, mediaType)];
}

Future<String> _downloadMediaDirectoryV2(
  String mediaType,
  List<String> segments,
) async {
  final roots = await _downloadMediaRootsV2(mediaType);
  final paths = roots.map((root) => _pathBelowDownloadDirectoryV2(root, segments));
  if (Platform.isAndroid) {
    return firstWritableDownloadDirectoryV2(paths.map(Directory.new));
  }
  return paths.first;
}

/// Produces the final Anime path expected by V2. iOS keeps an
/// app-documents-relative path so it survives sandbox container relocation;
/// Android keeps public Downloads when writable and otherwise uses app-specific
/// storage; desktop uses its Downloads directory.
Future<String> downloadDestinationPathV2(
  MultimediaItem item, {
  Episode? episode,
  required String filename,
}) async {
  if (filename.isEmpty ||
      filename == '.' ||
      filename == '..' ||
      filename.contains('/') ||
      filename.contains('\\') ||
      p.isAbsolute(filename) ||
      p.windows.basename(filename) != filename ||
      utf8.encode(filename).length > 255) {
    throw ArgumentError.value(filename, 'filename', 'Expected one filename leaf');
  }
  final title = _downloadFolderName(item.title, fallback: 'Unknown');
  final directory = await _downloadMediaDirectoryV2('anime', <String>[title]);
  return _pathBelowDownloadDirectoryV2(directory, <String>[filename]);
}

/// Produces a readable chapter directory:
/// Downloads/manga/<manga title>/<chapter label>.
Future<String> mangaChapterDestinationDirectoryV2(
  MultimediaItem manga,
  MangaChapter chapter,
) async {
  final title = _downloadFolderName(manga.title, fallback: 'Manga');
  final chapterLabel = _mangaChapterLabelV2(chapter);
  final chapterFolder = _downloadFolderName(chapterLabel, fallback: 'فصل');
  final mangaId = manga.syncData?['mangaId']?.trim().isNotEmpty == true
      ? manga.syncData!['mangaId']!.trim()
      : chapter.mangaId.trim();

  final identity = logicalDownloadIdForMangaChapter(
    mangaId: mangaId,
    chapterId: chapter.id,
  );
  final suffix = identity.value.substring(
    'manga_'.length,
    'manga_'.length + 12,
  );
  final oldTitle = _legacyDownloadFolderNameV2(manga.title, fallback: 'Manga');
  final oldChapter = _legacyDownloadFolderNameV2(chapterLabel, fallback: 'فصل');
  // Legacy UTF-16 truncation may have an on-disk replacement character.
  final oldBoundedChapter = utf8.decode(
    utf8.encode(
      oldChapter.length > 90 ? oldChapter.substring(0, 90) : oldChapter,
    ),
  );
  final candidates = <List<String>>[
    <String>[oldTitle, oldChapter],
    <String>[oldTitle, '$oldBoundedChapter-$suffix'],
    <String>[title, '$chapterFolder-$suffix'],
    <String>[title, chapterFolder],
  ];
  final roots = await _downloadMediaRootsV2('manga');
  // Existing chapter checkpoints retain their paths; new chapters have no ID suffix.
  for (final root in roots) {
    for (final segments in candidates) {
      if (!segments.every(_safeLegacyDownloadLeafV2)) {
        continue;
      }
      final path = _pathBelowDownloadDirectoryV2(root, segments);
      try {
        if (!await _mangaChapterPathIsUnlinkedV2(root, path)) {
          continue;
        }
        final manifest = await MangaChapterManifestV2.readFrom(
          Directory(await absoluteDownloadDestinationPathV2(path)),
        );
        if (manifest != null &&
            manifest.mangaId == mangaId &&
            manifest.chapterId == chapter.id.trim()) {
          return path;
        }
      } on FileSystemException {
        // An inaccessible legacy candidate is not a usable checkpoint.
      }
    }
  }

  for (final root in roots) {
    final path = _pathBelowDownloadDirectoryV2(root, <String>[
      title,
      chapterFolder,
    ]);
    try {
      if (!await _mangaChapterPathIsUnlinkedV2(root, path)) {
        throw StateError('Chapter destination is not a regular directory');
      }
      final directory = Directory(
        await absoluteDownloadDestinationPathV2(path),
      );
      if (await directory.exists() &&
          !await directory.list(followLinks: false).isEmpty) {
        throw StateError('Chapter destination is already occupied');
      }
      if (!Platform.isAndroid) {
        return path;
      }
      return await firstWritableDownloadDirectoryV2([directory]);
    } on FileSystemException {
      if (!Platform.isAndroid) {
        rethrow;
      }
      // Public Android Downloads may be read-only; try app-specific storage.
    }
  }
  throw const FileSystemException(
    'No writable download directory is available',
  );
}

Future<bool> _mangaChapterPathIsUnlinkedV2(String root, String path) async {
  final absoluteRoot = await absoluteDownloadDestinationPathV2(root);
  final absolutePath = await absoluteDownloadDestinationPathV2(path);
  var current = absoluteRoot;
  for (final segment in <String>[
    '',
    ...p.split(p.relative(absolutePath, from: absoluteRoot)),
  ]) {
    if (segment.isNotEmpty && segment != '.') {
      current = p.join(current, segment);
    }
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      return false;
    }
  }
  return await FileSystemEntity.type(
        p.join(absolutePath, MangaChapterManifestV2.fileName),
        followLinks: false,
      ) !=
      FileSystemEntityType.link;
}

Future<String> absoluteDownloadDestinationPathV2(String destinationPath) async {
  if (p.isAbsolute(destinationPath)) return destinationPath;
  final documents = await getApplicationDocumentsDirectory();
  return p.join(documents.path, destinationPath);
}
