import 'package:dio/dio.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../storage/provider_local_library.dart';
import '../base_provider.dart';

/// No access credentials or unofficial device identity are embedded here.
/// Replace this fail-closed adapter only when an authorized API is available.
class AnimeRiftProvider extends AnimeWitcherProvider {
  @override
  String get packageName => animeRiftProviderId;
  @override
  String get name => 'Anime Rift';
  @override
  String get mainUrl => 'https://anime-rift.com';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      Future.error(const AnimeRiftAccessUnavailable());

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => Future.error(const AnimeRiftAccessUnavailable());

  @override
  Future<MultimediaItem> getDetails(String url) =>
      Future.error(const AnimeRiftAccessUnavailable());

  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      Future.error(const AnimeRiftAccessUnavailable());
}

class AnimeRiftAccessUnavailable implements Exception {
  const AnimeRiftAccessUnavailable();

  @override
  String toString() =>
      'خدمة Anime Rift غير متاحة حتى تتهيأ طريقة الاتصال الرسمية.';
}
