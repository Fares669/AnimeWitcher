import 'dart:async';

import 'package:flutter/material.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/utils/digit_normalization.dart';
import 'package:animewitcher/shared/widgets/shimmer_placeholder.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../details_ratings.dart';
import 'countdown_unit_visibility.dart';
import 'details_ratings_row.dart';

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

  String _statusLabel(BuildContext context, Map<String, String> data) {
    final raw = _clean(data['awState']);
    late final String label;
    if (raw != null) {
      label = raw;
    } else {
      switch (item.status) {
        case ShowStatus.completed:
          label = 'مكتمل';
          break;
        case ShowStatus.upcoming:
          label = kNotYetAiredArabicState;
          break;
        case ShowStatus.ongoing:
          label = 'مستمر';
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
    String? season;
    for (final candidate in <String?>[
      _clean(data['awSeason']),
      _clean(data['awSeasonName']),
    ]) {
      if (candidate == null) continue;

      final normalized = normalizeLocalizedDigits(candidate.toLowerCase());
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
      final normalizedYear = normalizeLocalizedDigits(year);
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
    final embeddedYear = RegExp(r'(?:19|20)[0-9]{2}')
        .firstMatch(normalizeLocalizedDigits(season))
        ?.group(0);
    final displayYear = year ?? embeddedYear;

    final lower = season.toLowerCase();

    if (lower.contains('winter')) season = 'شتاء';
    if (lower.contains('spring')) season = 'ربيع';
    if (lower.contains('summer')) season = 'صيف';
    if (lower.contains('fall') || lower.contains('autumn')) season = 'خريف';

    if (displayYear != null && !season.contains(displayYear)) {
      return '$season $displayYear';
    }
    return season;
  }

  String _typeLabel(BuildContext context, Map<String, String> data) {
    final raw = _clean(data['awType']);
    if (raw != null) return raw;

    if (item.contentType == MultimediaContentType.movie) {
      return 'فيلم';
    }
    return 'مسلسل';
  }

  int? _episodeCount(Map<String, String> data) {
    final raw = _clean(data['awEpisodes']);
    if (raw == null) return null;
    final normalized = normalizeLocalizedDigits(raw);
    final match = RegExp(r'[0-9]+').firstMatch(normalized);
    final count = match == null ? null : int.tryParse(match.group(0)!);
    if (count == null || count <= 0) return null;
    return count;
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

    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.76),
      fontWeight: FontWeight.w700,
      height: 1.2,
    );
    final separatorStyle = style?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant
          .withValues(alpha: 0.55),
      fontWeight: FontWeight.w600,
    );

    final statusEntry = Text(_statusLabel(context, data), style: style);
    final seasonEntry = season == null ? null : Text(season, style: style);
    final typeEntry = Text(_typeLabel(context, data), style: style);
    final ageEntry = ageRating == null ? null : Text(ageRating, style: style);
    final episodeEntry = episodeCount == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.rtl,
            children: [
              Text('$episodeCount', style: style),
              const SizedBox(width: 4),
              Text('حلقة', style: style),
            ],
          );

    final firstRow = <Widget>[
      ...[if (seasonEntry != null) seasonEntry, statusEntry],
    ];
    final secondRow = <Widget>[
      ...[
        if (ageEntry != null) ageEntry,
        if (episodeEntry != null) episodeEntry,
        typeEntry,
      ],
    ];

    if (firstRow.isEmpty && secondRow.isEmpty && isLoading) {
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

    // Visibility and the rendered badges share one fresh projection.
    final ratings = AnimeDetailsRatings.fromItem(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetadataRow(firstRow, separatorStyle),
        if (secondRow.isNotEmpty) ...[
          const SizedBox(height: 2),
          _buildMetadataRow(secondRow, separatorStyle),
        ],
        if (ratings.hasSummary) ...[
          const SizedBox(height: 2),
          DetailsRatingsSummary(ratings: ratings),
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

enum _CountdownUnit {
  days('يوم', ValueKey('countdown-days')),
  hours('ساعة', ValueKey('countdown-hours')),
  minutes('دقيقة', ValueKey('countdown-minutes')),
  seconds('ثانية', ValueKey('countdown-seconds'));

  const _CountdownUnit(this.label, this.key);

  final String label;
  final Key key;

  int valueIn(Duration remaining) => switch (this) {
    days => remaining.inDays,
    hours => remaining.inHours.remainder(24),
    minutes => remaining.inMinutes.remainder(60),
    seconds => remaining.inSeconds.remainder(60),
  };
}

class _NextAiringWidgetState extends State<NextAiringWidget> {
  Timer? _timer;
  final _values = [
    for (final _ in _CountdownUnit.values) ValueNotifier<int>(0),
  ];
  late int _visibleCount;

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

  Duration _calculateRemaining(DateTime airingDate) {
    final difference = airingDate.difference(DateTime.now().toUtc());
    return difference.isNegative ? Duration.zero : difference;
  }

  int _updateUnitValues(Duration remaining) {
    final count = CountdownUnitVisibility.visibleCountFor(remaining);
    final units = _CountdownUnit.values;
    for (var index = units.length - count; index < units.length; index++) {
      _values[index].value = units[index].valueIn(remaining);
    }
    return count;
  }

  void _startCountdown() {
    _timer?.cancel();
    final airingDate = DateTime.fromMillisecondsSinceEpoch(
      widget.nextAiring.unixTime * 1000,
      isUtc: true,
    );
    _visibleCount = _updateUnitValues(_calculateRemaining(airingDate));
    if (_visibleCount == 0) return;

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      // Most ticks change only the seconds text, not the heading, labels or
      // card layout. Rebuild the row only when a leading unit disappears.
      final count = _updateUnitValues(_calculateRemaining(airingDate));
      if (count != _visibleCount) setState(() => _visibleCount = count);
      if (count == 0) _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final value in _values) {
      value.dispose();
    }
    super.dispose();
  }

  Widget _buildCountdownCard(BuildContext context, int index) {
    final unit = _CountdownUnit.values[index];
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final valueStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w800,
      height: 1,
    );
    return Container(
      key: unit.key,
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
          ValueListenableBuilder<int>(
            valueListenable: _values[index],
            builder: (context, value, child) => Text(
              value.toString(),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              maxLines: 1,
              style: valueStyle,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            unit.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownRow(BuildContext context) {
    final cards = [
      for (
        var index = _CountdownUnit.values.length - _visibleCount;
        index < _CountdownUnit.values.length;
        index++
      )
        _buildCountdownCard(context, index),
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

    final heading = 'الحلقة القادمة بعد';

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
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          if (_visibleCount == 0)
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
