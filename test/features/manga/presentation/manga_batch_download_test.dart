import 'dart:async';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_controller.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _PendingDownloads extends MangaDetailsController {
  final requested = <String>[];
  final pending = <String, Completer<void>>{};

  @override
  MangaDetailsState build(String itemUrl) => const MangaDetailsState();

  @override
  Future<void> downloadChapter(MangaChapter chapter) {
    requested.add(chapter.id);
    return (pending[chapter.id] = Completer<void>()).future;
  }
}

void main() {
  test(
    'batch submits every chapter while the first start is pending',
    () async {
      final controller = _PendingDownloads();
      final container = ProviderContainer(
        overrides: [
          mangaDetailsControllerProvider('/manga')
              .overrideWith(() => controller),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        mangaDetailsControllerProvider('/manga'),
        (_, _) {},
      );
      addTearDown(subscription.close);
      container.read(mangaDetailsControllerProvider('/manga'));

      final result = controller.downloadChapters([
        for (var i = 1; i <= 3; i++)
          MangaChapter(id: '$i', mangaId: 'm1', url: '/chapter/$i', name: '$i'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.requested, ['1', '2', '3']);
      controller.pending['2']!.completeError(StateError('unavailable'));
      controller.pending['3']!.complete();
      controller.pending['1']!.complete();
      expect(await result, 1);
    },
  );
}
