import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/coming_soon_screen.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/features/more/presentation/more_sidebar_shell.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/account_notifications_button.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
// MoreScreen uses the application's existing Material compatibility API.
// ignore: deprecated_member_use
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
const _frame = ValueKey<String>('c22-more-account-frame');
const _comingSoon = 'القادم قريبًا';

class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot(profile: _profile);

  void publish(AnimeWitcherAccountSnapshot snapshot) =>
      state = AsyncData(snapshot);

  void loading() => state = const AsyncLoading();
}

class _Selection extends ActiveProvider {
  _Selection(this.initial);
  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider build() => initial;

  void publish(AnimeWitcherProvider provider) => state = provider;
}

class _Native extends AnimeWitcherNativeProvider {
  _Native(Dio dio, StorageService storage)
    : super(dio, SettingsRepository(storage));

  bool restricted = false;
  final offsets = <int>[];

  @override
  bool get hidesEcchiInDiscovery => restricted;

  @override
  Future<ProviderMediaPage> getUpcomingPage({int offset = 0}) async {
    offsets.add(offset);
    return _page(
      restricted ? 'من القائمة المصفاة' : 'من المصدر المحلي',
      offset,
    );
  }
}

class _Witanime extends WitanimeProvider {
  _Witanime() : super((_, {cancelToken}) async => throw StateError('offline'));

  final offsets = <int>[];

  @override
  Future<ProviderMediaPage> getUpcomingPage({int offset = 0}) async {
    offsets.add(offset);
    return _page('من ويت أنمي', offset);
  }
}

ProviderMediaPage _page(String label, int offset) => ProviderMediaPage(
  items: [
    for (var i = 0; i < 36; i++)
      MultimediaItem(
        title: '$label $i',
        url: 'https://upcoming.invalid/$label/$i',
        posterUrl: '',
        status: ShowStatus.upcoming,
        year: 2026,
      ),
  ],
  nextOffset: offset + 36,
  hasMore: false,
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 48));
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
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'More keeps the Arabic upcoming route through invisible updates at ${size.width}',
      (tester) async {
        final wide = size.width >= 740;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        await tester.runAsync(
          () => TestFonts.loadFamily('Readex Pro', [
            'assets/fonts/readex_pro/ReadexPro-Regular.ttf',
            'assets/fonts/readex_pro/ReadexPro-Bold.ttf',
          ]),
        );
        final transport = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) =>
                  handler.reject(DioException(requestOptions: options)),
            ),
          );
        addTearDown(transport.close);
        final memory = MemoryStorageService();
        final native = _Native(transport, memory);
        final selection = _Selection(native);
        final changes = List.generate(3, (_) => _Native(transport, memory));
        final witanime = _Witanime();
        final account = _Account();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              animeWitcherAccountControllerProvider.overrideWith(() => account),
              accountNotificationCountProvider.overrideWith((ref) async => 0),
              storageServiceProvider.overrideWithValue(memory),
              activeProviderProvider.overrideWith(() => selection),
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
              home: const MoreScreen(),
            ),
          ),
        );
        await _pump(tester);
        final moreHeader = find
            .byWidgetPredicate(
              (widget) => widget is AppPageAppBar && widget.title == 'المزيد',
              skipOffstage: false,
            )
            .first;
        AppPageAppBar header() => tester.widget<AppPageAppBar>(moreHeader);
        final coming = find.byType(ComingSoonScreen);
        final sidebar = find.byType(MoreSidebarShell);
        final menuLabel = find.text(_comingSoon).first;
        final noOpFrames = <String>[];
        var accountHeaders = 0;
        var catalogHeaders = 0;
        var groups = 0;
        var destinations = 0;
        var profile = _profile;
        Future<void> measure(
          VoidCallback update, {
          required bool fromAccount,
        }) async {
          final previousHeader = header();
          final previousGroups = wide
              ? tester.widget<MoreSidebarShell>(sidebar).groups
              : const <MoreDestinationGroup>[];
          update();
          await tester.pump();
          if (!identical(previousHeader, header())) {
            if (fromAccount) {
              accountHeaders++;
            } else {
              catalogHeaders++;
            }
          }
          if (!wide) return;
          final nextGroups = tester.widget<MoreSidebarShell>(sidebar).groups;
          for (var i = 0; i < nextGroups.length; i++) {
            if (!identical(previousGroups[i], nextGroups[i])) groups++;
            for (var j = 0; j < nextGroups[i].items.length; j++) {
              if (!identical(
                previousGroups[i].items[j],
                nextGroups[i].items[j],
              ))
                destinations++;
            }
          }
        }

        expect(find.text(_profile.userName!), findsWidgets);
        if (!wide) {
          noOpFrames.add(await _pixels(tester));
          for (var i = 0; i < 3; i++) {
            await measure(
              () => account.publish(
                AnimeWitcherAccountSnapshot(
                  profile: _profile.copyWith(country: '$i'),
                  lastSyncAt: DateTime.utc(2026, 1, i + 1),
                ),
              ),
              fromAccount: true,
            );
          }
          for (final replacement in [...changes.take(2), native]) {
            await measure(
              () => selection.publish(replacement),
              fromAccount: false,
            );
          }
          noOpFrames.add(await _pixels(tester));
          expect(noOpFrames.first, noOpFrames.last);
          expect(
            find.text('أنميات لم يتم بثها بعد حسب بيانات AnimeWitcher'),
            findsOneWidget,
          );
        }
        await tester.ensureVisible(menuLabel);
        await tester.tap(menuLabel);
        await _pump(tester);
        expect(coming, findsOneWidget);
        expect(native.offsets, [0]);
        expect(find.text('من المصدر المحلي 0').hitTestable(), findsWidgets);
        final grid = find.descendant(
          of: coming,
          matching: find.byType(GridView),
        );
        final position = tester.widget<GridView>(grid).controller!.position;
        position.jumpTo(172);
        await _pump(tester);
        final visibleOffset = position.pixels;
        noOpFrames.add(await _pixels(tester));

        for (var i = 0; i < (wide ? 8 : 5); i++) {
          await measure(() {
            profile = profile.copyWith(
              bio: 'قصة $i',
              privacySettings: AnimeWitcherPrivacySettings(
                showReviewsToUsers: i.isEven,
              ),
            );
            account.publish(
              AnimeWitcherAccountSnapshot(
                profile: profile,
                lastSyncAt: DateTime.utc(2026, 2, i + 1),
              ),
            );
          }, fromAccount: true);
        }
        if (wide) {
          for (final replacement in [...changes.take(2), native]) {
            await measure(
              () => selection.publish(replacement),
              fromAccount: false,
            );
          }
        }
        await _pump(tester);
        noOpFrames.add(await _pixels(tester));
        expect(noOpFrames[noOpFrames.length - 2], noOpFrames.last);
        expect(
          tester.widget<GridView>(grid).controller!.position,
          same(position),
        );
        expect(position.pixels, visibleOffset);
        expect(native.offsets, [0]);
        expect(changes.expand((provider) => provider.offsets), isEmpty);

        debugPrint(
          'C22_MORE ${size.width} account=$accountHeaders catalog=$catalogHeaders groups=$groups destinations=$destinations rgba=${noOpFrames.join(',')}',
        );
        expect(
          (accountHeaders, catalogHeaders, groups, destinations),
          (0, 0, 0, 0),
        );

        // The upcoming pane keeps its own dependencies. A real discovery
        // preference change and the different provider still refresh it.
        native.restricted = true;
        final scope = ProviderScope.containerOf(
          tester.element(coming),
          listen: false,
        );
        scope.read(accountDataRevisionProvider.notifier).bump();
        await _pump(tester);
        expect(native.offsets, [0, 0]);
        expect(
          find.textContaining('من القائمة المصفاة').hitTestable(),
          findsWidgets,
        );

        final beforeSwitch = header();
        selection.publish(witanime);
        await _pump(tester);
        expect(witanime.offsets, [0]);
        expect(find.textContaining('من ويت أنمي').hitTestable(), findsWidgets);
        if (wide) expect(identical(beforeSwitch, header()), isTrue);

        if (!wide) {
          final back = find.descendant(
            of: coming,
            matching: find.byType(AppBackButton),
          );
          expect(back, findsOneWidget);
          final icon = find
              .descendant(of: back, matching: find.byType(IconButton))
              .hitTestable();
          expect(icon, findsOneWidget);
          await tester.tap(icon);
          // Pump once at the transition start before advancing its clock.
          await tester.pump();
          for (
            var frame = 0;
            frame < 24 && coming.evaluate().isNotEmpty;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(coming, findsNothing);
          expect(
            find.text('أنميات لم يتم بثها بعد حسب بيانات Witanime'),
            findsOneWidget,
          );
        } else {
          expect(
            find.descendant(of: coming, matching: find.byType(AppBackButton)),
            findsNothing,
          );
          // Selecting a destination may scroll its list above the account
          // header. Restore the real sidebar viewport before checking labels.
          final sidebarList = find
              .descendant(of: sidebar, matching: find.byType(ListView))
              .first;
          final sidebarScroll = find
              .descendant(of: sidebarList, matching: find.byType(Scrollable))
              .first;
          tester.state<ScrollableState>(sidebarScroll).position.jumpTo(0);
          await _pump(tester);
        }

        final beforeEmail = header();
        profile = profile.copyWith(email: 'new@example.test');
        account.publish(AnimeWitcherAccountSnapshot(profile: profile));
        await _pump(tester);
        expect(identical(beforeEmail, header()), wide);
        expect(
          find.text('new@example.test'),
          wide ? findsNothing : findsOneWidget,
        );

        account.publish(
          AnimeWitcherAccountSnapshot(
            profile: profile.copyWith(userName: 'اسم جديد'),
          ),
        );
        await _pump(tester);
        expect(find.text('اسم جديد'), findsOneWidget);
        account.publish(
          AnimeWitcherAccountSnapshot(
            profile: profile.copyWith(userName: '  '),
          ),
        );
        await _pump(tester);
        // With no display name, the email really is a title on both layouts.
        expect(find.text('new@example.test'), findsWidgets);
        if (!wide) {
          account.loading();
          await tester.pump();
          expect(find.text('جارٍ التحقق من الحساب...'), findsOneWidget);
        }
        account.publish(const AnimeWitcherAccountSnapshot());
        await _pump(tester);
        expect(
          find.text(wide ? 'تسجيل الدخول' : 'تسجيل الدخول أو إنشاء حساب'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
