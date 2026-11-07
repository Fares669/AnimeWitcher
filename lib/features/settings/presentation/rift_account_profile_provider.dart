import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/anime_rift_account_content.dart';
import '../../../core/extensions/providers/anime_rift_provider.dart';
import '../../../core/storage/anime_rift_account_scope.dart';

/// One in-flight profile read shared by the account, side menu and avatar.
/// No Rift artwork can survive a provider/account switch.
final riftAccountProfileProvider = FutureProvider.autoDispose
    .family<AnimeRiftAccountProfile?, String>((ref, expectedAccount) async {
      final provider = ref.watch(activeProviderProvider);
      if (provider is! AnimeRiftProvider ||
          !await provider.restoreAccountSession()) {
        return null;
      }
      final account = AnimeRiftLocalAccountScope.accountHash;
      if (account == null || account != expectedAccount) return null;
      final profile = await provider.loadAccountProfile();
      if (!ref.mounted ||
          AnimeRiftLocalAccountScope.accountHash != expectedAccount ||
          !identical(ref.read(activeProviderProvider), provider)) {
        return null;
      }
      return profile;
    });
