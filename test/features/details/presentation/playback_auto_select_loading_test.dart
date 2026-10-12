import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/loading_dialog.dart';
import 'package:animewitcher/shared/widgets/loading_indicator.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _AutoSettings extends GeneralSettingsNotifier {
  @override
  GeneralSettings build() => const GeneralSettings(autoSelectStreamSource: true);
}

final class _NoDownloads extends DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};

  @override
  Future<File?> resolveFile(MultimediaItem item, {Episode? episode, String? logicalId}) async {
    return null;
  }
}

final class _StubExtensions extends ExtensionManager {
  _StubExtensions(this.provider);

  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

final class _PendingSourceProvider extends AnimeWitcherProvider {
  _PendingSourceProvider(this.sources);

  final Completer<List<StreamResult>> sources;

  @override
  String get packageName => 'fake.playback';

  @override
  String get name => 'Fake playback';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.anime,
  };

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async =>
      const <String, List<MultimediaItem>>{};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const <MultimediaItem>[];

  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Show', url: url, posterUrl: '');

  @override
  Future<List<StreamResult>> loadStreamSources(String url) => sources.future;

  @override
  Future<List<StreamResult>> loadStreams(String url) async =>
      const <StreamResult>[];
}

void main() {
  testWidgets('auto server selection shows loading dialog while sources load', (
    tester,
  ) async {
    final pending = Completer<List<StreamResult>>();
    final provider = _PendingSourceProvider(pending);
    StreamResult? selected;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          generalSettingsProvider.overrideWith(_AutoSettings.new),
          downloadedFilesProvider.overrideWith(_NoDownloads.new),
          extensionManagerProvider.overrideWith(
            () => _StubExtensions(provider),
          ),
          activeProviderProvider.overrideWithValue(provider),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  unawaited(
                    ProviderScope.containerOf(context)
                        .read(playbackLauncherProvider)
                        .chooseSourceForItem(
                          context,
                          MultimediaItem(
                            title: 'Show',
                            url: 'https://example.test/show',
                            posterUrl: '',
                          ),
                          'https://example.test/ep1',
                          episode: Episode(
                            name: '',
                            url: 'https://example.test/ep1',
                            episode: 1,
                            serverName: 'الحلقة 1',
                          ),
                        )
                        .then((value) => selected = value),
                  );
                },
                child: const Text('play'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('play'));
    await tester.pump();

    expect(find.byType(LoadingDialog), findsOneWidget);
    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    expect(find.text('جارٍ التحميل...'), findsOneWidget);

    pending.complete(const <StreamResult>[
      StreamResult(url: 'https://cdn.test/video.mp4', source: 'PD', quality: '1080'),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(LoadingDialog), findsNothing);
    expect(selected?.source, 'PD');
  });
}
