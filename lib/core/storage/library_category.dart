import '../domain/entity/multimedia_item.dart';

typedef LibraryMembership = ({LibraryCategory? category, bool favorite});

enum LibraryCategory {
  favorite('favorite'),
  watching('watching'),
  continueLater('onHold'),
  planToWatch('pinned'),
  completed('completed'),
  notInterested('noWatching');

  final String storageKey;
  const LibraryCategory(this.storageKey);

  bool get isPrimary => this != LibraryCategory.favorite;

  static const List<LibraryCategory> primaryValues = <LibraryCategory>[
    LibraryCategory.watching,
    LibraryCategory.continueLater,
    LibraryCategory.planToWatch,
    LibraryCategory.completed,
    LibraryCategory.notInterested,
  ];

  static const List<LibraryCategory> witanimeValues = <LibraryCategory>[
    LibraryCategory.favorite,
    LibraryCategory.watching,
    LibraryCategory.planToWatch,
    LibraryCategory.completed,
  ];

  static const List<LibraryCategory> witanimePrimaryValues = <LibraryCategory>[
    LibraryCategory.watching,
    LibraryCategory.planToWatch,
    LibraryCategory.completed,
  ];

  static List<LibraryCategory> valuesForCatalog({required bool witanimeAnime}) =>
      witanimeAnime ? witanimeValues : LibraryCategory.values;

  /// List-assignment options for the details overflow menu.
  ///
  /// Hides [watching] when the title has not aired yet, hides [completed]
  /// unless the title is finished, and hides AnimeWitcher-only lists for
  /// Witanime anime/movies.
  static List<LibraryCategory> assignmentValuesFor(MultimediaItem item) {
    final isWitanimeAnime =
        item.provider == 'witanime' &&
        item.contentType != MultimediaContentType.manga;
    final candidates = isWitanimeAnime ? witanimePrimaryValues : primaryValues;
    return <LibraryCategory>[
      for (final category in candidates)
        if (category.isAssignableTo(item)) category,
    ];
  }

  bool isAssignableTo(MultimediaItem item) {
    return switch (this) {
      LibraryCategory.watching => !item.isNotYetAired,
      LibraryCategory.completed => item.status == ShowStatus.completed,
      _ => true,
    };
  }

  static LibraryCategory fromStorageKey(String? raw) {
    final value = (raw ?? '').trim();
    if (value == 'on_Hold' ||
        value == 'onHold' ||
        value == 'continueLater' ||
        value == 'continue_later') {
      return LibraryCategory.continueLater;
    }
    for (final category in LibraryCategory.values) {
      if (category.storageKey == value) return category;
    }
    if (value == 'no_watching') return LibraryCategory.notInterested;
    if (value == 'pin') return LibraryCategory.planToWatch;
    return LibraryCategory.favorite;
  }
}
