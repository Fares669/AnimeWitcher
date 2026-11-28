import 'package:flutter/widgets.dart';

/// The two-column metadata grid shared by anime and manga details.
///
/// Cells are built inside the layout callback, using the available width.
Widget buildDetailsInformationGrid<T>({
  required Color surface,
  required Color outline,
  required List<T> entries,
  required Widget Function(T) buildCell,
}) => DecoratedBox(
  decoration: BoxDecoration(
    color: surface.withValues(alpha: 0.55),
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: outline.withValues(alpha: 0.38)),
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
              SizedBox(width: cellWidth, child: buildCell(entry)),
          ],
        );
      },
    ),
  ),
);
