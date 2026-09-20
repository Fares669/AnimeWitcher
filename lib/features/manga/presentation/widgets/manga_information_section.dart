import 'package:flutter/material.dart';

import '../../../../core/domain/entity/multimedia_item.dart';

class MangaInformationSection extends StatelessWidget {
  const MangaInformationSection({super.key, required this.item});

  final MultimediaItem item;

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final sync = item.syncData ?? const <String, String>{};
    final rows = <(String, String)>[];

    void add(String ar, String en, Object? raw) {
      final value = raw?.toString().trim() ?? '';
      if (value.isEmpty) return;
      rows.add((isArabic ? ar : en, value));
    }

    add('النوع', 'Type', item.catalogType);
    add('السنة', 'Year', item.year);
    add('الحالة', 'Status', _statusLabel(item.status, isArabic));
    add(
      'العنوان الإنجليزي',
      'English title',
      sync['englishTitle'] ?? sync['awEnglishTitle'],
    );

    if (rows.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final row in rows) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      row.$1,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],

          ],
        ),
      ),
    );
  }

  String? _statusLabel(ShowStatus? status, bool isArabic) {
    return switch (status) {
      ShowStatus.ongoing => isArabic ? 'مستمر' : 'Ongoing',
      ShowStatus.completed => isArabic ? 'مكتمل' : 'Completed',
      ShowStatus.upcoming => isArabic ? 'قادم' : 'Upcoming',
      _ => null,
    };
  }
}
