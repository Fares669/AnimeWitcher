import 'anime_rift_comments.dart';

/// Account artwork is served by Rift, never by AnimeWitcher's user database.
class AnimeRiftAccountProfile {
  const AnimeRiftAccountProfile({this.name, this.avatarUrl, this.coverUrl});

  final String? name;
  final String? avatarUrl;
  final String? coverUrl;

  static String? _text(Object? input) =>
      input is String && input.trim().isNotEmpty ? input.trim() : null;

  static String? _image(Object? input) {
    if (input is Map) {
      input = input['url'] ?? input['image'] ?? input['src'];
    }
    final url = _text(input);
    final parsed = url == null ? null : Uri.tryParse(url);
    return parsed?.scheme == 'https' && parsed!.host.isNotEmpty ? url : null;
  }

  factory AnimeRiftAccountProfile.fromJson(Map<String, dynamic> response) {
    final items = response['items'] ?? response;
    if (items is! Map) {
      throw const FormatException('Invalid Rift account profile');
    }
    final profile = items['profile'] is Map ? items['profile'] as Map : items;
    final user = profile['user'] is Map ? profile['user'] as Map : profile;
    return AnimeRiftAccountProfile(
      name: _text(
        user['userName'] ??
            user['username'] ??
            user['displayName'] ??
            user['name'],
      ),
      avatarUrl: _image(user['avatar']),
      coverUrl: _image(user['cover']),
    );
  }
}

class AnimeRiftMyComment {
  const AnimeRiftMyComment({
    required this.comment,
    required this.isReview,
    this.animeTitle,
    this.animeId,
  });

  final AnimeRiftComment comment;
  final bool isReview;
  final String? animeTitle;
  final String? animeId;

  static AnimeRiftMyComment? fromJson(Object? value) {
    if (value is! Map) return null;
    final comment = AnimeRiftComment.fromJson(value);
    if (comment == null) return null;
    final anime = value['_anime'];
    final id = anime is Map ? anime['_id'] ?? anime['id'] : null;
    final safeId = id is String && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)
        ? id
        : null;
    final title = anime is Map ? anime['title'] ?? anime['name'] : null;
    return AnimeRiftMyComment(
      comment: comment,
      isReview: value['is_review'] == true,
      animeId: safeId,
      animeTitle: title is String && title.trim().isNotEmpty
          ? title.trim()
          : null,
    );
  }
}

class AnimeRiftMyCommentPage {
  const AnimeRiftMyCommentPage({required this.items, required this.hasMore});

  final List<AnimeRiftMyComment> items;
  final bool hasMore;

  factory AnimeRiftMyCommentPage.fromJson(Map<String, dynamic> response) {
    final envelope = response['items'];
    final raw = envelope is List
        ? envelope
        : envelope is Map
        ? envelope['items']
        : null;
    if (raw is! List) {
      throw const FormatException('Invalid Rift comment history');
    }
    final items = <AnimeRiftMyComment>[
      for (final entry in raw)
        if (AnimeRiftMyComment.fromJson(entry) case final comment?) comment,
    ];
    if (raw.isNotEmpty && items.isEmpty) {
      throw const FormatException('Unrecognized Rift comment history');
    }
    return AnimeRiftMyCommentPage(
      items: items,
      hasMore:
          response['hasNext'] == true ||
          (envelope is Map && envelope['hasNext'] == true),
    );
  }
}
