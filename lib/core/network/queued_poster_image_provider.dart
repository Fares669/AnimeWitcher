// Preserve both public provider entry points and the legacy cache interface.
// ignore_for_file: deprecated_member_use

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'poster_cache.dart';
import 'poster_decode_queue.dart';

/// The normal poster provider, with bounded first-frame work for fresh files.
///
/// Only the application's standard CacheManager stream contract is supported:
/// a valid cached file or first download is a single result; an expired cached
/// file may be followed by its refresh. Refreshing resolutions bypass the queue
/// entirely, preserving the existing completer's ordering and lifecycle.
class QueuedPosterImageProvider extends CachedNetworkImageProvider {
  QueuedPosterImageProvider(super.url)
    : super(cacheManager: posterCacheManager);

  /// Supplies a controlled stream with the standard CacheManager contract.
  @visibleForTesting
  const QueuedPosterImageProvider.withCache(
    super.url, {
    required BaseCacheManager super.cacheManager,
    super.cacheKey,
    super.scale,
    super.headers,
    super.maxWidth,
    super.maxHeight,
  });

  CachedNetworkImageProvider _provider(BaseCacheManager manager) =>
      CachedNetworkImageProvider(
        url,
        cacheManager: manager,
        cacheKey: cacheKey,
        scale: scale,
        headers: headers,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );

  @override
  ImageStreamCompleter loadImage(
    CachedNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    // Preserve ImageCacheManager's separate on-disk resizing route unchanged.
    if (maxWidth != null || maxHeight != null) {
      return super.loadImage(key, decode);
    }
    final manager = _PosterResolutionCache(cacheManager!);
    return _provider(manager).loadImage(key, (buffer, {getTargetSize}) async {
      final mayQueue = manager.mayQueue;
      final codec = await decode(buffer, getTargetSize: getTargetSize);
      return mayQueue ? PosterDecodeCodec.wrap(codec) : codec;
    });
  }

  @override
  ImageStreamCompleter loadBuffer(
    CachedNetworkImageProvider key,
    DecoderBufferCallback decode,
  ) {
    if (maxWidth != null || maxHeight != null) {
      return super.loadBuffer(key, decode);
    }
    final manager = _PosterResolutionCache(cacheManager!);
    return _provider(manager).loadBuffer(key, (
      buffer, {
      cacheWidth,
      cacheHeight,
      bool? allowUpscaling,
    }) async {
      final mayQueue = manager.mayQueue;
      // ResizeImage distinguishes absence from an explicitly supplied option.
      final codec = allowUpscaling == null
          ? await decode(
              buffer,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
            )
          : await decode(
              buffer,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              allowUpscaling: allowUpscaling,
            );
      return mayQueue ? PosterDecodeCodec.wrap(codec) : codec;
    });
  }
}

/// Intercepts actual stream metadata, not a racy second cache-validity lookup.
/// All storage/network operations remain owned by the original cache manager.
class _PosterResolutionCache implements BaseCacheManager {
  _PosterResolutionCache(this.delegate);
  final BaseCacheManager delegate;
  bool _seenFile = false;
  bool mayQueue = false;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => delegate
      .getFileStream(
        url,
        key: key,
        headers: headers,
        withProgress: withProgress,
      )
      .map((response) {
        if (response is FileInfo) {
          mayQueue =
              !_seenFile &&
              (response.source == FileSource.Cache ||
                  response.source == FileSource.Online) &&
              response.validTill.isAfter(DateTime.now());
          _seenFile = true;
        }
        return response;
      });

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) => key == null
      ? (headers == null
            ? delegate.getSingleFile(url)
            : delegate.getSingleFile(url, headers: headers))
      : (headers == null
            ? delegate.getSingleFile(url, key: key)
            : delegate.getSingleFile(url, key: key, headers: headers));
  @override
  Stream<FileInfo> getFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) => key == null
      ? (headers == null
            ? delegate.getFile(url)
            : delegate.getFile(url, headers: headers))
      : (headers == null
            ? delegate.getFile(url, key: key)
            : delegate.getFile(url, key: key, headers: headers));
  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) => delegate.downloadFile(
    url,
    key: key,
    authHeaders: authHeaders,
    force: force,
  );
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) => delegate.getFileFromCache(key, ignoreMemCache: ignoreMemCache);
  @override
  Future<FileInfo?> getFileFromMemory(String key) =>
      delegate.getFileFromMemory(key);
  @override
  Future<File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) => delegate.putFile(
    url,
    fileBytes,
    key: key,
    eTag: eTag,
    maxAge: maxAge,
    fileExtension: fileExtension,
  );
  @override
  Future<File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) => delegate.putFileStream(
    url,
    source,
    key: key,
    eTag: eTag,
    maxAge: maxAge,
    fileExtension: fileExtension,
  );
  @override
  Future<void> removeFile(String key) => delegate.removeFile(key);
  @override
  Future<void> emptyCache() => delegate.emptyCache();
  @override
  Future<void> dispose() => delegate.dispose();
}
