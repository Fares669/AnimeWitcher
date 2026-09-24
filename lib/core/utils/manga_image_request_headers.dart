const String mangaImageUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Mobile) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Mobile Safari/537.36';

Map<String, String> mangaImageRequestHeaders(Map<String, String> source) {
  final hasUserAgent = source.keys.any(
    (key) => key.toLowerCase() == 'user-agent',
  );
  if (hasUserAgent) return Map<String, String>.from(source);
  return <String, String>{...source, 'User-Agent': mangaImageUserAgent};
}
