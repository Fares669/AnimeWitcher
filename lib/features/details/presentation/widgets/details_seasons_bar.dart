import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/services/anilist_franchise_service.dart';
import 'package:animewitcher/core/services/anizip_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/catalog_label.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';

/// Relations that are part of the same story: the seasons before and after,
/// the work they branch from, and its side stories. Spin-offs, alternative
/// versions and recaps stay in the related tab — they are other shows.
const Set<String> _storyRelations = <String>{
  'PREQUEL',
  'SEQUEL',
  'PARENT',
  'PARENT_STORY',
  'FULL_STORY',
  'SIDE_STORY',
};

/// Which side of the current work a relation belongs on.
int _group(String type) => switch (type) {
  'PREQUEL' || 'PARENT' || 'PARENT_STORY' || 'FULL_STORY' => 0,
  'SEQUEL' => 2,
  _ => 3,
};

/// One stop on the seasons bar.
class SeasonsBarEntry {
  const SeasonsBarEntry({
    required this.item,
    required this.isCurrent,
    required this.label,
  });

  final MultimediaItem item;
  final bool isCurrent;

  /// A short name: `الموسم 2`, `فيلم`, `اوفا`. The catalog titles of one
  /// franchise share most of their words, and cut to fit a chip they read
  /// as the same title twice.
  final String label;
}

bool _isSeries(MultimediaItem item) {
  final type = catalogTypeLabel(item)?.trim() ?? '';
  return type.isEmpty || type == 'مسلسل';
}

final RegExp _seasonInTitle = RegExp(
  r'(\d+)\s*(?:st|nd|rd|th)\s+season|season\s*(\d+)',
  caseSensitive: false,
);
final RegExp _partInTitle = RegExp(
  r'(?:part|cour)\s*(\d+)|(\d+)\s*(?:st|nd|rd|th)\s+(?:part|cour)',
  caseSensitive: false,
);

int? _firstNumber(RegExpMatch? match) {
  if (match == null) return null;
  for (var i = 1; i <= match.groupCount; i++) {
    final value = int.tryParse(match.group(i) ?? '');
    if (value != null) return value;
  }
  return null;
}

/// Short names for a series' seasons, in the order given.
///
/// The number comes from the title when it has one — "2nd Season Part 2"
/// is season two, part two, not a season of its own — and otherwise counts
/// on from the season before. Movies and OVAs in the chain are named as
/// extras and do not move the count.
List<String> seasonsBarLabels(
  List<MultimediaItem> items, {
  String? rootTitle,
  Map<String, int> aniZipSeasonNumbers = const <String, int>{},
}) {
  final root =
      rootTitle ?? items.firstWhere(_isSeries, orElse: () => items.first).title;
  int? lastSeason;
  final seenPerSeason = <int, int>{};
  final labels = <String>[];
  for (final item in items) {
    if (!_isSeries(item)) {
      labels.add(_extraLabel(item, root));
      continue;
    }
    final title = item.title;
    var part = _firstNumber(_partInTitle.firstMatch(title));
    final aniZipSeason = aniZipSeasonNumbers[item.url];
    final season =
        aniZipSeason ??
        _firstNumber(_seasonInTitle.firstMatch(title)) ??
        (part != null ? (lastSeason ?? 1) : (lastSeason ?? 0) + 1);

    final seen = seenPerSeason[season] ?? 0;
    if (aniZipSeason != null && part == null && seen > 0) {
      part = seen + 1;
    }
    seenPerSeason[season] = seen + 1;
    lastSeason = season;
    labels.add(
      part != null ? 'الموسم $season - الجزء $part' : 'الموسم $season',
    );
  }
  return _numberRepeats(labels);
}

List<SeasonsBarEntry> applyAniZipSeasonNumbers(
  List<SeasonsBarEntry> entries,
  Map<String, int> seasonNumbers,
) {
  if (seasonNumbers.isEmpty || entries.isEmpty) return entries;

  final mainIndexes = <int>[];
  final mainItems = <MultimediaItem>[];
  for (var i = 0; i < entries.length; i++) {
    if (!entries[i].label.startsWith('الموسم ')) continue;
    mainIndexes.add(i);
    mainItems.add(entries[i].item);
  }
  if (mainItems.isEmpty) return entries;

  final labels = seasonsBarLabels(
    mainItems,
    rootTitle: mainItems.first.title,
    aniZipSeasonNumbers: seasonNumbers,
  );
  final relabeled = entries.toList(growable: false);
  for (var i = 0; i < mainIndexes.length; i++) {
    final index = mainIndexes[i];
    final entry = entries[index];
    relabeled[index] = SeasonsBarEntry(
      item: entry.item,
      isCurrent: entry.isCurrent,
      label: labels[i],
    );
  }
  return relabeled;
}

/// A movie's or an OVA's name: what its title adds to the franchise name
/// ("Coleus no Yume", "Dead Apple"), or its type when that is all it adds.
String _extraLabel(MultimediaItem item, String rootTitle) {
  final type = catalogTypeLabel(item)?.trim() ?? '';
  final rest = spinOffLabel(item.title, rootTitle);
  if (rest != item.title.trim() && rest.isNotEmpty) return rest;
  return type.isNotEmpty ? type : item.title.trim();
}

/// Numbers labels that appear more than once: فيلم, فيلم → فيلم 1, فيلم 2.
List<String> _numberRepeats(List<String> labels) {
  final totals = <String, int>{};
  for (final label in labels) {
    totals[label] = (totals[label] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return <String>[
    for (final label in labels)
      if ((totals[label] ?? 0) > 1)
        '$label ${seen[label] = (seen[label] ?? 0) + 1}'
      else
        label,
  ];
}

/// The seasons bar for [current]: what came before it, itself, what came
/// after, then its side stories — each group in release order.
///
/// Empty when nothing related is part of the same story, so a single-season
/// show draws no bar at all rather than one chip on its own.
List<SeasonsBarEntry> seasonsBarEntries(
  MultimediaItem current,
  Iterable<MultimediaItem> related,
) {
  final seen = <String>{current.url};
  final picked = <({MultimediaItem item, int group})>[];
  for (final item in related) {
    final type = item.relationType?.trim().toUpperCase() ?? '';
    if (!_storyRelations.contains(type)) continue;
    if (!seen.add(item.url)) continue;
    picked.add((item: item, group: _group(type)));
  }
  if (picked.isEmpty) return const <SeasonsBarEntry>[];

  picked.add((item: current, group: 1));
  final order = <MultimediaItem, int>{
    for (var i = 0; i < picked.length; i++) picked[i].item: i,
  };
  picked.sort((a, b) {
    final byGroup = a.group.compareTo(b.group);
    if (byGroup != 0) return byGroup;
    final byYear = (a.item.year ?? 0).compareTo(b.item.year ?? 0);
    if (byYear != 0) return byYear;
    return order[a.item]!.compareTo(order[b.item]!);
  });
  final labels = seasonsBarLabels([for (final entry in picked) entry.item]);
  return <SeasonsBarEntry>[
    for (var i = 0; i < picked.length; i++)
      SeasonsBarEntry(
        item: picked[i].item,
        isCurrent: identical(picked[i].item, current),
        label: labels[i],
      ),
  ];
}

/// The whole franchise, not just the neighbours.
///
/// A season's own related list only names the seasons either side of it:
/// season one knows season two, and nothing of three. So the chain is
/// walked — each prequel asked for its prequel, each sequel for its sequel
/// — and the side stories hung off every season along the way are
/// collected. [fetchRelated] is how a season's list is asked for;
/// [maxFetches] bounds the whole walk for a long-running series.
///
/// A page whose chain has a parent — an OVA, or a spin-off series such as
/// "Wan!" with seasons of its own — climbs to that parent and walks the
/// main series too. The bar then reads: the main seasons, the spin-off's
/// seasons, then the movies and OVAs.
Future<List<SeasonsBarEntry>> walkSeasonsBar({
  required MultimediaItem current,
  required List<MultimediaItem> related,
  required Future<List<MultimediaItem>> Function(String url) fetchRelated,
  int maxFetches = 12,
}) async {
  final budget = _FetchBudget(maxFetches);
  final own = await _walkChain(
    start: current,
    startRelated: related,
    fetchRelated: fetchRelated,
    budget: budget,
  );

  var main = own.chain;
  final spinOff = <MultimediaItem>[];
  var sides = own.sides;
  var spinOffStarts = own.spinOffs;
  if (own.parent case final parent?) {
    final parentWalk = await _walkChain(
      start: parent,
      fetchRelated: fetchRelated,
      budget: budget,
    );
    main = parentWalk.chain;
    spinOffStarts = parentWalk.spinOffs;
    // A chain of one is the page itself — an OVA or a movie — and sits with
    // the other extras; a longer one is a series of its own.
    if (own.chain.length > 1) {
      spinOff.addAll(own.chain);
      sides = [...parentWalk.sides, ...own.sides];
    } else {
      sides = [...parentWalk.sides, ...own.sides, ...own.chain];
    }
  }

  // Spin-off series the main seasons name — "Wan!" from season one — with
  // their own seasons, so every page of the franchise shows the same bar,
  // not only the spin-off's own pages.
  for (final start in spinOffStarts) {
    if (spinOff.any((item) => item.url == start.url)) continue;
    if (main.any((item) => item.url == start.url)) continue;
    final walk = await _walkChain(
      start: start,
      fetchRelated: fetchRelated,
      budget: budget,
    );
    for (final item in walk.chain) {
      if (!spinOff.any((known) => known.url == item.url)) spinOff.add(item);
    }
  }

  final seen = <String>{};
  MultimediaItem pick(MultimediaItem item) =>
      item.url == current.url ? current : item;
  final mainItems = [
    for (final item in main)
      if (seen.add(item.url)) pick(item),
  ];
  final spinItems = [
    for (final item in spinOff)
      if (seen.add(item.url)) pick(item),
  ];
  final sideItems = [
    for (final item in sides)
      if (seen.add(item.url)) pick(item),
  ];

  final rootTitle = mainItems.isEmpty ? '' : mainItems.first.title;

  sideItems.sort((a, b) => (a.year ?? 0).compareTo(b.year ?? 0));

  final items = [...mainItems, ...spinItems, ...sideItems];
  if (items.length < 2) return const <SeasonsBarEntry>[];

  final labels = <String>[
    ...seasonsBarLabels(mainItems, rootTitle: rootTitle),
    for (final item in spinItems) spinOffLabel(item.title, rootTitle),
    ..._numberRepeats([
      for (final item in sideItems) _extraLabel(item, rootTitle),
    ]),
  ];
  return <SeasonsBarEntry>[
    for (var i = 0; i < items.length; i++)
      SeasonsBarEntry(
        item: items[i],
        isCurrent: items[i].url == current.url,
        label: labels[i],
      ),
  ];
}

/// A spin-off season's name without the franchise name in front of it:
/// "Bungou Stray Dogs Wan! 2" under "Bungou Stray Dogs" reads "Wan! 2".
/// Numbering these as seasons would make "Wan!" the fifth season of the
/// main story, which it is not.
String spinOffLabel(String title, String rootTitle) {
  final root = rootTitle.trim();
  final full = title.trim();
  if (root.isNotEmpty && full.toLowerCase().startsWith(root.toLowerCase())) {
    final rest = full
        .substring(root.length)
        .replaceFirst(RegExp(r'^[\s:：\-–—]+'), '')
        .trim();
    if (rest.isNotEmpty) return rest;
  }
  return full;
}

class _FetchBudget {
  _FetchBudget(this.remaining);
  int remaining;
}

String _relationOf(MultimediaItem item) =>
    item.relationType?.trim().toUpperCase() ?? '';

const Set<String> _parentRelations = <String>{
  'PARENT',
  'PARENT_STORY',
  'FULL_STORY',
};

/// One series' seasons in order, the side stories hung off them, and the
/// first parent any of them names outside the chain.
Future<
  ({
    List<MultimediaItem> chain,
    List<MultimediaItem> sides,
    MultimediaItem? parent,
    List<MultimediaItem> spinOffs,
  })
>
_walkChain({
  required MultimediaItem start,
  List<MultimediaItem>? startRelated,
  required Future<List<MultimediaItem>> Function(String url) fetchRelated,
  required _FetchBudget budget,
}) async {
  final ranks = <String, ({MultimediaItem item, int rank})>{
    start.url: (item: start, rank: 0),
  };
  final sides = <String, MultimediaItem>{};
  final spinOffs = <String, MultimediaItem>{};
  MultimediaItem? parent;

  final queue = <MultimediaItem>[start];
  var first = true;
  while (queue.isNotEmpty) {
    final node = queue.removeAt(0);
    final rank = ranks[node.url]!.rank;
    List<MultimediaItem> list;
    if (first && startRelated != null) {
      list = startRelated;
    } else {
      if (budget.remaining <= 0) continue;
      budget.remaining--;
      try {
        list = await fetchRelated(node.url);
      } catch (_) {
        // One season that will not answer shortens the bar; it does not
        // stop the rest of it being drawn.
        first = false;
        continue;
      }
    }
    first = false;
    for (final r in list) {
      final type = _relationOf(r);
      if (type == 'SEQUEL' || type == 'PREQUEL') {
        if (ranks.containsKey(r.url)) continue;
        sides.remove(r.url);
        ranks[r.url] = (item: r, rank: rank + (type == 'SEQUEL' ? 1 : -1));
        queue.add(r);
      } else if (type == 'SIDE_STORY') {
        if (!ranks.containsKey(r.url)) sides.putIfAbsent(r.url, () => r);
      } else if (_parentRelations.contains(type)) {
        parent ??= r;
      } else if (type == 'SPIN_OFF') {
        spinOffs.putIfAbsent(r.url, () => r);
      }
    }
  }

  // A parent that turned out to be one of this chain's own seasons is not
  // somewhere else to climb to.
  if (parent != null && ranks.containsKey(parent.url)) parent = null;

  final chain = ranks.values.toList()
    ..sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      return (a.item.year ?? 0).compareTo(b.item.year ?? 0);
    });
  return (
    chain: [for (final entry in chain) entry.item],
    sides: sides.values.toList(),
    parent: parent,
    spinOffs: [
      for (final r in spinOffs.values)
        if (!ranks.containsKey(r.url)) r,
    ],
  );
}

int? _aniListMalIdFromUrl(String url) {
  const prefix = 'anilist-mal:';
  if (!url.startsWith(prefix)) return null;
  final id = int.tryParse(url.substring(prefix.length));
  return id != null && id > 0 ? id : null;
}

/// How the bar is drawn; chosen in settings.
enum SeasonsBarStyle {
  /// Wide cards with each season's banner art.
  cards,

  /// Short rounded buttons.
  pills;

  static SeasonsBarStyle fromName(String? raw) {
    for (final value in SeasonsBarStyle.values) {
      if (value.name == raw?.trim()) return value;
    }
    return SeasonsBarStyle.cards;
  }

  String label() => switch (this) {
    SeasonsBarStyle.cards => 'بطاقات بالصور',
    SeasonsBarStyle.pills => 'أزرار قصيرة',
  };
}

final seasonsBarStyleProvider =
    NotifierProvider<SeasonsBarStyleNotifier, SeasonsBarStyle>(
      SeasonsBarStyleNotifier.new,
    );

class SeasonsBarStyleNotifier extends Notifier<SeasonsBarStyle> {
  static const String storageKey = 'seasons_bar_style';

  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  SeasonsBarStyle build() {
    try {
      return SeasonsBarStyle.fromName(_storage.getString(storageKey));
    } catch (_) {
      return SeasonsBarStyle.cards;
    }
  }

  /// Whether a style was ever picked, so the first launch can ask.
  bool get hasStoredChoice {
    try {
      final raw = _storage.getString(storageKey);
      return SeasonsBarStyle.values.any((value) => value.name == raw?.trim());
    } catch (_) {
      // Unreadable storage is not a reason to put a dialog in front of
      // someone on every launch.
      return true;
    }
  }

  void select(SeasonsBarStyle style) {
    state = style;
    try {
      _storage.setString(storageKey, style.name);
    } catch (_) {
      // A lost preference only means the default style next launch.
    }
  }
}

/// A row of the show's seasons, movies and side stories above its episodes.
/// The one on screen is highlighted; the others open their own page.
class DetailsSeasonsBar extends ConsumerStatefulWidget {
  const DetailsSeasonsBar({
    super.key,
    required this.itemUrl,
    required this.current,
    required this.onOpen,
  });

  final String itemUrl;
  final MultimediaItem current;
  final ValueChanged<MultimediaItem> onOpen;

  @override
  ConsumerState<DetailsSeasonsBar> createState() => _DetailsSeasonsBarState();
}

class _DetailsSeasonsBarState extends ConsumerState<DetailsSeasonsBar> {
  List<SeasonsBarEntry>? _walked;
  int _loadGeneration = 0;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant DetailsSeasonsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current.url != widget.current.url ||
        oldWidget.current.artworkLookupMalId !=
            widget.current.artworkLookupMalId) {
      _walked = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final malId = widget.current.artworkLookupMalId;
    if (malId == null) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _walked = const <SeasonsBarEntry>[]);
      }
      return;
    }

    try {
      final aniList = ref.read(aniListFranchiseServiceProvider);
      final root = await aniList.fetchByMalId(malId);
      if (root == null) {
        if (mounted && generation == _loadGeneration) {
          setState(() => _walked = const <SeasonsBarEntry>[]);
        }
        return;
      }

      var graphEntries = await walkSeasonsBar(
        current: root.item,
        related: root.related,
        fetchRelated: (url) async {
          final relatedMalId = _aniListMalIdFromUrl(url);
          if (relatedMalId == null) return const <MultimediaItem>[];
          return (await aniList.fetchByMalId(relatedMalId))?.related ??
              const <MultimediaItem>[];
        },
      );

      final aniZip = AniZipService();
      final seasonPairs = await Future.wait(
        graphEntries.map((entry) async {
          final sync = entry.item.syncData;
          if (sync?['anilistFormat'] != 'TV') return null;
          final aniListId = int.tryParse(
            sync?['anilistId'] ?? sync?['anilist_id'] ?? '',
          );
          if (aniListId == null || aniListId <= 0) return null;
          final mapping = await aniZip
              .fetchSeasonMapping(aniListId)
              .timeout(const Duration(seconds: 2), onTimeout: () => null);
          return mapping == null
              ? null
              : (url: entry.item.url, season: mapping.seasonNumber);
        }),
      );
      final seasonNumbers = <String, int>{
        for (final pair in seasonPairs)
          if (pair != null) pair.url: pair.season,
      };
      graphEntries = applyAniZipSeasonNumbers(graphEntries, seasonNumbers);

      final provider = ref.read(activeProviderProvider);
      if (provider is! AnimeWitcherNativeProvider) {
        if (mounted && generation == _loadGeneration) {
          setState(() => _walked = const <SeasonsBarEntry>[]);
        }
        return;
      }

      final ids = graphEntries
          .map((entry) => entry.item.artworkLookupMalId)
          .whereType<int>()
          .toSet();
      final resolved = await provider.resolveCatalogAnimeByMalIds(ids);
      final matched = <SeasonsBarEntry>[];
      for (final entry in graphEntries) {
        final id = entry.item.artworkLookupMalId;
        final item = entry.isCurrent
            ? widget.current
            : (id == null ? null : resolved[id]);
        if (item == null) continue;
        matched.add(
          SeasonsBarEntry(
            item: item,
            isCurrent: entry.isCurrent,
            label: entry.label,
          ),
        );
      }

      if (!mounted || generation != _loadGeneration) return;
      setState(
        () =>
            _walked = matched.length < 2 ? const <SeasonsBarEntry>[] : matched,
      );
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _walked = const <SeasonsBarEntry>[]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(seasonsBarStyleProvider);
    final entries = _walked ?? const <SeasonsBarEntry>[];
    if (entries.isEmpty) return const SizedBox.shrink();

    final pageBanner = widget.current.bannerUrl?.trim() ?? '';
    final pageArt = pageBanner.isNotEmpty
        ? pageBanner
        : widget.current.posterUrl.trim();

    VoidCallback? tapFor(SeasonsBarEntry entry) =>
        entry.isCurrent ? null : () => widget.onOpen(entry.item);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: switch (style) {
        SeasonsBarStyle.cards => _ScrollStrip(
          height: 96,
          controller: _scroll,
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) => _SeasonCard(
              entry: entries[index],
              onTap: tapFor(entries[index]),
              fallbackImage: pageArt,
            ),
          ),
        ),
        SeasonsBarStyle.pills => _ScrollStrip(
          height: 36,
          controller: _scroll,
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            itemCount: entries.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              if (index == entries.length) {
                return Center(
                  child: Text(
                    '${entries.length} أجزاء',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                );
              }
              return _SeasonPill(
                entry: entries[index],
                onTap: tapFor(entries[index]),
              );
            },
          ),
        ),
      },
    );
  }
}

/// A horizontal row that can be moved with the mouse: arrows at either end
/// while there is more that way, dragging, and the wheel turned sideways.
/// A long franchise ran off the edge of the window with no way to reach the
/// rest from a desktop.
class _ScrollStrip extends StatefulWidget {
  const _ScrollStrip({
    required this.height,
    required this.controller,
    required this.child,
  });

  final double height;
  final ScrollController controller;
  final Widget child;

  @override
  State<_ScrollStrip> createState() => _ScrollStripState();
}

class _ScrollStripState extends State<_ScrollStrip> {
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    final back = position.pixels > position.minScrollExtent + 1;
    final forward = position.pixels < position.maxScrollExtent - 1;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  void _page(int direction) {
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    final target =
        (position.pixels + direction * position.viewportDimension * 0.8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    widget.controller.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Recheck once laid out: a window resized wider may no longer overflow.
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              // The wheel turns the row, so it can be read without a
              // trackpad; vertical page scroll resumes at either end.
              onPointerSignal: (event) {
                if (event is! PointerScrollEvent) return;
                if (!widget.controller.hasClients) return;
                final position = widget.controller.position;
                final delta = event.scrollDelta.dy != 0
                    ? event.scrollDelta.dy
                    : event.scrollDelta.dx;
                final target = (position.pixels + delta).clamp(
                  position.minScrollExtent,
                  position.maxScrollExtent,
                );
                if (target == position.pixels) return;
                GestureBinding.instance.pointerSignalResolver.register(
                  event,
                  (_) => widget.controller.jumpTo(target),
                );
              },
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: PointerDeviceKind.values.toSet(),
                  scrollbars: false,
                ),
                child: widget.child,
              ),
            ),
          ),
          // "Back" is the reading-start edge: the right in Arabic.
          if (_canBack)
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              child: _StripArrow(
                icon: rtl
                    ? Icons.chevron_right_rounded
                    : Icons.chevron_left_rounded,
                onTap: () => _page(-1),
              ),
            ),
          if (_canForward)
            PositionedDirectional(
              end: 0,
              top: 0,
              bottom: 0,
              child: _StripArrow(
                icon: rtl
                    ? Icons.chevron_left_rounded
                    : Icons.chevron_right_rounded,
                onTap: () => _page(1),
              ),
            ),
        ],
      ),
    );
  }
}

class _StripArrow extends StatelessWidget {
  const _StripArrow({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}

/// The caption under a season's name: its type and year.
String _caption(MultimediaItem item) => <String>[
  ?catalogTypeLabel(item),
  if ((item.year ?? 0) > 0) '${item.year}',
].join(' · ');

class _SeasonCard extends StatelessWidget {
  const _SeasonCard({
    required this.entry,
    required this.onTap,
    required this.fallbackImage,
  });

  final SeasonsBarEntry entry;
  final VoidCallback? onTap;

  /// The page's own art, for a season with no picture of its own.
  final String fallbackImage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final item = entry.item;
    final banner = item.bannerUrl?.trim() ?? '';
    final image = banner.isNotEmpty ? banner : item.posterUrl.trim();
    final caption = _caption(item);

    return Tooltip(
      message: item.title,
      child: Semantics(
        button: !entry.isCurrent,
        selected: entry.isCurrent,
        label: '${entry.label}، ${item.title}',
        child: Container(
          width: 190,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: entry.isCurrent ? colors.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Material(
              color: colors.surfaceContainerHighest,
              child: InkWell(
                onTap: onTap,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // The same loader as the page's own banner: when the
                    // catalog has no art for a season it looks one up, which
                    // is how the banner above had a picture while this card,
                    // drawing the catalog URL alone, was left blank.
                    FallbackPosterImage(
                      imageUrl: image,
                      preferBanner: true,
                      malId: item.artworkLookupMalId,
                      title: item.artworkLookupTitle,
                      fit: BoxFit.cover,
                      // Posters are tall; their top is where the faces are.
                      alignment: banner.isNotEmpty
                          ? Alignment.center
                          : const Alignment(0, -0.5),
                      memCacheWidth: 400,
                      placeholder: (_) => const SizedBox.shrink(),
                      // Nothing found anywhere: the page's own art, so the
                      // card is still a picture of this show.
                      errorWidget: (_) => fallbackImage.isEmpty
                          ? const SizedBox.shrink()
                          : CachedNetworkImage(
                              imageUrl: fallbackImage,
                              fit: BoxFit.cover,
                              memCacheWidth: 400,
                              errorWidget: (_, _, _) => const SizedBox.shrink(),
                            ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.05),
                            Colors.black.withValues(alpha: 0.8),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 8,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: entry.isCurrent
                                  ? colors.primary
                                  : Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (caption.isNotEmpty)
                            Text(
                              caption,
                              maxLines: 1,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.75),
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SeasonPill extends StatelessWidget {
  const _SeasonPill({required this.entry, required this.onTap});

  final SeasonsBarEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = entry.isCurrent;
    return Tooltip(
      message: entry.item.title,
      child: Semantics(
        button: !selected,
        selected: selected,
        label: '${entry.label}، ${entry.item.title}',
        child: Material(
          color: selected
              ? colors.primary
              : colors.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(99),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Center(
                child: Text(
                  entry.label,
                  style: TextStyle(
                    color: selected ? colors.onPrimary : colors.onSurface,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
