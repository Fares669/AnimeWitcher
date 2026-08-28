import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnimeWitcherCharacterHit', () {
    test('parses a flat Algolia character hit', () {
      final hit = AnimeWitcherCharacterHit.fromAlgolia(<String, dynamic>{
        'objectID': '417',
        'name': 'Lelouch Lamperouge',
        'main_picture': 'https://cdn.myanimelist.net/images/characters/8/l.jpg',
        'likes': 128,
      });

      expect(hit.id, '417');
      expect(hit.name, 'Lelouch Lamperouge');
      expect(
        hit.imageUrl,
        'https://cdn.myanimelist.net/images/characters/8/l.jpg',
      );
      expect(hit.likes, 128);
      expect(hit.documentPath, 'characters_list/417');
    });

    test('treats the MAL placeholder icon as no image', () {
      final hit = AnimeWitcherCharacterHit.fromAlgolia(<String, dynamic>{
        'objectID': '1',
        'name': 'Unknown',
        'main_picture': animeWitcherMalPlaceholderImage,
        'likes': 0,
      });

      expect(hit.imageUrl, isNull);
      expect(isAnimeWitcherMalPlaceholderImage(hit.imageUrl), isTrue);
    });
  });

  group('AnimeWitcherCharacterDocument', () {
    test('parses characters_list fields without mutating likes', () {
      final document = AnimeWitcherCharacterDocument.fromFields(
        '417',
        <String, dynamic>{
          'likes': 42,
          'data': <String, dynamic>{
            'name': 'Lelouch Lamperouge',
            'url': 'https://myanimelist.net/character/417/Lelouch_Lamperouge',
            'images': <String, dynamic>{
              'jpg': <String, dynamic>{
                'image_url': 'https://cdn.myanimelist.net/images/characters/8/l.jpg',
              },
            },
            'anime': <Map<String, dynamic>>[
              <String, dynamic>{
                'role': 'Main',
                'anime': <String, dynamic>{'mal_id': 1575},
              },
              <String, dynamic>{
                'role': 'Supporting',
                'anime': <String, dynamic>{'mal_id': '13759'},
              },
            ],
          },
        },
      );

      expect(document.id, '417');
      expect(document.name, 'Lelouch Lamperouge');
      expect(document.likes, 42);
      expect(
        document.url,
        'https://myanimelist.net/character/417/Lelouch_Lamperouge',
      );
      expect(document.animes, hasLength(2));
      expect(document.animes.first.malId, '1575');
      expect(document.animes.first.roleLabel, 'شخصية رئيسية');
      expect(document.animes.last.malId, '13759');
      expect(document.animes.last.roleLabel, 'شخصية ثانوية');
      expect(document.commentsCollectionPath, 'characters_list/417/comments');
    });
  });

  test('favorite write fields match the APK merge payload', () {
    expect(
      animeWitcherFavoriteCharacterWriteFields('417'),
      <String, dynamic>{'mal_id': '417'},
    );
    expect(
      animeWitcherFavoriteCharacterWriteFields('417').containsKey('likes'),
      isFalse,
    );
    expect(
      animeWitcherFavoriteCharacterDenormTrigger,
      <String, dynamic>{'update_character': true},
    );
  });

  test('favorite docs missing denorm fields request a CF update', () {
    final favorite = AnimeWitcherFavoriteCharacter.fromFields(
      '417',
      const <String, dynamic>{'mal_id': '417', 'date': '2026-01-01T00:00:00Z'},
    );
    expect(favorite.needsDenorm, isTrue);
    expect(favorite.malId, '417');
  });

  test('character comment target writes character_id and character_name', () {
    final target = animeWitcherCharacterCommentTarget(
      characterId: '417',
      name: 'Lelouch Lamperouge',
    );
    expect(target.collectionPath, 'characters_list/417/comments');
    expect(target.sourceDocumentPath, 'characters_list/417');
    expect(target.publishFields, <String, dynamic>{
      'character_id': '417',
      'character_name': 'Lelouch Lamperouge',
    });
  });

  test('search service settings expose browse credentials', () {
    final settings = AnimeWitcherSearchServiceSettings.fromFields(
      <String, dynamic>{
        'browseApiKey': 'browse-key',
        'is_search_active': false,
        'app_id': 'TESTAPPID',
        'error_message': 'البحث متوقف حاليا',
      },
    );
    expect(settings.browseApiKey, 'browse-key');
    expect(settings.appId, 'TESTAPPID');
    expect(settings.isSearchActive, isFalse);
    expect(settings.errorMessage, 'البحث متوقف حاليا');
  });

  test('path helpers match the original Firestore layout', () {
    expect(animeWitcherCharactersListPath('417'), 'characters_list/417');
    expect(
      animeWitcherFavCharacterPath('user-1', '417'),
      'users/user-1/fav_characters/417',
    );
    expect(
      animeWitcherFavCharactersCollectionPath('user-1'),
      'users/user-1/fav_characters',
    );
    expect(animeWitcherAnimeCharactersParent('code-geass'), 'anime_list/code-geass');
  });

  test('actor json keeps the character document id for details navigation', () {
    final actor = Actor(
      id: '417',
      name: 'Lelouch',
      image: 'https://cdn.example/l.jpg',
      role: 'شخصية رئيسية',
    );
    final restored = Actor.fromJson(actor.toJson());
    expect(restored.id, '417');
    expect(restored.name, 'Lelouch');
  });
}
