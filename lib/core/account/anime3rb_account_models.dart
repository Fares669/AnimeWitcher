import 'dart:convert';

import '../storage/library_category.dart';

enum Anime3rbAuthAction { signIn, register, forgotPassword }

class Anime3rbListCounts {
  const Anime3rbListCounts({
    this.watching = 0,
    this.completed = 0,
    this.onHold = 0,
    this.dropped = 0,
    this.planToWatch = 0,
    this.ratings = 0,
  });

  final int watching;
  final int completed;
  final int onHold;
  final int dropped;
  final int planToWatch;
  final int ratings;

  int? countFor(LibraryCategory category) => switch (category) {
    LibraryCategory.watching => watching,
    LibraryCategory.completed => completed,
    LibraryCategory.continueLater => onHold,
    LibraryCategory.notInterested => dropped,
    LibraryCategory.planToWatch => planToWatch,
    LibraryCategory.favorite => null,
  };

  Anime3rbListCounts copyWith({
    int? watching,
    int? completed,
    int? onHold,
    int? dropped,
    int? planToWatch,
    int? ratings,
  }) => Anime3rbListCounts(
    watching: watching ?? this.watching,
    completed: completed ?? this.completed,
    onHold: onHold ?? this.onHold,
    dropped: dropped ?? this.dropped,
    planToWatch: planToWatch ?? this.planToWatch,
    ratings: ratings ?? this.ratings,
  );

  Map<String, Object?> toJson() => {
    'watching': watching,
    'completed': completed,
    'onHold': onHold,
    'dropped': dropped,
    'planToWatch': planToWatch,
    'ratings': ratings,
  };

  factory Anime3rbListCounts.fromJson(Map<String, dynamic> json) {
    int readInt(String key) {
      final raw = json[key];
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '') ?? 0;
    }

    return Anime3rbListCounts(
      watching: readInt('watching'),
      completed: readInt('completed'),
      onHold: readInt('onHold'),
      dropped: readInt('dropped'),
      planToWatch: readInt('planToWatch'),
      ratings: readInt('ratings'),
    );
  }
}

class Anime3rbWatchingProgress {
  const Anime3rbWatchingProgress({
    required this.slug,
    required this.episodeNumber,
    required this.timeSeconds,
    this.progressPercent = 0,
    this.updatedAtMillis = 0,
  });

  final String slug;
  final int episodeNumber;
  final double timeSeconds;
  final double progressPercent;
  final int updatedAtMillis;

  Map<String, Object?> toCookieJson() => <String, Object?>{
    'video': episodeNumber,
    'time': timeSeconds,
    'progress': progressPercent,
    'updated_at': updatedAtMillis,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'slug': slug,
    'video': episodeNumber,
    'time': timeSeconds,
    'progress': progressPercent,
    'updated_at': updatedAtMillis,
  };

  static Anime3rbWatchingProgress? fromJson(
    String slug,
    Object? raw,
  ) {
    if (slug.trim().isEmpty || raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final video = (map['video'] is num)
        ? (map['video'] as num).toInt()
        : int.tryParse(map['video']?.toString() ?? '');
    if (video == null || video <= 0) return null;
    final time = (map['time'] is num)
        ? (map['time'] as num).toDouble()
        : double.tryParse(map['time']?.toString() ?? '') ?? 0;
    final progress = (map['progress'] is num)
        ? (map['progress'] as num).toDouble()
        : double.tryParse(map['progress']?.toString() ?? '') ?? 0;
    final updatedAt = (map['updated_at'] is num)
        ? (map['updated_at'] as num).toInt()
        : int.tryParse(map['updated_at']?.toString() ?? '') ?? 0;
    return Anime3rbWatchingProgress(
      slug: slug.trim(),
      episodeNumber: video,
      timeSeconds: time,
      progressPercent: progress,
      updatedAtMillis: updatedAt,
    );
  }
}

class Anime3rbNotificationItem {
  const Anime3rbNotificationItem({
    required this.id,
    required this.title,
    this.url,
    this.timeText,
    this.unread = false,
  });

  final String id;
  final String title;
  final String? url;
  final String? timeText;
  final bool unread;
}

class Anime3rbReportScopeOption {
  const Anime3rbReportScopeOption({required this.value, required this.label});

  final String value;
  final String label;

  static const List<Anime3rbReportScopeOption> defaults = [
    Anime3rbReportScopeOption(value: 'single', label: 'في هذه الحلقة فقط'),
    Anime3rbReportScopeOption(value: 'multiple', label: 'في عدة حلقات'),
    Anime3rbReportScopeOption(value: 'title', label: 'في العمل كله'),
    Anime3rbReportScopeOption(value: 'all', label: 'في كل الحلقات'),
  ];
}

class Anime3rbReportIssueOption {
  const Anime3rbReportIssueOption({
    required this.id,
    required this.label,
    this.description,
    this.note,
    this.requiresAdditionalDetails = false,
    this.children = const <Anime3rbReportIssueOption>[],
  });

  final int id;
  final String label;
  final String? description;
  final String? note;
  final bool requiresAdditionalDetails;
  final List<Anime3rbReportIssueOption> children;

  static List<Object?> unwrapLivewireList(Object? raw) {
    var cur = raw;
    while (cur is List &&
        cur.length == 2 &&
        cur[1] is Map &&
        (cur[1] as Map)['s'] == 'arr' &&
        cur.first is List) {
      cur = cur.first;
    }
    return cur is List ? cur : const <Object?>[];
  }

  static Anime3rbReportIssueOption? fromJson(Object? raw) {
    var target = raw;
    while (target is List && target.isNotEmpty) {
      if (target.length == 2 &&
          target[1] is Map &&
          (target[1] as Map)['s'] == 'arr') {
        target = target.first;
      } else if (target.first is Map || target.first is List) {
        target = target.first;
      } else {
        break;
      }
    }
    if (target is! Map || target['s'] == 'arr') return null;
    final map = Map<String, dynamic>.from(target);
    final id = (map['id'] is num)
        ? (map['id'] as num).toInt()
        : int.tryParse(map['id']?.toString() ?? '');
    final label = map['label']?.toString().trim() ?? '';
    if (id == null || label.isEmpty) return null;
    final childrenList = unwrapLivewireList(map['children']);
    final children = <Anime3rbReportIssueOption>[];
    for (final child in childrenList) {
      final parsed = fromJson(child);
      if (parsed != null) children.add(parsed);
    }
    return Anime3rbReportIssueOption(
      id: id,
      label: label,
      description: map['description']?.toString().trim(),
      note: map['note']?.toString().trim(),
      requiresAdditionalDetails: map['requires_additional_details'] == true,
      children: children,
    );
  }
}

class Anime3rbProfile {
  const Anime3rbProfile({
    required this.accountId,
    required this.userSlug,
    required this.displayName,
    this.email,
    this.avatarUrl,
    this.xtreamUsername,
    this.xtreamQuality,
    this.unreadNotifications = 0,
    this.counts = const Anime3rbListCounts(),
    this.watchingProgress = const <String, Anime3rbWatchingProgress>{},
  });

  final String accountId;
  final String userSlug;
  final String displayName;
  final String? email;
  final String? avatarUrl;
  final String? xtreamUsername;
  final String? xtreamQuality;
  final int unreadNotifications;
  final Anime3rbListCounts counts;
  final Map<String, Anime3rbWatchingProgress> watchingProgress;

  Anime3rbProfile copyWith({
    String? accountId,
    String? userSlug,
    String? displayName,
    String? email,
    String? avatarUrl,
    String? xtreamUsername,
    String? xtreamQuality,
    int? unreadNotifications,
    Anime3rbListCounts? counts,
    Map<String, Anime3rbWatchingProgress>? watchingProgress,
  }) => Anime3rbProfile(
    accountId: accountId ?? this.accountId,
    userSlug: userSlug ?? this.userSlug,
    displayName: displayName ?? this.displayName,
    email: email ?? this.email,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    xtreamUsername: xtreamUsername ?? this.xtreamUsername,
    xtreamQuality: xtreamQuality ?? this.xtreamQuality,
    unreadNotifications: unreadNotifications ?? this.unreadNotifications,
    counts: counts ?? this.counts,
    watchingProgress: watchingProgress ?? this.watchingProgress,
  );

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'userSlug': userSlug,
    'displayName': displayName,
    if (email != null) 'email': email,
    if (avatarUrl != null) 'avatarUrl': avatarUrl,
    if (xtreamUsername != null) 'xtreamUsername': xtreamUsername,
    if (xtreamQuality != null) 'xtreamQuality': xtreamQuality,
    'unreadNotifications': unreadNotifications,
    'counts': counts.toJson(),
    if (watchingProgress.isNotEmpty)
      'watchingProgress': {
        for (final entry in watchingProgress.entries)
          entry.key: entry.value.toJson(),
      },
  };

  static Anime3rbProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final accountId = map['accountId']?.toString().trim() ?? '';
    final userSlug = map['userSlug']?.toString().trim() ?? '';
    final displayName = map['displayName']?.toString().trim() ?? '';
    if (accountId.isEmpty || userSlug.isEmpty || displayName.isEmpty) {
      return null;
    }
    final countsRaw = map['counts'];
    final counts = countsRaw is Map
        ? Anime3rbListCounts.fromJson(Map<String, dynamic>.from(countsRaw))
        : const Anime3rbListCounts();
    final progressRaw = map['watchingProgress'];
    final progress = <String, Anime3rbWatchingProgress>{};
    if (progressRaw is Map) {
      for (final entry in progressRaw.entries) {
        final slug = entry.key.toString().trim();
        final parsed = Anime3rbWatchingProgress.fromJson(slug, entry.value);
        if (parsed != null) progress[slug] = parsed;
      }
    }
    return Anime3rbProfile(
      accountId: accountId,
      userSlug: userSlug,
      displayName: displayName,
      email: map['email']?.toString(),
      avatarUrl: map['avatarUrl']?.toString(),
      xtreamUsername: map['xtreamUsername']?.toString(),
      xtreamQuality: map['xtreamQuality']?.toString(),
      unreadNotifications: (map['unreadNotifications'] is num)
          ? (map['unreadNotifications'] as num).toInt()
          : int.tryParse(map['unreadNotifications']?.toString() ?? '') ?? 0,
      counts: counts,
      watchingProgress: progress,
    );
  }
}

class Anime3rbAccountSession {
  const Anime3rbAccountSession({
    required this.sessionCookie,
    required this.profile,
    required this.updatedAtMillis,
    this.csrfToken,
    this.comntoToken,
    this.comntoRefreshToken,
  });

  final String sessionCookie;
  final Anime3rbProfile profile;
  final int updatedAtMillis;
  final String? csrfToken;
  final String? comntoToken;
  final String? comntoRefreshToken;

  String get accountId => profile.accountId;

  Anime3rbAccountSession copyWith({
    String? sessionCookie,
    Anime3rbProfile? profile,
    int? updatedAtMillis,
    String? csrfToken,
    String? comntoToken,
    String? comntoRefreshToken,
    bool clearComnto = false,
  }) => Anime3rbAccountSession(
    sessionCookie: sessionCookie ?? this.sessionCookie,
    profile: profile ?? this.profile,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
    csrfToken: csrfToken ?? this.csrfToken,
    comntoToken: clearComnto ? null : (comntoToken ?? this.comntoToken),
    comntoRefreshToken: clearComnto
        ? null
        : (comntoRefreshToken ?? this.comntoRefreshToken),
  );

  String encode() => jsonEncode({
    'sessionCookie': sessionCookie,
    'profile': profile.toJson(),
    'updatedAtMillis': updatedAtMillis,
    if (csrfToken != null && csrfToken!.isNotEmpty) 'csrfToken': csrfToken,
    if (comntoToken != null && comntoToken!.isNotEmpty)
      'comntoToken': comntoToken,
    if (comntoRefreshToken != null && comntoRefreshToken!.isNotEmpty)
      'comntoRefreshToken': comntoRefreshToken,
  });

  static Anime3rbAccountSession? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final cookie = map['sessionCookie']?.toString().trim() ?? '';
      final profile = Anime3rbProfile.fromJson(map['profile']);
      if (cookie.isEmpty || profile == null) return null;
      return Anime3rbAccountSession(
        sessionCookie: cookie,
        profile: profile,
        updatedAtMillis: (map['updatedAtMillis'] is num)
            ? (map['updatedAtMillis'] as num).toInt()
            : 0,
        csrfToken: map['csrfToken']?.toString(),
        comntoToken: map['comntoToken']?.toString(),
        comntoRefreshToken: map['comntoRefreshToken']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}
