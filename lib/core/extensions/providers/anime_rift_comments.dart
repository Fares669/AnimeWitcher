import '../../domain/entity/multimedia_item.dart';
import '../../storage/provider_local_library.dart';
import '../../utils/anime_rift_identity.dart';

/// A comment target belongs to Rift only, never to AnimeWitcher Firestore.
class AnimeRiftCommentTarget {
  const AnimeRiftCommentTarget({
    required this.animeId,
    required this.title,
    this.episodeId,
    this.parentId,
  });

  final String animeId;
  final String title;
  final String? episodeId;
  final String? parentId;

  static AnimeRiftCommentTarget? forAnime(MultimediaItem item) {
    if (item.provider != animeRiftProviderId) return null;
    final canonical = canonicalAnimeRiftCatalogUrl(item.url);
    if (canonical == null) return null;
    return AnimeRiftCommentTarget(
      animeId: Uri.parse(canonical).pathSegments.last,
      title: item.title,
    );
  }

  static AnimeRiftCommentTarget? forEpisode(
    MultimediaItem parent,
    Episode episode,
  ) {
    final anime = forAnime(parent);
    final episodeId = animeRiftEpisodeIdForSync(episode.url);
    if (anime == null || episodeId == null) return null;
    final segments = Uri.parse(episode.url).pathSegments;
    if (segments[1] != anime.animeId) return null;
    return AnimeRiftCommentTarget(
      animeId: anime.animeId,
      episodeId: episodeId,
      title: '${parent.title} — ${episode.name}',
    );
  }

  AnimeRiftCommentTarget replies(String id) => AnimeRiftCommentTarget(
    animeId: animeId,
    episodeId: episodeId,
    parentId: id,
    title: title,
  );
}

class AnimeRiftComment {
  const AnimeRiftComment({
    required this.id,
    required this.text,
    required this.author,
    required this.likes,
    required this.replies,
    required this.spoiler,
    this.createdAt,
    this.photoUrl,
  });

  final String id;
  final String text;
  final String author;
  final int likes;
  final int replies;
  final bool spoiler;
  final DateTime? createdAt;
  final String? photoUrl;

  static AnimeRiftComment? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['_id'] ?? value['id'];
    final content = value['comment'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(id) ||
        content is! String ||
        content.trim().isEmpty) {
      return null;
    }
    final user = value['_user'] is Map
        ? value['_user'] as Map
        : value['user'] is Map
        ? value['user'] as Map
        : const <String, dynamic>{};
    final display = user['name'] ?? user['user_name'] ?? user['username'];
    final reactions = value['reactions_counts'];
    final thumbCount = reactions is Map ? reactions['thumbsUp'] : null;
    int count(Object? n) => n is int && n >= 0 ? n : 0;
    final rawDate = value['createdAt'] ?? value['created_at'];
    return AnimeRiftComment(
      id: id,
      text: content.trim(),
      author: display is String && display.trim().isNotEmpty
          ? display.trim()
          : 'مستخدم AnimeRift',
      likes: count(thumbCount ?? value['likes_count']),
      replies: count(value['replies_count'] ?? value['replies']),
      spoiler: value['spoiler'] == true,
      createdAt: rawDate is String ? DateTime.tryParse(rawDate) : null,
      photoUrl: switch (user['avatar'] ??
          user['profile_picture'] ??
          user['picture']) {
        final String value when Uri.tryParse(value)?.scheme == 'https' => value,
        _ => null,
      },
    );
  }
}

class AnimeRiftCommentPage {
  const AnimeRiftCommentPage({
    required this.items,
    required this.hasMore,
    this.serverUserIdPresent,
  });
  final List<AnimeRiftComment> items;
  final bool hasMore;

  /// `userId` is included by /comment/all on the real gateway. Retain only
  /// whether the server supplied an identity, never the user identifier.
  final bool? serverUserIdPresent;

  factory AnimeRiftCommentPage.fromJson(Map<String, dynamic> data) {
    final envelope = data['items'];
    final raw = envelope is List
        ? envelope
        : envelope is Map
        ? envelope['items']
        : null;
    if (raw is! List) {
      throw const FormatException('Invalid AnimeRift comments response');
    }
    final comments = <AnimeRiftComment>[
      for (final entry in raw)
        if (AnimeRiftComment.fromJson(entry) case final comment?) comment,
    ];
    // A nonempty server page must not turn into a false 'no comments' state
    // just because the server model changed and our parser rejected every row.
    if (raw.isNotEmpty && comments.isEmpty) {
      throw const FormatException('Unrecognized AnimeRift comment items');
    }
    return AnimeRiftCommentPage(
      items: comments,
      serverUserIdPresent: data.containsKey('userId')
          ? data['userId'] != null && data['userId'] != ''
          : null,
      hasMore:
          data['hasNext'] == true ||
          (envelope is Map && envelope['hasNext'] == true),
    );
  }
}
