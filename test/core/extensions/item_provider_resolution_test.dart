import 'package:animewitcher/core/extensions/item_provider_resolution.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage extends StorageService {}

class _Provider extends AnimeWitcherNativeProvider {
  _Provider(this.id) : super(Dio(), SettingsRepository(_Storage()));
  final String id;
  @override
  String get packageName => id;
  @override
  String get name => 'name-$id';
}

void main() {
  test('explicit identity resolves its provider and never falls back', () {
    final original = _Provider('original');
    final active = _Provider('alternate');
    final providers = [original, active];
    expect(resolveItemProvider(providers, 'original', active), same(original));
    expect(
      resolveItemProvider(providers, 'name-original', active),
      same(original),
    );
    expect(resolveItemProvider(providers, 'missing', active), isNull);
    expect(resolveItemProvider(providers, null, active), same(active));
    expect(resolveItemProvider(providers, '', active), same(active));
    expect(resolveItemProvider(providers, 'Remote', active), same(active));
    expect(resolveItemProvider(providers, 'Local', active), same(active));
  });
  test('legacy Witcher records resolve native even when Rift is selected', () {
    final native = _Provider('com.fares669.animewitcher.native');
    final rift = _Provider(animeRiftProviderId);
    for (final id in [null, '', 'Local', 'Remote']) {
      expect(resolveItemProvider([native, rift], id, rift), same(native));
      expect(resolveItemProvider([rift], id, rift), isNull);
    }
  });
}
