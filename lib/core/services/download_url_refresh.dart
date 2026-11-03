import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../domain/entity/multimedia_item.dart';
import '../extensions/base_provider.dart';
import '../extensions/extension_manager.dart';
import '../utils/anime_rift_identity.dart';
import 'download_v2/anime_rift_download_metadata_v2.dart';

const String kDownloadUrlRefreshBox = 'download_url_refresh_v1';
const Duration kDownloadUrlRefreshDescriptorTtl = Duration(days: 30);

class DownloadUrlRefreshDescriptor {
  const DownloadUrlRefreshDescriptor({
    required this.trackingUrl,
    required this.providerId,
    required this.source,
    required this.updatedAtMillis,
    this.generation = 0,
    this.ownerTaskId,
    this.logicalId,
    this.quality,
    this.refreshUrl,
  });

  final String trackingUrl;
  final String providerId;
  final String source;
  final String? quality;
  final String? refreshUrl;
  final int updatedAtMillis;
  final int generation;
  final String? ownerTaskId;
  final String? logicalId;

  Map<String, Object?> toJson() =>
      safeDownloadSourceDescriptorV2(<String, Object?>{
        'trackingUrl': trackingUrl,
        'providerId': providerId,
        'source': source,
        if (quality?.trim().isNotEmpty ?? false) 'quality': quality,
        if (refreshUrl?.trim().isNotEmpty ?? false) 'refreshUrl': refreshUrl,
        'updatedAtMillis': updatedAtMillis,
        'generation': generation,
        if (ownerTaskId?.trim().isNotEmpty ?? false) 'ownerTaskId': ownerTaskId,
        if (logicalId?.trim().isNotEmpty ?? false) 'logicalId': logicalId,
      });

  static DownloadUrlRefreshDescriptor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = safeDownloadSourceDescriptorV2(Map<String, Object?>.from(raw));
    final trackingUrl = _string(map['trackingUrl']);
    final providerId = _string(map['providerId']);
    final source = _string(map['source']);
    if (trackingUrl == null || providerId == null || source == null)
      return null;
    return DownloadUrlRefreshDescriptor(
      trackingUrl: trackingUrl,
      providerId: providerId,
      source: source,
      quality: _string(map['quality']),
      refreshUrl: _string(map['refreshUrl']),
      updatedAtMillis: _int(map['updatedAtMillis']),
      // Older descriptors predate generation fencing. Generation zero keeps
      // them readable until the owning V2 record rewrites the descriptor.
      generation: _int(map['generation']),
      ownerTaskId: _string(map['ownerTaskId']),
      logicalId: _string(map['logicalId']),
    );
  }
}

abstract interface class DownloadUrlRefreshBackend {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, Object?> value);
  Future<void> delete(String key);
}

class HiveDownloadUrlRefreshBackend implements DownloadUrlRefreshBackend {
  const HiveDownloadUrlRefreshBackend({this.boxName = kDownloadUrlRefreshBox});

  final String boxName;

  Future<Box<dynamic>> _box() => Hive.openBox<dynamic>(boxName);

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final raw = (await _box()).get(key);
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async {
    await (await _box()).put(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await (await _box()).delete(key);
  }
}

class DownloadUrlRefreshStore {
  DownloadUrlRefreshStore(this.backend, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DownloadUrlRefreshBackend backend;
  final DateTime Function() _now;

  String keyFor(String trackingUrl) =>
      md5.convert(utf8.encode(trackingUrl.trim())).toString();

  List<String> _keysForRead(String trackingUrl) {
    final raw = trackingUrl.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.host != animeRiftCatalogHost &&
            uri.host != 'www.$animeRiftCatalogHost')) {
      return <String>[keyFor(raw)];
    }
    final canonical = animeRiftDownloadTrackingIdentityV2(raw);
    if (canonical == null) return <String>[keyFor(raw)];
    final canonicalUri = Uri.parse(canonical);
    final wwwAlias = canonicalUri
        .replace(host: 'www.$animeRiftCatalogHost')
        .toString();
    return <String>{
      keyFor(canonical),
      keyFor(raw),
      keyFor(wwwAlias),
    }.toList(growable: false);
  }

  Future<({String key, DownloadUrlRefreshDescriptor descriptor})?>
  _readDescriptor(String trackingUrl) async {
    final entries = await _readDescriptors(trackingUrl);
    return entries.isEmpty ? null : entries.first;
  }

  Future<List<({String key, DownloadUrlRefreshDescriptor descriptor})>>
  _readDescriptors(String trackingUrl) async {
    final entries = <({String key, DownloadUrlRefreshDescriptor descriptor})>[];
    for (final key in _keysForRead(trackingUrl)) {
      final descriptor = DownloadUrlRefreshDescriptor.fromJson(
        await backend.read(key),
      );
      if (descriptor != null) entries.add((key: key, descriptor: descriptor));
    }
    return entries;
  }

  Future<void> _tail = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then<void>((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<bool> claimOwnership(DownloadUrlRefreshDescriptor descriptor) =>
      _serialize(() async {
        final safe = DownloadUrlRefreshDescriptor.fromJson(descriptor.toJson());
        if (safe == null) return false;
        descriptor = safe;
        final ownerTaskId = descriptor.ownerTaskId?.trim();
        final logicalId = descriptor.logicalId?.trim();
        if (descriptor.trackingUrl.trim().isEmpty ||
            descriptor.providerId.trim().isEmpty ||
            descriptor.source.trim().isEmpty ||
            ownerTaskId == null ||
            ownerTaskId.isEmpty ||
            logicalId == null ||
            logicalId.isEmpty) {
          return false;
        }
        final entries = await _readDescriptors(descriptor.trackingUrl);
        for (final entry in entries) {
          final existing = entry.descriptor;
          final existingLogicalId = existing.logicalId?.trim();
          if (existingLogicalId != null &&
              existingLogicalId.isNotEmpty &&
              existingLogicalId != logicalId) {
            return false;
          }
          if (existing.ownerTaskId == ownerTaskId &&
              existing.generation > descriptor.generation) {
            return false;
          }
        }
        final key = keyFor(descriptor.trackingUrl);
        await backend.write(key, descriptor.toJson());
        await Future.wait(
          entries
              .where((entry) => entry.key != key)
              .map((entry) => backend.delete(entry.key)),
        );
        return true;
      });

  Future<bool> save(DownloadUrlRefreshDescriptor descriptor) =>
      _serialize(() async {
        final safe = DownloadUrlRefreshDescriptor.fromJson(descriptor.toJson());
        if (safe == null) return false;
        descriptor = safe;
        if (descriptor.trackingUrl.trim().isEmpty ||
            descriptor.providerId.trim().isEmpty ||
            descriptor.source.trim().isEmpty) {
          return false;
        }
        final incomingOwner = descriptor.ownerTaskId?.trim();
        final entries = await _readDescriptors(descriptor.trackingUrl);

        // Owned descriptors can only be created/replaced through the explicit
        // claim path. This prevents a delayed old task from resurrecting its
        // descriptor after the current owner has deleted it.
        if (entries.isEmpty) {
          if (incomingOwner != null && incomingOwner.isNotEmpty) return false;
        } else {
          for (final entry in entries) {
            final existing = entry.descriptor;
            final existingOwner = existing.ownerTaskId?.trim();
            if (existingOwner != null && existingOwner.isNotEmpty) {
              if (incomingOwner != existingOwner) return false;
              final existingLogicalId = existing.logicalId?.trim();
              final incomingLogicalId = descriptor.logicalId?.trim();
              if (existingLogicalId != null &&
                  existingLogicalId.isNotEmpty &&
                  incomingLogicalId != existingLogicalId) {
                return false;
              }
            } else if (incomingOwner != null && incomingOwner.isNotEmpty) {
              // Adopting an older unowned descriptor into owned state is also a
              // claim operation, never a plain save.
              return false;
            }
            if (existing.generation > descriptor.generation) return false;
          }
        }

        final key = keyFor(descriptor.trackingUrl);
        await backend.write(key, descriptor.toJson());
        await Future.wait(
          entries
              .where((entry) => entry.key != key)
              .map((entry) => backend.delete(entry.key)),
        );
        return true;
      });

  Future<DownloadUrlRefreshDescriptor?> get(String trackingUrl) async {
    final entry = await _readDescriptor(trackingUrl);
    if (entry == null) return null;
    final descriptor = entry.descriptor;
    if (_now().millisecondsSinceEpoch - descriptor.updatedAtMillis >
        kDownloadUrlRefreshDescriptorTtl.inMilliseconds) {
      await backend.delete(entry.key);
      return null;
    }
    return descriptor;
  }

  Future<bool> removeForGeneration(String trackingUrl, int generation) =>
      _serialize(() async {
        final entries = await _readDescriptors(trackingUrl);
        if (entries.isEmpty) return true;
        for (final entry in entries) {
          final descriptor = entry.descriptor;
          // Generation-only cleanup is retained for older unowned rows only.
          // Once an owner exists, callers must prove the task identity as well.
          if (descriptor.ownerTaskId != null) return false;
          if (descriptor.generation != generation) return false;
        }
        await Future.wait(entries.map((entry) => backend.delete(entry.key)));
        return true;
      });

  Future<bool> removeForOwnerGeneration(
    String trackingUrl,
    String ownerTaskId,
    int generation,
  ) => _serialize(() async {
    final entries = await _readDescriptors(trackingUrl);
    if (entries.isEmpty) return true;
    for (final entry in entries) {
      final descriptor = entry.descriptor;
      if (descriptor.ownerTaskId?.trim() != ownerTaskId.trim()) return false;
      // A newer same-owner operation may clean an older descriptor after a
      // crash, but a stale operation can never delete a newer generation.
      if (descriptor.generation > generation) return false;
    }
    await Future.wait(entries.map((entry) => backend.delete(entry.key)));
    return true;
  });

  Future<void> remove(String trackingUrl) =>
      Future.wait(_keysForRead(trackingUrl).map(backend.delete));
}

class RefreshedDownloadUrl {
  const RefreshedDownloadUrl({
    required this.url,
    required this.headers,
    required this.source,
    this.quality,
  });

  final String url;
  final Map<String, String> headers;
  final String source;
  final String? quality;
}

class DownloadUrlRefresher {
  const DownloadUrlRefresher({required this.providerForId});

  final AnimeWitcherProvider? Function(String providerId) providerForId;

  Future<RefreshedDownloadUrl?> refresh(
    DownloadUrlRefreshDescriptor descriptor, {
    required String currentUrl,
  }) async {
    final safe = DownloadUrlRefreshDescriptor.fromJson(descriptor.toJson());
    if (safe == null) return null;
    descriptor = safe;
    final provider = providerForId(descriptor.providerId);
    if (provider == null) return null;
    provider.prepareForNetworkRetry();

    List<StreamResult> latest = const <StreamResult>[];
    try {
      final sources = await provider.loadStreamSources(descriptor.trackingUrl);
      final selected = _bestStreamMatch(sources, descriptor);
      if (selected != null) {
        latest = selected.requiresResolution
            ? await provider.loadStreams(selected.url)
            : <StreamResult>[selected];
      }
    } catch (_) {}

    var refreshed = _bestStreamMatch(latest, descriptor);
    if (_usableRefreshedStream(refreshed, currentUrl)) {
      return _refreshedDownloadUrl(refreshed!);
    }

    final refreshUrl = descriptor.refreshUrl?.trim();
    if (refreshUrl != null && refreshUrl.isNotEmpty) {
      try {
        final tokenCandidates = await provider.loadStreams(refreshUrl);
        final tokenResult = _bestStreamMatch(tokenCandidates, descriptor);
        if (_usableRefreshedStream(tokenResult, currentUrl)) {
          return _refreshedDownloadUrl(tokenResult!);
        }
        refreshed ??= tokenResult;
      } catch (_) {}
    }

    if (refreshed == null ||
        refreshed.requiresResolution ||
        refreshed.url.trim().isEmpty ||
        refreshed.url.trim() == currentUrl.trim()) {
      return null;
    }
    return _refreshedDownloadUrl(refreshed);
  }

  bool _usableRefreshedStream(StreamResult? stream, String currentUrl) =>
      stream != null &&
      !stream.requiresResolution &&
      stream.url.trim().isNotEmpty &&
      stream.url.trim() != currentUrl.trim();

  RefreshedDownloadUrl _refreshedDownloadUrl(StreamResult refreshed) {
    return RefreshedDownloadUrl(
      url: refreshed.url.trim(),
      headers: Map<String, String>.from(refreshed.headers ?? const {}),
      source: refreshed.source,
      quality: refreshed.quality,
    );
  }
}

StreamResult? _bestStreamMatch(
  List<StreamResult> streams,
  DownloadUrlRefreshDescriptor descriptor,
) {
  if (streams.isEmpty) return null;
  final wantedSource = descriptor.source.trim().toLowerCase();
  final wantedQuality = descriptor.quality?.trim().toLowerCase();

  StreamResult? best;
  var bestScore = -1;
  for (final stream in streams) {
    if (stream.source.trim().toLowerCase() != wantedSource) continue;
    var score = 0;
    if (stream.source.trim().toLowerCase() == wantedSource) score += 4;
    final quality = stream.quality?.trim().toLowerCase();
    if (wantedQuality != null && wantedQuality.isNotEmpty) {
      if (quality == wantedQuality) {
        score += 3;
      } else if (!(stream.requiresResolution &&
          (quality == null || quality.isEmpty))) {
        // An unresolved source may expose qualities only after extraction.
        // A playable replacement must match the saved quality exactly.
        continue;
      }
    } else if (quality == null || quality.isEmpty) {
      score += 1;
    }
    if (!stream.requiresResolution) score += 1;
    if (score > bestScore) {
      best = stream;
      bestScore = score;
    }
  }
  return best;
}

final downloadUrlRefreshStoreProvider = Provider<DownloadUrlRefreshStore>((
  ref,
) {
  return DownloadUrlRefreshStore(const HiveDownloadUrlRefreshBackend());
});

final downloadUrlRefresherProvider = Provider<DownloadUrlRefresher>((ref) {
  final manager = ref.read(extensionManagerProvider.notifier);
  return DownloadUrlRefresher(providerForId: manager.getProvider);
});

String? _string(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

int _int(Object? raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}
