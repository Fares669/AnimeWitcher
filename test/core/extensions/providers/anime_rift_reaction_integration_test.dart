import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_comments.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReactionClient extends AnimeRiftApiClient {
  _ReactionClient()
    : super(
        config: const AnimeRiftConfig(
          firebaseApiKey: 'test',
          firebaseAppId: 'test',
          signingKey: 'test',
        ),
      );

  ({String commentId, String? animeId, String? episodeId})? submitted;

  @override
  Future<Map<String, dynamic>> reactToComment(
    String commentId, {
    String? animeId,
    String? episodeId,
  }) async {
    submitted = (commentId: commentId, animeId: animeId, episodeId: episodeId);
    return const {};
  }
}

void main() {
  test(
    'AnimeRift reaction forwards native anime and episode context',
    () async {
      final client = _ReactionClient();
      final provider = AnimeRiftProvider(client: client);

      await provider.reactToComment(
        const AnimeRiftCommentTarget(
          animeId: 'anime42',
          episodeId: 'episode7',
          title: 'test',
        ),
        'comment1',
      );

      expect(client.submitted?.commentId, 'comment1');
      expect(client.submitted?.animeId, 'anime42');
      expect(client.submitted?.episodeId, 'episode7');
    },
  );

  test(
    'AnimeRift anime-level reaction does not invent an episode ID',
    () async {
      final client = _ReactionClient();
      final provider = AnimeRiftProvider(client: client);

      await provider.reactToComment(
        const AnimeRiftCommentTarget(animeId: 'anime42', title: 'test'),
        'comment2',
      );

      expect(client.submitted?.animeId, 'anime42');
      expect(client.submitted?.episodeId, isNull);
    },
  );
}
