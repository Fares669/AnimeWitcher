import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../home/presentation/view_all_screen.dart';

/// Trims empty, unknown, and "?" placeholders out of details metadata.
String? cleanAnimeInfoValue(dynamic raw) {
  if (raw == null) return null;
  final value = raw.toString().trim();
  if (value.isEmpty) return null;
  final lower = value.toLowerCase();
  if (lower == 'null' ||
      lower == 'n/a' ||
      lower == 'none' ||
      lower == 'unknown' ||
      value == '?' ||
      value == '؟') {
    return null;
  }
  return value;
}

/// True when [value] is the app/provider name rather than a real source.
bool isPlaceholderAnimeSource(String value) {
  final compact = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return compact == 'animewitcher' || compact == 'animewitchernative';
}

/// Real manga/light-novel source only — never the app name.
String? displayableAnimeSource({String? syncSource, String? itemSource}) {
  for (final raw in <String?>[syncSource, itemSource]) {
    final cleaned = cleanAnimeInfoValue(raw);
    if (cleaned == null || isPlaceholderAnimeSource(cleaned)) continue;
    return cleaned;
  }
  return null;
}

/// Splits the provider's studio value while preserving order and removing
/// duplicates. AnimeWitcher details may contain one studio or a comma/pipe
/// separated list.
List<String> normalizedAnimeStudios(String? raw) {
  final cleaned = cleanAnimeInfoValue(raw);
  if (cleaned == null) return const <String>[];

  final seen = <String>{};
  final studios = <String>[];
  for (final candidate in cleaned.split(RegExp(r'[,،|]'))) {
    final studio = candidate.trim();
    if (studio.isEmpty) continue;
    if (seen.add(studio.toLowerCase())) studios.add(studio);
  }
  return studios;
}

class AnimeInformationSection extends StatelessWidget {
  final MultimediaItem item;

  /// Optional override used by focused widget tests and embedders. The normal
  /// details screen uses AnimeWitcher's native studio browser automatically.
  final ValueChanged<String>? onStudioTap;

  const AnimeInformationSection({
    super.key,
    required this.item,
    this.onStudioTap,
  });

  String? _read(Map<String, String> data, List<String> keys) {
    for (final key in keys) {
      final value = cleanAnimeInfoValue(data[key]);
      if (value != null) return value;
    }
    return null;
  }

  String? _durationLabel(BuildContext context, Map<String, String> data) {
    final raw = cleanAnimeInfoValue(data['awDuration']);
    int? minutes;
    if (raw != null) {
      final match = RegExp(r'[0-9]+').firstMatch(raw);
      minutes = match == null ? null : int.tryParse(match.group(0)!);
    }
    if (minutes == null || minutes <= 0) minutes = item.duration;
    if (minutes == null || minutes <= 0) return null;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return isArabic ? '$minutes دقيقة' : '$minutes minutes';
  }

  void _openStudioResults(BuildContext context, String studio) {
    final override = onStudioTap;
    if (override != null) {
      override(studio);
      return;
    }

    final provider = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(activeProviderProvider);
    if (provider is! AnimeWitcherNativeProvider) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ViewAllScreen(
          title: studio,
          initialMediaList: const <MultimediaItem>[],
          category: ViewAllCategory.providerContent,
          forcePortrait: true,
          loadPage: (offset) => provider.getStudioPage(
            studio,
            offset: offset,
            limit: provider.viewAllPageSize,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final data = item.syncData ?? const <String, String>{};
    final colors = Theme.of(context).colorScheme;

    _AnimeInfoEntry? entry(
      String ar,
      String en,
      dynamic value, {
      bool showFullValue = false,
    }) {
      final cleaned = cleanAnimeInfoValue(value);
      if (cleaned == null) return null;
      return _AnimeInfoEntry(
        label: isArabic ? ar : en,
        value: cleaned,
        showFullValue: showFullValue,
      );
    }

    final source = displayableAnimeSource(
      syncSource: _read(data, const ['awSource']),
      itemSource: item.source,
    );
    final startDate = _read(data, const ['awStartDate']);
    final endDate = _read(data, const ['awEndDate']);
    final studios = normalizedAnimeStudios(_read(data, const ['awStudio']));

    final entries = <_AnimeInfoEntry?>[
      entry('المصدر', 'Source', source),
      entry('مدة الحلقة', 'Episode duration', _durationLabel(context, data)),
      if (startDate != null || endDate != null) ...[
        _AnimeInfoEntry(
          label: isArabic ? 'بداية العرض' : 'Start date',
          value: startDate ?? '?',
        ),
        _AnimeInfoEntry(
          label: isArabic ? 'نهاية العرض' : 'End date',
          value: endDate ?? '?',
        ),
      ],
      if (studios.isNotEmpty)
        _AnimeInfoEntry(
          label: isArabic ? 'الاستديو' : 'Studio',
          value: studios.join(', '),
          actionValues: studios,
          onValueTap: (studio) => _openStudioResults(context, studio),
        ),
      entry(
        'العنوان الإنجليزي',
        'English title',
        _read(data, const ['awEnglishTitle']),
        showFullValue: true,
      ),
    ].whereType<_AnimeInfoEntry>().toList(growable: false);

    if (entries.isEmpty) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.38),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cellWidth = (constraints.maxWidth - 20) / 2;
            return Wrap(
              spacing: 20,
              runSpacing: 22,
              children: [
                for (final value in entries)
                  SizedBox(
                    width: cellWidth,
                    child: _AnimeInfoValue(entry: value),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AnimeInfoEntry {
  final String label;
  final String value;
  final bool showFullValue;
  final List<String> actionValues;
  final ValueChanged<String>? onValueTap;

  const _AnimeInfoEntry({
    required this.label,
    required this.value,
    this.showFullValue = false,
    this.actionValues = const <String>[],
    this.onValueTap,
  });
}

class _AnimeInfoValue extends StatelessWidget {
  final _AnimeInfoEntry entry;

  const _AnimeInfoValue({required this.entry});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasActions =
        entry.actionValues.isNotEmpty && entry.onValueTap != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          entry.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleSmall?.copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        if (hasActions)
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final value in entry.actionValues)
                Material(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(999),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => entry.onValueTap!(value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium?.copyWith(
                          color: colors.onPrimary,
                          fontWeight: FontWeight.w600,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          )
        else
          Text(
            entry.value,
            maxLines: entry.showFullValue ? null : 2,
            overflow: entry.showFullValue
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.25,
            ),
          ),
      ],
    );
  }
}
