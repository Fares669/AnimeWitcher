import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/widgets/anime4k_sample_preview.dart';
import 'package:animewitcher/features/settings/presentation/app_version_provider.dart';
import 'package:animewitcher/features/settings/presentation/settings_screen.dart';
import 'package:animewitcher/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

const _assetHash =
    '43e757ad7e1a018aa3bb466b52b46c6b2db6d52cc6960492183ef969f5e401c0';
const _sampleBytes = 59075;

final class _Storage extends MemoryStorageService {
  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (settings[key] ?? defaultValue) as T?;

  @override
  Future<void> setPlayerSetting(String key, dynamic value) async {
    settings[key] = value;
  }
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

typedef _IoEvent = ({String kind, int bytes, bool flush, String sha});

final class _ObservedIo extends IOOverrides {
  _ObservedIo(this.path);

  final String path;
  final events = <_IoEvent>[];
  int sampleOpens = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (!p.equals(path, this.path)) return file;
    sampleOpens++;
    return _ObservedSampleFile(file, events);
  }
}

final class _ObservedSampleFile implements File {
  _ObservedSampleFile(this.real, this.events);

  final File real;
  final List<_IoEvent> events;

  @override
  String get path => real.path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await real.writeAsBytes(bytes, mode: mode, flush: flush);
    events.add((
      kind: 'write',
      bytes: bytes.length,
      flush: flush,
      sha: sha256.convert(bytes).toString(),
    ));
    return this;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    final bytes = await real.readAsBytes();
    events.add((
      kind: 'read',
      bytes: bytes.length,
      flush: false,
      sha: sha256.convert(bytes).toString(),
    ));
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

List<_IoEvent> get _copiedOnce => const <_IoEvent>[
  (kind: 'write', bytes: _sampleBytes, flush: true, sha: _assetHash),
  (kind: 'read', bytes: _sampleBytes, flush: false, sha: _assetHash),
];

Uint8List _view(ByteData bytes) => bytes.buffer.asUint8List(
  bytes.offsetInBytes,
  bytes.lengthInBytes,
);

Finder get _preview => find.byType(Anime4kSamplePreview);
Finder get _dialog => find.byType(AlertDialog);
Finder get _tile => find.byWidgetPredicate(
  (widget) => widget is SettingsTile && widget.title == 'Anime4K',
  description: 'the actual Anime4K Settings tile',
);

Future<void> _settings(WidgetTester tester, _Storage storage) async {
  await tester.binding.setSurfaceSize(const Size(1100, 950));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        appVersionProvider.overrideWith((ref) async => 'test'),
        deviceProfileProvider.overrideWith((ref) async => const DeviceProfile()),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final settingsScroll = find.descendant(
    of: find.byType(SettingsScreen),
    matching: find.byType(Scrollable),
  ).first;
  await tester.scrollUntilVisible(
    _tile,
    260,
    scrollable: settingsScroll,
    maxScrolls: 38,
  );
  await _alignInScroll(tester, _tile);
  expect(_tile, findsOneWidget);
}

// Settings intentionally extends behind an overlay app bar. Center the
// actual hit target in the list instead of testing a top-aligned row under it.
Future<void> _alignInScroll(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pump();
}

Future<Digest> _bundlePixels(WidgetTester tester) async {
  final expected = await tester.runAsync(() async {
    final data = await rootBundle.load(Anime4kSamplePreview.assetPath);
    final bytes = _view(data);
    expect(bytes.length, _sampleBytes);
    expect(sha256.convert(bytes).toString(), _assetHash);
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        expect((frame.image.width, frame.image.height), (500, 500));
        final rgba = (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        expect(rgba.lengthInBytes, 500 * 500 * 4);
        return sha256.convert(_view(rgba));
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });
  expect(expected, isNotNull);
  return expected!;
}

Future<void> _assertVisiblePreview(
  WidgetTester tester,
  Digest expected, {
  required String folder,
  Anime4kQuality quality = Anime4kQuality.m,
}) async {
  await pumpUntil(
    tester,
    () => _preview.evaluate().length == 1 &&
        tester.widget<Anime4kSamplePreview>(_preview).quality == quality,
    'actual Settings Anime4K dialog to mount its preview',
  );
  final panel = tester.widget<Anime4kSamplePreview>(_preview);
  expect(panel.mode, Anime4kMode.a);
  expect(panel.shaderDirectory, folder);
  expect(_dialog, findsOneWidget);
  await _alignInScroll(tester, _preview);
  final raw = find.descendant(
    of: _preview,
    matching: find.byType(RawImage),
  );
  bool ready() {
    final images = tester.widgetList<RawImage>(raw).toList();
    return images.length == 2 && images.every((image) => image.image != null);
  }
  await pumpUntil(tester, ready, 'both real decoded Anime4K image layers');
  expect(_preview.hitTestable(), findsOneWidget);
  expect(
    find.descendant(
      of: _preview,
      matching: find.byType(CircularProgressIndicator),
    ),
    findsNothing,
  );
  final images = tester.widgetList<RawImage>(raw).map((raw) => raw.image!).toList();
  expect(images, hasLength(2));
  for (final image in images) {
    expect((image.width, image.height), (500, 500));
    final actual = await tester.runAsync(() async {
      final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(rgba.lengthInBytes, 500 * 500 * 4);
      return sha256.convert(_view(rgba));
    });
    expect(actual, expected);
  }
}

Future<void> _openByTitle(WidgetTester tester) async {
  final title = find.descendant(of: _tile, matching: find.text('Anime4K'));
  await _alignInScroll(tester, title);
  expect(title.hitTestable(), findsOneWidget);
  await tester.tap(title);
}

Future<void> _close(WidgetTester tester) async {
  final done = find.descendant(
    of: _dialog,
    matching: find.widgetWithText(TextButton, 'تم'),
  );
  expect(done.hitTestable(), findsOneWidget);
  await tester.tap(done);
  await pumpUntil(
    tester,
    () => _dialog.evaluate().isEmpty,
    'actual Anime4K dialog dismissal',
  );
  await tester.pumpAndSettle();
  expect(_preview, findsNothing);
}

void _trace(String opening, List<_IoEvent> delta, int opens, Digest rgba) {
  final writes = delta.where((event) => event.kind == 'write');
  final reads = delta.where((event) => event.kind == 'read');
  stdout.writeln(
    'C34_SAMPLE_IO $opening write_bytes='
    '${writes.fold<int>(0, (sum, event) => sum + event.bytes)} '
    'requested_flushes=${writes.where((event) => event.flush).length} '
    'read_bytes=${reads.fold<int>(0, (sum, event) => sum + event.bytes)} '
    'sample_objects=$opens decoded_rgba_sha256=$rgba',
  );
}

void main() {
  testWidgets('Settings empty shader directory previews twice without sample IO', (
    tester,
  ) async {
    // Comparison mode deliberately belongs to the test only. The published
    // regression defaults to the required zero-I/O behavior.
    final stock = Platform.environment['ANIME4K_C34_EXPECT_STOCK'] == '1';
    final support = Directory.systemTemp.createTempSync('anime4k-no-folder-');
    final sample = File(p.join(support.path, 'anime4k_sample.jpg'));
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(support.path);
    final io = _ObservedIo(sample.path);
    final storage = _Storage();
    try {
      final expected = await _bundlePixels(tester);
      await IOOverrides.runWithIOOverrides(() async {
        await _settings(tester, storage);
        expect(_preview, findsNothing);
        expect(io.events, isEmpty);
        expect(io.sampleOpens, 0);

        final toggle = find.descendant(of: _tile, matching: find.byType(Switch));
        expect(tester.widget<Switch>(toggle).value, isFalse);
        await _alignInScroll(tester, toggle);
        expect(toggle.hitTestable(), findsOneWidget);
        await tester.tap(toggle);
        await _assertVisiblePreview(tester, expected, folder: '');
        expect(storage.settings['player_anime4k_enabled'], isTrue);
        expect(storage.settings['player_anime4k_mode'], 'a');
        final first = List<_IoEvent>.of(io.events);
        final firstOpens = io.sampleOpens;
        expect(first, stock ? _copiedOnce : isEmpty);
        expect(firstOpens, stock ? 1 : 0);
        _trace('first_enable', first, firstOpens, expected);

        await _close(tester);
        await _openByTitle(tester);
        await _assertVisiblePreview(tester, expected, folder: '');
        final next = io.events.skip(first.length).toList();
        final nextOpens = io.sampleOpens - firstOpens;
        expect(next, stock ? _copiedOnce : isEmpty);
        expect(nextOpens, stock ? 1 : 0);
        _trace('warm_reopen', next, nextOpens, expected);
        final qualityEventsBefore = io.events.length;
        final qualityOpensBefore = io.sampleOpens;
        final small = find.descendant(
          of: _dialog,
          matching: find.widgetWithText(ChoiceChip, 'S'),
        );
        await _alignInScroll(tester, small);
        await tester.pumpAndSettle();
        expect(small.hitTestable(), findsOneWidget);
        await tester.tap(small);
        await _assertVisiblePreview(
          tester,
          expected,
          folder: '',
          quality: Anime4kQuality.s,
        );
        expect(storage.settings['player_anime4k_quality'], 's');
        final qualityEvents = io.events.skip(qualityEventsBefore).toList();
        final qualityOpens = io.sampleOpens - qualityOpensBefore;
        expect(qualityEvents, stock ? _copiedOnce : isEmpty);
        expect(qualityOpens, stock ? 1 : 0);
        _trace('same_dialog_quality_change', qualityEvents, qualityOpens, expected);

        // Pop/unmount the enclosing route after this exact preview generation.
        await _close(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      }, io);

      expect(sample.existsSync(), stock);
      if (stock) expect(sha256.convert(sample.readAsBytesSync()).toString(), _assetHash);
    } finally {
      PathProviderPlatform.instance = oldPaths;
      support.deleteSync(recursive: true);
    }
  });

  testWidgets('Settings nonempty directory without shaders keeps fallback copy', (
    tester,
  ) async {
    final support = Directory.systemTemp.createTempSync('anime4k-empty-directory-');
    final folder = Directory(p.join(support.path, 'chosen-folder'))..createSync();
    final sample = File(p.join(support.path, 'anime4k_sample.jpg'));
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(support.path);
    final io = _ObservedIo(sample.path);
    final storage = _Storage()
      ..settings['player_anime4k_enabled'] = true
      ..settings['player_anime4k_mode'] = 'a'
      ..settings['player_anime4k_shader_dir'] = folder.path;
    try {
      final expected = await _bundlePixels(tester);
      await IOOverrides.runWithIOOverrides(() async {
        await _settings(tester, storage);
        await _openByTitle(tester);
        await _assertVisiblePreview(tester, expected, folder: folder.path);
        expect(io.events, _copiedOnce);
        expect(io.sampleOpens, 1);
        _trace('configured_empty_fallback', io.events, io.sampleOpens, expected);
        await _close(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      }, io);
      expect(sha256.convert(sample.readAsBytesSync()).toString(), _assetHash);
    } finally {
      PathProviderPlatform.instance = oldPaths;
      support.deleteSync(recursive: true);
    }
  });
}
