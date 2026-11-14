import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/features/player/presentation/widgets/skip_segment_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/shared/widgets/live_previews.dart';

import '../../support/memory_storage_service.dart';

/// Remembers the taskbar lists, with manga hidden until the saved order
/// places it, as the real storage does.
class _TaskbarStorage extends MemoryStorageService {
  List<String> order = <String>[];
  Set<String> hidden = <String>{};

  @override
  List<String> getTaskbarOrder() => order;

  @override
  Set<String> getHiddenTaskbarItems() =>
      order.contains('manga') ? hidden : <String>{...hidden, 'manga'};

  @override
  Future<void> setTaskbarOrder(List<String> value) async =>
      order = List<String>.of(value);

  @override
  Future<void> setHiddenTaskbarItems(Set<String> value) async =>
      hidden = Set<String>.of(value);

  // Finishing the setup saves every choice, not only the tab.
  final Map<String, String> strings = <String, String>{};
  final Map<String, Object?> player = <String, Object?>{};

  @override
  String? getString(String key) => strings[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      strings.remove(key);
    } else {
      strings[key] = value;
    }
  }

  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (player[key] ?? defaultValue) as T?;

  @override
  Future<void> setPlayerSetting(String key, dynamic value) async =>
      player[key] = value;
}

class _RiftAccountClient extends AnimeRiftApiClient {
  @override
  bool get isAccountLinked => true;

  @override
  AnimeRiftAccountIdentity? get accountIdentity =>
      const AnimeRiftAccountIdentity(
        id: 'rift-account',
        displayName: 'Rift account',
      );

  @override
  Future<bool> restoreAccountSession() async => true;
}

class _RiftSelected extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() =>
      AnimeRiftProvider(client: _RiftAccountClient());
}

void main() {
  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    StorageService? storage,
    bool riftSelected = false,
  }) async {
    // The window itself, not only the drawing surface: the screen decides
    // between its wide and narrow layouts from the window's size.
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (riftSelected)
            activeProviderProvider.overrideWith(_RiftSelected.new),
          storageServiceProvider.overrideWithValue(
            storage ?? MemoryStorageService(),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          supportedLocales: [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: FirstRunSetupScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  /// Walks every step with Next, checking each one draws cleanly, and
  /// returns the step titles seen.
  Future<List<String>> walkSteps(WidgetTester tester) async {
    const titles = ['المظهر', 'صفحة الأنمي', 'المشغل', 'الحساب'];
    final seen = <String>[];
    for (var guard = 0; guard < 5; guard++) {
      expect(tester.takeException(), isNull);
      for (final title in titles) {
        if (find.text(title).evaluate().isNotEmpty) seen.add(title);
      }
      if (find.text('ابدأ المشاهدة').evaluate().isNotEmpty) break;
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
    }
    return seen;
  }

  testWidgets('every step draws side by side on a wide window', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    final seen = await walkSteps(tester);
    expect(seen, containsAllInOrder(['المظهر', 'صفحة الأنمي', 'المشغل']));
  });

  testWidgets('account setup shows only the selected Rift identity', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800), riftSelected: true);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Rift account'), findsOneWidget);
    expect(find.text('حساب AnimeWitcher'), findsNothing);
    expect(find.textContaining('تسجيل الدخول غير متاح'), findsNothing);
  });

  testWidgets('every step draws stacked on a phone-sized window', (
    tester,
  ) async {
    await pumpAt(tester, const Size(390, 844));
    // Home is drawn as an upright phone, not a wide window, under the
    // choices.
    await tester.scrollUntilVisible(
      find.byType(HomeLayoutPreview),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final home = tester.getSize(find.byType(HomeLayoutPreview));
    expect(home.height, greaterThan(home.width));
    // A phone has no layout to pick: it has the bar and the side menu.
    expect(find.text('شكل التطبيق'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('المظهر'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );

    final seen = await walkSteps(tester);
    expect(seen, containsAllInOrder(['المظهر', 'المشغل', 'الحساب']));
    // The seasons bar is only on the wide anime page.
    expect(seen, isNot(contains('صفحة الأنمي')));
  });

  testWidgets('a desktop starts with the layout step, all three drawn', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpAt(tester, const Size(1280, 800));
      expect(find.text('المظهر'), findsOneWidget);
      expect(find.text('شكل التطبيق'), findsOneWidget);
      for (final label in ['شريط جانبي', 'شريط علوي', 'الشريط السفلي']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
      final seen = await walkSteps(tester);
      expect(seen, containsAllInOrder(['المظهر', 'صفحة الأنمي', 'المشغل']));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Anime4K turns on, offers its models, and fills the frame', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800));
    while (find.text('المشغل').evaluate().isEmpty) {
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
    }
    // The picture fills the preview frame, on and off.
    Size pictureSize() => tester.getSize(find.byType(Image).first);
    expect(pictureSize().width, greaterThan(400));

    await tester.tap(find.text('Anime4K · تحسين الصورة'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('A + A'), findsOneWidget);
    expect(find.textContaining('Anime4K · A'), findsOneWidget);
    expect(pictureSize().width, greaterThan(400));

    await tester.tap(find.text('C'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Anime4K · C'), findsOneWidget);
  });

  testWidgets('the preview follows the choices', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    while (find.text('المشغل').evaluate().isEmpty) {
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
    }
    // Skipping is on by default: the button shows, the automatic options
    // are offered.
    expect(find.byType(SkipPill), findsOneWidget);
    expect(find.text('تخطي المقدمة تلقائيًا'), findsOneWidget);

    // Off: no button, and the automatic options go with it.
    await tester.tap(find.text('تخطي المقدمة والخاتمة'));
    await tester.pumpAndSettle();
    expect(find.byType(SkipPill), findsNothing);
    expect(find.text('تخطي المقدمة تلقائيًا'), findsNothing);

    await tester.tap(find.text('تخطي المقدمة والخاتمة'));
    await tester.pumpAndSettle();
    expect(find.byType(SkipPill), findsOneWidget);

    await tester.tap(find.text('تخطي المقدمة تلقائيًا'));
    await tester.pumpAndSettle();
    // Automatic: no button — the real player shows none — and a note
    // under the preview says why.
    expect(find.byType(SkipPill), findsNothing);
    expect(find.textContaining('مع التخطي التلقائي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the account step is always there, last', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    final seen = await walkSteps(tester);
    expect(seen.last, 'الحساب');
  });

  testWidgets('the manga switch in setup takes effect when setup finishes', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800), storage: _TaskbarStorage());
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FirstRunSetupScreen)),
    );
    final before = container.read(mangaHasOwnTabProvider);

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('setup-manga-own-tab')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('setup-manga-own-tab')));
    await tester.pumpAndSettle();
    // Nothing changes until the setup is finished.
    expect(container.read(mangaHasOwnTabProvider), before);

    for (var guard = 0; guard < 5; guard++) {
      if (find.text('ابدأ المشاهدة').evaluate().isNotEmpty) break;
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('ابدأ المشاهدة'));
    await tester.pumpAndSettle();

    expect(container.read(mangaHasOwnTabProvider), !before);
  });

  testWidgets('turning the manga tab on shows it on the preview bar', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800), storage: _TaskbarStorage());
    final preview = find.byType(HomeLayoutPreview);
    final manga = find.descendant(
      of: preview,
      matching: find.byIcon(Icons.menu_book_rounded),
    );
    final before = manga.evaluate().length;

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('setup-manga-own-tab')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('setup-manga-own-tab')));
    await tester.pumpAndSettle();

    // Switched the other way from how it started: the icon came or went.
    expect(manga.evaluate().length, isNot(before));
  });
}
