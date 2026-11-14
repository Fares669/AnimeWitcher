import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/features/more/presentation/broadcast_schedule_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _ScheduleNative extends AnimeWitcherNativeProvider {
  _ScheduleNative() : super(Dio(), SettingsRepository(MemoryStorageService()));

  final requests = <Completer<ProviderMediaPage>>[];
  final cancellations = <CancelToken?>[];

  @override
  Future<ProviderMediaPage> getBroadcastSchedulePage(
    String day, {
    int offset = 0,
    int limit = 30,
    bool refresh = false,
    CancelToken? cancelToken,
  }) {
    final request = Completer<ProviderMediaPage>();
    requests.add(request);
    cancellations.add(cancelToken);
    // The test deliberately simulates a request that ignores cancellation.
    return request.future;
  }
}

class _ScheduleRift extends AnimeRiftProvider {
  @override
  Future<ProviderMediaPage> getBroadcastSchedulePage(
    String day, {
    int offset = 0,
    int limit = 30,
    bool refresh = false,
    CancelToken? cancelToken,
  }) async => _page('Rift schedule');
}

class _SelectedProvider extends ActiveProvider {
  _SelectedProvider(this.initial);

  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider? build() => initial;

  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

ProviderMediaPage _page(String title) => ProviderMediaPage(
  items: [
    MultimediaItem(
      title: title,
      url: 'https://animewitcher.test/$title',
      posterUrl: '',
    ),
  ],
  nextOffset: 1,
  hasMore: false,
);

void main() {
  for (final lateError in <Object>[
    StateError('late failure from old request'),
    DioException(requestOptions: RequestOptions(path: '/broadcast')),
  ]) {
    testWidgets(
      'Rift hides Witcher schedule; stale ${lateError.runtimeType} is ignored',
      (tester) async {
        final native = _ScheduleNative();
        final rift = _ScheduleRift();
        final container = ProviderContainer(
          overrides: [
            activeProviderProvider.overrideWith(
              () => _SelectedProvider(native),
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
              home: BroadcastScheduleScreen(),
            ),
          ),
        );
        expect(native.requests, hasLength(1));
        final outstanding = native.requests.single;

        await container.read(activeProviderProvider.notifier).set(rift);
        await tester.pump();
        expect(find.text('Rift schedule'), findsWidgets);
        expect(native.cancellations.single?.isCancelled, isTrue);

        await container.read(activeProviderProvider.notifier).set(native);
        await tester.pump();
        expect(native.requests, hasLength(2));

        outstanding.completeError(lateError);
        await tester.pump();
        expect(find.text('تعذر تحميل جدول البث'), findsNothing);

        native.requests.last.complete(_page('Witcher restored'));
        await tester.pump();
        expect(find.text('Witcher restored'), findsWidgets);
        expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsNothing);

        // A previously loaded Witcher card disappears immediately on Rift.
        await container.read(activeProviderProvider.notifier).set(rift);
        await tester.pump();
        expect(find.text('Witcher restored'), findsNothing);
        expect(find.text('Rift schedule'), findsWidgets);
      },
    );
  }
}
