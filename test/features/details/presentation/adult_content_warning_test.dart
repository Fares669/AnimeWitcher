import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/adult_content_warning.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

MultimediaItem _item({
  List<String>? tags,
  String? contentRating,
  Map<String, String>? syncData,
  NextAiring? nextAiring,
  bool isAdult = false,
}) {
  return MultimediaItem(
    title: 'تجريبي',
    url: 'https://example.test/anime',
    posterUrl: '',
    tags: tags,
    contentRating: contentRating,
    syncData: syncData,
    nextAiring: nextAiring,
    isAdult: isAdult,
    description: 'قصة الأنمي تظهر هنا مع الوسوم.',
  );
}

int _unixSecondsFromNow(Duration remaining) {
  return DateTime.now().toUtc().add(remaining).millisecondsSinceEpoch ~/ 1000;
}

Widget _app(Widget child, {String? fontFamily, Key? boundaryKey}) {
  final content = MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: const Color(0xFF111111),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFEEC60A),
        surface: Color(0xFF111111),
        onSurface: Color(0xFFE5E7EB),
        onSurfaceVariant: Color(0xFFB0B0B0),
      ),
    ),
    home: Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: child,
        ),
      ),
    ),
  );
  if (boundaryKey == null) return content;
  return RepaintBoundary(key: boundaryKey, child: content);
}

Widget _storyCard() {
  return const DecoratedBox(
    key: ValueKey('story-card'),
    decoration: BoxDecoration(
      color: Color(0x8C2A2A32),
      borderRadius: BorderRadius.all(Radius.circular(16)),
    ),
    child: Padding(
      padding: EdgeInsets.fromLTRB(16, 15, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'قصة',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          SizedBox(height: 8),
          Text('وصف الأنمي يظهر في بطاقة القصة.'),
        ],
      ),
    ),
  );
}

Future<void> _pumpStack(
  WidgetTester tester, {
  required MultimediaItem item,
  bool showCountdown = true,
  Key? boundaryKey,
  String? fontFamily,
}) {
  return tester.pumpWidget(
    _app(
      DetailsCountdownAndStory(
        item: item,
        showCountdown: showCountdown,
        showRatings: false,
        storyCard: _storyCard(),
      ),
      fontFamily: fontFamily,
      boundaryKey: boundaryKey,
    ),
  );
}

void main() {
  group('shouldShowAdultContentWarning', () {
    test('shows when tags contain the Arabic genre ايتشي', () {
      expect(
        shouldShowAdultContentWarning(_item(tags: const <String>['ايتشي'])),
        isTrue,
      );
    });

    test('shows when a hamza-prefixed إيتشي tag is normalized', () {
      expect(
        shouldShowAdultContentWarning(_item(tags: const <String>['إيتشي'])),
        isTrue,
      );
    });

    test('shows when ايتشي is one of several joined genres', () {
      expect(
        shouldShowAdultContentWarning(
          _item(tags: const <String>['أكشن, ايتشي, دراما']),
        ),
        isTrue,
      );
    });

    test('shows when details.age equals +17', () {
      expect(
        shouldShowAdultContentWarning(_item(contentRating: '+17')),
        isTrue,
      );
      expect(
        shouldShowAdultContentWarning(
          _item(syncData: const <String, String>{'awAge': '+17'}),
        ),
        isTrue,
      );
    });

    test('shows when either the Arabic tag or +17 is present (OR)', () {
      expect(
        shouldShowAdultContentWarning(
          _item(tags: const <String>['ايتشي'], contentRating: '+13'),
        ),
        isTrue,
      );
      expect(
        shouldShowAdultContentWarning(
          _item(tags: const <String>['دراما'], contentRating: '+17'),
        ),
        isTrue,
      );
    });

    test('hides English ecchi tags, other ages, and isAdult alone', () {
      expect(
        shouldShowAdultContentWarning(_item(tags: const <String>['ecchi'])),
        isFalse,
      );
      expect(
        shouldShowAdultContentWarning(_item(tags: const <String>['Ecchi'])),
        isFalse,
      );
      expect(
        shouldShowAdultContentWarning(_item(contentRating: '+13')),
        isFalse,
      );
      expect(
        shouldShowAdultContentWarning(
          _item(tags: const <String>['دراما'], isAdult: true),
        ),
        isFalse,
      );
    });
  });

  testWidgets('renders the exact APK copy on a red rounded card', (
    tester,
  ) async {
    await _pumpStack(
      tester,
      item: _item(tags: const <String>['ايتشي']),
      showCountdown: false,
    );

    expect(find.text(kAdultContentWarningText), findsOneWidget);
    final card = tester.widget<Card>(find.byKey(kAdultContentWarningKey));
    expect(card.color, Colors.red);
    expect(card.shape, isA<RoundedRectangleBorder>());
    final text = tester.widget<Text>(find.text(kAdultContentWarningText));
    expect(text.style?.color, Colors.white);
  });

  testWidgets('sits between the countdown and the story card', (tester) async {
    await _pumpStack(
      tester,
      item: _item(
        tags: const <String>['ايتشي'],
        nextAiring: NextAiring(
          episode: 2,
          unixTime: _unixSecondsFromNow(const Duration(hours: 4)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('الحلقة القادمة بعد'), findsOneWidget);
    final countdown = tester.getRect(find.byType(NextAiringWidget));
    final banner = tester.getRect(find.byKey(kAdultContentWarningKey));
    final story = tester.getRect(find.byKey(const ValueKey('story-card')));

    expect(banner.top, greaterThanOrEqualTo(countdown.bottom));
    expect(story.top, greaterThanOrEqualTo(banner.bottom));
    expect(banner.left, closeTo(story.left, 0.5));
    expect(banner.right, closeTo(story.right, 0.5));
  });

  testWidgets(
    'sits immediately above the story card when there is no countdown',
    (tester) async {
      await _pumpStack(
        tester,
        item: _item(contentRating: '+17'),
        showCountdown: false,
      );

      expect(find.byType(NextAiringWidget), findsNothing);
      final banner = tester.getRect(find.byKey(kAdultContentWarningKey));
      final story = tester.getRect(find.byKey(const ValueKey('story-card')));
      expect(story.top, greaterThanOrEqualTo(banner.bottom));
      expect(banner.left, closeTo(story.left, 0.5));
      expect(banner.right, closeTo(story.right, 0.5));
    },
  );

  testWidgets('stays hidden when APK conditions do not match', (tester) async {
    await _pumpStack(
      tester,
      item: _item(tags: const <String>['دراما'], isAdult: true),
    );

    expect(find.byKey(kAdultContentWarningKey), findsNothing);
    expect(find.text(kAdultContentWarningText), findsNothing);
  });

  testWidgets('does not consult a hide-ecchi setting', (tester) async {
    await _pumpStack(
      tester,
      item: _item(tags: const <String>['ايتشي']),
      showCountdown: false,
    );

    expect(find.byKey(kAdultContentWarningKey), findsOneWidget);
  });

  testWidgets('adult warning screenshots', (tester) async {
    final loaded = await tester.runAsync(TestFonts.loadWalkthroughFonts);
    if (loaded != true) return;

    final artifacts = debugShotDirectory();
    if (artifacts == null) return;

    Future<void> shot(String name, MultimediaItem item) async {
      final key = ValueKey(name);
      await _pumpStack(
        tester,
        item: item,
        fontFamily: 'NotoSansArabic',
        boundaryKey: key,
      );
      await tester.pump();
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${artifacts.path}/$name.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    await shot(
      'details_adult_warning_between_countdown_and_story',
      _item(
        tags: const <String>['ايتشي', 'خيال'],
        nextAiring: NextAiring(
          episode: 8,
          unixTime: _unixSecondsFromNow(
            const Duration(days: 2, hours: 5, minutes: 12),
          ),
        ),
      ),
    );
    await shot(
      'details_adult_warning_above_story_no_countdown',
      _item(contentRating: '+17', tags: const <String>['دراما']),
    );
    await shot(
      'details_adult_warning_hidden_for_non_matching',
      _item(tags: const <String>['دراما'], contentRating: '+13'),
    );
  });
}
