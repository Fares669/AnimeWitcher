import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production background gateway exposes manga chapter transport', () {
    final gateway = PackageBackgroundDownloaderGateway(
      initializePackage: () async {},
    );

    expect(gateway, isA<MangaChapterGatewayV2>());
  });
}
