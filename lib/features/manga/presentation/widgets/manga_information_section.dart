import 'package:flutter/material.dart';

import '../../../../core/domain/entity/multimedia_item.dart';

class MangaInformationSection extends StatelessWidget {
  const MangaInformationSection({super.key, required this.item});

  final MultimediaItem item;

  String? _clean(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return null;
    final normalized = value.toLowerCase();
    if (normalized == 'null' ||
        normalized == 'n/a' ||
        normalized == 'none' ||
        normalized == 'unknown' ||
        value == '?' ||
        value == '؟') {
      return null;
    }
    return value;
  }

  String? _statusLabel(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final raw = _clean(item.syncData?['awState']);
    if (raw != null) return raw;
    return switch (item.status) {
      ShowStatus.ongoing => isArabic ? 'مستمر' : 'Ongoing',
      ShowStatus.completed => isArabic ? 'مكتمل' : 'Completed',
      ShowStatus.upcoming => isArabic ? 'قادم' : 'Upcoming',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final sync = item.syncData ?? const <String, String>{};
    final entries = <({String label, String value})>[];

    void add(String ar, String en, Object? raw) {
      final value = _clean(raw);
      if (value == null) return;
      entries.add((label: isArabic ? ar : en, value: value));
    }

    add('النوع', 'Type', item.catalogType ?? sync['awType']);
    add('السنة', 'Year', item.year ?? sync['awYear']);
    add('الحالة', 'Status', _statusLabel(context));
    add(
      'العنوان الإنجليزي',
      'English title',
      sync['englishTitle'] ?? sync['awEnglishTitle'],
    );

    if (entries.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
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
              children: <Widget>[
                for (final entry in entries)
                  SizedBox(
                    width: cellWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
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
                        Text(
                          entry.value,
                          maxLines: entry.label ==
                                  (isArabic
                                      ? 'العنوان الإنجليزي'
                                      : 'English title')
                              ? null
                              : 2,
                          overflow: entry.label ==
                                  (isArabic
                                      ? 'العنوان الإنجليزي'
                                      : 'English title')
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
