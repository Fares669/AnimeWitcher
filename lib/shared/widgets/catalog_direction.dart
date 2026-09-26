import 'package:flutter/widgets.dart';

/// Lays catalog posters out in the app's reading direction.
///
/// In Arabic the first poster sits on the right and the grid fills toward
/// the left, as the home rails already do; in English it starts on the
/// left. Grids used to be pinned left-to-right in every language, which put
/// an Arabic page's first poster on the side it is read last.
///
/// Kept as one wrapper so every catalog page agrees, and so the direction
/// can be decided in one place.
class CatalogDirection extends StatelessWidget {
  const CatalogDirection({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
