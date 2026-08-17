import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/utils/image_fallbacks.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';
import 'package:skystream/shared/widgets/shimmer_placeholder.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:skystream/shared/widgets/thumbnail_error_placeholder.dart';
import 'package:skystream/core/utils/responsive_breakpoints.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'details_layout_widgets.dart';

bool _isArabicDetailsLocale(BuildContext context) =>
    Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

String _detailsText(
  BuildContext context, {
  required String english,
  required String arabic,
}) => _isArabicDetailsLocale(context) ? arabic : english;

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

  Widget _buildMetadataRow(
    List<Widget> entries,
    TextStyle? separatorStyle,
  ) {
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
      color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
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
              Icon(
                Icons.star_rounded,
                size: 17,
                color: Colors.amber.shade600,
              ),
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
    final thirdRow = <Widget>[
      if (ratingEntry != null) ratingEntry,
    ];

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
    required String value,
    required String label,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.45)),
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

    final days = _remaining.inDays.toString();
    final hours = _remaining.inHours.remainder(24).toString().padLeft(2, '0');
    final minutes = _remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = _remaining.inSeconds.remainder(60).toString().padLeft(2, '0');

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
              _detailsText(context, english: 'Airing now', arabic: 'تُعرض الآن'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            )
          else
            Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                children: [
                  _buildCountdownCard(
                    context,
                    value: days,
                    label: isArabic ? 'يوم' : 'Days',
                  ),
                  const SizedBox(width: 8),
                  _buildCountdownCard(
                    context,
                    value: hours,
                    label: isArabic ? 'ساعة' : 'Hours',
                  ),
                  const SizedBox(width: 8),
                  _buildCountdownCard(
                    context,
                    value: minutes,
                    label: isArabic ? 'دقيقة' : 'Minutes',
                  ),
                  const SizedBox(width: 8),
                  _buildCountdownCard(
                    context,
                    value: seconds,
                    label: isArabic ? 'ثانية' : 'Seconds',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class CastCarousel extends StatelessWidget {
  final List<Actor> cast;
  const CastCarousel({super.key, required this.cast});

  @override
  Widget build(BuildContext context) {
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
            itemCount: cast.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              final actor = cast[index];
              return SizedBox(
                width: 80,
                child: Column(
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
                      CachedNetworkImage(
                        imageUrl:
                            "https://img.youtube.com/vi/${_extractYoutubeId(trailer.url)}/mqdefault.jpg",
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            const Center(child: Icon(Icons.movie_rounded)),
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

  String? _relationBadgeLabel(BuildContext context, MultimediaItem item) {
    final explicit = item.relationLabel?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    // Compatibility with the current WitAnime extension version,
    // which stores the relation label in description.
    final legacy = item.description?.trim();
    const knownLegacyLabels = <String>{
      'previous',
      'next',
      'movie',
      'ova',
      'ona',
      'special',
      'side story',
      'spin-off',
      'alternative',
      'summary',
      'parent',
      'compilation',
      'adaptation',
      'related',
      'السابق',
      'التالي',
      'فيلم',
      'أوفا',
      'قصة جانبية',
      'عمل مشتق',
      'نسخة بديلة',
      'ملخص',
      'العمل الأصلي',
      'تجميعة',
      'اقتباس مرتبط',
      'عمل مرتبط',
      'عمل مرتبط بالشخصيات',
      'موسم سابق',
      'موسم لاحق',
    };
    if (legacy != null && knownLegacyLabels.contains(legacy.toLowerCase())) {
      return legacy;
    }

    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final relation = item.relationType?.trim().toUpperCase();

    switch (relation) {
      case 'PREQUEL':
        return isArabic ? 'السابق' : 'Previous';
      case 'SEQUEL':
        return isArabic ? 'التالي' : 'Next';
      case 'SIDE_STORY':
        return isArabic ? 'قصة جانبية' : 'Side Story';
      case 'SPIN_OFF':
        return isArabic ? 'عمل مشتق' : 'Spin-off';
      case 'ALTERNATIVE':
        return isArabic ? 'نسخة بديلة' : 'Alternative';
      case 'SUMMARY':
        return isArabic ? 'ملخص' : 'Summary';
      case 'PARENT':
        return isArabic ? 'العمل الأصلي' : 'Parent';
      case 'COMPILATION':
        return isArabic ? 'تجميعة' : 'Compilation';
      case 'ADAPTATION':
        return isArabic ? 'اقتباس' : 'Adaptation';
    }

    if (item.contentType == MultimediaContentType.movie) {
      return isArabic ? 'فيلم' : 'Movie';
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isLarge = context.isDesktop || context.isTv;
    final cardWidth = isLarge ? 180.0 : 110.0;
    final listHeight = isLarge ? 310.0 : 180.0;

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
          height: listHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              final relationBadge = showRelationBadge
                  ? _relationBadgeLabel(context, item)
                  : null;

              return CardsWrapper(
                onTap: () => onItemTap(item),
                child: SizedBox(
                  width: cardWidth,
                  height: listHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          imageUrl:
                              AppImageFallbacks.poster(
                                item.posterUrl,
                                label: item.title,
                              ) ??
                              '',
                          fit: BoxFit.cover,
                          width: cardWidth,
                          errorWidget: (_, _, _) =>
                              ThumbnailErrorPlaceholder(label: item.title),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: isLarge ? 106 : 78,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.82),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (relationBadge != null)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: cardWidth - 16,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black38,
                                    blurRadius: 4,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                relationBadge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onPrimary,
                                  fontSize: isLarge ? 12 : 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.start,
                            style: (isLarge
                                    ? Theme.of(context).textTheme.bodyMedium
                                    : Theme.of(context).textTheme.bodySmall)
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  shadows: const [
                                    Shadow(
                                      color: Colors.black,
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
