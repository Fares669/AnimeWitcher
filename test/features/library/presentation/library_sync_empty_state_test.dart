import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/library/presentation/widgets/bookmarks_tab.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/test_fonts.dart';

const _profile = AnimeWitcherProfile(
  documentId: 'local-fixture',
  uid: 'local-fixture',
  signInMethod: AnimeWitcherSignInMethod.email,
  userName: 'قارئ محلي',
  email: 'reader@example.test',
);
const _signedIn = AnimeWitcherAccountSnapshot(profile: _profile);
const _signedOut = AnimeWitcherAccountSnapshot();
const _frame = ValueKey<String>('c24-library-frame');
const _empty = 'لا توجد أعمال في هذه القائمة بعد';
const _gate = 'سجل الدخول لإضافة الأعمال إلى المفضلة والقوائم';

final class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async => _signedIn;

  void publish(AnimeWitcherAccountSnapshot snapshot) =>
      state = AsyncData(snapshot);
  void loading() => state = const AsyncLoading();
}

final class _Storage extends MemoryStorageService {
  @override
  String getSelectedLibraryCategory() => 'watching';

  @override
  List<MultimediaItem> getLibraryItems({String? category}) => const [];
}

final class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => const [];

  @override
  Future<void> refreshFromServer() async {}
}

Future<String> _pixels(
  WidgetTester tester,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  final image = await boundary.toImage();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return sha256
        .convert(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        )
        .toString();
  } finally {
    image.dispose();
  }
}))!;

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('Library skips account sync-only builds at width ${size.width}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => TestFonts.loadFamily('Readex Pro', [
          'assets/fonts/readex_pro/ReadexPro-Regular.ttf',
          'assets/fonts/readex_pro/ReadexPro-Bold.ttf',
        ]),
      );
      final account = _Account();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeWitcherAccountControllerProvider.overrideWith(() => account),
            storageServiceProvider.overrideWithValue(_Storage()),
            watchHistoryProvider.overrideWith(_History.new),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'Readex Pro',
              ),
            ),
            builder: (context, child) =>
                RepaintBoundary(key: _frame, child: child),
            home: const LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final library = find.byType(LibraryScreen);
      final shelf = find.descendant(
        of: library,
        matching: find.byType(LibraryEmptyState),
      );
      Finder copy(String text) =>
          find.descendant(of: shelf, matching: find.text(text));
      final signedIn = copy(_empty).hitTestable();
      final signedOut = copy(_gate).hitTestable();
      final signIn = copy('تسجيل الدخول').hitTestable();
      expect(signedIn, findsOneWidget);
      expect(signIn, findsNothing);
      expect(Directionality.of(tester.element(signedIn)), TextDirection.rtl);
      final signedInPixels = await _pixels(tester);
      var card = tester.widget<Text>(signedIn);
      var builds = 0;
      for (var i = 0; i < 8; i++) {
        account.publish(
          _signedIn.copyWith(lastSyncAt: DateTime.utc(2026, 1, 1, 0, i)),
        );
        await tester.pump();
        final updated = tester.widget<Text>(signedIn);
        if (!identical(updated, card)) builds++;
        card = updated;
      }
      expect(builds, const bool.fromEnvironment('C24_LIBRARY_STOCK') ? 8 : 0);
      expect(await _pixels(tester), signedInPixels);

      // The loading state still closes the gate, even before explicit sign-out.
      account.loading();
      await tester.pumpAndSettle();
      expect(signedIn, findsNothing);
      expect(signedOut, findsOneWidget);
      expect(signIn, findsOneWidget);
      final signedOutPixels = await _pixels(tester);
      expect(signedOutPixels, isNot(signedInPixels));
      account.publish(_signedOut);
      await tester.pumpAndSettle();
      expect(signedOut, findsOneWidget);
      expect(await _pixels(tester), signedOutPixels);
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      expect(find.byType(AnimeWitcherAccountScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(AnimeWitcherAccountScreen)))
          .pop();
      await tester.pumpAndSettle();
      expect(signedOut, findsOneWidget);
      account.publish(_signedIn);
      await tester.pumpAndSettle();
      expect(signedIn, findsOneWidget);
      expect(await _pixels(tester), signedInPixels);
      // ignore: avoid_print
      print(
        'C24_LIBRARY ${size.width} builds=$builds rgba=$signedInPixels,$signedOutPixels',
      );
    });
  }
}
