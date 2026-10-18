import 'package:animewitcher/features/search/presentation/search_text_direction.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Arabic UI keeps Latin queries LTR and Arabic queries RTL', () {
    expect(
      searchTextDirection('One Piece', fallback: TextDirection.rtl),
      TextDirection.ltr,
    );
    expect(
      searchTextDirection('ون بيس', fallback: TextDirection.rtl),
      TextDirection.rtl,
    );
    for (final query in ['', '123', '  ! 🎬']) {
      expect(
        searchTextDirection(query, fallback: TextDirection.rtl),
        TextDirection.rtl,
      );
    }
  });
}
