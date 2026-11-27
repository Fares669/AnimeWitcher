import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/features/more/presentation/coming_soon_screen.dart';
import 'package:animewitcher/features/more/presentation/seasons_screen.dart';
import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

const _ordinary = 'Ordinary fixture';
const _classified = 'Filtered fixture';

class _Selection extends ActiveProvider {
  _Selection(this.initial);

  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider build() => initial;

  void choose(AnimeWitcherProvider provider) => state = provider;
}

class _Catalog extends AnimeWitcherNativeProvider {
  _Catalog(Dio dio, this.identity, bool Function() hidesRestricted)
    : super(
        dio,
        SettingsRepository(MemoryStorageService()),
        isEcchiHidden: hidesRestricted,
      ) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          void respond(Object result) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: result,
            ),
          );
          if (options.uri.path.endsWith('/Settings/constants')) {
            respond(const {
              'fields': {
                'search_settings': {
                  'mapValue': {
                    'fields': {
                      'app_id_v3': {'stringValue': 'FIXTURE'},
                      'api_key': {'stringValue': 'synthetic-search-key'},
                      'browse_api_key': {'stringValue': 'synthetic-browse-key'},
                      'is_search_active': {'booleanValue': true},
                    },
                  },
                },
              },
            });
          } else if (options.uri.path.endsWith('/series/browse')) {
            // Pause the real first-page request until the test settles it.
            loads.add(
              () => respond({
                'hits': [
                  _hit(_ordinary, 'ordinary', ['drama']),
                  _hit(_classified, 'restricted', ['ecchi']),
                ],
                'nbPages': 1,
              }),
            );
          } else {
            handler.reject(DioException(requestOptions: options));
          }
        },
      ),
    );
  }

  final String identity;
  int configs = 0;
  final loads = <void Function()>[];

  @override
  String get packageName => identity;

  @override
  Future<AnimeWitcherSeasonConfig> getSeasonConfig() {
    configs++;
    return super.getSeasonConfig();
  }

  Map<String, dynamic> _hit(String title, String id, List<String> tags) => {
    'objectID': '$identity-$id',
    'name': title,
    'path': '/anime/$identity-$id',
    'tags': tags,
  };

  void finishLatest() => loads.last();
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  for (final (:label, :screen, :isSeason) in [
    (label: 'Seasons', screen: const SeasonsScreen(), isSeason: true),
    (label: 'Coming Soon', screen: const ComingSoonScreen(), isSeason: false),
  ]) {
    testWidgets('$label ignores account revisions unrelated to its filter', (
      tester,
    ) async {
      final firstTransport = Dio();
      final secondTransport = Dio();
      addTearDown(firstTransport.close);
      addTearDown(secondTransport.close);
      var account = const AnimeWitcherAccountSnapshot();
      const cachedProfile = AnimeWitcherProfile(
        documentId: 'fixture',
        uid: 'fixture',
        signInMethod: AnimeWitcherSignInMethod.email,
      );
      bool hidesRestricted() =>
          account.profile?.privacySettings.hideEcchiAnime ?? false;
      final first = _Catalog(firstTransport, 'first', hidesRestricted);
      final second = _Catalog(secondTransport, 'second', hidesRestricted);
      final selection = _Selection(first);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [activeProviderProvider.overrideWith(() => selection)],
          child: MaterialApp(home: screen),
        ),
      );
      await _flush(tester);
      final screenFinder = find.byType(screen.runtimeType);
      final scope = ProviderScope.containerOf(
        tester.element(screenFinder),
        listen: false,
      );
      final revision = scope.read(accountDataRevisionProvider.notifier);
      expect(first.loads, hasLength(1));

      // Separate frames model the immediate restored-account notification and
      // remote validation of the same account while the first page is held.
      account = account.copyWith(profile: cachedProfile);
      revision.bump();
      await _flush(tester);
      account = account.copyWith(lastSyncAt: DateTime.utc(2026));
      revision.bump();
      await _flush(tester);
      debugPrint(
        'C01_CATALOG $label after 2 unrelated revisions: '
        '${first.loads.length} page requests; ${first.configs} config calls',
      );
      expect(first.loads, hasLength(1));
      expect(first.configs, isSeason ? 1 : 0);
      first.finishLatest();
      await tester.pumpAndSettle();
      expect(find.text(_ordinary), findsWidgets);
      expect(find.text(_classified), findsWidgets);

      // Changing the actual discovery setting clears the unfiltered result
      // immediately and obtains a fresh first page.
      account = account.copyWith(
        profile: cachedProfile.copyWith(
          privacySettings: const AnimeWitcherPrivacySettings(
            hideEcchiAnime: true,
          ),
        ),
      );
      revision.bump();
      await _flush(tester);
      expect(find.text(_classified), findsNothing);
      expect(find.byType(AnimePosterShimmer), findsWidgets);
      expect(first.loads, hasLength(2));
      first.finishLatest();
      await tester.pumpAndSettle();
      expect(find.text(_ordinary), findsWidgets);
      expect(find.text(_classified), findsNothing);

      revision.bump();
      await tester.pumpAndSettle();
      expect(first.loads, hasLength(2));

      final refresh = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator).hitTestable(),
      );
      unawaited(refresh.show());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await _flush(tester);
      expect(first.loads, hasLength(3));
      first.finishLatest();
      await tester.pumpAndSettle();

      selection.choose(second);
      await _flush(tester);
      expect(first.loads, hasLength(3));
      expect(second.loads, hasLength(1));
      second.finishLatest();
      await tester.pumpAndSettle();
      expect(find.text(_ordinary), findsWidgets);
      expect(find.text(_classified), findsNothing);

      // Returning to the default preference must also repopulate positions
      // the prior filter omitted (for example after account sign out).
      account = account.copyWith(clearProfile: true);
      revision.bump();
      await _flush(tester);
      expect(second.loads, hasLength(2));
      second.finishLatest();
      await tester.pumpAndSettle();
      expect(find.text(_classified), findsWidgets);
    });
  }
}
