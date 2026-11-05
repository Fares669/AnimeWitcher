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
  });

  final String id;
  final String text;
  final String author;
  final int likes;
  final int replies;
  final bool spoiler;
  final DateTime? createdAt;

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
    );
  }
}

class AnimeRiftCommentPage {
  const AnimeRiftCommentPage({required this.items, required this.hasMore});
  final List<AnimeRiftComment> items;
  final bool hasMore;

  factory AnimeRiftCommentPage.fromJson(Map<String, dynamic> data) {
    final raw = data['items'];
    if (raw is! List) {
      throw const FormatException('Invalid AnimeRift comments response');
    }
    return AnimeRiftCommentPage(
      items: [
        for (final entry in raw)
          if (AnimeRiftComment.fromJson(entry) case final comment?) comment,
      ],
      hasMore: data['hasNext'] == true,
    );
  }
}
