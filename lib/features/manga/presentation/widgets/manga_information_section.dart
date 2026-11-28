import 'package:flutter/material.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../shared/widgets/details_information_grid.dart';

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
    final raw = _clean(item.syncData?['awState']);
    if (raw != null) return raw;
    return switch (item.status) {
      ShowStatus.ongoing => 'مستمر',
      ShowStatus.completed => 'مكتمل',
      ShowStatus.upcoming => 'قادم',
    };
  }

  @override
  Widget build(BuildContext context) {
    final sync = item.syncData ?? const <String, String>{};
    final entries = <({String label, String value})>[];

    void add(String ar, String en, Object? raw) {
      final value = _clean(raw);
      if (value == null) return;
      entries.add((label: ar, value: value));
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
    return buildDetailsInformationGrid(
      surface: colors.surfaceContainerHighest,
      outline: colors.outlineVariant,
      entries: entries,
      buildCell: (entry) => Column(
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
            maxLines: entry.label == 'العنوان الإنجليزي' ? null : 2,
            overflow: entry.label == 'العنوان الإنجليزي'
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}
