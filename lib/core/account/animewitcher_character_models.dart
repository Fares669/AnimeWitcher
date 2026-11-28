import '../domain/entity/multimedia_item.dart';
import 'animewitcher_account_payload.dart';
import 'animewitcher_comment_models.dart';
import 'animewitcher_model_fields.dart' as decode;
import 'firestore_rest_client.dart';

/// MAL placeholder icon used when a character has no real artwork.
const String animeWitcherMalPlaceholderImage =
    'https://cdn.myanimelist.net/img/sp/icon/apple-touch-icon-256.png';

const String animeWitcherCharactersAlgoliaIndex = 'characters';
const String animeWitcherCharactersListCollection = 'characters_list';
const String animeWitcherFavCharactersCollection = 'fav_characters';
const String animeWitcherSearchServicePath = 'Settings/search_service';

const List<String> animeWitcherCharacterAlgoliaAttributes = <String>[
  'name',
  'main_picture',
  'likes',
  'objectID',
];

const int animeWitcherCharacterBrowseHitsPerPage = 20;
const int animeWitcherCharacterSearchHitsPerPage = 500;
const int animeWitcherFavoriteCharactersPageSize = 12;
const int animeWitcherAnimeCastStripLimit = 10;

/// Fetch one extra so the rail can tell 10 characters from 11+.
const int animeWitcherAnimeCastStripFetchLimit = 11;

/// Visible cards in a details rail. An 11th fetched hit becomes المزيد.
int animeWitcherCastStripVisibleCount(int fetchedCount) {
  if (fetchedCount > animeWitcherAnimeCastStripLimit) {
    return animeWitcherAnimeCastStripLimit;
  }
  return fetchedCount < 0 ? 0 : fetchedCount;
}

bool animeWitcherCastStripShowsMore(int fetchedCount) =>
    fetchedCount > animeWitcherAnimeCastStripLimit;

/// Extra-tab body is always 2 rows × 3 poster cards. More than this count
/// shows five posters plus a المزيد tile.
const int animeWitcherExtraTabPreviewSlots = 6;
const int animeWitcherExtraTabPreviewItemsWhenMore = 5;

/// APK `AnimeDetailsActivity.setUpViewPager` extra-tab labels.
const String animeWitcherSimilarTabLabel = 'أنميات مشابهة';
const String animeWitcherRelatedTabLabel = 'ذات صلة';
const String animeWitcherCharactersTabLabel = 'الشخصيات';
const String animeWitcherMainCharactersHeader = 'الشخصيات الرئيسية';
const String animeWitcherSupportingCharactersHeader = 'الشخصيات المساعدة';
const String animeWitcherShowMoreLabel = 'المزيد';
const String animeWitcherSimilarSearchDisabledMessage =
    'خطأ في تحميل البيانات! سوف تعود خدمة اقتراح الأنميات في أسرع وقت.';
const String animeWitcherSimilarEmptyMessage = 'لا يوجد بيانات!';
const String animeWitcherRelatedEmptyMessage = 'لا توجد أنميات ذات صلة.';
const String animeWitcherRelatedErrorMessage = 'حدث خطأ أثناء تحميل الأنميات.';
const String animeWitcherCharactersEmptyMessage =
    'لم يتم اضافة الشخصيات حتي الان.';
const String animeWitcherCharactersDataEmptyMessage =
    'لم يتم اضافة بيانات الشخصيات حتي الان.';

String animeWitcherCharactersListPath(String characterId) =>
    '$animeWitcherCharactersListCollection/${characterId.trim()}';

String animeWitcherFavCharactersCollectionPath(String userId) =>
    'users/${userId.trim()}/$animeWitcherFavCharactersCollection';

String animeWitcherFavCharacterPath(String userId, String characterId) =>
    '${animeWitcherFavCharactersCollectionPath(userId)}/${characterId.trim()}';

String animeWitcherAnimeCharactersParent(String animeId) =>
    'anime_list/${animeId.trim()}';

/// Optimistic favorite write. `date` is applied as a server timestamp.
Map<String, dynamic> animeWitcherFavoriteCharacterWriteFields(
  String characterId,
) {
  return <String, dynamic>{'mal_id': characterId.trim()};
}

const Map<String, dynamic> animeWitcherFavoriteCharacterDenormTrigger =
    <String, dynamic>{'update_character': true};

bool isAnimeWitcherMalPlaceholderImage(String? url) {
  final value = url?.trim() ?? '';
  if (value.isEmpty) return true;
  return value == animeWitcherMalPlaceholderImage;
}

String? animeWitcherSanitizedCharacterImage(dynamic raw) {
  final value = decode.text(raw);
  if (isAnimeWitcherMalPlaceholderImage(value)) return null;
  return value;
}

String animeWitcherCharacterRoleLabel(dynamic raw) {
  switch (decode.text(raw).toUpperCase()) {
    case 'MAIN':
      return 'شخصية رئيسية';
    case 'SUPPORTING':
      return 'شخصية ثانوية';
    default:
      return decode.text(raw).isEmpty ? 'شخصية' : decode.text(raw);
  }
}

class AnimeWitcherSearchServiceSettings {
  const AnimeWitcherSearchServiceSettings({
    required this.isSearchActive,
    required this.appId,
    required this.browseApiKey,
    this.errorMessage = '',
  });

  final bool isSearchActive;
  final String appId;
  final String browseApiKey;
  final String errorMessage;

  factory AnimeWitcherSearchServiceSettings.fromFields(dynamic raw) {
    final fields = decode.stringMap(raw);
    return AnimeWitcherSearchServiceSettings(
      isSearchActive: readAnimeWitcherPayloadBool(
        fields['is_search_active'] ?? fields['isSearchActive'],
        true,
      ),
      appId: decode.text(
        fields['app_id'] ?? fields['appId'] ?? fields['application_id'],
      ),
      browseApiKey: decode.text(
        fields['browseApiKey'] ??
            fields['browse_api_key'] ??
            fields['browseAPIKey'],
      ),
      errorMessage: decode.text(
        fields['error_message'] ?? fields['errorMessage'],
      ),
    );
  }
}

class AnimeWitcherSearchDisabledException implements Exception {
  const AnimeWitcherSearchDisabledException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AnimeWitcherCharacterHit {
  const AnimeWitcherCharacterHit({
    required this.id,
    required this.name,
    this.imageUrl,
    this.likes = 0,
  });

  final String id;
  final String name;
  final String? imageUrl;
  final int likes;

  String get documentPath => animeWitcherCharactersListPath(id);

  factory AnimeWitcherCharacterHit.fromAlgolia(dynamic raw) {
    final hit = decode.stringMap(raw);
    final id = decode.text(hit['objectID'] ?? hit['objectId'] ?? hit['id']);
    return AnimeWitcherCharacterHit(
      id: id,
      name: decode.text(hit['name']),
      imageUrl: animeWitcherSanitizedCharacterImage(hit['main_picture']),
      likes: _positiveInt(hit['likes']),
    );
  }
}

class AnimeWitcherCharacterAnimeRef {
  const AnimeWitcherCharacterAnimeRef({
    required this.malId,
    required this.role,
  });

  final String malId;
  final String role;

  String get roleLabel => animeWitcherCharacterRoleLabel(role);
}

class AnimeWitcherCharacterDocument {
  const AnimeWitcherCharacterDocument({
    required this.id,
    required this.name,
    required this.likes,
    this.url,
    this.imageUrl,
    this.animes = const <AnimeWitcherCharacterAnimeRef>[],
  });

  final String id;
  final String name;
  final int likes;
  final String? url;
  final String? imageUrl;
  final List<AnimeWitcherCharacterAnimeRef> animes;

  String get commentsCollectionPath =>
      '${animeWitcherCharactersListPath(id)}/comments';

  factory AnimeWitcherCharacterDocument.fromFields(String id, dynamic raw) {
    final fields = decode.stringMap(raw);
    final data = decode.stringMap(fields['data']);
    final images = decode.stringMap(data['images'] ?? fields['images']);
    final jpg = decode.stringMap(images['jpg']);
    final webp = decode.stringMap(images['webp']);
    final image = animeWitcherSanitizedCharacterImage(
      jpg['image_url'] ??
          jpg['large_image_url'] ??
          webp['image_url'] ??
          webp['large_image_url'] ??
          data['main_picture'] ??
          fields['main_picture'] ??
          fields['image'],
    );
    return AnimeWitcherCharacterDocument(
      id: id.trim(),
      name: decode.text(data['name'] ?? fields['name']),
      likes: _positiveInt(fields['likes']),
      url: decode.optionalText(data['url'] ?? fields['url']),
      imageUrl: image,
      animes: parseAnimeWitcherCharacterAnimes(
        data['anime'] ?? fields['anime'],
      ),
    );
  }
}

class AnimeWitcherFavoriteCharacter {
  const AnimeWitcherFavoriteCharacter({
    required this.id,
    required this.malId,
    required this.name,
    this.imageUrl,
    this.likes = 0,
    this.date,
    this.needsDenorm = false,
  });

  final String id;
  final String malId;
  final String name;
  final String? imageUrl;
  final int likes;
  final DateTime? date;
  final bool needsDenorm;

  AnimeWitcherCharacterHit get asHit => AnimeWitcherCharacterHit(
    id: malId,
    name: name,
    imageUrl: imageUrl,
    likes: likes,
  );

  factory AnimeWitcherFavoriteCharacter.fromFields(
    String documentId,
    dynamic raw,
  ) {
    final fields = decode.stringMap(raw);
    final malId = decode.text(
      fields['mal_id'] ?? fields['malId'] ?? documentId,
    );
    final name = decode.text(fields['name']);
    final image = animeWitcherSanitizedCharacterImage(fields['main_picture']);
    final likes = _positiveInt(fields['likes']);
    final needsDenorm =
        name.isEmpty || image == null || !fields.containsKey('likes');
    return AnimeWitcherFavoriteCharacter(
      id: documentId.trim(),
      malId: malId.isEmpty ? documentId.trim() : malId,
      name: name,
      imageUrl: image,
      likes: likes,
      date: decode.localDate(fields['date']),
      needsDenorm: needsDenorm,
    );
  }

  AnimeWitcherFavoriteCharacter copyWith({
    String? name,
    String? imageUrl,
    int? likes,
    bool? needsDenorm,
  }) {
    return AnimeWitcherFavoriteCharacter(
      id: id,
      malId: malId,
      name: name ?? this.name,
      imageUrl: imageUrl ?? this.imageUrl,
      likes: likes ?? this.likes,
      date: date,
      needsDenorm: needsDenorm ?? this.needsDenorm,
    );
  }
}

class AnimeWitcherCharacterPage {
  const AnimeWitcherCharacterPage({
    required this.items,
    required this.page,
    required this.hasMore,
  });

  final List<AnimeWitcherCharacterHit> items;
  final int page;
  final bool hasMore;
}

class AnimeWitcherFavoriteCharacterPage {
  const AnimeWitcherFavoriteCharacterPage({
    required this.items,
    this.cursor,
    required this.hasMore,
  });

  final List<AnimeWitcherFavoriteCharacter> items;
  final FirestoreDocument? cursor;
  final bool hasMore;
}

class AnimeWitcherCharacterShow {
  const AnimeWitcherCharacterShow({required this.item, required this.role});

  final MultimediaItem item;
  final String role;

  String get roleLabel => animeWitcherCharacterRoleLabel(role);
}

List<AnimeWitcherCharacterAnimeRef> parseAnimeWitcherCharacterAnimes(
  dynamic raw,
) {
  final entries = _characterAnimeEntries(raw);
  if (entries.isEmpty) return const <AnimeWitcherCharacterAnimeRef>[];
  final output = <AnimeWitcherCharacterAnimeRef>[];
  final seen = <String>{};
  for (final entry in entries) {
    final row = decode.stringMap(entry);
    final anime = decode.stringMap(row['anime']);
    final malId = _digits(
      anime['mal_id'] ??
          anime['malId'] ??
          row['mal_id'] ??
          row['malId'] ??
          entry,
    );
    if (malId.isEmpty || !seen.add(malId)) continue;
    output.add(
      AnimeWitcherCharacterAnimeRef(
        malId: malId,
        role: decode.text(row['role'] ?? anime['role']),
      ),
    );
  }
  return output;
}

List<dynamic> _characterAnimeEntries(dynamic raw) {
  if (raw is Iterable && raw is! String) {
    return raw.map<dynamic>((entry) => entry).toList(growable: false);
  }
  final map = decode.stringMap(raw);
  if (map.isEmpty) return const <dynamic>[];
  final nested = map['arrayValue'] ?? map['values'] ?? map['anime'];
  if (nested is Iterable && nested is! String) {
    return nested.map<dynamic>((entry) => entry).toList(growable: false);
  }
  final values = decode.stringMap(map['arrayValue'])['values'];
  if (values is Iterable && values is! String) {
    return values.map<dynamic>((entry) => entry).toList(growable: false);
  }
  if (map.containsKey('mal_id') ||
      map.containsKey('malId') ||
      map.containsKey('anime') ||
      map.containsKey('role')) {
    return <dynamic>[map];
  }
  return const <dynamic>[];
}

String _digits(dynamic raw) {
  final match = RegExp(r'\d+').firstMatch(decode.text(raw));
  return match?.group(0) ?? '';
}

AnimeWitcherCommentTarget animeWitcherCharacterCommentTarget({
  required String characterId,
  required String name,
}) {
  final id = characterId.trim();
  final sourcePath = animeWitcherCharactersListPath(id);
  return AnimeWitcherCommentTarget(
    collectionPath: '$sourcePath/comments',
    sourceDocumentPath: sourcePath,
    title: name,
    characterId: id,
    characterName: name,
  );
}

int _positiveInt(dynamic raw) {
  if (raw is num) {
    final value = raw.toInt();
    return value > 0 ? value : 0;
  }
  final match = RegExp(r'\d+').firstMatch(decode.text(raw));
  final value = match == null ? 0 : int.tryParse(match.group(0)!) ?? 0;
  return value > 0 ? value : 0;
}
