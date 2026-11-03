/// Only stable catalog selectors are placed in picker/history/refresh URLs.
class AnimeRiftSourceIdentity {
  const AnimeRiftSourceIdentity(
    this.anime,
    this.episode, {
    this.number,
    this.host,
    this.quality,
    this.download = false,
  });
  final String anime, episode;
  final int? number;
  final String? host, quality;
  final bool download;
  static final _id = RegExp(r'^[A-Za-z0-9_-]+$');
  static bool isValidId(String value) => _id.hasMatch(value);
  String get episodeUrl =>
      'https://anime-rift.com/anime/$anime/episode/$episode';
  String get sourceUrl =>
      '$episodeUrl/source/$host/quality/${quality ?? '_default'}/${download ? 'download' : 'play'}/n/$number';
  static AnimeRiftSourceIdentity? parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !const {'anime-rift.com', 'www.anime-rift.com'}.contains(uri.host) ||
        uri.hasQuery ||
        uri.hasFragment)
      return null;
    final p = uri.pathSegments;
    if ((p.length != 4 && p.length != 11) ||
        p[0] != 'anime' ||
        p[2] != 'episode' ||
        !_id.hasMatch(p[1]) ||
        !_id.hasMatch(p[3]))
      return null;
    if (p.length == 4) return AnimeRiftSourceIdentity(p[1], p[3]);
    if (p[4] != 'source' ||
        p[6] != 'quality' ||
        p[9] != 'n' ||
        !_id.hasMatch(p[5]) ||
        !_id.hasMatch(p[7]) ||
        !const {'play', 'download'}.contains(p[8]))
      return null;
    final number = int.tryParse(p[10]);
    if (number == null || number < 0) return null;
    return AnimeRiftSourceIdentity(
      p[1],
      p[3],
      number: number,
      host: p[5],
      quality: p[7] == '_default' ? null : p[7],
      download: p[8] == 'download',
    );
  }
}
