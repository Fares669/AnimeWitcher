import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_notification_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MenuAccountService extends AnimeWitcherAccountService {
  _MenuAccountService()
    : super(
        storage: StorageService(),
        secureStorage: SecureTokenStorage(StorageService()),
      );
  @override
  AnimeWitcherAccountSnapshot get snapshot => const AnimeWitcherAccountSnapshot(
    profile: AnimeWitcherProfile(
      documentId: 'profile-1',
      uid: 'user-1',
      signInMethod: AnimeWitcherSignInMethod.email,
    ),
  );
  @override
  Future<int> loadNotificationCount() async => 0;
  @override
  Future<AnimeWitcherNotificationPage> loadNotifications({
    FirestoreDocument? cursor,
  }) async => const AnimeWitcherNotificationPage(
    items: [],
    cursor: null,
    hasMore: false,
  );
  @override
  Future<void> markNotificationsSeen(String id) async {}
}

final class _SignedOutAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot();
  }
}

final class _SignedInAccount extends AnimeWitcherAccountController {
  _SignedInAccount({
    this.coverUrl = 'https://example.test/banner.jpg',
    this.photoUrl = 'https://example.test/avatar.jpg',
  });

  final String? coverUrl;
  final String? photoUrl;
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return AnimeWitcherAccountSnapshot(
      profile: AnimeWitcherProfile(
        documentId: 'profile-1',
        uid: 'user-1',
        signInMethod: AnimeWitcherSignInMethod.email,
        email: 'viewer@example.test',
        userName: 'Viewer',
        photoUrl: photoUrl,
        coverUrl: coverUrl,
      ),
    );
  }
}

const _destinations = <TaskbarDestination>[
  TaskbarDestination.home,
  TaskbarDestination.search,
  TaskbarDestination.library,
  TaskbarDestination.settings,
];

final class _Harness {
  final picked = <TaskbarDestination>[];
  int accountOpened = 0;
  int backWhenClosed = 0;
  int settingsOpened = 0;
  bool canOpen = true;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool signedIn = false,
  Size size = const Size(400, 860),
  int fillerEntries = 0,
  double devicePixelRatio = 1,
  String? fixtureCover,
}) async {
  final harness = _Harness();
  tester.view.physicalSize = size * devicePixelRatio;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = ProviderScope(
    overrides: [
      animeWitcherAccountServiceProvider.overrideWithValue(
        _MenuAccountService(),
      ),
      animeWitcherAccountControllerProvider.overrideWith(
        signedIn
            ? () => fixtureCover == null
                  ? _SignedInAccount()
                  : _SignedInAccount(coverUrl: fixtureCover, photoUrl: null)
            : _SignedOutAccount.new,
      ),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppSideMenuShell(
        destinations: _destinations,
        currentBranchIndex: TaskbarDestination.home.branchIndex,
        onDestination: harness.picked.add,
        onAccount: () => harness.accountOpened++,
        canOpen: () => harness.canOpen,
        canPopWhenClosed: false,
        onBackWhenClosed: () => harness.backWhenClosed++,
        entries: [
          AppSideMenuEntry(
            id: 'settings',
            icon: Icons.settings_rounded,
            label: 'الإعدادات',
            onTap: () => harness.settingsOpened++,
          ),
          for (var index = 0; index < fillerEntries; index++)
            AppSideMenuEntry(
              id: 'filler-$index',
              icon: Icons.circle_outlined,
              label: 'عنصر $index',
              onTap: () {},
            ),
        ],
        child: const Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  key: ValueKey<String>('page'),
                  color: Colors.black,
                ),
              ),
              Positioned(top: 20, left: 12, child: AppSideMenuButton()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    fixtureCover == null
        ? app
        : RepaintBoundary(
            key: const ValueKey<String>('side-menu-test-frame'),
            child: app,
          ),
  );
  await tester.pump();
  return harness;
}

Finder get _menu =>
    find.byKey(const ValueKey<String>('app-side-menu'), skipOffstage: false);
Finder get _page => find.byKey(const ValueKey<String>('page'));

bool _menuShowing(WidgetTester tester) => !tester
    .widgetList<Offstage>(
      find.ancestor(
        of: _menu,
        matching: find.byType(Offstage, skipOffstage: false),
      ),
    )
    .first
    .offstage;

class _FixtureImages extends Fake implements HttpClient {
  _FixtureImages(this.bytes);

  final Uint8List bytes;
  final requests = <Uri>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return _FixtureRequest(bytes);
  }
}

class _FixtureRequest extends Fake implements HttpClientRequest {
  _FixtureRequest(this.bytes);
  final Uint8List bytes;

  @override
  Future<HttpClientResponse> close() async => _FixtureResponse(bytes);
}

class _FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  _FixtureResponse(this.bytes);
  final Uint8List bytes;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Uint8List> _coverBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawColor(const Color(0xff3060b0), ui.BlendMode.src)
    ..drawRect(
      Rect.fromLTRB(width / 2, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xffe8ab30),
    );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

const _coverKey = ValueKey<String>('app-side-menu-account-cover');

Finder _decodedCover({bool skipOffstage = true}) => find.descendant(
  of: find.byKey(_coverKey, skipOffstage: skipOffstage),
  matching: find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
    skipOffstage: skipOffstage,
  ),
  skipOffstage: skipOffstage,
);

Future<void> _waitForDecode(WidgetTester tester) async {
  for (var frame = 0; frame < 100; frame++) {
    if (_decodedCover(skipOffstage: false).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Account banner never decoded');
}

Future<List<int>> _paintedCoverSamples(WidgetTester tester, Rect art) async {
  final frame = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey<String>('side-menu-test-frame')),
  );
  return (await tester.runAsync(() async {
    final image = await frame.toImage();
    try {
      final bytes = (await image.toByteData())!;
      return [
        for (final x in [art.left + art.width * .28, art.left + art.width * .7])
          bytes.getUint32(
            ((art.top + 23).floor() * image.width + x.floor()) * 4,
          ),
      ];
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  for (final (layout, size, dpr, width, height, decoded) in [
    ('phone', const Size(390, 844), 1.0, 1400, 800, (375, 214)),
    ('desktop', const Size(1280, 900), 2.0, 1400, 800, (750, 429)),
    ('wide cover', const Size(400, 860), 1.0, 2000, 500, (780, 195)),
    ('small cover', const Size(400, 860), 1.0, 175, 100, (175, 100)),
  ]) {
    testWidgets('account cover keeps its crop and activity on $layout', (
      tester,
    ) async {
      final url = Uri.https('cover.fixture.invalid', '/$layout.png');
      final bytes = (await tester.runAsync(() => _coverBytes(width, height)))!;
      final client = _FixtureImages(bytes);
      final savedHttp = debugNetworkImageHttpClientProvider;
      final cache = PaintingBinding.instance.imageCache;
      cache
        ..clear()
        ..clearLiveImages();
      debugNetworkImageHttpClientProvider = () => client;
      try {
        final harness = await _pump(
          tester,
          signedIn: true,
          size: size,
          devicePixelRatio: dpr,
          fixtureCover: url.toString(),
        );
        expect(_menuShowing(tester), isFalse);
        await _waitForDecode(tester);
        final closed = _decodedCover(skipOffstage: false);
        expect(closed, findsOneWidget);
        final original = tester.widget<RawImage>(closed).image!;
        expect(client.requests, [url]);
        expect(cache.currentSize, 1);
        final cacheBytes = cache.currentSizeBytes;

        Future<void> open() async {
          await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
          await tester.pumpAndSettle();
        }

        await open();
        final cover = _decodedCover();
        final box = tester.getRect(cover);
        expect(box.height, 156);
        expect(box.width, AppSideMenuShell.menuWidthFor(size.width) - 20);
        expect(tester.widget<RawImage>(cover).fit, BoxFit.cover);
        expect(
          tester.widget<RawImage>(cover).image!.isCloneOf(original),
          isTrue,
        );
        final samples = await _paintedCoverSamples(tester, box);

        // The physical box gets one limiting dimension. The codec rounds the
        // other by a pixel or less while preserving the original aspect ratio.
        expect(original.width, decoded.$1);
        expect(original.height, closeTo(decoded.$2, 1));
        expect(cacheBytes, original.width * original.height * 4);
        final expectedColors = [0x1e3c6dff, 0x906a1eff];
        for (var i = 0; i < expectedColors.length; i++) {
          for (final shift in [0, 8, 16, 24]) {
            expect(
              (samples[i] >> shift) & 255,
              closeTo((expectedColors[i] >> shift) & 255, 2),
            );
          }
        }

        await tester.tap(find.byKey(const ValueKey('app-side-menu-account')));
        await tester.pumpAndSettle();
        expect(harness.accountOpened, 1);
        expect(_menuShowing(tester), isFalse);
        await open();
        expect(_menuShowing(tester), isTrue);
        expect(
          await _paintedCoverSamples(tester, tester.getRect(cover)),
          samples,
        );
        expect(
          tester.widget<RawImage>(cover).image!.isCloneOf(original),
          isTrue,
        );
        expect(client.requests, [url]);
        if (layout == 'phone') {
          tester.view.physicalSize = const Size(320, 844);
          await tester.pumpAndSettle();
          expect(tester.getSize(cover), const Size(236, 156));
          expect(
            await _paintedCoverSamples(tester, tester.getRect(cover)),
            samples,
          );
          expect(
            tester.widget<RawImage>(cover).image!.isCloneOf(original),
            isTrue,
          );
          expect(client.requests, [url]);
          expect(cache.currentSizeBytes, cacheBytes);
        }

        // Check actual Flutter focus and navigation after the cover warms.
        final library = find.byKey(const ValueKey('app-side-menu-library'));
        final libraryLabel = find.descendant(
          of: library,
          matching: find.text('المكتبة'),
        );
        final focus = Focus.of(tester.element(libraryLabel));
        focus.requestFocus();
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        await tester.tap(library);
        await tester.pumpAndSettle();
        expect(harness.picked, [TaskbarDestination.library]);
        expect(_menuShowing(tester), isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugNetworkImageHttpClientProvider = savedHttp;
        cache
          ..clear()
          ..clearLiveImages();
      }
    });
  }

  testWidgets('a broken cover keeps the account and menu usable', (
    tester,
  ) async {
    final url = Uri.https('cover.fixture.invalid', '/broken.png');
    final client = _FixtureImages(Uint8List.fromList([0xff, 0x13, 0x45]));
    final savedHttp = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => client;
    try {
      final harness = await _pump(
        tester,
        signedIn: true,
        fixtureCover: url.toString(),
      );
      await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
      await tester.pumpAndSettle();
      final fallback = find.descendant(
        of: find.byKey(_coverKey),
        matching: find.byType(SizedBox),
      );
      for (var frame = 0; frame < 100 && fallback.evaluate().isEmpty; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(fallback, findsOneWidget);
      expect(_decodedCover(), findsNothing);
      expect(client.requests, [url]);
      expect(find.text('Viewer'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('app-side-menu-account')));
      await tester.pumpAndSettle();
      expect(harness.accountOpened, 1);
      expect(_menuShowing(tester), isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugNetworkImageHttpClientProvider = savedHttp;
    }
  });

  testWidgets('the menu button opens the menu: account on top, ✕ top left', (
    tester,
  ) async {
    await _pump(tester);
    expect(_menuShowing(tester), isFalse);

    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();

    expect(_menuShowing(tester), isTrue);
    // The page is pushed to the right, the menu on the left.
    expect(tester.getTopLeft(_page).dx, greaterThan(200));
    expect(tester.getTopLeft(_menu).dx, closeTo(0, 0.5));
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('الرئيسية'), findsOneWidget);
    expect(find.text('المزيد'), findsOneWidget);

    final close = tester.getCenter(
      find.byKey(const ValueKey('app-side-menu-close')),
    );
    final account = tester.getCenter(
      find.byKey(const ValueKey('app-side-menu-account')),
    );
    // ✕ in the top-left corner, above the pages.
    expect(close.dx, lessThan(account.dx));
    expect(close.dx, lessThan(80));
    expect(
      close.dy,
      lessThan(
        tester.getCenter(find.byKey(const ValueKey('app-side-menu-home'))).dy,
      ),
    );
  });

  testWidgets('notification entry closes the sidebar before opening inbox', (
    tester,
  ) async {
    await _pump(tester, signedIn: true);
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('account-notifications-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('الإشعارات'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('signed-in menu uses banner, larger avatar, and no email', (
    tester,
  ) async {
    await _pump(tester, signedIn: true);
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    final bell = find.byKey(const ValueKey('account-notifications-button'));
    final accountAvatar = find.byKey(const ValueKey('account-avatar-button'));
    expect(bell, findsOneWidget);
    expect(
      tester.getBottomLeft(bell).dy,
      lessThanOrEqualTo(tester.getTopLeft(accountAvatar).dy),
    );

    expect(find.text('Viewer'), findsOneWidget);
    expect(find.text('viewer@example.test'), findsNothing);

    final banner = find.byKey(
      const ValueKey<String>('app-side-menu-account-banner'),
    );
    expect(banner, findsOneWidget);
    final bannerRect = tester.getRect(banner);
    expect(bannerRect.height, greaterThanOrEqualTo(152));
    expect(bannerRect.width, greaterThanOrEqualTo(292));

    final close = find.byKey(const ValueKey<String>('app-side-menu-close'));
    final closeRect = tester.getRect(close);
    expect(closeRect.left, lessThanOrEqualTo(bannerRect.left + 12));
    expect(closeRect.top, lessThan(bannerRect.top + 28));
    expect(closeRect.bottom, lessThan(bannerRect.bottom));

    final avatar = find.byKey(const ValueKey<String>('account-avatar-button'));
    expect(tester.getRect(avatar).width, greaterThanOrEqualTo(76));

    final name = tester.widget<Text>(
      find.descendant(of: banner, matching: find.text('Viewer')),
    );
    expect(name.style?.fontSize, 22);

    final cover = tester.widget<Image>(
      find.byKey(const ValueKey<String>('app-side-menu-account-cover')),
    );
    expect(cover.fit, BoxFit.cover);
  });

  testWidgets('account banner scrolls with pages while close stays pinned', (
    tester,
  ) async {
    await _pump(
      tester,
      signedIn: true,
      size: const Size(400, 500),
      fillerEntries: 8,
    );
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();

    final banner = find.byKey(
      const ValueKey<String>('app-side-menu-account-banner'),
    );
    final close = find.byKey(const ValueKey<String>('app-side-menu-close'));
    final list = find.descendant(of: _menu, matching: find.byType(ListView));

    final bannerBefore = tester.getTopLeft(banner).dy;
    final closeBefore = tester.getTopLeft(close).dy;

    await tester.drag(list, const Offset(0, -80));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(banner).dy, lessThan(bannerBefore - 20));
    expect(tester.getTopLeft(close).dy, closeTo(closeBefore, 0.5));
  });

  testWidgets('✕, a tap on the page and the back button all close it', (
    tester,
  ) async {
    final harness = await _pump(tester);
    Future<void> open() async {
      await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
      await tester.pumpAndSettle();
      expect(_menuShowing(tester), isTrue);
    }

    await open();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-close')));
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);

    await open();
    await tester.tapAt(const Offset(380, 500));
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);

    await open();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
    // Closing the menu is all the back button did.
    expect(harness.backWhenClosed, 0);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(harness.backWhenClosed, 1);
  });

  testWidgets('pulling the page right opens it, pulling left shuts it', (
    tester,
  ) async {
    await _pump(tester);

    await tester.timedDragFrom(
      const Offset(150, 500),
      const Offset(220, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isTrue);

    await tester.timedDragFrom(
      const Offset(380, 500),
      const Offset(-250, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('a short pull springs back shut', (tester) async {
    await _pump(tester);

    await tester.timedDragFrom(
      const Offset(150, 500),
      const Offset(60, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('no pull opens it over a page pushed inside a tab', (
    tester,
  ) async {
    final harness = await _pump(tester);
    // Opened and shut once first: shutting must leave it reading as shut.
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-close')));
    await tester.pumpAndSettle();
    harness.canOpen = false;

    await tester.timedDragFrom(
      const Offset(150, 500),
      const Offset(220, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('a page and the account open from the menu, which then shuts', (
    tester,
  ) async {
    final harness = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-library')));
    await tester.pumpAndSettle();
    expect(harness.picked, [TaskbarDestination.library]);
    expect(_menuShowing(tester), isFalse);

    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-account')));
    await tester.pumpAndSettle();
    expect(harness.accountOpened, 1);
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('outside the side-menu layout the button draws nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppSideMenuButton())),
    );
    expect(find.byKey(const ValueKey('app-side-menu-button')), findsNothing);
  });

  testWidgets('top bar hides page menu buttons and keeps its own control', (
    tester,
  ) async {
    var opened = 0;
    void open() => opened++;
    for (final showPageButtons in [true, false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: AppSideMenuScope(
            open: open,
            showPageButtons: showPageButtons,
            child: const Scaffold(
              body: Column(
                children: [
                  AppSideMenuButton(key: ValueKey('page-menu')),
                  AppSideMenuButton(
                    key: ValueKey('navigation-menu'),
                    inNavigationBar: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('app-side-menu-button')),
        findsNWidgets(showPageButtons ? 2 : 1),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('navigation-menu')),
          matching: find.byType(InkWell),
        ),
      );
    }
    expect(opened, 3);
  });

  testWidgets('the More pages sit under the tabs and open from the menu', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();

    final settings = find.byKey(const ValueKey('app-side-menu-page-settings'));
    expect(
      tester.getTopLeft(settings).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('app-side-menu-home'))).dy,
      ),
    );
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(harness.settingsOpened, 1);
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('the menu retains its panel while the page slides', (
    tester,
  ) async {
    await _pump(tester);
    final panel = find.byType(AppSideMenuPanel, skipOffstage: false);
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    await tester.pump(const Duration(milliseconds: 16));
    final before = tester.widget<AppSideMenuPanel>(panel);
    final offset = tester.getTopLeft(_page).dx;

    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getTopLeft(_page).dx, greaterThan(offset));
    expect(tester.widget<AppSideMenuPanel>(panel), same(before));

    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isTrue);
  });
}
