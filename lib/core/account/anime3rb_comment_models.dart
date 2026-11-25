import 'package:html/parser.dart' as html_parser;

import '../domain/entity/multimedia_item.dart';
import '../extensions/providers/anime3rb_provider.dart';

enum Anime3rbCommentSort {
  popular('popular', 'الأكثر إعجابًا'),
  latest('latest', 'الأحدث'),
  oldest('oldest', 'الأقدم');

  const Anime3rbCommentSort(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

class Anime3rbCommentTarget {
  const Anime3rbCommentTarget({
    required this.pageUrl,
    required this.title,
    this.initialTopic,
    this.initialSsoToken,
    this.isEpisode = false,
  });

  final String pageUrl;
  final String title;
  final String? initialTopic;
  final String? initialSsoToken;
  final bool isEpisode;

  static Anime3rbCommentTarget? fromAnime(MultimediaItem item) {
    if (item.provider != Anime3rbProvider.id) return null;
    final link = Anime3rbProvider.parseCatalogLink(item.url);
    if (link == null) return null;
    final sync = item.syncData ?? const <String, String>{};
    return Anime3rbCommentTarget(
      pageUrl: link.work.toString(),
      title: item.title,
      initialTopic: sync['aw3rbComntoTopic'],
      initialSsoToken: sync['aw3rbComntoSso'],
      isEpisode: false,
    );
  }

  static Anime3rbCommentTarget? fromEpisode(
    MultimediaItem parent,
    Episode episode,
  ) {
    if (parent.provider != Anime3rbProvider.id) return null;
    final link = Anime3rbProvider.parseCatalogLink(episode.url);
    final pageUri = link?.watch ?? Uri.tryParse(episode.url.trim());
    if (pageUri == null) return null;
    final epNum = episode.episode ?? 0;
    final label = epNum > 0
        ? '${parent.title} · الحلقة $epNum'
        : parent.title;
    return Anime3rbCommentTarget(
      pageUrl: pageUri.toString(),
      title: label,
      isEpisode: true,
    );
  }
}

class Anime3rbCommentAuthor {
  const Anime3rbCommentAuthor({
    required this.uuid,
    required this.name,
    this.username,
    this.avatarUrl,
    this.isModerator = false,
  });

  final String uuid;
  final String name;
  final String? username;
  final String? avatarUrl;
  final bool isModerator;

  factory Anime3rbCommentAuthor.fromJson(Object? raw) {
    if (raw is! Map) {
      return const Anime3rbCommentAuthor(uuid: '', name: 'مستخدم');
    }
    final map = Map<String, dynamic>.from(raw);
    final name = map['name']?.toString().trim() ?? '';
    final username = map['username']?.toString().trim();
    return Anime3rbCommentAuthor(
      uuid: map['uuid']?.toString().trim() ?? map['id']?.toString().trim() ?? '',
      name: name.isNotEmpty
          ? name
          : (username != null && username.isNotEmpty ? username : 'مستخدم'),
      username: (username != null && username.isNotEmpty) ? username : null,
      avatarUrl: map['avatar_small_url']?.toString().trim().isNotEmpty == true
          ? map['avatar_small_url']?.toString().trim()
          : (map['avatar_url']?.toString().trim().isNotEmpty == true
                ? map['avatar_url']?.toString().trim()
                : null),
      isModerator: map['is_moderator'] == true,
    );
  }
}

class Anime3rbComment {
  const Anime3rbComment({
    required this.uuid,
    required this.author,
    required this.bodyHtml,
    required this.bodyText,
    required this.createdAt,
    this.parentUuid,
    this.repliesCount = 0,
    this.upvotesCount = 0,
    this.downvotesCount = 0,
    this.userVote,
    this.isPinned = false,
    this.isEdited = false,
    this.isDeleted = false,
    this.status,
  });

  final String uuid;
  final Anime3rbCommentAuthor author;
  final String bodyHtml;
  final String bodyText;
  final DateTime? createdAt;
  final String? parentUuid;
  final int repliesCount;
  final int upvotesCount;
  final int downvotesCount;

  /// `1` for upvote, `-1` for downvote, `null` when not voted.
  final int? userVote;
  final bool isPinned;
  final bool isEdited;
  final bool isDeleted;
  final String? status;

  bool isOwnedBy({String? comntoUserUuid, String? userSlug, String? displayName}) {
    if (comntoUserUuid != null &&
        comntoUserUuid.isNotEmpty &&
        author.uuid.isNotEmpty &&
        author.uuid == comntoUserUuid) {
      return true;
    }
    if (userSlug != null &&
        userSlug.isNotEmpty &&
        author.username != null &&
        author.username!.toLowerCase() == userSlug.toLowerCase()) {
      return true;
    }
    return false;
  }

  Anime3rbComment copyWith({
    String? bodyHtml,
    String? bodyText,
    int? repliesCount,
    int? upvotesCount,
    int? downvotesCount,
    int? userVote,
    bool clearUserVote = false,
    bool? isEdited,
    bool? isDeleted,
  }) => Anime3rbComment(
    uuid: uuid,
    author: author,
    bodyHtml: bodyHtml ?? this.bodyHtml,
    bodyText: bodyText ?? this.bodyText,
    createdAt: createdAt,
    parentUuid: parentUuid,
    repliesCount: repliesCount ?? this.repliesCount,
    upvotesCount: upvotesCount ?? this.upvotesCount,
    downvotesCount: downvotesCount ?? this.downvotesCount,
    userVote: clearUserVote ? null : (userVote ?? this.userVote),
    isPinned: isPinned,
    isEdited: isEdited ?? this.isEdited,
    isDeleted: isDeleted ?? this.isDeleted,
    status: status,
  );

  static Anime3rbComment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final uuid = map['uuid']?.toString().trim() ?? '';
    if (uuid.isEmpty) return null;
    final rawHtml = map['body']?.toString() ?? '';
    final isDeleted = map['is_deleted'] == true;
    final parsedText = isDeleted
        ? 'تم حذف هذا التعليق.'
        : comntoHtmlToPlainText(rawHtml);

    int readInt(Object? v) {
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    final votesRaw = map['votes'];
    final votesMap = votesRaw is Map
        ? Map<String, dynamic>.from(votesRaw)
        : const <String, dynamic>{};
    final rawUserVote = votesMap['user_vote'];
    final userVote = rawUserVote is num
        ? rawUserVote.toInt()
        : int.tryParse(rawUserVote?.toString() ?? '');

    final parentRaw = map['parent'];
    String? parentUuid;
    if (parentRaw is String && parentRaw.trim().isNotEmpty) {
      parentUuid = parentRaw.trim();
    } else if (parentRaw is Map) {
      parentUuid = parentRaw['uuid']?.toString().trim();
    }

    return Anime3rbComment(
      uuid: uuid,
      author: Anime3rbCommentAuthor.fromJson(map['user']),
      bodyHtml: rawHtml,
      bodyText: parsedText,
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      parentUuid: parentUuid,
      repliesCount: readInt(map['replies_count']),
      upvotesCount: readInt(votesMap['upvotes_count']),
      downvotesCount: readInt(votesMap['downvotes_count']),
      userVote: (userVote == 1 || userVote == -1) ? userVote : null,
      isPinned: map['is_pinned'] == true,
      isEdited: map['is_edited'] == true,
      isDeleted: isDeleted,
      status: map['status']?.toString(),
    );
  }
}

class Anime3rbCommentPage {
  const Anime3rbCommentPage({
    required this.topic,
    required this.items,
    this.totalCount,
    this.nextCursor,
    this.hasMore = false,
    this.isTopicClosed = false,
    this.viewerUuid,
  });

  final String topic;
  final List<Anime3rbComment> items;
  final int? totalCount;
  final String? nextCursor;
  final bool hasMore;
  final bool isTopicClosed;
  final String? viewerUuid;
}

String comntoHtmlToPlainText(String html) {
  if (html.trim().isEmpty) return '';
  final normalized = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>\s*<p[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'</div>\s*<div[^>]*>', caseSensitive: false), '\n');
  final doc = html_parser.parseFragment(normalized);
  final lines = doc.text
          ?.split('\n')
          .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
          .toList() ??
      const <String>[];
  return lines.join('\n').trim();
}

String plainTextToComntoHtml(String text) {
  final escaped = text
      .trim()
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final paragraphs = escaped
      .split(RegExp(r'\n{2,}'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .map((p) => '<p>${p.replaceAll('\n', '<br>')}</p>')
      .toList();
  return paragraphs.isEmpty ? '<p></p>' : paragraphs.join();
}
