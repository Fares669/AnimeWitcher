import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/more/presentation/recent_watched_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/catalog_page.dart';
// Match the app's existing Material compatibility API.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../support/memory_storage_service.dart';

const _historySize = 1800;
const _revisionCount = 12;

String _url(int index) => 'https://animewitcher.com/watch/fixture-$index';

class _Fields extends MapBase<String, dynamic> {
  _Fields(this.row, this.onProjection);

  final Map<String, dynamic> row;
  final void Function() onProjection;

  @override
  dynamic operator [](Object? key) {
    // HistoryItem.fromMap reads position exactly once per model projected.
    if (key == 'position') onProjection();
    return row[key];
  }

  @override
  Iterable<String> get keys => row.keys;

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('read-only fixture');

  @override
  void clear() => throw UnsupportedError('read-only fixture');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('read-only fixture');
}

class _Storage extends MemoryStorageService {
  List<Map<String, dynamic>>? _raw;
  List<Map<String, dynamic>> _observed = const [];
  String selected = 'watching';
  int projections = 0;

  @override
  String getSelectedLibraryCategory() => selected;

  @override
  Future<void> setSelectedLibraryCategory(String category) async {
    selected = category;
  }

  @override
  List<MultimediaItem> getLibraryItems({String? category}) => const [];

  @override
  List<Map<String, dynamic>> getWatchHistory() {
    final rows = super.getWatchHistory();
    if (!identical(rows, _raw)) {
      _raw = rows;
      _observed = [for (final row in rows) _Fields(row, () => projections++)];
    }
    return _observed;
  }
}

class _Account extends AnimeWitcherAccountService {
  _Account(StorageService storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  int recentRequests = 0;
  Completer<void>? recentGate;
  bool rejectNext = false;

  @override
  bool get isSignedIn => true;

  @override
  String get accountUid => 'test-library-user';

  @override
  Future<void> syncRecentWatched() async {
    recentRequests++;
    if (rejectNext) {
      rejectNext = false;
      throw StateError('offline fixture');
    }
    await recentGate?.future;
  }

  @override
  Future<Map<LibraryCategory, int>> fetchLibraryCounts({
    bool manga = false,
  }) async => {LibraryCategory.watching: 1};

  @override
  Future<AnimeWitcherLibraryPage> fetchLibraryPage({
    required LibraryCategory category,
    bool manga = false,
    AnimeWitcherLibraryCursor? cursor,
  }) async => AnimeWitcherLibraryPage(
    items: [
      MultimediaItem(
        title: 'Offline shelf fixture',
        url: _url(2000),
        posterUrl: '',
        contentType: MultimediaContentType.anime,
      ),
    ],
    total: 1,
    nextCursor: null,
  );
}

Future<void> _paint(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final phone in [false, true]) {
    testWidgets(
      '${phone ? 'Phone' : 'Desktop'} Library shares a Hive history projection '
      'and refreshes Recent once per entry',
      (tester) async {
        tester.view.physicalSize = phone
            ? const Size(400, 860)
            : const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final storage = _Storage();
        final data = await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp('aw-history-view-');
          Hive.init(dir.path);
          await storage.initHistory();
          final box = Hive.box<dynamic>(StorageService.kHistoryBox);
          await box.putAll({
            for (var i = 0; i < _historySize; i++)
              _url(i): <String, dynamic>{
                'url': _url(i),
                'title': 'Offline history ${i.toString().padLeft(4, '0')}',
                'type': 'anime',
                'provider': 'AnimeWitcher',
                'position': i,
                'duration': 10000,
                'timestamp': 100 + i,
              },
            'old-alias': <String, dynamic>{
              'url': 'http://www.animewitcher.com/watch/fixture-1?old=1',
              'title': 'Stale alias',
              'type': 'anime',
              'timestamp': 10,
            },
          });
          return dir;
        });
        addTearDown(() async {
          await Hive.close();
          await data!.delete(recursive: true);
        });

        final account = _Account(storage);
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(account),
            activeProviderProvider.overrideWithValue(null),
            deviceProfileProvider.overrideWith(
              (_) async => const DeviceProfile(),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              locale: Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: LibraryScreen(),
            ),
          ),
        );
        await _paint(tester);
        expect(account.recentRequests, phone ? 1 : 0);
        final rows = container.read(watchHistoryProvider);
        expect(rows, hasLength(_historySize));
        expect(rows.first.item.url, _url(_historySize - 1));
        expect(rows.where((row) => row.item.url == _url(1)).single.position, 1);

        final readsBefore = storage.projections;
        final revision = container.read(accountDataRevisionProvider.notifier);
        for (var i = 0; i < _revisionCount; i++) {
          revision.bump();
          await tester.pump();
        }
        final history = container.read(historyRepositoryProvider);
        final sameItem = history.getWatchHistoryItem(
          MultimediaItem(title: '', url: rows.first.item.url, posterUrl: ''),
        );
        expect(storage.projections - readsBefore, 0);
        expect(container.read(watchHistoryProvider), same(rows));
        expect(sameItem, same(rows.first));
        expect(() => rows.clear(), throwsUnsupportedError);

        final recent = find.byKey(
          ValueKey(phone ? 'library-list-tab-recent' : 'library-side-recent'),
        );
        final watching = find.byKey(
          ValueKey(
            phone ? 'library-list-tab-watching' : 'library-side-anime-watching',
          ),
        );
        final beforeOpen = account.recentRequests;
        account.recentGate = Completer<void>();
        await tester.ensureVisible(recent);
        await tester.tap(recent);
        await _paint(tester);
        expect(account.recentRequests - beforeOpen, 1);
        expect(find.byType(RecentWatchedBody), findsOneWidget);
        expect(find.text('Offline history 1799'), findsWidgets);
        account.recentGate!.complete();
        account.recentGate = null;
        await _paint(tester);

        await tester.ensureVisible(watching);
        await tester.tap(watching);
        await _paint(tester);
        final beforeReturn = account.recentRequests;
        await tester.ensureVisible(recent);
        await tester.tap(recent);
        await _paint(tester);
        expect(account.recentRequests - beforeReturn, 1);

        await tester.runAsync(
          () => storage.updateHistoryItemTimestampAndPosition(
            _url(1),
            null,
            2100,
            111,
          ),
        );
        revision.bump();
        await _paint(tester);
        final latest = container.read(watchHistoryProvider);
        expect(latest, hasLength(_historySize));
        expect(latest, isNot(same(rows)));
        expect(latest.first.item.url, _url(1));
        expect(latest.first.position, 111);
        expect(rows.first.item.url, _url(_historySize - 1));
        expect(find.text('Offline history 0001'), findsWidgets);

        // Once entry sync ends, even an offline manual refresh leaves history
        // visible and the next manual refresh can retry.
        final recentBody = find.descendant(
          of: find.byType(RecentWatchedBody),
          matching: find.byType(CatalogBody),
        );
        final onRefresh = tester.widget<CatalogBody>(recentBody).onRefresh!;
        final beforeManual = account.recentRequests;
        account.rejectNext = true;
        await onRefresh();
        await tester.pump();
        expect(find.text('Offline history 0001'), findsWidgets);
        await onRefresh();
        await tester.pump();
        expect(account.recentRequests - beforeManual, 2);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
