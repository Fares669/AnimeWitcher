import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/theme/app_theme.dart';
import 'package:animewitcher/features/details/presentation/adult_content_warning.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_ratings_row.dart';
import 'package:animewitcher/features/details/presentation/widgets/scale_rating_bar.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

class _FakeAccountService extends AnimeWitcherAccountService {
  _FakeAccountService({
    this.signedIn = false,
    this.userRating,
  }) : super(
         storage: StorageService(),
         secureStorage: SecureTokenStorage(StorageService()),
       );

  final bool signedIn;
  int? userRating;
  final bool reviewsClosedLive = false;
  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];

  @override
  bool get isSignedIn => signedIn;

  @override
  AnimeWitcherAccountSnapshot get snapshot => AnimeWitcherAccountSnapshot(
    profile: signedIn
        ? const AnimeWitcherProfile(
            documentId: 'user-doc',
            uid: 'uid-1',
            signInMethod: AnimeWitcherSignInMethod.google,
            userName: 'Me',
          )
        : null,
  );

  @override
  Future<int?> loadAnimeUserRating(String animeId) async => userRating;

  @override
  Future<int?> saveAnimeUserRating(String animeId, int rate) async {
    writes.add('$animeId:$rate');
    userRating = rate;
    return rate;
  }

  @override
  Future<void> clearAnimeUserRating(String animeId) async {
    deletes.add(animeId);
    userRating = null;
  }

  @override
  Future<bool> isAnimeReviewsClosed(String animeId) async => reviewsClosedLive;

  @override
  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    return const AnimeWitcherCommentPage(
      items: <AnimeWitcherComment>[],
      cursor: null,
      hasMore: false,
    );
  }
}

class _FixedAccountController extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return ref.read(animeWitcherAccountServiceProvider).snapshot;
  }
}

MultimediaItem _item({
  List<String>? tags,
  String? contentRating,
  Map<String, String>? syncData,
  NextAiring? nextAiring,
  ShowStatus status = ShowStatus.ongoing,
  String? imdbId,
}) {
  return MultimediaItem(
    title: 'تجريبي',
    url: 'https://animewitcher.com/anime/test-anime',
    posterUrl: '',
    tags: tags,
    contentRating: contentRating,
    syncData: syncData,
    nextAiring: nextAiring,
    status: status,
    imdbId: imdbId,
    description: 'قصة الأنمي تظهر هنا مع الوسوم.',
  );
}

int _unixSecondsFromNow(Duration remaining) {
  return DateTime.now().toUtc().add(remaining).millisecondsSinceEpoch ~/ 1000;
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

Widget _app({
  required Widget child,
  required _FakeAccountService service,
  String? fontFamily,
  Key? boundaryKey,
}) {
  final content = ProviderScope(
    overrides: [
      animeWitcherAccountServiceProvider.overrideWithValue(service),
      animeWitcherAccountControllerProvider.overrideWith(
        _FixedAccountController.new,
      ),
    ],
    child: MaterialApp(
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
    ),
  );
  if (boundaryKey == null) return content;
  return RepaintBoundary(key: boundaryKey, child: content);
}

Future<void> _pumpStack(
  WidgetTester tester, {
  required MultimediaItem item,
  _FakeAccountService? service,
  bool showCountdown = true,
  bool showRatingsSummary = true,
  Key? boundaryKey,
  String? fontFamily,
}) {
  return tester.pumpWidget(
    _app(
      service: service ?? _FakeAccountService(),
      fontFamily: fontFamily,
      boundaryKey: boundaryKey,
      child: DetailsCountdownAndStory(
        item: item,
        showCountdown: showCountdown,
        showRatingsSummary: showRatingsSummary,
        storyCard: _storyCard(),
      ),
    ),
  );
}

Map<String, String> _ratedSync({
  String score = '9.1',
  String? scoreCount,
  String mal = '8.73',
  String users = '668508',
  String malId = '20',
  bool reviewsClosed = false,
  String? state,
}) {
  return <String, String>{
    'awScore': score,
    if (scoreCount != null) 'awScoreCount': scoreCount,
    'awMalScore': mal,
    'awMalScoringUsers': users,
    'malId': malId,
    if (reviewsClosed) 'awReviewsClosed': 'true',
    if (state != null) 'awState': state,
  };
}

void main() {
  testWidgets('sits between the adult warning and the story card', (
    tester,
  ) async {
    await _pumpStack(
      tester,
      item: _item(
        tags: const <String>['ايتشي'],
        nextAiring: NextAiring(
          episode: 2,
          unixTime: _unixSecondsFromNow(const Duration(hours: 4)),
        ),
        syncData: _ratedSync(),
      ),
    );
    await tester.pump();

    final countdown = tester.getRect(find.byType(NextAiringWidget));
    final banner = tester.getRect(find.byKey(kAdultContentWarningKey));
    final ratings = tester.getRect(find.byKey(kDetailsRatingsRowKey));
    final story = tester.getRect(find.byKey(const ValueKey('story-card')));

    expect(banner.top, greaterThanOrEqualTo(countdown.bottom));
    expect(ratings.top, greaterThanOrEqualTo(banner.bottom));
    expect(story.top, greaterThanOrEqualTo(ratings.bottom));
  });

  testWidgets('sits between countdown and story when there is no warning', (
    tester,
  ) async {
    await _pumpStack(
      tester,
      item: _item(
        tags: const <String>['دراما'],
        nextAiring: NextAiring(
          episode: 2,
          unixTime: _unixSecondsFromNow(const Duration(hours: 4)),
        ),
        syncData: _ratedSync(),
      ),
    );
    await tester.pump();

    expect(find.byKey(kAdultContentWarningKey), findsNothing);
    final countdown = tester.getRect(find.byType(NextAiringWidget));
    final ratings = tester.getRect(find.byKey(kDetailsRatingsRowKey));
    final story = tester.getRect(find.byKey(const ValueKey('story-card')));
    expect(ratings.top, greaterThanOrEqualTo(countdown.bottom));
    expect(story.top, greaterThanOrEqualTo(ratings.bottom));
  });

  testWidgets('sits immediately above the story when there is no countdown', (
    tester,
  ) async {
    await _pumpStack(
      tester,
      item: _item(syncData: _ratedSync()),
      showCountdown: false,
    );

    expect(find.byType(NextAiringWidget), findsNothing);
    final ratings = tester.getRect(find.byKey(kDetailsRatingsRowKey));
    final story = tester.getRect(find.byKey(const ValueKey('story-card')));
    expect(story.top, greaterThanOrEqualTo(ratings.bottom));
  });

  testWidgets('places Witcher on the visual left and MAL on the right', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpStack(
      tester,
      item: _item(syncData: _ratedSync()),
      showCountdown: false,
    );

    final witcher = tester.getRect(find.byKey(kDetailsRatingsWitcherKey));
    final mal = tester.getRect(find.byKey(kDetailsRatingsMalKey));
    expect(witcher.left, lessThan(mal.left));
    expect(find.text('تقييم انمي ويتشر'), findsOneWidget);
    expect(find.text('قيّم'), findsOneWidget);
    expect(find.text('المراجعات'), findsOneWidget);
    expect(find.text('9.1'), findsOneWidget);
    expect(find.text('8.73'), findsOneWidget);
    expect(find.text('(668508)'), findsOneWidget);
    expect(find.textContaining('تصويت'), findsNothing);
    final malStar = tester.getRect(find.byKey(kDetailsRatingsMalStarKey));
    final malScore = tester.getRect(find.text('8.73'));
    expect(malStar.left, lessThan(malScore.left));
    final badge = tester.widget<Container>(
      find.byKey(kDetailsRatingsMalBadgeKey),
    );
    expect((badge.decoration as BoxDecoration).color, kMalBadgeBlue);
    final malLabel = tester.widget<Text>(
      find.descendant(
        of: find.byKey(kDetailsRatingsMalBadgeKey),
        matching: find.text('MAL'),
      ),
    );
    expect(malLabel.style?.color, Colors.white);
    Color buttonFill(Key key) {
      return tester
          .widget<Material>(
            find
                .descendant(
                  of: find.byKey(key),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color!;
    }

    expect(
      buttonFill(kDetailsRatingsReviewsButtonKey),
      buttonFill(kDetailsRatingsRateButtonKey),
    );
    expect(
      buttonFill(kDetailsRatingsReviewsButtonKey),
      isNot(AppTheme.animeWitcherAccent.withValues(alpha: 0.16)),
    );
    final star1 = tester.getRect(
      find.descendant(
        of: find.byKey(kDetailsRatingsUserStarsKey),
        matching: find.bySemanticsLabel('1'),
      ),
    );
    final star10 = tester.getRect(
      find.descendant(
        of: find.byKey(kDetailsRatingsUserStarsKey),
        matching: find.bySemanticsLabel('10'),
      ),
    );
    expect(star1.left, lessThan(star10.left));
  });

  testWidgets('metadata bar places compact ratings below episode and type', (
    tester,
  ) async {
    final item = _item(
      syncData: <String, String>{
        ..._ratedSync(),
        'awEpisodes': '20',
        'awType': 'مسلسل',
      },
    );
    expect(hasDetailsRatingsSummary(item), isTrue);

    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(),
        child: MetadataBar(item: item),
      ),
    );

    final typeRect = tester.getRect(find.text('مسلسل'));
    final ratingRect = tester.getRect(find.byKey(kDetailsRatingsCompactKey));
    expect(ratingRect.top, greaterThanOrEqualTo(typeRect.bottom));
    expect(find.text('9.1'), findsOneWidget);
    expect(find.text('8.73'), findsOneWidget);
  });

  testWidgets('compact summary puts Witcher left, source right, with one dot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(),
        child: DetailsRatingsSummary(item: _item(syncData: _ratedSync())),
      ),
    );

    final witcher = tester.getRect(
      find.byKey(kDetailsRatingsCompactWitcherKey),
    );
    final external = tester.getRect(
      find.byKey(kDetailsRatingsCompactExternalKey),
    );
    expect(witcher.left, lessThan(external.left));
    expect(find.text('•'), findsOneWidget);

    final star = tester.getRect(find.byIcon(Icons.star_rounded));
    final witcherScore = tester.getRect(find.text('9.1'));
    expect(star.left, lessThan(witcherScore.left));

    final badge = tester.getRect(
      find.byKey(kDetailsRatingsCompactExternalBadgeKey),
    );
    final malScore = tester.getRect(find.text('8.73'));
    expect(badge.left, lessThan(malScore.left));
    final badgeWidget = tester.widget<Container>(
      find.byKey(kDetailsRatingsCompactExternalBadgeKey),
    );
    expect((badgeWidget.decoration as BoxDecoration).color, kMalBadgeBlue);
  });

  testWidgets('mobile actions-only rating card hides score columns', (tester) async {
    await _pumpStack(
      tester,
      item: _item(syncData: _ratedSync()),
      showCountdown: false,
      showRatingsSummary: false,
    );

    expect(find.byKey(kDetailsRatingsWitcherKey), findsNothing);
    expect(find.byKey(kDetailsRatingsMalKey), findsNothing);
    expect(find.byKey(kDetailsRatingsRateButtonKey), findsOneWidget);
    expect(find.byKey(kDetailsRatingsReviewsButtonKey), findsOneWidget);
  });

  testWidgets('compact summary uses the IMDb badge on the right', (tester) async {
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(),
        child: DetailsRatingsSummary(
          item: _item(
            imdbId: 'tt0283754',
            syncData: const <String, String>{
              'awScore': '8.37',
              'awImdbId': 'tt0283754',
              'awImdbScore': '7.4',
            },
          ),
        ),
      ),
    );

    final witcher = tester.getRect(
      find.byKey(kDetailsRatingsCompactWitcherKey),
    );
    final external = tester.getRect(
      find.byKey(kDetailsRatingsCompactExternalKey),
    );
    expect(witcher.left, lessThan(external.left));
    expect(find.text('IMDb'), findsOneWidget);
    final badgeWidget = tester.widget<Container>(
      find.byKey(kDetailsRatingsCompactExternalBadgeKey),
    );
    expect((badgeWidget.decoration as BoxDecoration).color, kImdbBadgeYellow);
    final badge = tester.getRect(
      find.byKey(kDetailsRatingsCompactExternalBadgeKey),
    );
    final score = tester.getRect(find.text('7.4'));
    expect(badge.left, lessThan(score.left));
  });

  testWidgets('shows IMDb fallback when MAL is unavailable', (tester) async {
    await _pumpStack(
      tester,
      item: _item(
        imdbId: 'tt0283754',
        syncData: const <String, String>{
          'awScore': '8.37',
          'awImdbId': 'tt0283754',
          'awImdbScore': '7.4',
        },
      ),
      showCountdown: false,
    );

    expect(find.byKey(kDetailsRatingsMalKey), findsNothing);
    expect(find.byKey(kDetailsRatingsImdbKey), findsOneWidget);
    expect(find.text('IMDb'), findsOneWidget);
    expect(find.text('7.4'), findsOneWidget);
    expect(find.text('IMDb Score'), findsOneWidget);
    final badge = tester.widget<Container>(
      find.byKey(kDetailsRatingsImdbBadgeKey),
    );
    expect((badge.decoration as BoxDecoration).color, kImdbBadgeYellow);
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(kDetailsRatingsImdbBadgeKey),
        matching: find.text('IMDb'),
      ),
    );
    expect(label.style?.color, Colors.black);
    final star = tester.widget<Icon>(find.byKey(kDetailsRatingsImdbStarKey));
    expect(star.color, kImdbBadgeYellow);
  });

  testWidgets('hides the MAL column without mal_id or imdb_id', (tester) async {
    await _pumpStack(
      tester,
      item: _item(
        syncData: const <String, String>{'awScore': '8.1', 'awMalScore': '7.4'},
      ),
      showCountdown: false,
    );
    expect(find.byKey(kDetailsRatingsMalKey), findsNothing);
    expect(find.byKey(kDetailsRatingsWitcherKey), findsOneWidget);
    expect(find.text('المراجعات'), findsOneWidget);
  });

  testWidgets('hides the rate button for unaired titles', (tester) async {
    await _pumpStack(
      tester,
      item: _item(
        status: ShowStatus.upcoming,
        syncData: _ratedSync(state: 'لم يتم بثه بعد'),
      ),
      showCountdown: false,
    );
    expect(find.byKey(kDetailsRatingsRateButtonKey), findsNothing);
    expect(find.byKey(kDetailsRatingsReviewsButtonKey), findsOneWidget);
    expect(find.text('(0)'), findsOneWidget);
  });

  testWidgets('shows a real Witcher vote count when rating.num exists', (
    tester,
  ) async {
    await _pumpStack(
      tester,
      item: _item(syncData: _ratedSync(scoreCount: '1200')),
      showCountdown: false,
    );
    expect(find.text('1200 تصويت'), findsOneWidget);
  });

  testWidgets('rate requires login and toasts the APK copy', (tester) async {
    final service = _FakeAccountService();
    await _pumpStack(
      tester,
      service: service,
      item: _item(syncData: _ratedSync()),
      showCountdown: false,
    );
    await tester.tap(find.byKey(kDetailsRatingsRateButtonKey));
    await tester.pump();
    final notifications = ProviderScope.containerOf(
      tester.element(find.byKey(kDetailsRatingsRowKey)),
    ).read(notificationServiceProvider);
    expect(
      notifications.toasts.map((toast) => toast.message),
      contains(kRateLoginRequiredToast),
    );
    expect(find.text('قيّم'), findsOneWidget);
    expect(find.text('تأكيد'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('reviews_closed toasts the APK copy and does not open the list', (
    tester,
  ) async {
    await _pumpStack(
      tester,
      item: _item(syncData: _ratedSync(reviewsClosed: true)),
      showCountdown: false,
    );
    await tester.tap(find.byKey(kDetailsRatingsReviewsButtonKey));
    await tester.pump();
    final notifications = ProviderScope.containerOf(
      tester.element(find.byKey(kDetailsRatingsRowKey)),
    ).read(notificationServiceProvider);
    expect(
      notifications.toasts.map((toast) => toast.message),
      contains(kReviewsClosedToast),
    );
    expect(find.text('المراجعات'), findsWidgets);
    expect(find.text('لا توجد مراجعات منشورة بعد.'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('reviews button opens the Firestore reviews list page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpStack(
      tester,
      item: _item(syncData: _ratedSync()),
      showCountdown: false,
    );
    await tester.tap(find.byKey(kDetailsRatingsReviewsButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('لا توجد مراجعات منشورة بعد.'), findsOneWidget);
    expect(find.text('المراجعات'), findsWidgets);
    expect(
      find.text('سجّل الدخول إلى حساب AnimeWitcher لإضافة مراجعة.'),
      findsOneWidget,
    );
  });

  testWidgets('signed-in rate dialog writes the selected integer', (
    tester,
  ) async {
    final service = _FakeAccountService(signedIn: true, userRating: 4);
    await _pumpStack(
      tester,
      service: service,
      item: _item(syncData: _ratedSync()),
      showCountdown: false,
    );
    await tester.pump();
    expect(find.text('4/10'), findsOneWidget);
    await tester.tap(find.byKey(kDetailsRatingsRateButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('4 /10'), findsOneWidget);
    final dialogStars = find.descendant(
      of: find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(ScaleRatingBar),
      ),
      matching: find.byType(InkWell),
    );
    expect(dialogStars, findsNWidgets(10));
    await tester.tap(dialogStars.at(9));
    await tester.pumpAndSettle();
    expect(find.text('10 /10'), findsOneWidget);
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();
    expect(service.writes, contains('test-anime:10'));
    expect(service.userRating, 10);
    expect(find.text('10/10'), findsOneWidget);
    final rateIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(kDetailsRatingsRateButtonKey),
        matching: find.byIcon(Icons.star_rounded),
      ),
    );
    expect(rateIcon.color, AppTheme.animeWitcherAccent);
  });

  testWidgets('dialog stars stay LTR with 1 on the left', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpStack(
      tester,
      service: _FakeAccountService(signedIn: true, userRating: 1),
      item: _item(syncData: _ratedSync()),
      showCountdown: false,
    );
    await tester.pump();
    await tester.tap(find.byKey(kDetailsRatingsRateButtonKey));
    await tester.pumpAndSettle();
    final dialogBar = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(ScaleRatingBar),
    );
    final first = tester.getRect(
      find.descendant(of: dialogBar, matching: find.bySemanticsLabel('1')),
    );
    final tenth = tester.getRect(
      find.descendant(of: dialogBar, matching: find.bySemanticsLabel('10')),
    );
    expect(first.left, lessThan(tenth.left));
  });

  testWidgets('ratings screenshots', (tester) async {
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

    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await shot(
      'details_ratings_between_warning_and_story',
      _item(
        tags: const <String>['ايتشي', 'خيال'],
        nextAiring: NextAiring(
          episode: 8,
          unixTime: _unixSecondsFromNow(
            const Duration(days: 2, hours: 5, minutes: 12),
          ),
        ),
        syncData: _ratedSync(),
      ),
    );
    await shot(
      'details_ratings_between_countdown_and_story',
      _item(
        tags: const <String>['دراما'],
        nextAiring: NextAiring(
          episode: 3,
          unixTime: _unixSecondsFromNow(const Duration(hours: 6)),
        ),
        syncData: _ratedSync(),
      ),
    );
    await shot(
      'details_ratings_above_story_no_countdown',
      _item(syncData: _ratedSync()),
    );
    await shot(
      'details_ratings_mal_hidden',
      _item(syncData: const <String, String>{'awScore': '8.4'}),
    );

    const ratedKey = ValueKey('details_ratings_after_user_rates');
    await _pumpStack(
      tester,
      service: _FakeAccountService(signedIn: true, userRating: 8),
      item: _item(syncData: _ratedSync()),
      fontFamily: 'NotoSansArabic',
      boundaryKey: ratedKey,
      showCountdown: false,
    );
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(ratedKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/details_ratings_after_user_rates.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });

    await tester.tap(find.byKey(kDetailsRatingsRateButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('8 /10'), findsOneWidget);
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(ratedKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/details_rate_dialog.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
