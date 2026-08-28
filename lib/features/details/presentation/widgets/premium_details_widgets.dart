import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/shared/widgets/cards_wrapper.dart';
import 'package:animewitcher/shared/widgets/shimmer_placeholder.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'countdown_unit_visibility.dart';

bool _isArabicDetailsLocale(BuildContext context) => true;

String _detailsText(
  BuildContext context, {
  required String english,
  required String arabic,
}) => arabic;

class MetadataBar extends ConsumerWidget {
  final MultimediaItem item;
  final bool isLoading;
  const MetadataBar({super.key, required this.item, this.isLoading = false});

  String? _clean(dynamic raw) {
    if (raw == null) return null;
    final value = raw.toString().trim();
    if (value.isEmpty || value.toLowerCase() == 'null') return null;
    return value;
  }

  String _normalizeDigits(String value) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const eastern = '۰۱۲۳۴۵۶۷۸۹';
    return value
        .replaceAllMapped(
          RegExp(r'[٠-٩]'),
          (match) => '${arabic.indexOf(match.group(0)!)}',
        )
        .replaceAllMapped(
          RegExp(r'[۰-۹]'),
          (match) => '${eastern.indexOf(match.group(0)!)}',
        );
  }

  String _statusLabel(BuildContext context, Map<String, String> data) {
    final isArabic = _isArabicDetailsLocale(context);
    final raw = _clean(data['awState']);
    late final String label;
    if (raw != null) {
      label = raw;
    } else {
      switch (item.status) {
        case ShowStatus.completed:
          label = isArabic ? 'مكتمل' : 'Completed';
          break;
        case ShowStatus.upcoming:
          label = isArabic ? 'لم يتم بثه بعد' : 'Not yet aired';
          break;
        case ShowStatus.ongoing:
          label = isArabic ? 'مستمر' : 'Ongoing';
          break;
      }
    }

    final normalized = (raw ?? '').toLowerCase();
    final isOngoing =
        normalized == 'مستمر' ||
        normalized == 'ongoing' ||
        normalized == 'airing' ||
        (raw == null && item.status == ShowStatus.ongoing);
    final showTime = _clean(data['awShowTime']);
    if (isOngoing && showTime != null) {
      // AnimeWitcher constructs this as "(show_time) state". The Arabic
      // bidirectional renderer displays it as "state (show_time)".
      return '($showTime) $label';
    }
    return label;
  }

  String? _seasonLabel(BuildContext context, Map<String, String> data) {
    final isArabic = _isArabicDetailsLocale(context);

    String? season;
    for (final candidate in <String?>[
      _clean(data['awSeason']),
      _clean(data['awSeasonName']),
    ]) {
      if (candidate == null) continue;

      final normalized = _normalizeDigits(candidate.toLowerCase());
      if (normalized == 'undefined' ||
          normalized == 'undefined عام 0' ||
          normalized == 'undefined year 0' ||
          normalized == 'عام 0') {
        continue;
      }
      season = candidate;
      break;
    }

    var year = _clean(data['awYear']) ?? item.year?.toString();
    if (year != null) {
      final normalizedYear = _normalizeDigits(year);
      final match = RegExp(r'(?:19|20)[0-9]{2}').firstMatch(normalizedYear);
      if (match != null) {
        year = match.group(0);
      } else if (normalizedYear == '0') {
        year = null;
      }
    }

    final startDate = _clean(data['awStartDate']);
    if (season == null) return year ?? startDate;

    season = season.replaceAll('عام ', '').trim();
    final embeddedYear = RegExp(
      r'(?:19|20)[0-9]{2}',
    ).firstMatch(_normalizeDigits(season))?.group(0);
    final displayYear = year ?? embeddedYear;

    final lower = season.toLowerCase();
    if (isArabic) {
      if (lower.contains('winter')) season = 'شتاء';
      if (lower.contains('spring')) season = 'ربيع';
      if (lower.contains('summer')) season = 'صيف';
      if (lower.contains('fall') || lower.contains('autumn')) season = 'خريف';
    }

    if (displayYear != null && !season.contains(displayYear)) {
      return '$season $displayYear';
    }
    return season;
  }

  String _typeLabel(BuildContext context, Map<String, String> data) {
    final raw = _clean(data['awType']);
    if (raw != null) return raw;

    final isArabic = _isArabicDetailsLocale(context);
    if (item.contentType == MultimediaContentType.movie) {
      return isArabic ? 'فيلم' : 'Movie';
    }
    return isArabic ? 'مسلسل' : 'Series';
  }

  int? _episodeCount(Map<String, String> data) {
    final raw = _clean(data['awEpisodes']);
    if (raw == null) return null;
    final normalized = _normalizeDigits(raw);
    final match = RegExp(r'[0-9]+').firstMatch(normalized);
    final count = match == null ? null : int.tryParse(match.group(0)!);
    if (count == null || count <= 0) return null;
    return count;
  }

  String? _ratingValue(Map<String, String> data) {
    final raw = _clean(data['awMalScore']);
    if (raw == null) return null;
    final normalized = _normalizeDigits(raw);
    final match = RegExp(r'[0-9]+(?:[.][0-9]+)?').firstMatch(normalized);
    final score = match == null ? null : double.tryParse(match.group(0)!);
    if (score == null || score <= 0) return null;
    return score
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'[.]$'), '');
  }

  Widget _buildMetadataRow(List<Widget> entries, TextStyle? separatorStyle) {
    return Wrap(
      spacing: 8,
      runSpacing: 7,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var index = 0; index < entries.length; index++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (index > 0) ...[
                Text('•', style: separatorStyle),
                const SizedBox(width: 8),
              ],
              entries[index],
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = item.syncData ?? const <String, String>{};
    final ageRating = _clean(data['awAge']) ?? _clean(item.contentRating);
    final season = _seasonLabel(context, data);
    final episodeCount = _episodeCount(data);
    final ratingValue = _ratingValue(data);

    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.76),
      fontWeight: FontWeight.w700,
      height: 1.2,
    );
    final separatorStyle = style?.copyWith(
      color: Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
      fontWeight: FontWeight.w600,
    );

    final statusEntry = Text(_statusLabel(context, data), style: style);
    final seasonEntry = season == null ? null : Text(season, style: style);
    final typeEntry = Text(_typeLabel(context, data), style: style);
    final ageEntry = ageRating == null ? null : Text(ageRating, style: style);
    final episodeEntry = episodeCount == null
        ? null
        : _isArabicDetailsLocale(context)
        ? Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.rtl,
            children: [
              Text('$episodeCount', style: style),
              const SizedBox(width: 4),
              Text('حلقة', style: style),
            ],
          )
        : Text('$episodeCount episodes', style: style);
    final ratingEntry = ratingValue == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star_rounded, size: 17, color: Colors.amber.shade600),
              const SizedBox(width: 3),
              Text(ratingValue, style: style),
            ],
          );

    final isArabic = _isArabicDetailsLocale(context);
    final firstRow = <Widget>[
      if (isArabic) ...[
        if (seasonEntry != null) seasonEntry,
        statusEntry,
      ] else ...[
        statusEntry,
        if (seasonEntry != null) seasonEntry,
      ],
    ];
    final secondRow = <Widget>[
      if (isArabic) ...[
        if (ageEntry != null) ageEntry,
        if (episodeEntry != null) episodeEntry,
        typeEntry,
      ] else ...[
        typeEntry,
        if (episodeEntry != null) episodeEntry,
        if (ageEntry != null) ageEntry,
      ],
    ];
    final thirdRow = <Widget>[if (ratingEntry != null) ratingEntry];

    if (firstRow.isEmpty &&
        secondRow.isEmpty &&
        thirdRow.isEmpty &&
        isLoading) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(
          4,
          (_) => ShimmerPlaceholder.rectangular(
            width: 72,
            height: 20,
            borderRadius: 4,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetadataRow(firstRow, separatorStyle),
        if (secondRow.isNotEmpty) ...[
          const SizedBox(height: 4),
          _buildMetadataRow(secondRow, separatorStyle),
        ],
        if (thirdRow.isNotEmpty) ...[
          const SizedBox(height: 4),
          _buildMetadataRow(thirdRow, separatorStyle),
        ],
      ],
    );
  }
}

class NextAiringWidget extends StatefulWidget {
  final NextAiring nextAiring;

  const NextAiringWidget({super.key, required this.nextAiring});

  @override
  State<NextAiringWidget> createState() => _NextAiringWidgetState();
}

class _NextAiringWidgetState extends State<NextAiringWidget> {
  Timer? _timer;
  late Duration _remaining;

  DateTime get _airingDate => DateTime.fromMillisecondsSinceEpoch(
    widget.nextAiring.unixTime * 1000,
    isUtc: true,
  );

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void didUpdateWidget(covariant NextAiringWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nextAiring.unixTime != widget.nextAiring.unixTime) {
      _startCountdown();
    }
  }

  Duration _calculateRemaining() {
    final difference = _airingDate.difference(DateTime.now().toUtc());
    return difference.isNegative ? Duration.zero : difference;
  }

  void _startCountdown() {
    _timer?.cancel();
    _remaining = _calculateRemaining();
    if (_remaining == Duration.zero) return;

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = _calculateRemaining();
      if (!mounted) return;

      setState(() => _remaining = remaining);
      if (remaining == Duration.zero) _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _buildCountdownCard(
    BuildContext context, {
    Key? key,
    required String value,
    required String label,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: key,
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownRow(BuildContext context) {
    final isArabic = _isArabicDetailsLocale(context);
    final visibility = CountdownUnitVisibility.fromRemaining(_remaining);
    final days = _remaining.inDays.toString();
    final hours = _remaining.inHours.remainder(24).toString();
    final minutes = _remaining.inMinutes.remainder(60).toString();
    final seconds = _remaining.inSeconds.remainder(60).toString();

    final cards = <Widget>[
      if (visibility.showDays)
        _buildCountdownCard(
          context,
          key: const ValueKey('countdown-days'),
          value: days,
          label: isArabic ? 'يوم' : 'Days',
        ),
      if (visibility.showHours)
        _buildCountdownCard(
          context,
          key: const ValueKey('countdown-hours'),
          value: hours,
          label: isArabic ? 'ساعة' : 'Hours',
        ),
      if (visibility.showMinutes)
        _buildCountdownCard(
          context,
          key: const ValueKey('countdown-minutes'),
          value: minutes,
          label: isArabic ? 'دقيقة' : 'Minutes',
        ),
      if (visibility.showSeconds)
        _buildCountdownCard(
          context,
          key: const ValueKey('countdown-seconds'),
          value: seconds,
          label: isArabic ? 'ثانية' : 'Seconds',
        ),
    ];

    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          const maxSlots = 4;
          final slotWidth =
              (constraints.maxWidth - gap * (maxSlots - 1)) / maxSlots;

          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                SizedBox(width: slotWidth, child: cards[i]),
              ],
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nextAiring.unixTime <= 0) {
      return const SizedBox.shrink();
    }

    final isArabic = _isArabicDetailsLocale(context);
    final heading = isArabic ? 'الحلقة القادمة بعد' : 'Next episode in';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Directionality(
            textDirection: Directionality.of(context),
            child: Text(
              heading,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          if (_remaining == Duration.zero)
            Text(
              _detailsText(
                context,
                english: 'Airing now',
                arabic: 'تُعرض الآن',
              ),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            )
          else
            _buildCountdownRow(context),
        ],
      ),
    );
  }
}

class CastCarousel extends StatelessWidget {
  final List<Actor> cast;
  final void Function(Actor actor)? onActorTap;
  final VoidCallback? onShowMore;

  const CastCarousel({
    super.key,
    required this.cast,
    this.onActorTap,
    this.onShowMore,
  });

  @override
  Widget build(BuildContext context) {
    final extra = onShowMore == null ? 0 : 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text(
            _detailsText(context, english: 'Cast', arabic: 'طاقم الشخصيات'),
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length + extra,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              if (index >= cast.length) {
                return SizedBox(
                  width: 80,
                  child: InkWell(
                    onTap: onShowMore,
                    borderRadius: BorderRadius.circular(40),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 35,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.16),
                          child: Icon(
                            Icons.more_horiz_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _detailsText(
                            context,
                            english: 'More',
                            arabic: 'المزيد',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final actor = cast[index];
              final content = Column(
                children: [
                  CircleAvatar(
                    radius: 35,
                    backgroundImage: actor.image != null
                        ? CachedNetworkImageProvider(actor.image!)
                        : null,
                    child: actor.image == null
                        ? const Icon(Icons.person)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    actor.name,
                    textDirection: TextDirection.ltr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (actor.role != null)
                    Text(
                      actor.role!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                ],
              );
              return SizedBox(
                width: 80,
                child: onActorTap == null
                    ? content
                    : InkWell(
                        onTap: () => onActorTap!(actor),
                        borderRadius: BorderRadius.circular(12),
                        child: content,
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TrailersSection extends StatelessWidget {
  final List<Trailer> trailers;
  const TrailersSection({super.key, required this.trailers});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text(
            _detailsText(
              context,
              english: 'Trailers & Extras',
              arabic: 'العرض الدعائي',
            ),
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: trailers.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              final trailer = trailers[index];
              return CardsWrapper(
                onTap: () async {
                  final uri = Uri.tryParse(trailer.url);
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  width: 240,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _YoutubeThumbnail(
                        videoId: _extractYoutubeId(trailer.url),
                      ),
                      Container(
                        color: Colors.black26,
                        child: const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _detailsText(
                              context,
                              english: 'Trailer',
                              arabic: 'إعلان',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _extractYoutubeId(String url) {
    // Simple extraction for common patterns
    if (url.contains("v=")) return url.split("v=")[1].split("&")[0];
    if (url.contains("be/")) return url.split("be/")[1].split("?")[0];
    return "";
  }
}

/// Trailer still at the best resolution YouTube has for the video.
///
/// `maxresdefault` only exists for HD uploads, so each size falls back to the
/// next one down instead of showing the placeholder icon.
class _YoutubeThumbnail extends StatelessWidget {
  const _YoutubeThumbnail({required this.videoId});

  static const List<String> _sizes = <String>[
    'maxresdefault',
    'sddefault',
    'hqdefault',
    'mqdefault',
  ];

  final String videoId;

  @override
  Widget build(BuildContext context) => _buildSize(0);

  Widget _buildSize(int index) {
    if (videoId.isEmpty || index >= _sizes.length) {
      return const Center(child: Icon(Icons.movie_rounded));
    }
    return ArtworkDecode(
      paintedWidth: 240,
      builder: (BuildContext context, int? decodeWidth) => CachedNetworkImage(
        imageUrl: 'https://img.youtube.com/vi/$videoId/${_sizes[index]}.jpg',
        fit: BoxFit.cover,
        memCacheWidth: decodeWidth,
        filterQuality: FilterQuality.medium,
        errorWidget: (_, _, _) => _buildSize(index + 1),
      ),
    );
  }
}

class RecommendationsCarousel extends StatelessWidget {
  final List<MultimediaItem> items;
  final void Function(MultimediaItem) onItemTap;
  final String? title;
  final bool showRelationBadge;

  const RecommendationsCarousel({
    super.key,
    required this.items,
    required this.onItemTap,
    this.title,
    this.showRelationBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidth = MultimediaCardLayout.cardWidth(
      context,
      isPortrait: true,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text(
            title ??
                _detailsText(
                  context,
                  english: 'More Like This',
                  arabic: 'المزيد مثل هذا',
                ),
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: MultimediaCardLayout.listHeight(
            cardWidth,
            isPortrait: true,
          ),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: ListView.separated(
              cacheExtent: 2000,
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return MultimediaCard.fromItem(
                  key: ValueKey('${title ?? 'more-like-this'}-rail-$index'),
                  item: item,
                  heroTag: 'related_${item.url}_$index',
                  showRelationBadge: showRelationBadge,
                  onTap: () => onItemTap(item),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
