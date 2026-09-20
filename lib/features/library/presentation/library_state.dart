import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/storage/library_category.dart';
import 'library_media_kind.dart';

sealed class LibraryState {
  final LibraryCategory category;
  final LibraryMediaKind mediaKind;

  const LibraryState(this.category, this.mediaKind);
}

class LibraryLoading extends LibraryState {
  const LibraryLoading(super.category, super.mediaKind);
}

class LibraryEmpty extends LibraryState {
  const LibraryEmpty(super.category, super.mediaKind);
}

class LibrarySuccess extends LibraryState {
  final List<MultimediaItem> items;

  const LibrarySuccess(this.items, super.category, super.mediaKind);
}

class LibraryError extends LibraryState {
  final String message;

  const LibraryError(this.message, super.category, super.mediaKind);
}
