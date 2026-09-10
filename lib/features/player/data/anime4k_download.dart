/// Fetches the Anime4K shaders so nobody has to go and find them.
///
/// The shaders are a separate MIT-licensed project, not something this app
/// ships. Asking a viewer to download a zip, find the `.glsl` files inside it
/// and point a file picker at them is three steps too many for a feature
/// whose whole appeal is that it makes the picture better without thinking
/// about it. So the app fetches the official release itself, on request.
///
/// The release tag is pinned rather than tracking "latest": what gets
/// downloaded should be the set these pipelines were written against, and a
/// new release that renames or reshapes the files should be something a
/// person looks at, not something that lands silently on a viewer's machine.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/network/dio_client_provider.dart';

part 'anime4k_download.g.dart';

/// The release this app was written against.
const String anime4kReleaseTag = 'v4.0.1';

/// The one asset that release carries — about 760 KB of GLSL.
const String anime4kDownloadUrl =
    'https://github.com/bloc97/Anime4K/releases/download/'
    '$anime4kReleaseTag/Anime4K_v4.0.zip';

/// Where the project lives, for crediting it in the interface.
const String anime4kProjectUrl = 'https://github.com/bloc97/Anime4K';

/// The name to write an archive entry under, or null to skip it.
///
/// Only `.glsl` files are taken, and only ever under their bare filename.
/// That flattening is what the resolver expects — it matches on filenames,
/// not on the folders the release happens to group them into — and it is also
/// what makes extraction safe: an archive entry is never allowed to steer
/// where it lands, so an entry named `../../autoexec` cannot escape the
/// folder it is being written to.
String? anime4kExtractName(String entryName) {
  final trimmed = entryName.trim();
  if (trimmed.isEmpty) return null;
  // Zip entries always use forward slashes, whatever wrote them; Windows
  // archivers sometimes use backslashes anyway.
  final base = trimmed.split(RegExp(r'[/\\]')).last;
  if (base.isEmpty || base == '.' || base == '..') return null;
  if (p.extension(base).toLowerCase() != '.glsl') return null;
  // A name that still looks like a path after taking its last segment is not
  // a name this will write.
  if (base.contains(':')) return null;
  return base;
}

/// What a download did.
class Anime4kDownloadResult {
  const Anime4kDownloadResult({required this.directory, required this.written});

  /// Where the shaders now are, ready to be handed to the settings.
  final String directory;

  /// How many `.glsl` files were written.
  final int written;
}

class Anime4kDownloadException implements Exception {
  const Anime4kDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Anime4kDownloader {
  const Anime4kDownloader(this._dio);

  final Dio _dio;

  /// The folder the app keeps downloaded shaders in.
  ///
  /// Application support rather than documents: these are not the viewer's
  /// files to manage, and nothing else should be tidying them away.
  static Future<Directory> defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'anime4k_shaders'));
  }

  /// Downloads the pinned release and writes its shaders to [into], or to
  /// [defaultDirectory] when that is not given.
  ///
  /// [onProgress] receives a fraction from 0 to 1 while the archive comes
  /// down, or null when the server does not say how large it is.
  Future<Anime4kDownloadResult> download({
    Directory? into,
    void Function(double? progress)? onProgress,
  }) async {
    final target = into ?? await defaultDirectory();

    final Uint8List bytes;
    try {
      final response = await _dio.get<List<int>>(
        anime4kDownloadUrl,
        options: Options(
          responseType: ResponseType.bytes,
          // The archive is small, but a stalled connection should not hang
          // a dialog the viewer is sitting in front of.
          receiveTimeout: const Duration(minutes: 2),
        ),
        onReceiveProgress: (received, total) {
          onProgress?.call(total > 0 ? received / total : null);
        },
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const Anime4kDownloadException('The download came back empty.');
      }
      bytes = Uint8List.fromList(data);
    } on DioException catch (error) {
      throw Anime4kDownloadException(
        'Could not reach the Anime4K release: ${error.message ?? error.type}',
      );
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      throw const Anime4kDownloadException(
        'The downloaded file is not a readable archive.',
      );
    }

    await target.create(recursive: true);
    var written = 0;
    final seen = <String>{};
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = anime4kExtractName(entry.name);
      if (name == null) continue;
      // First one wins, so a re-run writes the same set in the same way.
      if (!seen.add(name.toLowerCase())) continue;
      final content = entry.readBytes();
      if (content == null || content.isEmpty) continue;
      await File(p.join(target.path, name)).writeAsBytes(content, flush: true);
      written += 1;
    }

    if (written == 0) {
      throw const Anime4kDownloadException(
        'The archive held no shader files.',
      );
    }
    return Anime4kDownloadResult(directory: target.path, written: written);
  }
}

@Riverpod(keepAlive: true)
Anime4kDownloader anime4kDownloader(Ref ref) {
  return Anime4kDownloader(ref.watch(dioClientProvider));
}
