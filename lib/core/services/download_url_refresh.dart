import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../domain/entity/multimedia_item.dart';
import '../extensions/base_provider.dart';
import '../extensions/extension_manager.dart';

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

  Map<String, Object?> toJson() => <String, Object?>{
    'trackingUrl': trackingUrl,
    'providerId': providerId,
    'source': source,
    if (quality?.trim().isNotEmpty ?? false) 'quality': quality,
    if (refreshUrl?.trim().isNotEmpty ?? false) 'refreshUrl': refreshUrl,
    'updatedAtMillis': updatedAtMillis,
    'generation': generation,
    if (ownerTaskId?.trim().isNotEmpty ?? false) 'ownerTaskId': ownerTaskId,
    if (logicalId?.trim().isNotEmpty ?? false) 'logicalId': logicalId,
  };

  static DownloadUrlRefreshDescriptor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
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
      // Legacy descriptors predate generation fencing. Generation zero keeps
      // them readable until the owning DownloadService rewrites the record.
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
        final key = keyFor(descriptor.trackingUrl);
        final existing = DownloadUrlRefreshDescriptor.fromJson(
          await backend.read(key),
        );
        final existingLogicalId = existing?.logicalId?.trim();
        if (existingLogicalId != null &&
            existingLogicalId.isNotEmpty &&
            existingLogicalId != logicalId) {
          return false;
        }
        if (existing?.ownerTaskId == ownerTaskId &&
            existing!.generation > descriptor.generation) {
          return false;
        }
        await backend.write(key, descriptor.toJson());
        return true;
      });

  Future<bool> save(DownloadUrlRefreshDescriptor descriptor) =>
      _serialize(() async {
        if (descriptor.trackingUrl.trim().isEmpty ||
            descriptor.providerId.trim().isEmpty ||
            descriptor.source.trim().isEmpty) {
          return false;
        }
        final key = keyFor(descriptor.trackingUrl);
        final existing = DownloadUrlRefreshDescriptor.fromJson(
          await backend.read(key),
        );
        final incomingOwner = descriptor.ownerTaskId?.trim();
        final existingOwner = existing?.ownerTaskId?.trim();

        // Owned descriptors can only be created/replaced through the explicit
        // claim path. This prevents a delayed old task from resurrecting its
        // descriptor after the current owner has deleted it.
        if (existing == null) {
          if (incomingOwner != null && incomingOwner.isNotEmpty) return false;
        } else if (existingOwner != null && existingOwner.isNotEmpty) {
          if (incomingOwner != existingOwner) return false;
          final existingLogicalId = existing.logicalId?.trim();
          final incomingLogicalId = descriptor.logicalId?.trim();
          if (existingLogicalId != null &&
              existingLogicalId.isNotEmpty &&
              incomingLogicalId != existingLogicalId) {
            return false;
          }
        } else if (incomingOwner != null && incomingOwner.isNotEmpty) {
          // Migrating a legacy unowned descriptor to owned state is also a
          // claim operation, never a plain save.
          return false;
        }

        if (existing != null && existing.generation > descriptor.generation) {
          return false;
        }
        await backend.write(key, descriptor.toJson());
        return true;
      });

  Future<DownloadUrlRefreshDescriptor?> get(String trackingUrl) async {
    final key = keyFor(trackingUrl);
    final descriptor = DownloadUrlRefreshDescriptor.fromJson(
      await backend.read(key),
    );
    if (descriptor == null) return null;
    if (_now().millisecondsSinceEpoch - descriptor.updatedAtMillis >
        kDownloadUrlRefreshDescriptorTtl.inMilliseconds) {
      await backend.delete(key);
      return null;
    }
    return descriptor;
  }

  Future<bool> removeForGeneration(
    String trackingUrl,
    int generation,
  ) => _serialize(() async {
    final key = keyFor(trackingUrl);
    final descriptor = DownloadUrlRefreshDescriptor.fromJson(
      await backend.read(key),
    );
    if (descriptor == null) return true;
    // Generation-only cleanup is retained for legacy unowned rows only. Once
    // an owner exists, callers must prove the task identity as well.
    if (descriptor.ownerTaskId != null) return false;
    if (descriptor.generation != generation) return false;
    await backend.delete(key);
    return true;
  });

  Future<bool> removeForOwnerGeneration(
    String trackingUrl,
    String ownerTaskId,
    int generation,
  ) => _serialize(() async {
    final key = keyFor(trackingUrl);
    final descriptor = DownloadUrlRefreshDescriptor.fromJson(
      await backend.read(key),
    );
    if (descriptor == null) return true;
    if (descriptor.ownerTaskId?.trim() != ownerTaskId.trim()) return false;
    // A newer same-owner operation may clean an older descriptor after a
    // crash, but a stale operation can never delete a newer generation.
    if (descriptor.generation > generation) return false;
    await backend.delete(key);
    return true;
  });

  Future<void> remove(String trackingUrl) =>
      backend.delete(keyFor(trackingUrl));
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
    final provider = providerForId(descriptor.providerId);
    if (provider == null) return null;
    provider.prepareForNetworkRetry();

    List<StreamResult> candidates = const <StreamResult>[];
    final refreshUrl = descriptor.refreshUrl?.trim();
    if (refreshUrl != null && refreshUrl.isNotEmpty) {
      try {
        candidates = await provider.loadStreams(refreshUrl);
      } catch (_) {}
    }

    if (_bestStreamMatch(candidates, descriptor) == null) {
      List<StreamResult> sources;
      try {
        sources = await provider.loadStreamSources(descriptor.trackingUrl);
      } catch (_) {
        return null;
      }
      final selected = _bestStreamMatch(sources, descriptor);
      if (selected == null) return null;
      if (selected.requiresResolution) {
        try {
          candidates = await provider.loadStreams(selected.url);
        } catch (_) {
          return null;
        }
      } else {
        candidates = <StreamResult>[selected];
      }
    }

    final refreshed = _bestStreamMatch(candidates, descriptor);
    if (refreshed == null ||
        refreshed.requiresResolution ||
        refreshed.url.trim().isEmpty)
      return null;
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
