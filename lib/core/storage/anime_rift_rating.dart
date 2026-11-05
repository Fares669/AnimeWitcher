/// AnimeRift stores five independent scores. They must never be replaced by
/// one AnimeWitcher account rating duplicated into all fields.
class AnimeRiftRating {
  const AnimeRiftRating({
    required this.general,
    required this.story,
    required this.characters,
    required this.animation,
    required this.music,
  });

  final double general;
  final double story;
  final double characters;
  final double animation;
  final double music;

  bool get isValid => [
    general,
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

    final general = score('general_rating');
    final story = score('story_rating');
    final characters = score('characters_rating');
    final animation = score('animation_rating');
    final music = score('music_rating');
    if (general == null ||
        story == null ||
        characters == null ||
        animation == null ||
        music == null) {
      return null;
    }
    return AnimeRiftRating(
      general: general,
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
      general == other.general &&
      story == other.story &&
      characters == other.characters &&
      animation == other.animation &&
      music == other.music;

  @override
  int get hashCode => Object.hash(general, story, characters, animation, music);
}
