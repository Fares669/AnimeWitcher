import 'dart:convert';

import 'package:html/dom.dart';

/// Reads the first JSON-LD movie or series object in the document.
Map<String, dynamic> readShowJsonLdMetadata(Document document) {
  for (final script in document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    try {
      final value = jsonDecode(script.text);
      if (value is Map<String, dynamic> &&
          const {'TVSeries', 'Movie'}.contains(value['@type'])) {
        return value;
      }
    } on FormatException {
      continue;
    }
  }
  return const {};
}
