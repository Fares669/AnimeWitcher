import 'firestore_rest_client.dart';

const animeWitcherNotificationPageSize = 20;

bool _safeSegment(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !RegExp(r'[/\\%?#\s]').hasMatch(value);

bool animeWitcherOwnsNotificationPath(String path, String profileId) {
  final parts = path.split('/');
  return _safeSegment(profileId) &&
      parts.length == 4 &&
      parts[0] == 'users' &&
      parts[1] == profileId &&
      parts[2] == 'notifications' &&
      _safeSegment(parts[3]);
}

String? _targetPath(dynamic raw, {required bool review}) {
  if (raw is! String) return null;
  final parts = raw.split('/');
  if (!parts.every(_safeSegment)) return null;
  if (review) {
    return parts.length == 4 &&
            parts[0] == 'anime_list' &&
            parts[2] == 'reviews'
        ? raw
        : null;
  }
  if (parts.length == 4 &&
      const {'anime_list', 'characters_list', 'news'}.contains(parts[0]) &&
      parts[2] == 'comments') {
    return raw;
  }
  if (parts.length == 6 &&
      parts[0] == 'anime_list' &&
      parts[2] == 'episodes' &&
      parts[4] == 'comments') {
    return raw;
  }
  return null;
}

String? animeWitcherNotificationTargetPath(String? path) =>
    _targetPath(path, review: true) ?? _targetPath(path, review: false);

class AnimeWitcherNotificationPage {
  const AnimeWitcherNotificationPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });
  final List<AnimeWitcherNotification> items;
  final FirestoreDocument? cursor;
  final bool hasMore;
}

class AnimeWitcherNotification {
  const AnimeWitcherNotification({
    required this.path,
    required this.type,
    required this.clicked,
    required this.actorName,
    this.actorPhotoUrl,
    this.date,
    this.targetPath,
    this.contextName,
  });

  final String path;
  final String type;
  final bool clicked;
  final String actorName;
  final String? actorPhotoUrl;
  final DateTime? date;
  final String? targetPath;
  final String? contextName;

  String? get actionText {
    for (final prefix in const [
      'review',
      'anime_comment',
      'episode_comment',
      'character_comment',
      'news_comment',
    ]) {
      if (!type.startsWith('${prefix}_')) continue;
      final subject = prefix == 'review' ? 'مراجعتك' : 'تعليقك';
      return switch (type.substring(prefix.length + 1)) {
        'like' => 'أعجب بـ$subject',
        'reply' => 'رد على $subject',
        'reply_like' => 'أعجب بردك',
        'reply_tag' => 'أشار إليك في رد',
        _ => null,
      };
    }
    return null;
  }

  String get message => actionText == null
      ? 'إشعار جديد، يرجى تحديث التطبيق لعرضه'
      : '$actorName $actionText${contextName == null ? '' : ' • $contextName'}';

  AnimeWitcherNotification copyWith({required bool clicked}) =>
      AnimeWitcherNotification(
        path: path,
        type: type,
        clicked: clicked,
        actorName: actorName,
        actorPhotoUrl: actorPhotoUrl,
        date: date,
        targetPath: targetPath,
        contextName: contextName,
      );

  factory AnimeWitcherNotification.fromDocument(FirestoreDocument document) {
    final fields = document.fields;
    final actor = fields['user'] is Map
        ? fields['user'] as Map
        : const <dynamic, dynamic>{};
    String? text(dynamic raw) =>
        raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
    final photo = text(actor['pic']);
    final uri = photo == null ? null : Uri.tryParse(photo);
    final value = AnimeWitcherNotification(
      path: document.path,
      type: text(fields['type']) ?? '',
      clicked: fields['clicked'] == true,
      actorName: text(actor['name']) ?? 'مستخدم',
      actorPhotoUrl:
          uri != null &&
              uri.hasAuthority &&
              (uri.scheme == 'http' || uri.scheme == 'https')
          ? photo
          : null,
      date: fields['date'] is DateTime ? fields['date'] as DateTime : null,
      contextName: text(fields['character_name']) ?? text(fields['anime_name']),
      targetPath: fields['review_doc_ref'] != null
          ? _targetPath(fields['review_doc_ref'], review: true)
          : _targetPath(fields['comment_doc_ref'], review: false),
    );
    if (value.actionText != null) return value;
    return AnimeWitcherNotification(
      path: value.path,
      type: value.type,
      clicked: value.clicked,
      actorName: value.actorName,
      actorPhotoUrl: value.actorPhotoUrl,
      date: value.date,
      contextName: value.contextName,
    );
  }
}
