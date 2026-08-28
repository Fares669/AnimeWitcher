import '../domain/entity/multimedia_item.dart';
import '../utils/episode_label.dart';
import '../utils/safe_uri.dart';
import 'firestore_rest_client.dart';

const String animeWitcherNativeProviderId =
    'com.fares669.animewitcher.native';

enum AnimeWitcherCommentSort {
  newest,
  oldest,
  mostLiked;

  String get orderField => this == AnimeWitcherCommentSort.mostLiked ? 'likes' : 'date';

  bool get descending => this != AnimeWitcherCommentSort.oldest;
}

class AnimeWitcherCommentPage {
  const AnimeWitcherCommentPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });

  final List<AnimeWitcherComment> items;
  final FirestoreDocument? cursor;
  final bool hasMore;
}

class AnimeWitcherCommentTarget {
  const AnimeWitcherCommentTarget({
    required this.collectionPath,
    required this.sourceDocumentPath,
    required this.title,
    this.animeId,
    this.episodeId,
    this.episodeName,
    this.newsId,
    this.characterId,
    this.characterName,
  });

  final String collectionPath;
  final String sourceDocumentPath;
  final String title;
  final String? animeId;
  final String? episodeId;
  final String? episodeName;
  final String? newsId;
  final String? characterId;
  final String? characterName;

  Map<String, dynamic> get publishFields => <String, dynamic>{
        if (animeId?.isNotEmpty == true) 'anime_id': animeId,
        if (episodeId?.isNotEmpty == true) 'episode_id': episodeId,
        if (episodeName?.isNotEmpty == true) 'episode_name': episodeName,
        if (newsId?.isNotEmpty == true) 'new_id': newsId,
        if (characterId?.isNotEmpty == true) 'character_id': characterId,
        if (characterName?.isNotEmpty == true) 'character_name': characterName,
      };
}

class AnimeWitcherComment {
  const AnimeWitcherComment({
    required this.id,
    required this.path,
    required this.text,
    required this.userId,
    required this.userName,
    required this.likes,
    required this.replies,
    required this.spoiler,
    this.userPhotoUrl,
    this.date,
    this.animeId,
    this.episodeId,
    this.episodeName,
    this.characterId,
    this.characterName,
    this.newsId,
    this.repliesClosed = false,
    this.likedByMe = false,
  });

  final String id;
  final String path;
  final String text;
  final String userId;
  final String userName;
  final String? userPhotoUrl;
  final int likes;
  final int replies;
  final bool spoiler;
  final DateTime? date;
  final String? animeId;
  final String? episodeId;
  final String? episodeName;
  final String? characterId;
  final String? characterName;
  final String? newsId;
  final bool repliesClosed;
  final bool likedByMe;

  String get repliesCollectionPath => '$path/replies';

  AnimeWitcherComment copyWith({
    String? text,
    int? likes,
    int? replies,
    bool? spoiler,
    bool? likedByMe,
    bool? repliesClosed,
  }) {
    return AnimeWitcherComment(
      id: id,
      path: path,
      text: text ?? this.text,
      userId: userId,
      userName: userName,
      likes: likes ?? this.likes,
      replies: replies ?? this.replies,
      spoiler: spoiler ?? this.spoiler,
      userPhotoUrl: userPhotoUrl,
      date: date,
      animeId: animeId,
      episodeId: episodeId,
      episodeName: episodeName,
      characterId: characterId,
      characterName: characterName,
      newsId: newsId,
      repliesClosed: repliesClosed ?? this.repliesClosed,
      likedByMe: likedByMe ?? this.likedByMe,
    );
  }

  factory AnimeWitcherComment.fromDocument(
    FirestoreDocument document, {
    bool likedByMe = false,
    String? fallbackUserName,
    String? fallbackUserPhotoUrl,
  }) {
    final fields = document.fields;
    final user = _stringMap(fields['user']);
    return AnimeWitcherComment(
      id: document.id,
      path: document.path,
      text: _text(fields['comment']),
      userId: _text(fields['user_id']),
      userName: _firstNonEmpty(<dynamic>[
        user['name'],
        user['user_name'],
        fallbackUserName,
        'AnimeWitcher User',
      ]),
      userPhotoUrl:
          _optionalText(user['pic'] ?? user['pic_uri']) ??
          _optionalText(fallbackUserPhotoUrl),
      likes: _intValue(fields['likes']),
      replies: _intValue(fields['replies']),
      spoiler: fields['spoiler'] == true,
      date: _dateValue(fields['date']),
      animeId: _optionalText(fields['anime_id']),
      episodeId: _optionalText(fields['episode_id']),
      episodeName: _optionalText(fields['episode_name']),
      characterId: _optionalText(fields['character_id']),
      characterName: _optionalText(fields['character_name']),
      newsId: _optionalText(fields['new_id']),
      repliesClosed: fields['replies_closed'] == true,
      likedByMe: likedByMe,
    );
  }
}

bool isAnimeWitcherCommentItem(MultimediaItem item) {
  return item.provider == animeWitcherNativeProviderId ||
      item.url.toLowerCase().contains('animewitcher.com/watch/');
}

AnimeWitcherCommentTarget? animeWitcherAnimeCommentTarget(
  MultimediaItem item,
) {
  final animeId = _animeIdFromItem(item);
  if (animeId.isEmpty) return null;
  final sourcePath = 'anime_list/$animeId';
  return AnimeWitcherCommentTarget(
    collectionPath: '$sourcePath/comments',
    sourceDocumentPath: sourcePath,
    title: item.title,
    animeId: animeId,
  );
}

AnimeWitcherCommentTarget? animeWitcherEpisodeCommentTarget(
  MultimediaItem parent,
  Episode episode,
) {
  var animeId = _animeIdFromItem(parent);
  var episodeId = '';
  final parts = episode.url.split('|');
  if (parts.length >= 2) {
    if (animeId.isEmpty) animeId = _decode(parts.first);
    episodeId = _decode(parts.sublist(1).join('|'));
  }
  if (animeId.isEmpty || episodeId.isEmpty) return null;
  final sourcePath = 'anime_list/$animeId/episodes/$episodeId';
  final episodeName = formatEpisodeLabel(
    episode: episode.episode,
    isArabic: true,
    title: episode.name,
    isFinal: episode.isFinal,
    serverName: episode.serverName,
  );
  return AnimeWitcherCommentTarget(
    collectionPath: '$sourcePath/comments',
    sourceDocumentPath: sourcePath,
    title: '${parent.title} • $episodeName',
    animeId: animeId,
    episodeId: episodeId,
    episodeName: episodeName,
  );
}

AnimeWitcherCommentTarget animeWitcherNewsCommentTarget(NewsItem item) {
  final fallback = 'news/${item.id}';
  final sourcePath = _normalizeDocumentPath(item.docRef) ?? fallback;
  final newsId = sourcePath.split('/').isEmpty
      ? item.id
      : sourcePath.split('/').last;
  return AnimeWitcherCommentTarget(
    collectionPath: '$sourcePath/comments',
    sourceDocumentPath: sourcePath,
    title: item.title,
    newsId: newsId,
  );
}

String _animeIdFromItem(MultimediaItem item) {
  final uri = safeTryParseUri(item.url);
  if (uri != null && uri.pathSegments.isNotEmpty) {
    final value = uri.pathSegments.last.trim();
    if (value.isNotEmpty) return value;
  }
  return '';
}

String? _normalizeDocumentPath(String? raw) {
  var value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  const marker = '/documents/';
  final markerIndex = value.indexOf(marker);
  if (markerIndex >= 0) value = value.substring(markerIndex + marker.length);
  value = value.replaceFirst(RegExp(r'^/+'), '').replaceFirst(RegExp(r'/+$'), '');
  return value.isEmpty ? null : value;
}

String _decode(String value) {
  try {
    return safeDecodeUriComponent(value);
  } catch (_) {
    return value;
  }
}

Map<String, dynamic> _stringMap(dynamic raw) {
  if (raw is! Map) return const <String, dynamic>{};
  return raw.map<String, dynamic>(
    (key, value) => MapEntry(key.toString(), value),
  );
}

String _text(dynamic raw) => raw?.toString().trim() ?? '';

String? _optionalText(dynamic raw) {
  final value = _text(raw);
  return value.isEmpty ? null : value;
}

String _firstNonEmpty(Iterable<dynamic> values) {
  for (final raw in values) {
    final value = _text(raw);
    if (value.isNotEmpty) return value;
  }
  return '';
}

int _intValue(dynamic raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

DateTime? _dateValue(dynamic raw) {
  if (raw is DateTime) return raw.toLocal();
  final parsed = DateTime.tryParse(raw?.toString() ?? '');
  return parsed?.toLocal();
}
