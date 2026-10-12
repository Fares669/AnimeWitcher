import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/details/presentation/stream_source_prefetch.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _Settings extends GeneralSettingsNotifier {
  _Settings(this.auto);
  final bool auto;
  @override
  GeneralSettings build() => GeneralSettings(autoSelectStreamSource: auto);
}

class _Downloads extends DownloadedFiles {
  _Downloads({this.local = false});
  final bool local;
  @override
  Map<String, File?> build() => const {};
  @override
  Future<File?> resolveFile(MultimediaItem item, {Episode? episode, String? logicalId}) async => local ? File('/tmp/saved.mp4') : null;
}

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

class _Sources extends AnimeWitcherProvider {
  final pending = <Completer<List<StreamResult>>>[];
  @override
  String get packageName => 'test.fresh.sources';
  @override
  String get name => 'Fresh sources';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken}) async => const [];
  @override
  Future<MultimediaItem> getDetails(String url) async => MultimediaItem(title: 'Show', url: url, posterUrl: '');
  @override
  Future<List<StreamResult>> loadStreamSources(String url) {
    final result = Completer<List<StreamResult>>();
    pending.add(result);
    return result.future;
  }
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
}

Future<BuildContext> _shell(WidgetTester tester, _Sources provider, {bool auto = false, bool local = false, NotificationService? notifications}) async {
  await tester.pumpWidget(ProviderScope(overrides: [
    storageServiceProvider.overrideWithValue(MemoryStorageService()),
    generalSettingsProvider.overrideWith(() => _Settings(auto)),
    downloadedFilesProvider.overrideWith(() => _Downloads(local: local)),
    extensionManagerProvider.overrideWith(() => _Extensions(provider)),
    activeProviderProvider.overrideWithValue(provider),
    if (notifications != null) notificationServiceProvider.overrideWithValue(notifications),
  ], child: MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('episode page')),
      )), child: const Text('details page'),
    ))),
  )));
  await tester.pumpAndSettle();
  await tester.tap(find.text('details page'));
  await tester.pumpAndSettle();
  return tester.element(find.text('episode page'));
}

final _item = MultimediaItem(title: 'Show', url: 'https://example.test/show', posterUrl: '');
final _episode = Episode(name: '', url: 'https://example.test/episode/2', episode: 2, serverName: 'الحلقة ٢');
List<StreamResult> _list(String source) => [StreamResult(url: 'https://cdn.test/$source.mp4', source: source)];

void main() {
  test('history retains the original generic name rather than synthesizing a different label', () {
    const original = 'الحلقة ٢';
    final saved = episodeTitleForStorage(episode: 2, title: original);
    expect(saved, original);
    expect(continueWatchingPrimaryLabel(episode: 2, isArabic: true, episodeTitle: saved), original);
  });

  test('history retains decimal and special labels without filename normalization', () {
    for (final original in ['الحلقة ٢.٥', 'الحلقة الخاصة: العودة / الجزء؟', '  الحلقة ٢  ']) {
      expect(episodeTitleForStorage(episode: 2, title: original), original);
      expect(continueWatchingPrimaryLabel(episode: 2, isArabic: true, episodeServerName: original), original);
    }
  });

  testWidgets('watching chooser fetches again after a successful list was cached', (tester) async {
    final provider = _Sources();
    final context = await _shell(tester, provider);
    final container = ProviderScope.containerOf(context);
    final prefetch = container.read(streamSourcePrefetchProvider);
    final cached = prefetch.sources(provider, _episode.url);
    provider.pending.single.complete(_list('cached'));
    await cached;
    final launcher = container.read(playbackLauncherProvider);
    final first = launcher.chooseSourceForItem(context, _item, _episode.url, episode: _episode);
    await tester.pump();
    expect(provider.pending, hasLength(2));
    provider.pending.last.complete(_list('fresh-first'));
    await tester.pumpAndSettle();
    expect(find.text('fresh-first'), findsOneWidget);
    expect(find.text('cached'), findsNothing);
    Navigator.of(tester.element(find.text('fresh-first'))).pop();
    await tester.pumpAndSettle();
    expect(await first, isNull);
    final second = launcher.chooseSourceForItem(context, _item, _episode.url, episode: _episode);
    await tester.pump();
    expect(provider.pending, hasLength(3));
    provider.pending.last.complete(_list('fresh-second'));
    await tester.pumpAndSettle();
    expect(find.text('fresh-second'), findsOneWidget);
    Navigator.of(tester.element(find.text('fresh-second'))).pop();
    await tester.pumpAndSettle();
    expect(await second, isNull);
  });

  testWidgets('older canceled chooser completion cannot replace a newer source list', (tester) async {
    final provider = _Sources();
    final context = await _shell(tester, provider);
    final launcher = ProviderScope.containerOf(context).read(playbackLauncherProvider);
    final old = launcher.chooseSourceForItem(context, _item, _episode.url, episode: _episode);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    Navigator.of(context, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    expect(await old, isNull);
    final current = launcher.chooseSourceForItem(context, _item, _episode.url, episode: _episode);
    await tester.pump();
    expect(provider.pending, hasLength(2));
    provider.pending.last.complete(_list('current'));
    await tester.pumpAndSettle();
    provider.pending.first.complete(_list('stale'));
    await tester.pumpAndSettle();
    expect(find.text('current'), findsOneWidget);
    expect(find.text('stale'), findsNothing);
    Navigator.of(tester.element(find.text('current'))).pop();
    await tester.pumpAndSettle();
    expect(await current, isNull);
  });

  testWidgets('local episode bypasses fresh watching source discovery', (tester) async {
    final provider = _Sources();
    final context = await _shell(tester, provider, local: true);
    final source = await ProviderScope.containerOf(context).read(playbackLauncherProvider).chooseSourceForItem(context, _item, _episode.url, episode: _episode);
    expect(source!.source, 'محلي');
    expect(provider.pending, isEmpty);
  });

  for (final fails in [false, true]) {
    testWidgets('auto download source failure keeps its caller route fails=$fails and permits retry', (tester) async {
      final provider = _Sources();
      final notifications = NotificationService();
      addTearDown(notifications.dispose);
      final context = await _shell(tester, provider, auto: true, notifications: notifications);
      final launcher = ProviderScope.containerOf(context).read(downloadLauncherProvider);
      final first = launcher.launch(context, _item, episode: _episode);
      await tester.pump();
      if (fails) {
        provider.pending.single.completeError(StateError('source unavailable'));
      } else {
        provider.pending.single.complete(const []);
      }
      await tester.pump();
      await first;
      expect(find.text('episode page'), findsOneWidget);
      expect(notifications.toasts, hasLength(1));
      final retry = launcher.launch(context, _item, episode: _episode);
      await tester.pump();
      expect(provider.pending, hasLength(2));
      provider.pending.last.complete(const []);
      await tester.pump();
      await retry;
      expect(find.text('episode page'), findsOneWidget);
      expect(notifications.toasts, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
