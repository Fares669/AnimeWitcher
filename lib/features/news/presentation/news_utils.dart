import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/domain/entity/multimedia_item.dart';

/// Landscape news list shows two articles per row; portrait stays one.
int newsListColumnCount(Size size) {
  if (!size.width.isFinite || !size.height.isFinite) return 1;
  return size.width > size.height ? 2 : 1;
}

/// Card height so two landscape tiles fill the viewport, like the
/// current full-width card but side by side.
double newsListLandscapeMainAxisExtent({
  required Size size,
  required EdgeInsets padding,
  double toolbarHeight = kToolbarHeight,
}) {
  const verticalGridPadding = 12.0 + 28.0;
  final available =
      size.height - padding.vertical - toolbarHeight - verticalGridPadding;
  return available.clamp(188.0, 420.0);
}

Future<void> openNewsUrl(NewsItem item) async {
  final rawUrl = item.newsUrl?.trim();
  if (rawUrl == null || rawUrl.isEmpty) return;

  final uri = Uri.tryParse(rawUrl);
  if (uri == null || !uri.hasScheme) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
