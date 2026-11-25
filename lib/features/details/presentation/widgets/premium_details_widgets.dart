import 'dart:async';

import 'package:flutter/material.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/utils/digit_normalization.dart';
import 'package:animewitcher/shared/widgets/shimmer_placeholder.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetadataRow(firstRow, separatorStyle),
        if (secondRow.isNotEmpty) ...[
          const SizedBox(height: 2),
          _buildMetadataRow(secondRow, separatorStyle),
        ],
        if (hasDetailsRatingsSummary(item)) ...[
          const SizedBox(height: 2),
          DetailsRatingsSummary(item: item),
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
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800, height: 1),
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
          label: 'يوم',
        ),
      if (visibility.showHours)
        _buildCountdownCard(
          context,
          key: const ValueKey('countdown-hours'),
          value: hours,
          label: 'ساعة',
        ),
      if (visibility.showMinutes)
        _buildCountdownCard(
          context,
          key: const ValueKey('countdown-minutes'),
          value: minutes,
          label: 'دقيقة',
        ),
      if (visibility.showSeconds)
        _buildCountdownCard(
          context,
          key: const ValueKey('countdown-seconds'),
          value: seconds,
          label: 'ثانية',
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
