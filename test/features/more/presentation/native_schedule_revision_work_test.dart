import 'dart:convert';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/broadcast_schedule_screen.dart';
import 'package:animewitcher/features/more/presentation/coming_soon_screen.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
// Match the app's Material compatibility API.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

const _root = ValueKey('c27-native-schedule-frame');
const _font = 'C27ScheduleReadex';
const _isStock = bool.fromEnvironment('C27_NATIVE_SCHEDULE_STOCK');

final class _Guest extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

final class _Settings extends MemoryStorageService {
  bool highQuality = false;

  @override
  bool isHighQualityPostersEnabled() => highQuality;
}

final class _Offline {
  _Offline() {
    dio.interceptors.add(InterceptorsWrapper(onRequest: _respond));
    native = AnimeWitcherNativeProvider(
      dio,
      SettingsRepository(settings),
      isEcchiHidden: () => hideEcchi,
    );
  }

  final settings = _Settings();
  final dio = Dio();
  late final AnimeWitcherNativeProvider native;
  final schedule = <String>[];
  final upcoming = <String>[];
  final unexpected = <Uri>[];
  bool hideEcchi = false;
  bool fail = false;
  int fallbacks = 0;
  bool holdNext = false;
  ({String day, RequestOptions options, RequestInterceptorHandler handler})?
  held;

  void releaseHeld() {
    final old = held!;
    held = null;
    old.handler.resolve(
      Response<Object?>(
        requestOptions: old.options,
        statusCode: 200,
        data: _page(old.day, 'متأخر', count: 12),
      ),
    );
  }

  void _respond(RequestOptions options, RequestInterceptorHandler handler) {
    final uri = options.uri;
    Object? payload;
    var status = 200;
    if (uri.path.contains('Settings/constants')) {
      payload = {
        'fields': {
          'search_settings': {
            'mapValue': {
              'fields': {
                'app_id_v3': {'stringValue': 'C27FIXTURE'},
                'api_key': {'stringValue': 'local-search'},
                'browse_api_key': {'stringValue': 'local-browse'},
                'is_search_active': {'booleanValue': true},
              },
            },
          },
        },
      };
    } else if (uri.path.endsWith('/indexes/series/query')) {
      final args = Uri.splitQueryString(
        (options.data as Map)['params'] as String,
        encoding: utf8,
      );
      final day = animeWitcherBroadcastDays.singleWhere(
        (day) => args['filters']!.contains('"$day"'),
      );
      schedule.add(day);
      if (holdNext) {
        holdNext = false;
        held = (day: day, options: options, handler: handler);
        return;
      }
      status = fail ? 503 : 200;
      payload = _page(day, 'بث', count: 12);
    } else if (uri.path.endsWith('/indexes/series/browse')) {
      upcoming.add(uri.queryParameters['filters'] ?? '');
      payload = _page('قادم', 'عرض', count: 9);
    } else if (uri.path.endsWith(':runQuery')) {
      fallbacks++;
      status = 503;
      payload = const [];
    } else if (uri.path.endsWith('/indexes/Settings/constants')) {
      payload = const {};
    } else {
      unexpected.add(uri);
      status = 503;
      payload = const {};
    }
    handler.resolve(
      Response<Object?>(
        requestOptions: options,
        statusCode: status,
        data: payload,
      ),
    );
  }

  Map<String, Object> _page(String day, String title, {required int count}) {
    return {
      'nbPages': 1,
      'hits': [
        for (var i = 0; i < count; i++)
          {
            'objectID': '${animeWitcherBroadcastDays.indexOf(day)}-$i',
            'name': '$title $day $i',
            'show_time': day,
            'type': 'مسلسل',
            'details': {
              'state': day == 'قادم' ? 'لم يتم بثه بعد' : 'مستمر',
              'season': 'شتاء عام 2027',
              'mal_mean': '٨.${i % 10}',
            },
            'tags': [i == 1 ? 'Ecchi' : 'Adventure'],
          },
      ],
    };
  }
}

Future<String> _rgba(WidgetTester tester) async => (await tester.runAsync(
  () async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_root),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = (await image.toByteData())!;
      return sha256
          .convert(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          )
          .toString();
    } finally {
      image.dispose();
    }
  },
))!;

Finder _titleCard(String title) => find.byWidgetPredicate(
  (widget) => widget is MultimediaCard && widget.title == title,
);

Map<Key, MultimediaCard> _cards(WidgetTester tester) => {
  for (final card in tester.widgetList<MultimediaCard>(
    find.byType(MultimediaCard),
  ))
    card.key!: card,
};

Future<void> _tapDay(WidgetTester tester, String day) async {
  final tab = find.widgetWithText(Tab, day);
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final fonts = FontLoader(_font)
      ..addFont(
        rootBundle.load('assets/fonts/readex_pro/ReadexPro-Regular.ttf'),
      );
    await fonts.load();
  });

  testWidgets(
    'Arabic native broadcast keeps day pages across neutral revisions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final offline = _Offline();
      addTearDown(() => offline.dio.close(force: true));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(offline.settings),
            animeWitcherAccountControllerProvider.overrideWith(_Guest.new),
            activeProviderProvider.overrideWithValue(offline.native),
          ],
          child: RepaintBoundary(
            key: _root,
            child: MaterialApp(
              theme: ThemeData(fontFamily: _font),
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const MoreScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final more = find.byType(MoreScreen);
      final moreHashes = <String>[await _rgba(tester)];
      final broadcastTitle = find.text('جدول البث').hitTestable();
      expect(broadcastTitle, findsOneWidget);
      await tester.tap(broadcastTitle);
      await tester.pumpAndSettle();

      final screen = find.byType(BroadcastScheduleScreen);
      final container = ProviderScope.containerOf(tester.element(screen));
      expect(Directionality.of(tester.element(screen)), TextDirection.rtl);
      final tabBar = find.byType(TabBar);
      int selected() => tester.widget<TabBar>(tabBar).controller!.index;
      final initial = offline.schedule.single;
      expect(animeWitcherBroadcastDays[selected()], initial);
      expect(visibleWeekday(), initial);
      final secondary = animeWitcherBroadcastDays.firstWhere(
        (day) => day != initial,
      );
      expect(_titleCard('بث $initial 0'), findsOneWidget);
      moreHashes.add(await _rgba(tester));

      await _tapDay(tester, secondary);
      expect(offline.schedule, [initial, secondary]);
      expect(animeWitcherBroadcastDays[selected()], secondary);
      expect(_titleCard('بث $secondary 1'), findsOneWidget);
      final original = _cards(tester);
      expect(original.length, greaterThanOrEqualTo(6));
      moreHashes.add(await _rgba(tester));

      final reviser = container.read(accountDataRevisionProvider.notifier);
      final before = offline.schedule.length;
      var configReplacements = 0;
      for (var i = 0; i < 6; i++) {
        final prior = _cards(tester);
        reviser.bump();
        await tester.pumpAndSettle();
        final after = _cards(tester);
        expect(after.keys, orderedEquals(prior.keys));
        configReplacements += prior.keys
            .where((key) => !identical(prior[key], after[key]))
            .length;
        expect(animeWitcherBroadcastDays[selected()], secondary);
      }
      final neutralLoads = offline.schedule.length - before;
      expect(neutralLoads, _isStock ? 6 : 0);
      expect(configReplacements, _isStock ? original.length * 6 : 0);
      moreHashes.add(await _rgba(tester));

      final beforeReturn = offline.schedule.length;
      await _tapDay(tester, initial);
      expect(offline.schedule.length - beforeReturn, _isStock ? 1 : 0);
      expect(_titleCard('بث $initial 1'), findsOneWidget);
      moreHashes.add(await _rgba(tester));

      // An in-flight day still uses the prior cancellation fence: a
      // neutral revision can replace it without publishing a late payload.
      final thirdDay = animeWitcherBroadcastDays.firstWhere(
        (day) => day != initial && day != secondary,
      );
      offline.holdNext = true;
      await _tapDay(tester, thirdDay);
      expect(offline.held!.day, thirdDay);
      final beforePending = offline.schedule.length;
      reviser.bump();
      await tester.pumpAndSettle();
      expect(offline.schedule.length - beforePending, 1);
      expect(offline.held!.options.cancelToken!.isCancelled, isTrue);
      offline.releaseHeld();
      await tester.pumpAndSettle();
      expect(_titleCard('بث $thirdDay 0'), findsOneWidget);
      expect(_titleCard('متأخر $thirdDay 0'), findsNothing);
      await _tapDay(tester, initial);

      offline.hideEcchi = true;
      final beforePrivacy = offline.schedule.length;
      reviser.bump();
      await tester.pumpAndSettle();
      expect(offline.schedule.length - beforePrivacy, 1);
      expect(_titleCard('بث $initial 1'), findsNothing);
      expect(_titleCard('بث $initial 0'), findsOneWidget);
      moreHashes.add(await _rgba(tester));

      // A genuine poster preference change still invalidates the native day.
      offline.settings.highQuality = true;
      offline.fail = true;
      final beforeError = offline.schedule.length;
      reviser.bump();
      await tester.pumpAndSettle();
      expect(offline.schedule.length - beforeError, greaterThan(0));
      expect(offline.fallbacks, 1);
      expect(find.text('تعذر تحميل جدول البث'), findsOneWidget);
      moreHashes.add(await _rgba(tester));

      // Preserve the prior recovery path when the cached page actually failed.
      offline.fail = false;
      final beforeRetry = offline.schedule.length;
      reviser.bump();
      await tester.pumpAndSettle();
      expect(offline.schedule.length - beforeRetry, 1);
      expect(_titleCard('بث $initial 0'), findsOneWidget);
      expect(_titleCard('بث $initial 1'), findsNothing);

      final back = find.byType(AppBackButton).hitTestable();
      final backIcon = find.descendant(
        of: back,
        matching: find.byIcon(Icons.arrow_back_ios_new_rounded),
      );
      Focus.of(tester.element(backIcon)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(more, findsOneWidget);
      expect(screen, findsNothing);

      final comingTitle = find.text('القادم قريبًا').hitTestable();
      await tester.tap(comingTitle);
      await tester.pumpAndSettle();
      expect(find.byType(ComingSoonScreen), findsOneWidget);
      expect(offline.upcoming.single, contains('لم يتم بثه بعد'));
      expect(_titleCard('عرض قادم 0'), findsOneWidget);
      expect(_titleCard('عرض قادم 1'), findsNothing);
      moreHashes.add(await _rgba(tester));
      expect(offline.unexpected, isEmpty);
      expect(tester.takeException(), isNull);

      debugPrint(
        'C27_SCHEDULE loads=$neutralLoads configs=$configReplacements '
        'mounted=${original.length} rgba=${moreHashes.join(',')}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

String visibleWeekday() =>
    animeWitcherBroadcastDays[(DateTime.now().weekday + 1) % 7];
