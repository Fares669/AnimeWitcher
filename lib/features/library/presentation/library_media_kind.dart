import '../../../core/domain/entity/multimedia_item.dart';

enum LibraryMediaKind {
  anime('anime'),
  manga('manga');

  const LibraryMediaKind(this.storageKey);

  final String storageKey;

  bool accepts(MultimediaItem item) => switch (this) {
    LibraryMediaKind.anime =>
      item.contentType != MultimediaContentType.manga,
    LibraryMediaKind.manga =>
      item.contentType == MultimediaContentType.manga,
  };

  static LibraryMediaKind fromStorageKey(String? raw) {
    final value = raw?.trim().toLowerCase();
    for (final kind in values) {
      if (kind.storageKey == value) return kind;
    }
    return LibraryMediaKind.anime;
  }
}

List<MultimediaItem> filterLibraryItemsByKind(
  Iterable<MultimediaItem> items,
  LibraryMediaKind kind,
) {
  return items.where(kind.accepts).toList(growable: false);
}
