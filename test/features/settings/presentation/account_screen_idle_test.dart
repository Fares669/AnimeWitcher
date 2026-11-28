import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_config.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _DeferredAccount extends AnimeWitcherAccountController {
  final restored = Completer<AnimeWitcherAccountSnapshot>();
  final submission = Completer<void>();
  int signIns = 0;

  @override
  Future<AnimeWitcherAccountSnapshot> build() => restored.future;

  void finishRestore() =>
      restored.complete(const AnimeWitcherAccountSnapshot());

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) {
    signIns++;
    return submission.future;
  }
}

final _screen = find.byType(AnimeWitcherAccountScreen);
final _submit = find.descendant(
  of: _screen,
  matching: find.widgetWithText(FilledButton, 'تسجيل الدخول'),
);
final _progress = find.descendant(
  of: _submit,
  matching: find.byType(CircularProgressIndicator),
);
final _forgot = find.descendant(
  of: _screen,
  matching: find.widgetWithText(TextButton, 'نسيت كلمة المرور؟'),
);
final _createMode = find.descendant(
  of: _screen,
  matching: find.text('حساب جديد'),
);
final _fields = find.descendant(of: _screen, matching: find.byType(TextField));

Future<_DeferredAccount> _mount(
  WidgetTester tester, {
  required bool wide,
}) async {
  tester.view.physicalSize = wide
      ? const Size(1600, 1000)
      : const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final account = _DeferredAccount();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeWitcherAccountControllerProvider.overrideWith(() => account),
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
      ],
      child: const MaterialApp(
        locale: Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MoreScreen(),
      ),
    ),
  );
  if (!wide) {
    await tester.tap(find.text('تسجيل الدخول أو إنشاء حساب'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(_screen, findsOneWidget);
  expect(_progress, findsOneWidget);
  expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
  return account;
}

Future<int> _scheduledFrames(WidgetTester tester) async {
  var result = 0;
  for (var i = 0; i < 60; i++) {
    if (tester.binding.hasScheduledFrame) result++;
    await tester.pump(const Duration(milliseconds: 16));
  }
  return result;
}

void main() {
  final configured = AnimeWitcherAccountConfig.firebaseConfigured;

  for (final wide in [true, false]) {
    testWidgets(
      'unconfigured ${wide ? 'wide More' : 'compact Account'} settles idle',
      skip: configured,
      (tester) async {
        final account = await _mount(tester, wide: wide);
        final loadingFrames = await _scheduledFrames(tester);
        expect(loadingFrames, 60);

        account.finishRestore();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final idleFrames = await _scheduledFrames(tester);
        expect(idleFrames, 0);
        expect(_progress, findsNothing);
        expect(
          find.descendant(
            of: _submit,
            matching: find.byIcon(Icons.login_rounded),
          ),
          findsOneWidget,
        );
        expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
        expect(tester.widget<TextButton>(_forgot).onPressed, isNull);
        await tester.tap(_createMode);
        await tester.pump();
        expect(_fields, findsNWidgets(2));
        expect(find.textContaining('مزامنة الحساب غير مهيأة'), findsOneWidget);

        await tester.enterText(_fields.at(0), 'local@example.test');
        await tester.enterText(_fields.at(1), 'fixture-password');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        expect(account.signIns, 0);
      },
    );
  }

  testWidgets(
    'configured account animates only while restoring or submitting',
    skip: !configured,
    (tester) async {
      final account = await _mount(tester, wide: false);
      expect(await _scheduledFrames(tester), 60);
      account.finishRestore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_progress, findsNothing);
      expect(tester.widget<FilledButton>(_submit).onPressed, isNotNull);

      await tester.enterText(_fields.at(0), 'local@example.test');
      await tester.enterText(_fields.at(1), 'fixture-password');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(account.signIns, 1);
      expect(_progress, findsOneWidget);
      expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
      expect(tester.widget<TextButton>(_forgot).onPressed, isNull);
      await tester.tap(_createMode);
      await tester.pump();
      expect(_fields, findsNWidgets(2));
      expect(await _scheduledFrames(tester), 60);

      account.submission.complete();
      await tester.pump();
      expect(_progress, findsNothing);
      expect(tester.widget<TextButton>(_forgot).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(_submit).onPressed, isNotNull);
      await tester.tap(_createMode);
      await tester.pump();
      expect(find.text('إنشاء حساب جديد'), findsOneWidget);
      expect(_fields, findsNWidgets(4));
    },
  );
}
