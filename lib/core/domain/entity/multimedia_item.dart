import 'package:html_unescape/html_unescape.dart';
import 'package:collection/collection.dart';

enum MultimediaContentType { movie, series, anime, livestream, other }

enum ShowStatus { completed, ongoing, upcoming }

enum DubStatus { none, dubbed, subbed }

class Actor {
  final String name;
  final String? image;
  final String? role;
  final Actor? voiceActor;
  final String? id;
  final int likes;

  Actor({
    required this.name,
    this.image,
    this.role,
    this.voiceActor,
    this.id,
    this.likes = 0,
  });

  factory Actor.fromJson(Map<String, dynamic> json) {
    return Actor(
      name: (json['name'] as String?) ?? '',
      image: json['image'] as String?,
      role: (json['role'] as String?) ?? (json['roleString'] as String?),
      voiceActor: json['voiceActor'] != null
          ? Actor.fromJson(Map<String, dynamic>.from(json['voiceActor'] as Map))
          : null,
      id: (json['id'] as String?) ?? (json['characterId'] as String?),
      likes: (json['likes'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'image': image,
      'role': role,
      'voiceActor': voiceActor?.toJson(),
      'id': id,
      'likes': likes,
    };
  }
}

/// First page of franchise-related titles from `related_anime_ids`.
class RelatedAnimePage {
  const RelatedAnimePage({
    required this.items,
    this.hasMore = false,
  });

  final List<MultimediaItem> items;
  final bool hasMore;
}

class Trailer {
  final String url;
  final Map<String, String>? headers;

  Trailer({required this.url, this.headers});

  factory Trailer.fromJson(Map<String, dynamic> json) {
    return Trailer(
      url: (json['url'] as String?) ?? (json['extractorUrl'] as String?) ?? '',
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {'url': url, 'headers': headers};
  }
}

class NextAiring {
  final int episode;
  final int unixTime;
  final int? season;

  NextAiring({required this.episode, required this.unixTime, this.season});

  factory NextAiring.fromJson(Map<String, dynamic> json) {
    return NextAiring(
      episode: (json['episode'] as int?) ?? 0,
      unixTime: (json['unixTime'] as int?) ?? 0,
      season: json['season'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {'episode': episode, 'unixTime': unixTime, 'season': season};
  }
}

class MultimediaItem {
  static final _unescape = HtmlUnescape();
  final String title;
  final String url;
  final String posterUrl;

  /// Largest available poster, used by the zoom viewer even when catalog
  /// cards keep the lighter standard artwork.
  final String? fullPosterUrl;
  final String? bannerUrl;
  final String? logoUrl;
  final String? description;
  final MultimediaContentType contentType;
  final List<Episode>? episodes;
  final String? provider;
  final Map<String, String>? headers;

  // New parity fields
  final int? year;
  final double? score;
  final int? duration;
  final ShowStatus status;
  final List<String>? tags;
  final String? contentRating;
  final List<Actor>? cast;
  final List<Trailer>? trailers;
  final List<MultimediaItem>? recommendations;

  /// Entries that belong to the same franchise.
  ///
  /// This is independent from [recommendations], which contains
  /// similar titles.
  final List<MultimediaItem>? related;

  /// Text shown on a related title poster badge.
  ///
  /// Examples: Previous, Next, Movie, OVA, Side Story.
  final String? relationLabel;

  /// Optional machine-readable relationship value.
  ///
  /// Examples: PREQUEL, SEQUEL, SIDE_STORY, SPIN_OFF.
  final String? relationType;
  final Map<String, String>? syncData;
  final String? playbackPolicy;
  final bool isAdult;
  final NextAiring? nextAiring;
  final List<StreamResult>? streams;

  final int? tmdbId;
  final String? imdbId;
  final String? source;

  /// Provider-defined text displayed over a media poster.
  ///
  /// AnimeWitcher renders this value unchanged. The extension decides
  /// the language and format.
  final String? episodeBadge;

  /// Catalog type as the server sent it (`مسلسل`, `فيلم`, `خاصة`, `اونا`).
  final String? catalogType;

  /// When a latest-episode row was published, for "منذ ساعتين" captions.
  final DateTime? publishedAt;

  /// True when the catalog marks this title as a dubbed version.
  final bool isDubbed;

  MultimediaItem({
    required this.title,
    required this.url,
    required this.posterUrl,
    this.fullPosterUrl,
    this.bannerUrl,
    this.logoUrl,
    this.description,
    this.contentType = MultimediaContentType.movie,
    List<Episode>? episodes,
    this.provider,
    this.headers,
    this.year,
    this.score,
    this.duration,
    this.status = ShowStatus.ongoing,
    this.tags,
    this.contentRating,
    this.cast,
    this.trailers,
    this.recommendations,
    this.related,
    this.relationLabel,
    this.relationType,
    this.syncData,
    this.playbackPolicy,
    this.isAdult = false,
    this.nextAiring,
    this.streams,
    this.tmdbId,
    this.imdbId,
    this.source,
    this.episodeBadge,
    this.catalogType,
    this.publishedAt,
    this.isDubbed = false,
  }) : episodes = episodes != null
           ? (List<Episode>.from(episodes)..sort((a, b) {
               if (a.season != b.season) return a.season.compareTo(b.season);
               return a.episode.compareTo(b.episode);
             }))
           : null;

  static List<MultimediaItem>? _parseItemList(dynamic raw) {
    if (raw is! List) return null;

    final items = <MultimediaItem>[];
    for (final value in raw) {
      if (value is! Map) continue;

      try {
        items.add(MultimediaItem.fromJson(Map<String, dynamic>.from(value)));
      } catch (_) {
        // One malformed related/recommendation item must not make the
        // whole details page fail.
      }
    }

    return items.isEmpty ? null : items;
  }

  static String? _parseOptionalString(dynamic raw) {
    if (raw == null || raw is Map || raw is List) return null;

    final value = raw.toString().trim();
    return value.isEmpty ? null : value;
  }

  factory MultimediaItem.fromJson(Map<String, dynamic> json) {
    final title = json['title'] != null
        ? _unescape.convert(json['title'] as String)
        : '';

    final String? typeStr =
        (json['type'] as String?) ?? (json['contentType'] as String?);
    final MultimediaContentType type = MultimediaItem.parseContentType(typeStr);

    return MultimediaItem(
      title: title,
      url: (json['url'] as String?) ?? '',
      posterUrl: (json['posterUrl'] as String?) ?? '',
      fullPosterUrl: _parseOptionalString(
        json['fullPosterUrl'] ??
            json['full_poster_url'] ??
            json['originalPosterUrl'],
      ),
      bannerUrl:
          (json['backgroundPosterUrl'] as String?) ??
          (json['bannerUrl'] as String?),
      logoUrl: json['logoUrl'] as String?,
      description: json['description'] != null
          ? _unescape.convert(json['description'] as String)
          : null,
      contentType: type,
      episodes: json['episodes'] != null
          ? (json['episodes'] as List)
                .map<Episode>(
                  (e) => Episode.fromJson(Map<String, dynamic>.from(e as Map)),
                )
                .toList()
          : null,
      streams: json['streams'] != null
          ? (json['streams'] as List)
                .map<StreamResult>(
                  (s) => StreamResult.fromJson(
                    Map<String, dynamic>.from(s as Map),
                  ),
                )
                .toList()
          : null,
      provider: json['provider'] as String?,
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      year: json['year'] as int?,
      score: (json['score'] as num?)?.toDouble(),
      duration: json['duration'] as int?,
      status: _parseShowStatus(json['status'] ?? json['showStatus']),
      tags: json['tags'] != null
          ? List<String>.from(json['tags'] as List)
          : null,
      cast: json['cast'] != null || json['actors'] != null
          ? ((json['cast'] ?? json['actors']) as List)
                .map<Actor>(
                  (a) => Actor.fromJson(Map<String, dynamic>.from(a as Map)),
                )
                .toList()
          : null,
      trailers: json['trailers'] != null
          ? (json['trailers'] as List)
                .map<Trailer>(
                  (t) => Trailer.fromJson(Map<String, dynamic>.from(t as Map)),
                )
                .toList()
          : null,

      recommendations: _parseItemList(json['recommendations']),
      related: _parseItemList(json['related'] ?? json['relations']),
      relationLabel: _parseOptionalString(
        json['relationLabel'] ??
            json['relation_label'] ??
            json['relationBadge'] ??
            json['relation_badge'] ??
            json['relation'],
      ),
      relationType: _parseOptionalString(
        json['relationType'] ?? json['relation_type'],
      ),
      syncData: json['syncData'] != null
          ? Map<String, String>.from(json['syncData'] as Map)
          : null,
      playbackPolicy:
          (json['playbackPolicy'] as String?) ?? (json['vpnStatus'] as String?),
      isAdult: (json['isAdult'] as bool?) ?? false,
      nextAiring: json['nextAiring'] != null
          ? NextAiring.fromJson(
              Map<String, dynamic>.from(json['nextAiring'] as Map),
            )
          : null,
      tmdbId: json['tmdbId'] as int?,
      imdbId: json['imdbId'] as String?,
      source: json['source'] as String?,
      episodeBadge: _parseOptionalString(
        json['episodeBadge'] ??
            json['episode_badge'] ??
            json['badgeText'] ??
            json['badge_text'],
      ),
      catalogType: _catalogTypeFromJson(json, typeStr),
      publishedAt: _parseDateTime(
        json['publishedAt'] ?? json['published_at'] ?? json['date'],
      ),
      isDubbed:
          json['isDubbed'] == true ||
          json['dubbed'] == true ||
          json['is_dubbed'] == true,
    );
  }

  static String? _catalogTypeFromJson(
    Map<String, dynamic> json,
    String? typeStr,
  ) {
    final explicit = _parseOptionalString(
      json['catalogType'] ?? json['catalog_type'],
    );
    if (explicit != null) return explicit;
    if (typeStr == null || typeStr.trim().isEmpty) return null;
    const enumNames = <String>{
      'movie',
      'series',
      'tvseries',
      'tv',
      'anime',
      'livestream',
      'live',
      'iptv',
      'other',
    };
    if (enumNames.contains(typeStr.trim().toLowerCase())) return null;
    return typeStr.trim();
  }

  static DateTime? _parseDateTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    final number = raw is num ? raw.toInt() : int.tryParse(raw.toString());
    if (number != null) {
      final timestamp = number.abs() < 100000000000 ? number * 1000 : number;
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    return DateTime.tryParse(raw.toString());
  }

  static ShowStatus _parseShowStatus(dynamic raw) {
    if (raw == null) return ShowStatus.ongoing;
    final str = raw.toString().toLowerCase();
    if (str.contains('completed')) return ShowStatus.completed;
    if (str.contains('upcoming') || str.contains('soon')) {
      return ShowStatus.upcoming;
    }
    return ShowStatus.ongoing;
  }

  static MultimediaContentType parseContentType(String? raw) {
    if (raw == null) return MultimediaContentType.movie;
    final value = raw.trim().toLowerCase();
    switch (value) {
      case 'movie':
      case 'film':
        return MultimediaContentType.movie;
      case 'series':
      case 'tvseries':
      case 'tv':
        return MultimediaContentType.series;
      case 'anime':
        return MultimediaContentType.anime;
      case 'livestream':
      case 'live':
      case 'iptv':
        return MultimediaContentType.livestream;
      default:
        if (value.contains('فيلم') || value.contains('فلم')) {
          return MultimediaContentType.movie;
        }
        if (value.contains('بث') || value.contains('live')) {
          return MultimediaContentType.livestream;
        }
        if (value.contains('مسلسل') ||
            value.contains('انمي') ||
            value.contains('أنمي') ||
            value.contains('اونا') ||
            value.contains('اوفا') ||
            value.contains('خاصة') ||
            value.contains('ova') ||
            value.contains('ona') ||
            value.contains('special')) {
          return MultimediaContentType.anime;
        }
        return MultimediaContentType.other;
    }
  }

  // Compatibility getters for TmdbItem migration
  int get id => tmdbId ?? 0;
  String get mediaType {
    return contentType.name.toUpperCase();
  }

  String get tmdbMediaType =>
      contentType == MultimediaContentType.series ? 'tv' : 'movie';

  String get backdropImageUrl {
    final normalizedBanner = bannerUrl?.trim();
    return normalizedBanner == null || normalizedBanner.isEmpty
        ? posterUrl
        : normalizedBanner;
  }

  String get posterImageUrl => posterUrl;
  String get thumbnailImageUrl => posterUrl;

  /// Poster loaded by the fullscreen zoom viewer.
  ///
  /// Prefers [fullPosterUrl] so tapping a poster still requests the largest
  /// artwork when the high-quality catalog setting is off.
  String get posterViewerUrl {
    final full = fullPosterUrl?.trim();
    if (full != null && full.isNotEmpty) return full;
    return posterUrl;
  }

  String get releaseDate => year?.toString() ?? '';
  String get overview => description ?? '';
  double get voteAverage => score ?? 0.0;
  String get genresStr => tags?.join(' | ') ?? '';

  MultimediaItem copyWith({
    String? title,
    String? url,
    String? posterUrl,
    String? fullPosterUrl,
    String? bannerUrl,
    String? logoUrl,
    String? description,
    MultimediaContentType? contentType,
    List<Episode>? episodes,
    String? provider,
    Map<String, String>? headers,
    int? year,
    double? score,
    int? duration,
    ShowStatus? status,
    List<String>? tags,
    String? contentRating,
    List<Actor>? cast,
    List<Trailer>? trailers,
    List<MultimediaItem>? recommendations,
    List<MultimediaItem>? related,
    String? relationLabel,
    String? relationType,
    Map<String, String>? syncData,
    String? playbackPolicy,
    bool? isAdult,
    NextAiring? nextAiring,
    List<StreamResult>? streams,
    int? tmdbId,
    String? imdbId,
    String? source,
    String? episodeBadge,
    String? catalogType,
    DateTime? publishedAt,
    bool? isDubbed,
  }) {
    return MultimediaItem(
      title: title ?? this.title,
      url: url ?? this.url,
      posterUrl: posterUrl ?? this.posterUrl,
      fullPosterUrl: fullPosterUrl ?? this.fullPosterUrl,
      bannerUrl: bannerUrl ?? this.bannerUrl,
      logoUrl: logoUrl ?? this.logoUrl,
      description: description ?? this.description,
      contentType: contentType ?? this.contentType,
      episodes: episodes ?? this.episodes,
      provider: provider ?? this.provider,
      headers: headers ?? this.headers,
      year: year ?? this.year,
      score: score ?? this.score,
      duration: duration ?? this.duration,
      status: status ?? this.status,
      tags: tags ?? this.tags,
      contentRating: contentRating ?? this.contentRating,
      cast: cast ?? this.cast,
      trailers: trailers ?? this.trailers,
      recommendations: recommendations ?? this.recommendations,
      related: related ?? this.related,
      relationLabel: relationLabel ?? this.relationLabel,
      relationType: relationType ?? this.relationType,
      syncData: syncData ?? this.syncData,
      playbackPolicy: playbackPolicy ?? this.playbackPolicy,
      isAdult: isAdult ?? this.isAdult,
      nextAiring: nextAiring ?? this.nextAiring,
      streams: streams ?? this.streams,
      tmdbId: tmdbId ?? this.tmdbId,
      imdbId: imdbId ?? this.imdbId,
      source: source ?? this.source,
      episodeBadge: episodeBadge ?? this.episodeBadge,
      catalogType: catalogType ?? this.catalogType,
      publishedAt: publishedAt ?? this.publishedAt,
      isDubbed: isDubbed ?? this.isDubbed,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
      'posterUrl': posterUrl,
      'fullPosterUrl': fullPosterUrl,
      'bannerUrl': bannerUrl,
      'logoUrl': logoUrl,
      'description': description,
      'type': contentType.name,
      'episodes': episodes?.map((e) => e.toJson()).toList(),
      'provider': provider,
      'headers': headers,
      'year': year,
      'score': score,
      'duration': duration,
      'status': status.name,
      'tags': tags,
      'contentRating': contentRating,
      'cast': cast?.map((a) => a.toJson()).toList(),
      'trailers': trailers?.map((t) => t.toJson()).toList(),
      'recommendations': recommendations?.map((r) => r.toJson()).toList(),
      'related': related?.map((r) => r.toJson()).toList(),
      'relationLabel': relationLabel,
      'relationType': relationType,
      'syncData': syncData,
      'playbackPolicy': playbackPolicy,
      'isAdult': isAdult,
      'nextAiring': nextAiring?.toJson(),
      'tmdbId': tmdbId,
      'imdbId': imdbId,
      'streams': streams?.map((s) => s.toJson()).toList(),
      'source': source,
      'episodeBadge': episodeBadge,
      'catalogType': catalogType,
      'publishedAt': publishedAt?.millisecondsSinceEpoch,
      'isDubbed': isDubbed,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MultimediaItem &&
          runtimeType == other.runtimeType &&
          url == other.url &&
          title == other.title &&
          posterUrl == other.posterUrl &&
          provider == other.provider &&
          tmdbId == other.tmdbId &&
          imdbId == other.imdbId &&
          episodeBadge == other.episodeBadge &&
          const MapEquality<String, String>().equals(syncData, other.syncData);

  @override
  int get hashCode =>
      url.hashCode ^
      title.hashCode ^
      posterUrl.hashCode ^
      (provider?.hashCode ?? 0) ^
      (tmdbId?.hashCode ?? 0) ^
      (imdbId?.hashCode ?? 0) ^
      (episodeBadge?.hashCode ?? 0) ^
      const MapEquality<String, String>().hash(syncData);
}

class Episode {
  static final _unescape = HtmlUnescape();
  final String name;
  final String url;
  final int season;
  final int episode;
  final String? description;
  final String? posterUrl;
  final Map<String, String>? headers;

  /// Whether the provider marked this episode as filler.
  final bool isFiller;

  /// Whether the provider marked this as the final episode
  /// (e.g. server name "الحلقة 12 والأخيرة").
  final bool isFinal;

  /// Raw AnimeWitcher `name` field (e.g. "الحلقة 12 والأخيرة", "مترجم").
  /// Used for the primary list label and must survive AniZip image enrichment.
  final String serverName;

  // Parity fields
  final double? rating;
  final int? runtime;
  final String? airDate;
  final DubStatus dubStatus;
  final String? playbackPolicy;
  final List<StreamResult>? streams;

  Episode({
    required this.name,
    required this.url,
    this.season = 0,
    this.episode = 0,
    this.description,
    this.posterUrl,
    this.headers,
    this.isFiller = false,
    this.isFinal = false,
    this.serverName = '',
    this.rating,
    this.runtime,
    this.airDate,
    this.dubStatus = DubStatus.none,
    this.playbackPolicy,
    this.streams,
  });

  Episode copyWith({
    String? name,
    String? url,
    int? season,
    int? episode,
    String? description,
    String? posterUrl,
    Map<String, String>? headers,
    bool? isFiller,
    bool? isFinal,
    String? serverName,
    double? rating,
    int? runtime,
    String? airDate,
    DubStatus? dubStatus,
    String? playbackPolicy,
    List<StreamResult>? streams,
  }) {
    return Episode(
      name: name ?? this.name,
      url: url ?? this.url,
      season: season ?? this.season,
      episode: episode ?? this.episode,
      description: description ?? this.description,
      posterUrl: posterUrl ?? this.posterUrl,
      headers: headers ?? this.headers,
      isFiller: isFiller ?? this.isFiller,
      isFinal: isFinal ?? this.isFinal,
      serverName: serverName ?? this.serverName,
      rating: rating ?? this.rating,
      runtime: runtime ?? this.runtime,
      airDate: airDate ?? this.airDate,
      dubStatus: dubStatus ?? this.dubStatus,
      playbackPolicy: playbackPolicy ?? this.playbackPolicy,
      streams: streams ?? this.streams,
    );
  }

  factory Episode.fromJson(Map<String, dynamic> json) {
    final name = json['name'] != null
        ? _unescape.convert(json['name'] as String)
        : '';
    final serverName = json['serverName'] != null
        ? _unescape.convert(json['serverName'] as String)
        : '';
    return Episode(
      name: name,
      url: (json['url'] as String?) ?? '',
      season: (json['season'] as int?) ?? 0,
      episode: (json['episode'] as int?) ?? 0,
      description: json['description'] != null
          ? _unescape.convert(json['description'] as String)
          : null,
      posterUrl: json['posterUrl'] as String?,
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      isFiller: _parseBoolean(
        json['isFiller'] ?? json['is_filler'] ?? json['filler'],
      ),
      isFinal: _parseBoolean(
        json['isFinal'] ?? json['is_final'] ?? json['final'],
      ),
      serverName: serverName,
      rating: (json['rating'] as num?)?.toDouble(),
      runtime: (json['runtime'] as int?) ?? (json['duration'] as int?),
      airDate: json['airDate'] as String?,
      dubStatus: _parseDubStatus(
        json['dubStatus'],
        name.isNotEmpty ? name : serverName,
      ),
      playbackPolicy:
          (json['playbackPolicy'] as String?) ?? (json['vpnStatus'] as String?),
      streams: json['streams'] != null
          ? (json['streams'] as List)
                .map<StreamResult>(
                  (s) => StreamResult.fromJson(
                    Map<String, dynamic>.from(s as Map),
                  ),
                )
                .toList()
          : null,
    );
  }

  static bool _parseBoolean(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;

    final value = raw?.toString().trim().toLowerCase();
    return value == 'true' ||
        value == '1' ||
        value == 'yes' ||
        value == 'filler' ||
        value == 'فلر';
  }

  static DubStatus _parseDubStatus(dynamic raw, [String? name]) {
    if (raw != null) {
      final str = raw.toString().toLowerCase();
      if (str.contains('dub') || str.contains('مدبلج')) return DubStatus.dubbed;
      if (str.contains('sub') || str.contains('مترجم')) return DubStatus.subbed;
    }

    if (name != null) {
      final lowerName = name.toLowerCase().trim();
      if (lowerName.contains('dub') ||
          lowerName == 'مدبلج' ||
          lowerName == 'مدبلجة') {
        return DubStatus.dubbed;
      }
      if (lowerName.contains('sub') ||
          lowerName == 'مترجم' ||
          lowerName == 'مترجمة') {
        return DubStatus.subbed;
      }
    }

    return DubStatus.none;
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'season': season,
      'episode': episode,
      'description': description,
      'posterUrl': posterUrl,
      'headers': headers,
      'isFiller': isFiller,
      'isFinal': isFinal,
      'serverName': serverName,
      'rating': rating,
      'runtime': runtime,
      'airDate': airDate,
      'dubStatus': dubStatus.name,
      'playbackPolicy': playbackPolicy,
      'streams': streams?.map((s) => s.toJson()).toList(),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Episode &&
          runtimeType == other.runtimeType &&
          url == other.url &&
          season == other.season &&
          episode == other.episode;

  @override
  int get hashCode => url.hashCode ^ season.hashCode ^ episode.hashCode;
}

class StreamResult {
  final String url;
  final String source;
  final String? quality;
  final bool requiresResolution;
  final Map<String, String>? headers;
  final List<SubtitleFile>? subtitles;
  final String? drmKid;
  final String? drmKey;
  final String? licenseUrl;

  /// Opaque provider URL that [AnimeWitcherProvider.loadStreams] can extract
  /// again — used to mint a fresh signed CDN link after a long pause or a
  /// mid-playback 403. AnimeWitcher stores `animewitcher-source://…` here.
  final String? refreshUrl;

  const StreamResult({
    required this.url,
    required this.source,
    this.quality,
    this.requiresResolution = false,
    this.headers,
    this.subtitles,
    this.drmKid,
    this.drmKey,
    this.licenseUrl,
    this.refreshUrl,
  });

  StreamResult copyWith({
    String? url,
    String? source,
    String? quality,
    bool? requiresResolution,
    Map<String, String>? headers,
    List<SubtitleFile>? subtitles,
    String? drmKid,
    String? drmKey,
    String? licenseUrl,
    String? refreshUrl,
  }) {
    return StreamResult(
      url: url ?? this.url,
      source: source ?? this.source,
      quality: quality ?? this.quality,
      requiresResolution: requiresResolution ?? this.requiresResolution,
      headers: headers ?? this.headers,
      subtitles: subtitles ?? this.subtitles,
      drmKid: drmKid ?? this.drmKid,
      drmKey: drmKey ?? this.drmKey,
      licenseUrl: licenseUrl ?? this.licenseUrl,
      refreshUrl: refreshUrl ?? this.refreshUrl,
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'source': source,
    'quality': quality,
    'requiresResolution': requiresResolution,
    'headers': headers,
    'subtitles': subtitles?.map((x) => x.toJson()).toList(),
    'drmKid': drmKid,
    'drmKey': drmKey,
    'licenseUrl': licenseUrl,
    'refreshUrl': refreshUrl,
  };

  factory StreamResult.fromJson(Map<String, dynamic> json) {
    return StreamResult(
      url: (json['url'] as String?) ?? '',
      source: (json['source'] as String?) ?? 'Unknown',
      quality: json['quality'] as String?,
      requiresResolution: json['requiresResolution'] == true,
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      subtitles: json['subtitles'] != null
          ? (json['subtitles'] as List)
                .map(
                  (x) => SubtitleFile.fromJson(
                    Map<String, dynamic>.from(x as Map),
                  ),
                )
                .toList()
          : null,
      drmKid: json['drmKid'] as String?,
      drmKey: json['drmKey'] as String?,
      licenseUrl: json['licenseUrl'] as String?,
      refreshUrl: json['refreshUrl'] as String?,
    );
  }
}

class SubtitleFile {
  final String url;
  final String label;
  final String? lang;

  SubtitleFile({required this.url, required this.label, this.lang});

  Map<String, dynamic> toJson() => {'url': url, 'label': label, 'lang': lang};

  factory SubtitleFile.fromJson(Map<String, dynamic> json) {
    return SubtitleFile(
      url: (json['url'] as String?) ?? '',
      label: (json['label'] as String?) ?? 'Unknown',
      lang: json['lang'] as String?,
    );
  }
}

/// A news article shown in the provider home feed or news list.
///
/// News is intentionally separate from [MultimediaItem] because AnimeWitcher's
/// article cards have a different layout and navigation model from anime cards.
class NewsItem {
  const NewsItem({
    required this.id,
    required this.title,
    required this.imageUrl,
    this.newsUrl,
    this.animeId,
    this.docRef,
    this.publishedAt,
  });

  final String id;
  final String title;
  final String imageUrl;
  final String? newsUrl;
  final String? animeId;
  final String? docRef;
  final DateTime? publishedAt;

  bool get hasAnimeLink => animeId?.trim().isNotEmpty == true;
}
