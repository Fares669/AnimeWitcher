import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_auto_sync.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_pending.dart';
import 'package:animewitcher/core/storage/anime_rift_rating.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_rating_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _url = 'https://anime-rift.com/anime/rating-test';
const _initial = AnimeRiftRating(
  story: 8,
  characters: 8,
  animation: 8,
  music: 8,
);

class _MemoryStorage extends StorageService {
  final values = <String, String>{};
  Completer<void>? failWriteAfter;

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (failWriteAfter case final gate?) {
      await gate.future;
      throw StateError('Journal persistence failed');
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

class _Rift extends AnimeRiftProvider {
  @override
  Future<bool> restoreAccountSession() async => true;

  @override
  Future<AnimeRiftRating?> fetchCloudRating(String url) async => _initial;
}

class _DelayedWriter implements AnimeRiftVerifiedCloudWriter {
  final release = Completer<void>();
  final changes = <AnimeRiftCloudPendingChange>[];

  @override
  Future<bool> write(
    String accountHash,
    AnimeRiftCloudPendingChange change,
  ) async {
    AnimeRiftCloudPendingJournal.requireAccount(accountHash);
    changes.add(change);
    await release.future;
    return true;
  }
}

class _RatingHost extends ConsumerStatefulWidget {
  const _RatingHost();

  @override
  ConsumerState<_RatingHost> createState() => _RatingHostState();
}

class _RatingHostState extends ConsumerState<_RatingHost> {
  int? score = 8;
  AnimeRatingOutcome? outcome;
  final seenScores = <int?>[];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('score:$score'),
        Text(outcome == null ? 'saving' : 'changed:${outcome!.changed}'),
        TextButton(
          onPressed: () async {
            final result = await openRiftRatingDialog(
              context,
              ref,
              MultimediaItem(
                title: 'Rift rating',
                url: _url,
                posterUrl: '',
                provider: animeRiftProviderId,
              ),
              onOptimisticRating: (value) => setState(() {
                seenScores.add(value);
                score = value;
              }),
            );
            if (mounted) setState(() => outcome = result);
          },
          child: const Text('rate'),
        ),
      ],
    ),
  );
}

Future<void> _selectSixAndSave(WidgetTester tester) async {
  await tester.tap(find.text('rate'));
  await tester.pumpAndSettle();
  for (var index = 0; index < 4; index++) {
    tester
        .widget<Slider>(find.byKey(ValueKey('rift-rating-$index')))
        .onChanged!(6);
    await tester.pump();
  }
  await tester.tap(find.text('حفظ'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AnimeRiftLocalAccountScope.activate('test'));
  tearDown(AnimeRiftLocalAccountScope.reset);

  for (final failJournal in [false, true]) {
    testWidgets(
      failJournal
          ? 'Rift rating rolls back when durable journal write fails'
          : 'Rift rating updates and returns before delayed cloud confirmation',
      (tester) async {
        final storage = _MemoryStorage();
        if (failJournal) storage.failWriteAfter = Completer<void>();
        final provider = _Rift();
        final writer = _DelayedWriter();
        final notifications = NotificationService();
        final sync = AnimeRiftAutoSyncCoordinator(
          storage: storage,
          activeRift: () => provider,
          verifiedWriter: writer,
          debounce: const Duration(days: 1),
        );
        addTearDown(sync.dispose);
        addTearDown(notifications.clearToasts);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeProviderProvider.overrideWithValue(provider),
              storageServiceProvider.overrideWithValue(storage),
              riftAutoSyncProvider.overrideWithValue(sync),
              notificationServiceProvider.overrideWithValue(notifications),
            ],
            child: const MaterialApp(home: _RatingHost()),
          ),
        );
        await _selectSixAndSave(tester);
        final host = tester.state<_RatingHostState>(find.byType(_RatingHost));
        expect(find.text('score:6'), findsOneWidget);
        expect(host.seenScores, [6]);
        expect(writer.release.isCompleted, isFalse);

        if (failJournal) {
          expect(host.outcome, isNull);
          expect(writer.changes, isEmpty);
          storage.failWriteAfter!.complete();
          await tester.pumpAndSettle();
          expect(find.text('score:8'), findsOneWidget);
          expect(host.seenScores, [6, 8]);
          expect(host.outcome?.changed, isFalse);
          expect(sync.hasPendingRating(_url), isFalse);
          expect(writer.changes, isEmpty);
          expect(
            notifications.toasts.single.message,
            'تعذر حفظ تقييم Anime Rift',
          );
        } else {
          expect(host.outcome, (changed: true, rating: 6));
          expect(writer.changes, hasLength(1));
          expect(sync.pendingRating(_url)?.general, 6);
          expect(sync.hasPendingRating(_url), isTrue);
          writer.release.complete();
          await tester.pumpAndSettle();
          expect(sync.hasPendingRating(_url), isFalse);
          expect(find.text('score:6'), findsOneWidget);
          expect(host.seenScores, [6]);
        }
        notifications.clearToasts();
        sync.dispose();
      },
    );
  }
}
