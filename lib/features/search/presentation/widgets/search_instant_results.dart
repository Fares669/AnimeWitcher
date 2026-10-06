// Laid out after Harbor's search overlay (src/components/search/*).
// Harbor: Copyright (c) 2026 Harbor, MIT License — see THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../../../../core/account/animewitcher_character_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../shared/widgets/fallback_poster_image.dart';
import '../../../../shared/widgets/poster_plate.dart';

/// Which results the tabs above them show.
enum _ResultKind { all, series, movies, animation, manga, characters }

/// The results shown while the search box is typed in: the best match on its
/// own with an open button, the other entries of the same series as posters,
/// then each kind as a short list — series and films, and when every category
/// is searched, animation, manga and characters too — with tabs counting each
/// kind. Enter, or "all results", still runs the full search.
class SearchInstantResults extends StatefulWidget {
  const SearchInstantResults({
    super.key,
    required this.items,
    required this.loading,
    required this.onOpen,
    required this.onSeeAll,
    this.animation = const <MultimediaItem>[],
    this.manga = const <MultimediaItem>[],
    this.characters = const <AnimeWitcherCharacterHit>[],
    this.onOpenCharacter,
    this.firstFocusNode,
    this.onClose,
  });

  /// Closes the floating panel the results sit in; no button without it.
  final VoidCallback? onClose;

  /// Anime: series and films.
  final List<MultimediaItem> items;

  /// The other categories, when every one is searched.
  final List<MultimediaItem> animation;
  final List<MultimediaItem> manga;
  final List<AnimeWitcherCharacterHit> characters;
  final ValueChanged<AnimeWitcherCharacterHit>? onOpenCharacter;

  /// A newer search is on its way; the results shown are the last ones.
  final bool loading;
  final ValueChanged<MultimediaItem> onOpen;
  final VoidCallback onSeeAll;

  /// Focus for the best match, so the arrow keys reach the results.
  final FocusNode? firstFocusNode;

  static bool isMovie(MultimediaItem item) =>
      item.contentType == MultimediaContentType.movie;

  /// The shared name of a series: the title before a colon, or with a
  /// trailing season or part number taken off.
  static String seriesNameOf(String title) {
    var name = title.toLowerCase().split(':').first.trim();
    name = name.replaceAll(
      RegExp(r'\s+(season|part|s)\s*\d+.*$|\s+\d+(st|nd|rd|th)\s+season.*$'),
      '',
    );
    return name.trim();
  }

  /// Other entries of [top]'s series among [items]: sequels, prequels and
  /// films, by name, as the catalogue lists no relations in its search.
  static List<MultimediaItem> sameSeries(
    MultimediaItem top,
    List<MultimediaItem> items,
  ) {
    final name = seriesNameOf(top.title);
    if (name.length < 3) return const <MultimediaItem>[];
    return items
        .where(
          (item) =>
              item.url != top.url && item.title.toLowerCase().contains(name),
        )
        .take(10)
        .toList(growable: false);
  }

  @override
  State<SearchInstantResults> createState() => _SearchInstantResultsState();
}

class _SearchInstantResultsState extends State<SearchInstantResults> {
  _ResultKind _kind = _ResultKind.all;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final series = widget.items
        .where((item) => !SearchInstantResults.isMovie(item))
        .toList(growable: false);
    final movies = widget.items
        .where(SearchInstantResults.isMovie)
        .toList(growable: false);
    final total =
        widget.items.length +
        widget.animation.length +
        widget.manga.length +
        widget.characters.length;

    // The best match comes from the kind shown, anime first.
    final List<MultimediaItem> pool = switch (_kind) {
      _ResultKind.all =>
        widget.items.isNotEmpty
            ? widget.items
            : widget.animation.isNotEmpty
            ? widget.animation
            : widget.manga,
      _ResultKind.series => series,
      _ResultKind.movies => movies,
      _ResultKind.animation => widget.animation,
      _ResultKind.manga => widget.manga,
      _ResultKind.characters => const <MultimediaItem>[],
    };
    final top = pool.isEmpty ? null : pool.first;
    List<MultimediaItem> without(List<MultimediaItem> list) => top == null
        ? list
        : list.where((item) => item.url != top.url).toList(growable: false);
    final related = top == null
        ? const <MultimediaItem>[]
        : SearchInstantResults.sameSeries(top, <MultimediaItem>[
            ...widget.items,
            ...widget.animation,
          ]);

    Widget section(String english, String arabic, List<MultimediaItem> list) =>
        _Section(
          title: appText(context, english: english, arabic: arabic),
          items: list,
          onOpen: widget.onOpen,
        );
    final sections = <Widget>[
      if (_kind == _ResultKind.all) ...[
        if (without(series).isNotEmpty)
          section('Series', 'مسلسلات', without(series)),
        if (without(movies).isNotEmpty)
          section('Movies', 'أفلام', without(movies)),
        if (without(widget.animation).isNotEmpty)
          section('Animation', 'انميشن', without(widget.animation)),
        if (without(widget.manga).isNotEmpty)
          section('Manga', 'مانجا', without(widget.manga)),
      ] else if (_kind != _ResultKind.characters && without(pool).isNotEmpty)
        section('More', 'المزيد', without(pool)),
    ];
    final showCharacters =
        widget.characters.isNotEmpty &&
        (_kind == _ResultKind.all || _kind == _ResultKind.characters);

    Widget tab(_ResultKind kind, String english, String arabic, int count) {
      if (kind != _ResultKind.all && count == 0) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: ChoiceChip(
          key: ValueKey<String>('search-instant-tab-${kind.name}'),
          selected: _kind == kind,
          showCheckmark: false,
          label: Text(
            '${appText(context, english: english, arabic: arabic)}  $count',
          ),
          onSelected: (_) => setState(() => _kind = kind),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(99),
          ),
        ),
      );
    }

    final wide = MediaQuery.sizeOf(context).width >= 760;
    final sectionRows = <Widget>[
      if (wide)
        for (var i = 0; i < sections.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: sections[i]),
                const SizedBox(width: 28),
                Expanded(
                  child: i + 1 < sections.length
                      ? sections[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          )
      else
        for (final list in sections)
          Padding(padding: const EdgeInsets.only(bottom: 18), child: list),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Results stay while the next ones load, under a thin bar.
        SizedBox(
          height: 2,
          child: widget.loading
              ? const LinearProgressIndicator(minHeight: 2)
              : null,
        ),
        Flexible(
          child: ListView(
            key: const ValueKey<String>('search-instant-results'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          tab(_ResultKind.all, 'All', 'الكل', total),
                          tab(
                            _ResultKind.series,
                            'Series',
                            'مسلسلات',
                            series.length,
                          ),
                          tab(
                            _ResultKind.movies,
                            'Movies',
                            'أفلام',
                            movies.length,
                          ),
                          tab(
                            _ResultKind.animation,
                            'Animation',
                            'انميشن',
                            widget.animation.length,
                          ),
                          tab(
                            _ResultKind.manga,
                            'Manga',
                            'مانجا',
                            widget.manga.length,
                          ),
                          tab(
                            _ResultKind.characters,
                            'Characters',
                            'شخصيات',
                            widget.characters.length,
                          ),
                        ],
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey<String>('search-instant-see-all'),
                    onPressed: widget.onSeeAll,
                    icon: const Icon(Icons.manage_search_rounded, size: 18),
                    label: Text(
                      appText(
                        context,
                        english: 'All results',
                        arabic: 'كل النتائج',
                      ),
                    ),
                  ),
                  if (widget.onClose != null) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Esc',
                      child: IconButton(
                        key: const ValueKey<String>('search-instant-close'),
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              if (top != null)
                _TopMatch(
                  item: top,
                  onOpen: widget.onOpen,
                  focusNode: widget.firstFocusNode,
                )
              else if (!showCharacters)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Text(
                    appText(
                      context,
                      english: 'Nothing of this kind',
                      arabic: 'لا يوجد نتائج من هذا النوع',
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              if (related.isNotEmpty && _kind == _ResultKind.all) ...[
                const SizedBox(height: 22),
                _Heading(
                  icon: Icons.auto_awesome_motion_rounded,
                  text: appText(
                    context,
                    english: 'Same series',
                    arabic: 'من نفس السلسلة',
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 176,
                  child: ListView.separated(
                    key: const ValueKey<String>('search-instant-related'),
                    scrollDirection: Axis.horizontal,
                    itemCount: related.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) => _RelatedPoster(
                      item: related[index],
                      onOpen: widget.onOpen,
                    ),
                  ),
                ),
              ],
              if (showCharacters) ...[
                const SizedBox(height: 22),
                _Heading(
                  icon: Icons.person_rounded,
                  text: appText(
                    context,
                    english: 'Characters',
                    arabic: 'شخصيات',
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 116,
                  child: ListView.separated(
                    key: const ValueKey<String>('search-instant-characters'),
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.characters.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, index) => _CharacterBubble(
                      character: widget.characters[index],
                      onOpen: widget.onOpenCharacter,
                    ),
                  ),
                ),
              ],
              if (sectionRows.isNotEmpty) ...[
                const SizedBox(height: 22),
                ...sectionRows,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A character's round picture and name.
class _CharacterBubble extends StatelessWidget {
  const _CharacterBubble({required this.character, this.onOpen});

  final AnimeWitcherCharacterHit character;
  final ValueChanged<AnimeWitcherCharacterHit>? onOpen;

  @override
  Widget build(BuildContext context) {
    final image = character.imageUrl?.trim() ?? '';
    return InkWell(
      key: ValueKey<String>('search-instant-character-${character.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: onOpen == null ? null : () => onOpen!(character),
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            ClipOval(
              child: SizedBox.square(
                dimension: 68,
                child: image.isEmpty
                    ? PosterPlate(seed: character.name)
                    : FallbackPosterImage(
                        imageUrl: image,
                        malId: null,
                        memCacheWidth: 170,
                        placeholder: (_) => PosterPlate(seed: character.name),
                        errorWidget: (_) => PosterPlate(seed: character.name),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              character.name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
        ],
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.item, required this.width, this.radius = 10});

  final MultimediaItem item;
  final double width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: width * 1.45,
        child: FallbackPosterImage(
          imageUrl: item.posterUrl,
          malId: item.artworkLookupMalId,
          title: item.artworkLookupTitle,
          memCacheWidth: (width * 2.5).round(),
          placeholder: (_) => PosterPlate(seed: item.title),
          errorWidget: (_) => PosterPlate(seed: item.title),
        ),
      ),
    );
  }
}

/// "Series • 2002 • ★ 8.4".
String _metaLine(BuildContext context, MultimediaItem item) {
  final parts = <String>[
    SearchInstantResults.isMovie(item)
        ? appText(context, english: 'Movie', arabic: 'فيلم')
        : appText(context, english: 'Series', arabic: 'مسلسل'),
    if (item.year != null && item.year! > 0) '${item.year}',
  ];
  return parts.join('  •  ');
}

class _Score extends StatelessWidget {
  const _Score({required this.item});

  final MultimediaItem item;

  @override
  Widget build(BuildContext context) {
    final score = item.score;
    if (score == null || score <= 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('  •  '),
        const Icon(Icons.star_rounded, size: 16, color: Color(0xFFF5A623)),
        const SizedBox(width: 2),
        Text(score.toStringAsFixed(score == score.roundToDouble() ? 0 : 1)),
      ],
    );
  }
}

class _TopMatch extends StatelessWidget {
  const _TopMatch({required this.item, required this.onOpen, this.focusNode});

  final MultimediaItem item;
  final ValueChanged<MultimediaItem> onOpen;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      key: const ValueKey<String>('search-instant-top'),
      color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        focusNode: focusNode,
        onTap: () => onOpen(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Poster(item: item, width: 72, radius: 10),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText(
                        context,
                        english: 'Top match',
                        arabic: 'أفضل نتيجة',
                      ),
                      style: TextStyle(
                        color: colors.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DefaultTextStyle.merge(
                      style: TextStyle(color: colors.onSurfaceVariant),
                      child: Row(
                        children: [
                          Text(_metaLine(context, item)),
                          _Score(item: item),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                key: const ValueKey<String>('search-instant-open'),
                onPressed: () => onOpen(item),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.onSurface,
                  foregroundColor: colors.surface,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(appText(context, english: 'Open', arabic: 'فتح')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RelatedPoster extends StatelessWidget {
  const _RelatedPoster({required this.item, required this.onOpen});

  final MultimediaItem item;
  final ValueChanged<MultimediaItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onOpen(item),
      child: SizedBox(
        width: 92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Poster(item: item, width: 92, radius: 10),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            Text(
              _metaLine(context, item),
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.items,
    required this.onOpen,
  });

  final String title;
  final List<MultimediaItem> items;
  final ValueChanged<MultimediaItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(text: title),
        const SizedBox(height: 8),
        for (final item in items.take(6))
          InkWell(
            key: ValueKey<String>('search-instant-row-${item.url}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => onOpen(item),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _Poster(item: item, width: 40, radius: 6),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        DefaultTextStyle.merge(
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                          child: Row(
                            children: [
                              Text(_metaLine(context, item)),
                              _Score(item: item),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
