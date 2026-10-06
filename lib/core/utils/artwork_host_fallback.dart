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
const String _probeUrl =
    'https://cdn.myanimelist.net/images/favicon.ico';

/// How long a probe result is trusted before checking again. Long enough to
/// cost nothing, short enough that the app recovers when a block lifts.
const Duration probeTtl = Duration(hours: 6);

/// Publishes a stored probe result immediately, so the first frame already
/// picks the right artwork instead of waiting for the network.
void seedMalArtworkReachability(bool unreachable) {
  malArtworkUnreachable.value = unreachable;
}

/// Checks whether the MyAnimeList CDN responds, and returns the result so the
/// caller can persist it. Deliberately short-timeout: a poster that resolves
/// late is a poster the viewer already saw fail.
Future<bool> probeMalArtworkUnreachable({
  Duration timeout = const Duration(seconds: 3),
}) async {
  // A blocking network usually answers the name with a sinkhole address
  // (0.0.0.0), which is known at once; a request to it would only hang.
  try {
    final addresses = await InternetAddress.lookup(Uri.parse(_probeUrl).host)
        .timeout(timeout);
    if (addresses.isEmpty || addresses.every(_isSinkhole)) return true;
  } catch (_) {
    return true;
  }
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = timeout;
    final request = await client
        .headUrl(Uri.parse(_probeUrl))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>();
    // Any answer at all means the host is reachable; the status itself does
    // not matter, only that something responded.
    return false;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[Artwork] MyAnimeList CDN unreachable, using AniList: $e');
    }
    return true;
  } finally {
    client?.close(force: true);
  }
}

bool _isSinkhole(InternetAddress address) =>
    address.isLoopback ||
    address.isLinkLocal ||
    address.address == '0.0.0.0' ||
    address.address == '::';
