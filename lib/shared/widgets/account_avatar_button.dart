import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/account/account_providers.dart';
import '../../core/extensions/extension_manager.dart';
import '../../core/extensions/providers/anime_rift_provider.dart';
import '../../features/settings/presentation/account_screen.dart';

/// Opens the selected anime provider's account page.
void openAccountScreen(BuildContext context) {
  final provider = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(activeProviderProvider);
  Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => provider is AnimeRiftProvider
          ? const AnimeRiftAccountScreen()
          : const AnimeWitcherAccountScreen(),
    ),
  );
}

/// The account as a round picture, the way Harbor keeps it in the corner of
/// its navigation: the profile photo when there is one, the first letter of
/// the name when there is not, and a plain person when nobody is signed in.
class AccountAvatarButton extends ConsumerWidget {
  const AccountAvatarButton({super.key, required this.onTap, this.size = 36});

  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final activeProvider = ref.watch(activeProviderProvider);
    final rift = activeProvider is AnimeRiftProvider ? activeProvider : null;
    if (rift != null) ref.watch(accountDataRevisionProvider);
    final profile = rift == null
        ? ref.watch(animeWitcherAccountControllerProvider).asData?.value.profile
        : null;
    final photo = profile?.photoUrl?.trim() ?? '';
    final userName = profile?.userName?.trim() ?? '';
    final name = rift == null
        ? (userName.isNotEmpty ? userName : profile?.email?.trim() ?? '')
        : (rift.accountIdentity?.displayName?.trim().isNotEmpty == true
              ? rift.accountIdentity!.displayName!.trim()
              : 'Anime Rift');
    final signedIn = rift?.isAccountLinked ?? (profile != null);
    final initial = name.isEmpty ? '' : name.characters.first.toUpperCase();

    Widget fallback() => signedIn && initial.isNotEmpty
        ? Text(
            initial,
            style: TextStyle(
              color: colors.onPrimary,
              fontSize: size * 0.42,
              fontWeight: FontWeight.w700,
            ),
          )
        : Icon(
            Icons.person_outline_rounded,
            size: size * 0.58,
            color: colors.onSurfaceVariant,
          );

    return Tooltip(
      message: signedIn ? (name.isEmpty ? 'الحساب' : name) : 'تسجيل الدخول',
      child: Semantics(
        button: true,
        label: 'الحساب',
        child: Material(
          key: const ValueKey<String>('account-avatar-button'),
          color: signedIn && photo.isEmpty
              ? colors.primary
              : colors.surfaceContainerHighest,
          shape: CircleBorder(
            side: BorderSide(
              color: signedIn
                  ? colors.primary
                  : colors.onSurfaceVariant.withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.square(
              dimension: size,
              child: photo.isEmpty
                  ? Center(child: fallback())
                  : Image.network(
                      photo,
                      fit: BoxFit.cover,
                      // Decoded at the size it is drawn, not the photo's.
                      cacheWidth:
                          (size * MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                      errorBuilder: (_, _, _) => Center(child: fallback()),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
