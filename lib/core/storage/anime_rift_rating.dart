/// AnimeRift's four editable rating dimensions. The native APK computes the
/// displayed general score as their arithmetic mean (sum divided by four).
class AnimeRiftRating {
  const AnimeRiftRating({
    required this.story,
    required this.characters,
    required this.animation,
    required this.music,
  });

  final double story;
  final double characters;
  final double animation;
  final double music;

  /// This is derived, never separately editable or persisted as user input.
  double get general => (story + characters + animation + music) / 4;

  bool get isValid => [
    story,
    characters,
    animation,
    music,
  ].every((score) => score.isFinite && score >= 1 && score <= 10);

  Map<String, Object?> toJson() => {
    'general_rating': general,
    'story_rating': story,
    'characters_rating': characters,
    'animation_rating': animation,
    'music_rating': music,
  };

  static AnimeRiftRating? fromMap(Object? value) {
    if (value is! Map) return null;
    double? score(String key) {
      final raw = value[key];
      if (raw is! num || !raw.isFinite) {
        return null;
      }
      final number = raw.toDouble();
      return number >= 1 && number <= 10 ? number : null;
    }

    final story = score('story_rating');
    final characters = score('characters_rating');
    final animation = score('animation_rating');
    final music = score('music_rating');
    if (story == null ||
        characters == null ||
        animation == null ||
        music == null) {
      return null;
    }
    return AnimeRiftRating(
      story: story,
      characters: characters,
      animation: animation,
      music: music,
    );
  }

  static AnimeRiftRating? fromServer(Map<String, dynamic> response) {
    final item = response['item'];
    final interactions = response['interactions'];
    final candidates = [
      interactions,
      item is Map ? item['interactions'] : null,
      item is Map ? item['my_rating'] : null,
      item,
      response,
    ];
    for (final candidate in candidates) {
      final rating = fromMap(candidate);
      if (rating != null) return rating;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is AnimeRiftRating &&
      story == other.story &&
      characters == other.characters &&
      animation == other.animation &&
      music == other.music;

  @override
  int get hashCode => Object.hash(story, characters, animation, music);
}
