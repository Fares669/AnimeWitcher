import 'dart:async';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_config.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/features/settings/presentation/account_privacy_settings_screen.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:animewitcher/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/account_notifications_button.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/test_fonts.dart';

const _initial = AnimeWitcherProfile(
  documentId: 'offline-profile',
  uid: 'offline-user',
  signInMethod: AnimeWitcherSignInMethod.email,
  userName: 'قارئ محلي',
  email: 'reader@example.invalid',
  bio: 'نبذة تجريبية',
  country: 'الأردن',
  birthYear: '2000',
  providerIds: ['password'],
  privacySettings: AnimeWitcherPrivacySettings(showReviewsToUsers: false),
);
const _frame = ValueKey<String>('account-sync-frame');
const _authError = 'البريد الإلكتروني أو كلمة المرور غير صحيحة.';
const _privacy = 'الخصوصية والمحتوى';
const _changeEmail = 'تغيير البريد الإلكتروني';
const _changePassword = 'تغيير كلمة المرور';
const _signOut = 'تسجيل الخروج';
const _firstName = 'قارئ محلي';
const _nextName = 'قارئ جديد';
const _registered = 'خلي تقدمك وقوائمك معك دائمًا';
const _bell = ValueKey('account-notifications-button');

class _NoCredentials extends SecureTokenStorage {
  _NoCredentials(super.storage);

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) =>
      throw StateError('Unexpected credential write in offline fixture');

  @override
  Future<void> delete(String key) =>
      throw StateError('Unexpected credential delete in offline fixture');

  @override
  Future<void> clearAll() =>
      throw StateError('Unexpected credential reset in offline fixture');
}

class _Account extends AnimeWitcherAccountController {
  final restored = Completer<AnimeWitcherAccountSnapshot>();
  final signOutConfirmation = Completer<void>();
  int signOutRequests = 0;
  int syncs = 0;

  @override
  Future<AnimeWitcherAccountSnapshot> build() => restored.future;

  void publish(AnimeWitcherAccountSnapshot snapshot) {
    state = AsyncData(snapshot);
  }

  void fail() {
    state = AsyncError(
      const AnimeWitcherAccountException('invalid-credentials', 'offline'),
      StackTrace.empty,
    );
  }

  void loading() => state = const AsyncLoading();

  @override
  Future<void> syncNow() async {
    final previous = state.requireValue;
    publish(
      previous.copyWith(lastSyncAt: DateTime.utc(2026, 1, 1, 0, syncs++)),
    );
    ref.read(accountDataRevisionProvider.notifier).bump();
  }

  @override
  Future<void> signOut() async {
    signOutRequests++;
    await signOutConfirmation.future;
    publish(const AnimeWitcherAccountSnapshot());
  }
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
  for (final size in [const Size(412, 915), const Size(1280, 1000)]) {
    testWidgets('Arabic Account skips sync-only rebuilds at ${size.width}', (
      tester,
    ) async {
      final wide = size.width >= 900;
      final configured = AnimeWitcherAccountConfig.firebaseConfigured;
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
      final memory = MemoryStorageService();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeWitcherAccountControllerProvider.overrideWith(() => account),
            accountNotificationCountProvider.overrideWith((ref) async => 3),
            storageServiceProvider.overrideWithValue(memory),
            secureTokenStorageProvider.overrideWithValue(
              _NoCredentials(memory),
            ),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'Readex Pro',
              ),
            ),
            builder: (_, child) => RepaintBoundary(key: _frame, child: child),
            home: const MoreScreen(),
          ),
        ),
      );
      if (!wide) {
        await tester.tap(find.text('تسجيل الدخول أو إنشاء حساب'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      final route = find.byType(AnimeWitcherAccountScreen);
      Finder inside(Finder item) => find.descendant(of: route, matching: item);
      Finder text(String value) => inside(find.text(value));
      Finder tile(String value) =>
          inside(find.widgetWithText(SettingsTile, value));
      final submit = inside(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      final spinner = find.descendant(
        of: submit,
        matching: find.byType(CircularProgressIndicator),
      );
      final badge = inside(find.byKey(_bell));
      expect(route, findsOneWidget);
      expect(spinner, findsOneWidget);
      expect(badge, findsNothing);
      expect(Directionality.of(tester.element(route)), TextDirection.rtl);

      const signedIn = AnimeWitcherAccountSnapshot(profile: _initial);
      account.restored.complete(signedIn);
      await tester.pumpAndSettle();
      expect(text(_firstName), findsOneWidget);
      expect(text('نبذة تجريبية'), findsOneWidget);
      expect(text('الأردن'), findsOneWidget);
      expect(text('2000'), findsOneWidget);
      expect(text('3'), findsOneWidget);
      expect(badge, findsOneWidget);
      expect(text('reader@example.invalid'), findsNothing);
      expect(text('r•••••@example.invalid'), findsOneWidget);

      final ordered = [
        'تعديل الملف الشخصي',
        _privacy,
        'تعليقاتي',
        'مراجعاتي',
        _changeEmail,
        _changePassword,
        _signOut,
        'حذف الحساب',
      ];
      for (var i = 0; i < ordered.length; i++) {
        final row = tile(ordered[i]);
        expect(row, findsOneWidget);
        expect(tester.widget<SettingsTile>(row).onTap != null, configured);
        if (i > 0) {
          expect(
            tester.getTopLeft(row).dy,
            greaterThan(tester.getTopLeft(tile(ordered[i - 1])).dy),
          );
        }
      }

      final masked = await _pixels(tester);
      await tester.tap(inside(find.byTooltip('إظهار البريد')));
      await tester.pumpAndSettle();
      expect(text('reader@example.invalid'), findsOneWidget);
      final revealed = await _pixels(tester);
      expect(revealed, isNot(masked));

      var pageBuilds = 0;
      final previousRebuild = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, built) {
        previousRebuild?.call(element, built);
        if (element.widget is AnimeWitcherAccountScreen) pageBuilds++;
      };
      try {
        for (var i = 0; i < 24; i++) {
          await account.syncNow();
          await tester.pump();
        }
      } finally {
        debugOnRebuildDirtyWidget = previousRebuild;
      }
      expect(account.syncs, 24);
      expect(
        pageBuilds,
        const bool.fromEnvironment('C25_ACCOUNT_STOCK') ? 24 : 0,
      );
      expect(await _pixels(tester), revealed);
      expect(text('reader@example.invalid'), findsOneWidget);

      final next = _initial.copyWith(
        userName: _nextName,
        providerIds: ['local-fixture'],
      );
      account.publish(signedIn.copyWith(profile: next));
      await tester.pumpAndSettle();
      expect(text(_nextName), findsOneWidget);
      expect(text(_changeEmail), findsNothing);
      expect(text(_changePassword), findsNothing);
      expect(badge, findsOneWidget);
      final changed = await _pixels(tester);
      expect(changed, isNot(revealed));

      // Privacy-only changes do not affect this page's pixels, but tapping
      // its settings row must open the new profile preferences.
      account.publish(
        signedIn.copyWith(
          profile: next.copyWith(
            privacySettings: const AnimeWitcherPrivacySettings(
              showFavoritesToUsers: false,
              showReviewsToUsers: false,
              hideEcchiAnime: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(await _pixels(tester), changed);

      if (configured) {
        await Scrollable.ensureVisible(
          tester.element(tile(_privacy)),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(tile(_privacy));
        await tester.pumpAndSettle();
        final privacy = find.byType(AnimeWitcherPrivacySettingsScreen);
        expect(privacy, findsOneWidget);
        expect(
          tester
              .widgetList<Switch>(
                find.descendant(of: privacy, matching: find.byType(Switch)),
              )
              .map((toggle) => toggle.value),
          [false, true, false, true],
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'حفظ التغييرات'),
              )
              .onPressed,
          isNull,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(
          tester.element(tile(_signOut)),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(tile(_signOut));
        await tester.pumpAndSettle();
        expect(find.text('تسجيل الخروج؟'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'خروج'));
        await tester.pumpAndSettle();
        expect(account.signOutRequests, 1);
        expect(tester.widget<SettingsTile>(tile(_signOut)).onTap, isNull);
        expect(badge, findsOneWidget);
        account.signOutConfirmation.complete();
      } else {
        account.publish(const AnimeWitcherAccountSnapshot());
      }

      await tester.pumpAndSettle();
      expect(text(_registered), findsOneWidget);
      expect(spinner, findsNothing);
      expect(badge, findsNothing);
      final guest = await _pixels(tester);
      expect(guest, isNot(changed));

      account.loading();
      await tester.pump();
      expect(spinner, findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      account.fail();
      await tester.pumpAndSettle();
      final error = text(_authError);
      await tester.ensureVisible(error);
      await tester.pumpAndSettle();
      expect(error, findsOneWidget);
      expect(spinner, findsNothing);
      expect(badge, findsNothing);
      expect(tester.widget<FilledButton>(submit).onPressed != null, configured);
      final failed = await _pixels(tester);
      expect(failed, isNot(guest));
      expect(tester.takeException(), isNull);
      // ignore: avoid_print
      print(
        'C25_ACCOUNT ${size.width} builds=$pageBuilds '
        'rgba=$masked,$revealed,$changed,$guest,$failed',
      );
    });
  }
}
