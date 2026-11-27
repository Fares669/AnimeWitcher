import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether MyAnimeList's image CDN can actually be reached from here.
///
/// The catalog stores most artwork on `cdn.myanimelist.net`, which is blocked
/// by some ISPs and in some countries. A blocked URL is not an empty one, so
/// the existing "use the next candidate when this one is missing" logic never
/// fires — every poster just fails to load. This switch lets artwork
/// selection demote those URLs in favour of the AniList copy the catalog
/// also stores.
///
/// Image widgets are leaves spread across every feature, so this lives in one
/// listenable rather than being threaded through all of them, mirroring
/// [highQualityArtwork].
final ValueNotifier<bool> malArtworkUnreachable = ValueNotifier<bool>(false);

/// Whether to look for artwork outside the catalog at all.
///
/// Off by default: the catalog's own URLs are correct for most viewers, and
/// only a viewer whose network blocks the artwork host needs anything else.
/// While this is off nothing here probes, reorders or looks anything up, so
/// artwork behaves exactly as it did before this existed.
final ValueNotifier<bool> artworkFallbackEnabled = ValueNotifier<bool>(false);

/// The setting governs looking artwork up elsewhere; whether the CDN is
/// reachable is checked regardless, and is not reset by it.
void applyArtworkFallbackEnabled(bool enabled) {
  artworkFallbackEnabled.value = enabled;
}

bool isMalArtworkUrl(String url) {
  if (url.isEmpty) return false;
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) return url.contains('myanimelist.net');
  return host.endsWith('myanimelist.net');
}

/// Orders artwork candidates so ones that can actually load come first.
///
/// Order is otherwise preserved, so the catalog's own preference still
/// decides between two reachable URLs. Only the catalog's own candidates are
/// reordered, so this needs no setting: on a network that blocks the CDN, the
/// AniList copy the catalog stores comes first.
List<String> preferReachableArtwork(Iterable<String> candidates) {
  final values = candidates.where((c) => c.trim().isNotEmpty).toList();
  if (!malArtworkUnreachable.value) {
    return values;
  }
  final reachable = values.where((c) => !isMalArtworkUrl(c)).toList();
  final blocked = values.where(isMalArtworkUrl).toList();
  // Blocked URLs stay at the end rather than being dropped: they are better
  // than showing nothing if the probe was wrong or the block is partial.
  return <String>[...reachable, ...blocked];
}

/// A tiny asset on the same CDN as the posters. Fetching it is enough to know
/// whether the host resolves at all.
const String _probeUrl = 'https://cdn.myanimelist.net/images/favicon.ico';

/// How long a probe result is trusted before checking again. Long enough to
/// cost nothing, short enough that the app recovers when a block lifts.
const Duration probeTtl = Duration(hours: 6);

/// Publishes a stored probe result immediately, so the first frame already
/// picks the right artwork instead of waiting for the network.
void seedMalArtworkReachability(bool unreachable) {
  malArtworkUnreachable.value = unreachable;
}

/// Whether the MyAnimeList CDN is unreachable. A timeout is unknown, so
/// callers should retain their previous answer and not persist it as a block.
Future<bool?> probeMalArtworkUnreachable({
  Duration timeout = const Duration(seconds: 3),
}) => probeArtworkHost(timeout: timeout);

@visibleForTesting
Future<bool?> probeArtworkHost({
  required Duration timeout,
  Future<List<InternetAddress>> Function(String) lookup =
      InternetAddress.lookup,
  HttpClient Function() createClient = HttpClient.new,
}) async {
  final uri = Uri.parse(_probeUrl);
  HttpClient? client;
  var expired = false;

  Future<bool?> check() async {
    try {
      // Some blocking DNS servers reply immediately with a sinkhole address.
      final addresses = await lookup(uri.host);
      if (expired) return null;
      if (addresses.isEmpty || addresses.every(_isSinkhole)) return true;

      final activeClient = createClient();
      client = activeClient;
      final request = await activeClient.headUrl(uri);
      if (expired) return null;
      await request.close();
      // Response headers prove reachability regardless of status. No need to
      // wait for a response body from a dedicated HEAD request.
      return expired ? null : false;
    } on TimeoutException {
      return null;
    } catch (error) {
      if (expired) return null;
      if (kDebugMode) {
        debugPrint(
          '[Artwork] MyAnimeList CDN unreachable, using AniList: $error',
        );
      }
      return true;
    }
  }

  try {
    // One budget for DNS, opening the connection and receiving headers, not
    // one per phase. DNS itself cannot be cancelled, but a late result cannot
    // open a client or publish an answer.
    return await check().timeout(
      timeout,
      onTimeout: () {
        expired = true;
        return null;
      },
    );
  } finally {
    client?.close(force: true);
  }
}

bool _isSinkhole(InternetAddress address) =>
    address.isLoopback ||
    address.isLinkLocal ||
    address.address == '0.0.0.0' ||
    address.address == '::';
