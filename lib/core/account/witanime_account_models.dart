import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../storage/library_category.dart';

enum WitanimeAuthAction { signIn, register, forgotPassword }

class WitanimeListCounts {
  const WitanimeListCounts({
    this.watching = 0,
    this.completed = 0,
    this.planToWatch = 0,
    this.favorites = 0,
  });

  final int watching;
  final int completed;
  final int planToWatch;
  final int favorites;

  int? countFor(LibraryCategory category) => switch (category) {
    LibraryCategory.watching => watching,
    LibraryCategory.completed => completed,
    LibraryCategory.planToWatch => planToWatch,
    LibraryCategory.favorite => favorites,
    LibraryCategory.continueLater || LibraryCategory.notInterested => null,
  };

  WitanimeListCounts copyWith({
    int? watching,
    int? completed,
    int? planToWatch,
    int? favorites,
  }) => WitanimeListCounts(
    watching: watching ?? this.watching,
    completed: completed ?? this.completed,
    planToWatch: planToWatch ?? this.planToWatch,
    favorites: favorites ?? this.favorites,
  );

  Map<String, Object?> toJson() => {
    'watching': watching,
    'completed': completed,
    'planToWatch': planToWatch,
    'favorites': favorites,
  };

  factory WitanimeListCounts.fromJson(Map<String, dynamic> json) {
    int readInt(String key) {
      final raw = json[key];
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '') ?? 0;
    }

    return WitanimeListCounts(
      watching: readInt('watching'),
      completed: readInt('completed'),
      planToWatch: readInt('planToWatch'),
      favorites: readInt('favorites'),
    );
  }
}

class WitanimeProfile {
  const WitanimeProfile({
    required this.accountId,
    required this.displayName,
    this.email,
    this.avatarUrl,
    this.counts = const WitanimeListCounts(),
  });

  final String accountId;
  final String displayName;
  final String? email;
  final String? avatarUrl;
  final WitanimeListCounts counts;

  WitanimeProfile copyWith({
    String? accountId,
    String? displayName,
    String? email,
    String? avatarUrl,
    WitanimeListCounts? counts,
  }) => WitanimeProfile(
    accountId: accountId ?? this.accountId,
    displayName: displayName ?? this.displayName,
    email: email ?? this.email,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    counts: counts ?? this.counts,
  );

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'displayName': displayName,
    if (email != null) 'email': email,
    if (avatarUrl != null) 'avatarUrl': avatarUrl,
    'counts': counts.toJson(),
  };

  factory WitanimeProfile.fromJson(Map<String, dynamic> json) {
    final countsRaw = json['counts'];
    return WitanimeProfile(
      accountId: json['accountId']?.toString().trim() ?? '',
      displayName: json['displayName']?.toString().trim() ?? '',
      email: json['email']?.toString().trim(),
      avatarUrl: json['avatarUrl']?.toString().trim(),
      counts: countsRaw is Map
          ? WitanimeListCounts.fromJson(Map<String, dynamic>.from(countsRaw))
          : const WitanimeListCounts(),
    );
  }

  /// Extracts profile fields and list counters from Witanime's `/profile` HTML.
  static WitanimeProfile? fromProfileHtml(String body, {Uri? baseUri}) {
    final document = html.parse(body);
    final root = document.querySelector('main') ?? document.body;
    if (root == null) return null;

    // Guest / redirected-to-login pages carry the login form, not profile fields.
    if (root.querySelector('form[action*="/login"]') != null &&
        root.querySelector('input[name="password"]') != null) {
      return null;
    }

    String? textOf(String selector) {
      final value = root
          .querySelector(selector)
          ?.text
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return value == null || value.isEmpty ? null : value;
    }

    final nameInput = root.querySelector('input[name="name"]')?.attributes['value'];
    final emailInput =
        root.querySelector('input[name="email"]')?.attributes['value'];
    final displayName =
        nameInput?.trim().isNotEmpty == true
        ? nameInput!.trim()
        : (textOf('[data-profile-name]') ?? textOf('h1'));
    if (displayName == null || displayName.isEmpty) return null;

    final email = emailInput?.trim().isNotEmpty == true
        ? emailInput!.trim()
        : textOf('[data-profile-email]');
    final accountId =
        root.attributes['data-user-id']?.trim() ??
        root.querySelector('[data-user-id]')?.attributes['data-user-id']?.trim() ??
        (email?.isNotEmpty == true ? email! : displayName);

    final rawAvatar =
        root.querySelector('img[data-profile-avatar]')?.attributes['src'] ??
        root.querySelector('img[src*="/avatars/"]')?.attributes['src'];
    final avatarUrl = rawAvatar != null && baseUri != null
        ? baseUri.resolve(rawAvatar.trim()).toString()
        : rawAvatar?.trim();

    int readCount(String key, List<String> labels) {
      final attr = root
          .querySelector('[data-count="$key"]')
          ?.text
          .replaceAll(RegExp(r'[^0-9]'), '');
      if (attr != null && attr.isNotEmpty) {
        return int.tryParse(attr) ?? 0;
      }
      for (final node in root.querySelectorAll('div, li, a, span')) {
        final text = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        for (final label in labels) {
          if (text.contains(label)) {
            final numMatch = RegExp(r'\d+').firstMatch(text);
            if (numMatch != null) {
              return int.tryParse(numMatch.group(0)!) ?? 0;
            }
          }
        }
      }
      return 0;
    }

    return WitanimeProfile(
      accountId: accountId,
      displayName: displayName,
      email: email,
      avatarUrl: avatarUrl,
      counts: WitanimeListCounts(
        watching: readCount('watching', const ['أشاهده']),
        completed: readCount('completed', const ['أكملته']),
        planToWatch: readCount('plan_to_watch', const ['أنوي مشاهدته', 'أرغب بمشاهدته']),
        favorites: readCount('favorites', const ['المفضلة']),
      ),
    );
  }
}

class WitanimeAccountSession {
  const WitanimeAccountSession({
    required this.sessionCookie,
    required this.profile,
    this.csrfToken,
    this.updatedAtMillis = 0,
  });

  final String sessionCookie;
  final String? csrfToken;
  final WitanimeProfile profile;
  final int updatedAtMillis;

  String get accountId => profile.accountId;

  Map<String, Object?> toJson() => {
    'sessionCookie': sessionCookie,
    if (csrfToken != null && csrfToken!.isNotEmpty) 'csrfToken': csrfToken,
    'profile': profile.toJson(),
    'updatedAtMillis': updatedAtMillis,
  };

  String encode() => jsonEncode(toJson());

  static WitanimeAccountSession? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final cookie = decoded['sessionCookie']?.toString().trim() ?? '';
      final profileRaw = decoded['profile'];
      if (cookie.isEmpty || profileRaw is! Map) return null;
      final profile = WitanimeProfile.fromJson(
        Map<String, dynamic>.from(profileRaw),
      );
      if (profile.accountId.isEmpty) return null;
      return WitanimeAccountSession(
        sessionCookie: cookie,
        csrfToken: decoded['csrfToken']?.toString().trim(),
        profile: profile,
        updatedAtMillis:
            (decoded['updatedAtMillis'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}
