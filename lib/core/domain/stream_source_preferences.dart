import 'entity/multimedia_item.dart';

const List<String> defaultStreamServerPriority = <String>[
  'PD',
  'MF',
  'ST',
  'SF',
  'GF',
  'KF',
];

const List<String> defaultStreamQualityPriority = <String>[
  '2160p',
  '1080p',
  '720p',
  '480p',
  '360p',
  'متعدد',
];

/// Offer each server once when every selected episode has that server.
/// Video URLs and qualities are only resolved after the user chooses a server.
List<StreamResult> commonBatchStreamServers(
  List<List<StreamResult>> episodeSources,
) => _commonBatchOptions<String>(episodeSources, (source) {
  if (source.url.trim().isEmpty) return null;
  final key = streamServerPreferenceKey(source.source).toLowerCase();
  return key.isEmpty ? null : key;
});

/// A pair is offered for a batch only if *every* episode provides it.
/// Keep the first episode's original source for the existing picker UI.
List<StreamResult> commonBatchStreamSources(
  List<List<StreamResult>> episodeSources,
) => _commonBatchOptions<(String, String)>(episodeSources, (source) {
  final key = batchStreamSourceKey(source);
  return key.$2.isEmpty ? null : key;
});

List<StreamResult> _commonBatchOptions<K extends Object>(
  List<List<StreamResult>> episodes,
  K? Function(StreamResult source) keyOf,
) {
  if (episodes.isEmpty) return const <StreamResult>[];

  // Keep first-episode order and the first representative of each option.
  final common = <K, StreamResult>{};
  for (final source in episodes.first) {
    final key = keyOf(source);
    if (key != null) common.putIfAbsent(key, () => source);
  }
  for (final episode in episodes.skip(1)) {
    if (common.isEmpty) break;
    final available = <K>{};
    for (final source in episode) {
      final key = keyOf(source);
      if (key != null) available.add(key);
    }
    common.removeWhere((key, _) => !available.contains(key));
  }
  return common.values.toList(growable: false);
}

(String, String) batchStreamSourceKey(StreamResult source) => (
  streamServerPreferenceKey(source.source).toLowerCase(),
  streamQualityPreferenceKey(source.quality).toLowerCase(),
);

Future<List<StreamResult>> resolveBatchStreamSources(
  List<StreamResult> sources, {
  required Future<List<StreamResult>> Function(StreamResult candidate)
  resolveCandidate,
}) async {
  final output = <StreamResult>[];
  for (final candidate in sources) {
    if (!candidate.requiresResolution) {
      if (candidate.url.trim().isNotEmpty) output.add(candidate);
      continue;
    }
    try {
      final resolved = await resolveCandidate(candidate);
      for (final stream in resolved) {
        if (stream.url.trim().isEmpty) continue;
        final refreshUrl = stream.refreshUrl?.trim() ?? '';
        output.add(
          stream.copyWith(
            source: candidate.source.trim().isEmpty
                ? stream.source
                : candidate.source,
            requiresResolution: false,
            refreshUrl: refreshUrl.isNotEmpty ? refreshUrl : candidate.url,
          ),
        );
      }
    } catch (_) {
      // A dead server must not discard other servers for this episode.
    }
  }
  return List<StreamResult>.unmodifiable(output);
}

List<String> normalizeStreamPriority(
  Iterable<Object?>? raw,
  List<String> defaults,
) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in raw ?? const <Object?>[]) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || !seen.add(text.toLowerCase())) continue;
    result.add(text);
  }
  for (final value in defaults) {
    if (seen.add(value.toLowerCase())) result.add(value);
  }
  return List<String>.unmodifiable(result);
}

List<StreamResult> orderStreamSourcesByPreference(
  List<StreamResult> sources, {
  required List<String> qualityPriority,
  required List<String> serverPriority,
}) {
  if (sources.isEmpty) return const <StreamResult>[];
  if (sources.length == 1) return List<StreamResult>.unmodifiable(sources);

  Map<String, int> ranks(List<String> priority) {
    final result = <String, int>{};
    for (final (index, name) in priority.indexed) {
      result.putIfAbsent(name.toLowerCase(), () => index);
    }
    return result;
  }

  final qualityRanks = ranks(qualityPriority);
  final serverRanks = ranks(serverPriority);
  final unlistedQuality = qualityPriority.length;
  final ordered = sources.indexed
      .map((entry) {
        final (index, source) = entry;
        final quality = _streamQuality(source.quality);
        final server = streamServerPreferenceKey(source.source).toLowerCase();
        return (
          source: source,
          index: index,
          qualityRank:
              qualityRanks[quality.key.toLowerCase()] ?? unlistedQuality,
          score: quality.score,
          serverRank: serverRanks[server] ?? serverPriority.length,
        );
      })
      .toList(growable: false);
  ordered.sort((a, b) {
    final qualityCompare = a.qualityRank.compareTo(b.qualityRank);
    if (qualityCompare != 0) return qualityCompare;

    if (a.qualityRank == unlistedQuality) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;
    }

    final serverCompare = a.serverRank.compareTo(b.serverRank);
    return serverCompare != 0 ? serverCompare : a.index.compareTo(b.index);
  });

  return List<StreamResult>.unmodifiable(ordered.map((entry) => entry.source));
}

Future<StreamResult?> resolvePreferredStreamSource(
  List<StreamResult> sources, {
  required List<String> qualityPriority,
  required List<String> serverPriority,
  required Future<List<StreamResult>> Function(StreamResult candidate)
  resolveCandidate,
  bool Function(Object error)? tryNextOnError,
}) async {
  final ordered = orderStreamSourcesByPreference(
    sources,
    qualityPriority: qualityPriority,
    serverPriority: serverPriority,
  );
  for (final candidate in ordered) {
    if (!candidate.requiresResolution) return candidate;
    try {
      final resolved = await resolveCandidate(candidate);
      if (resolved.isEmpty) continue;
      final first = resolved.first;
      final refreshUrl = first.refreshUrl?.trim() ?? '';
      return refreshUrl.isNotEmpty
          ? first
          : first.copyWith(refreshUrl: candidate.url);
    } catch (error) {
      if (tryNextOnError?.call(error) == false) rethrow;
      // One dead server must not skip the rest of the same quality tier.
    }
  }
  return null;
}

StreamResult? selectPreferredStreamSource(
  List<StreamResult> sources, {
  required List<String> qualityPriority,
  required List<String> serverPriority,
}) {
  final ordered = orderStreamSourcesByPreference(
    sources,
    qualityPriority: qualityPriority,
    serverPriority: serverPriority,
  );
  return ordered.isEmpty ? null : ordered.first;
}

final _nonServerKeyCharacter = RegExp(r'[^A-Z0-9]');

String streamServerPreferenceKey(String source) {
  final upper = source.toUpperCase();
  final normalized = upper.replaceAll(_nonServerKeyCharacter, '');
  if (normalized.startsWith('PD') || normalized.contains('PIXELDRAIN')) {
    return 'PD';
  }
  if (normalized.startsWith('MF') ||
      normalized == 'MD' ||
      normalized.contains('MEDIAFIRE')) {
    return 'MF';
  }
  if (normalized.startsWith('ST') || normalized.contains('STREAMTAPE')) {
    return 'ST';
  }
  if (normalized.startsWith('SF')) return 'SF';
  return upper.trim();
}

String streamQualityPreferenceKey(String? quality) =>
    _streamQuality(quality).key;

({String key, int score}) _streamQuality(String? quality) {
  final raw = quality?.trim() ?? '';
  final lower = raw.toLowerCase();
  final score = _qualityScore(lower);
  if (score > 0) return (key: '${score}p', score: score);
  if (raw.contains('متعدد') ||
      lower.contains('multi') ||
      lower.contains('auto')) {
    return (key: 'متعدد', score: score);
  }
  return (key: raw, score: score);
}

final _qualityNumber = RegExp(r'(\d{3,4})');

int _qualityScore(String lower) {
  final numeric = _qualityNumber.firstMatch(lower);
  if (numeric != null) return int.tryParse(numeric.group(1)!) ?? -1;
  if (lower.contains('4k') || lower.contains('uhd')) return 2160;
  if (lower.contains('fhd') || lower.contains('fullhd')) return 1080;
  if (lower.contains('hd')) return 720;
  if (lower.contains('sd')) return 480;
  return -1;
}
