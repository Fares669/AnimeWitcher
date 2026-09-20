import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';

final class MangaDetailsState {
  const MangaDetailsState({
    this.item,
    this.details = const AsyncLoading<MultimediaItem?>(),
    this.chapters = const AsyncLoading<List<MangaChapter>>(),
  });

  final MultimediaItem? item;
  final AsyncValue<MultimediaItem?> details;
  final AsyncValue<List<MangaChapter>> chapters;

  MangaDetailsState copyWith({
    MultimediaItem? item,
    AsyncValue<MultimediaItem?>? details,
    AsyncValue<List<MangaChapter>>? chapters,
  }) {
    return MangaDetailsState(
      item: item ?? this.item,
      details: details ?? this.details,
      chapters: chapters ?? this.chapters,
    );
  }
}
