import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

class _AccountStorage extends MemoryStorageService {
  @override
  String? getString(String key) => settings[key] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'unreadable secure session restores signed out and preserves local data',
    () async {
      final storage = _AccountStorage();
      storage.settings['download_sentinel'] = '/offline/episode.mp4';
      storage.settings['settings_sentinel'] = 'keep';
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        throw PlatformException(code: 'BAD_DECRYPT', message: 'Legacy cipher');
      });
      final service = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );

      final restored = await service.restoreCachedSession().timeout(
        const Duration(seconds: 1),
      );

      expect(restored.isSignedIn, isFalse);
      expect(calls, ['read']);
      expect(storage.getString('download_sentinel'), '/offline/episode.mp4');
      expect(storage.getString('settings_sentinel'), 'keep');
    },
  );
}
