const String mangaImageUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Safari/537.36';

Map<String, String> mangaImageRequestHeaders(Map<String, String> headers) {
  if (headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
    return headers;
  }
  return <String, String>{...headers, 'User-Agent': mangaImageUserAgent};
}
