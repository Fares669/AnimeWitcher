import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/utils/layout_constants.dart';
import 'package:animewitcher/core/utils/window_controls_inset.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _EmptyDownloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => [];
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Size size,
  TextDirection direction = TextDirection.rtl,
  double safeTop = 0,
  VoidCallback? openMenu,
}) async {
  debugWindowControlsInsetOverride = platform == TargetPlatform.windows
      ? 128
      : 0;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    debugWindowControlsInsetOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadsProvider.overrideWith(_EmptyDownloads.new),
        deviceProfileProvider.overrideWith(
          (ref) async => const DeviceProfile(),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: safeTop),
          ),
          child: Directionality(
            textDirection: direction,
            child: AppSideMenuScope(
              open: openMenu ?? () {},
              child: const DownloadsScreen(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final direction in TextDirection.values) {
    for (final width in [500.0, 1200.0]) {
      testWidgets('Windows tabs replace heading at $width in $direction', (
        tester,
      ) async {
        var menuOpened = false;
        await _pumpScreen(
          tester,
          platform: TargetPlatform.windows,
          size: Size(width, 800),
          direction: direction,
          openMenu: () => menuOpened = true,
        );
        final context = tester.element(find.byType(DownloadsScreen));
        final l10n = AppLocalizations.of(context)!;
        final tabs = find.byType(FilterStyleTabBar);
        final pager = find.byType(TabBarView);
        final menu = find.byKey(const ValueKey('app-side-menu-button'));
        expect(find.text(l10n.downloads), findsOneWidget);
        expect(tester.getTopLeft(tabs).dy, 8);
        expect(tester.getTopRight(tabs).dx, lessThanOrEqualTo(width - 128));
        expect(tester.getTopRight(menu).dx, lessThanOrEqualTo(width - 128));
        // Only the strip reserves caption space; the list keeps its full width.
        expect(tester.getSize(pager).width, width);
        expect(tester.getTopLeft(pager).dy, tester.getBottomLeft(tabs).dy);
        expect(Directionality.of(tester.element(tabs)), TextDirection.rtl);
        await tester.tap(menu);
        expect(menuOpened, isTrue);
        await tester.tap(find.text(l10n.downloadsTabCompleted));
        await tester.pumpAndSettle();
        expect(tester.widget<FilterStyleTabBar>(tabs).controller.index, 1);
        expect(find.text(l10n.noCompletedDownloadsYet), findsOneWidget);
        await tester.tap(find.text(l10n.downloads));
        await tester.pumpAndSettle();
        expect(tester.widget<FilterStyleTabBar>(tabs).controller.index, 0);
        expect(find.text(l10n.noDownloadsYet), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform handset retains safe-area tabs without a heading', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        platform: platform,
        size: const Size(390, 844),
        safeTop: 24,
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DownloadsScreen)),
      )!;
      expect(find.text(l10n.downloads), findsOneWidget);
      expect(tester.getTopLeft(find.byType(FilterStyleTabBar)).dy, 24);
      expect(tester.getTopRight(find.byType(FilterStyleTabBar)).dx, 390);
      expect(tester.getSize(find.byType(TabBarView)).width, 390);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    testWidgets('$platform desktop keeps the existing heading', (tester) async {
      await _pumpScreen(
        tester,
        platform: platform,
        size: const Size(1200, 800),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DownloadsScreen)),
      )!;
      expect(find.text(l10n.downloads), findsNWidgets(2));
      expect(
        tester.getTopLeft(find.byType(FilterStyleTabBar)).dy,
        8 + LayoutConstants.dashboardHeaderHeight,
      );
      expect(tester.getTopRight(find.byType(FilterStyleTabBar)).dx, 1200);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));
  }
}
