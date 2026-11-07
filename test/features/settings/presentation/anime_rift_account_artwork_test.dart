import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_account_content.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _AccountFixture extends AnimeRiftProvider {
  int reads = 0;

  @override
  bool get isAccountLinked => true;

  @override
  AnimeRiftAccountIdentity get accountIdentity =>
      const AnimeRiftAccountIdentity(id: 'fixture-user');

  @override
  Future<bool> restoreAccountSession() async => true;

  @override
  Future<AnimeRiftAccountProfile> loadAccountProfile() async {
    reads++;
    return const AnimeRiftAccountProfile(
      name: 'Rift Owner',
      avatarUrl: 'https://cdn.example.test/avatar.png',
      coverUrl: 'https://cdn.example.test/cover.jpg',
    );
  }
}

class _Selected extends ActiveProvider {
  _Selected(this.fixture);
  final _AccountFixture fixture;

  @override
  AnimeWitcherProvider build() => fixture;
}

class _Registry extends ExtensionManager {
  _Registry(this.fixture);
  final _AccountFixture fixture;

  @override
  List<AnimeWitcherProvider> build() => [fixture];
}

void main() {
  setUp(() => AnimeRiftLocalAccountScope.activate('fixture-user'));
  tearDown(AnimeRiftLocalAccountScope.reset);

  testWidgets('Rift profile uses Witcher banner and has My Comments entry', (
    tester,
  ) async {
    final fixture = _AccountFixture();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeProviderProvider.overrideWith(() => _Selected(fixture)),
          extensionManagerProvider.overrideWith(() => _Registry(fixture)),
        ],
        child: const MaterialApp(home: AnimeRiftAccountScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(fixture.reads, 1);
    expect(find.text('Rift Owner'), findsOneWidget);
    final avatar = tester.widget<CircleAvatar>(
      find.byKey(const ValueKey('rift-profile-avatar')),
    );
    expect(avatar.foregroundImage, isA<NetworkImage>());
    expect(find.byKey(const ValueKey('rift-profile-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('rift-my-comments')), findsOneWidget);
  });
}
