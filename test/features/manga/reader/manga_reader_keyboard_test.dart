import 'package:animewitcher/features/manga/reader/manga_reader_keyboard_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Mangayomi keyboard mapping keeps RTL page direction and chapter keys', () {
    var previousPage = 0;
    var nextPage = 0;
    var previousChapter = 0;
    var nextChapter = 0;
    var close = 0;
    var fullscreen = 0;

    final handler = MangaReaderKeyboardHandler(
      onEscape: () => close++,
      onFullScreen: () => fullscreen++,
      onPreviousPage: () => previousPage++,
      onNextPage: () => nextPage++,
      onPreviousChapter: () => previousChapter++,
      onNextChapter: () => nextChapter++,
    );

    handler.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowLeft,
        logicalKey: LogicalKeyboardKey.arrowLeft,
        timeStamp: Duration.zero,
      ),
      isReverseHorizontal: true,
    );
    expect(nextPage, 1);
    expect(previousPage, 0);

    handler.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.pageDown,
        logicalKey: LogicalKeyboardKey.pageDown,
        timeStamp: Duration.zero,
      ),
    );
    handler.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.pageUp,
        logicalKey: LogicalKeyboardKey.pageUp,
        timeStamp: Duration.zero,
      ),
    );
    expect(nextChapter, 1);
    expect(previousChapter, 1);

    handler.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.escape,
        logicalKey: LogicalKeyboardKey.escape,
        timeStamp: Duration.zero,
      ),
    );
    handler.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.f11,
        logicalKey: LogicalKeyboardKey.f11,
        timeStamp: Duration.zero,
      ),
    );
    expect(close, 1);
    expect(fullscreen, 1);
  });
}
