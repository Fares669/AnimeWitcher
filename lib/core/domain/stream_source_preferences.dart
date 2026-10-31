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
) {
  if (episodeSources.isEmpty) return const <StreamResult>[];
  final shared = episodeSources
      .skip(1)
      .map(
        (sources) => sources
            .where((source) => source.url.trim().isNotEmpty)
            .map(
              (source) =>
                  streamServerPreferenceKey(source.source).toLowerCase(),
            )
            .toSet(),
      )
      .toList();
  final seen = <String>{};
  return episodeSources.first
      .where((source) {
        final key = streamServerPreferenceKey(source.source).toLowerCase();
        return source.url.trim().isNotEmpty &&
            key.isNotEmpty &&
            seen.add(key) &&
            shared.every((keys) => keys.contains(key));
      })
      .toList(growable: false);
}

/// A pair is offered for a batch only if *every* episode provides it.
/// Keep the first episode's original source for the existing picker UI.
List<StreamResult> commonBatchStreamSources(
  List<List<StreamResult>> episodeSources,
) {
  if (episodeSources.isEmpty) return const <StreamResult>[];
  final shared = episodeSources
      .skip(1)
      .map(
        (sources) => sources
            .where(
              (source) => batchStreamSourceKey(source).$2.trim().isNotEmpty,
            )
            .map(batchStreamSourceKey)
            .toSet(),
      )
      .toList();
  final seen = <(String, String)>{};
  return episodeSources.first
      .where((source) {
        final key = batchStreamSourceKey(source);
        return key.$2.trim().isNotEmpty &&
            seen.add(key) &&
            shared.every((keys) => keys.contains(key));
      })
      .toList(growable: false);
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
  final ordered = List<({StreamResult source, int index})>.generate(
    sources.length,
    (index) => (source: sources[index], index: index),
    growable: false,
  );

  int rank(List<String> priority, String value) {
    final wanted = value.toLowerCase();
    final index = priority.indexWhere((entry) => entry.toLowerCase() == wanted);
    return index < 0 ? priority.length : index;
  }

  ordered.sort((a, b) {
    final qualityA = streamQualityPreferenceKey(a.source.quality);
    final qualityB = streamQualityPreferenceKey(b.source.quality);
    final rankA = rank(qualityPriority, qualityA);
    final rankB = rank(qualityPriority, qualityB);
    final qualityCompare = rankA.compareTo(rankB);
    if (qualityCompare != 0) return qualityCompare;

    if (rankA == qualityPriority.length) {
      final scoreCompare = _qualityScore(b.source.quality)
          .compareTo(_qualityScore(a.source.quality));
      if (scoreCompare != 0) return scoreCompare;
    }

    final serverA = streamServerPreferenceKey(a.source.source);
    final serverB = streamServerPreferenceKey(b.source.source);
    final serverCompare = rank(
      serverPriority,
      serverA,
    ).compareTo(rank(serverPriority, serverB));
    if (serverCompare != 0) return serverCompare;

    return a.index.compareTo(b.index);
  });

  return List<StreamResult>.unmodifiable(ordered.map((entry) => entry.source));
}

Future<StreamResult?> resolvePreferredStreamSource(
  List<StreamResult> sources, {
  required List<String> qualityPriority,
  required List<String> serverPriority,
  required Future<List<StreamResult>> Function(StreamResult candidate)
  resolveCandidate,
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
    } catch (_) {
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

String streamServerPreferenceKey(String source) {
  final normalized = source.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
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
  return source.trim().toUpperCase();
}

String streamQualityPreferenceKey(String? quality) {
  final score = _qualityScore(quality);
  if (score > 0) return '${score}p';

  final raw = quality?.trim() ?? '';
  final lower = raw.toLowerCase();
  if (raw.contains('متعدد') ||
      lower.contains('multi') ||
      lower.contains('auto')) {
    return 'متعدد';
  }
  return raw;
}

int _qualityScore(String? quality) {
  final raw = quality?.trim();
  if (raw == null || raw.isEmpty) return -1;
  final lower = raw.toLowerCase();
  final numeric = RegExp(r'(\d{3,4})').firstMatch(lower);
  if (numeric != null) return int.tryParse(numeric.group(1)!) ?? -1;
  if (lower.contains('4k') || lower.contains('uhd')) return 2160;
  if (lower.contains('fhd') || lower.contains('fullhd')) return 1080;
  if (lower == 'hd' || lower.contains('hd')) return 720;
  if (lower.contains('sd')) return 480;
  return -1;
}
