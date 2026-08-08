/// Returns the exact MediaFire share-page URL that should be requested.
///
/// In particular, `/file_premium/` must not be rewritten to `/file/`: MF2 in
/// AnimeWitcher uses premium share links whose download token is exposed only
/// by the premium page.
String mediaFirePageRequestUrl(String rawUrl) {
  final value = rawUrl.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('//')) return 'https:$value';
  if (value.startsWith('/')) return 'https://www.mediafire.com$value';
  if (!value.contains('://')) return 'https://$value';
  return value;
}
