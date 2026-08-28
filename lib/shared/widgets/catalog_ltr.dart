import 'package:flutter/widgets.dart';

/// Lays catalog posters out left-to-right even when the app is Arabic RTL.
///
/// [GridView] and horizontal [ListView] follow [Directionality], so the first
/// card would otherwise sit on the right. Wrapping the catalog keeps index 0
/// on the left on every page.
class CatalogLtr extends StatelessWidget {
  const CatalogLtr({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Directionality(textDirection: TextDirection.ltr, child: child);
  }
}
