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
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

const _frame = ValueKey<String>('anime4k-comparison-frame');

final class _Storage extends MemoryStorageService {
  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (settings[key] ?? defaultValue) as T?;

  @override
  Future<void> setPlayerSetting(String key, dynamic value) async {
    settings[key] = value;
  }
}

final _preview = find.byType(Anime4kSamplePreview);
final _tile = find.byWidgetPredicate(
  (widget) => widget is SettingsTile && widget.title == 'Anime4K',
);
final _surface = find.descendant(
  of: _preview,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is GestureDetector && widget.onHorizontalDragUpdate != null,
  ),
);
final _clip = find.descendant(
  of: _preview,
  matching: find.byWidgetPredicate(
    (widget) => widget is ClipRect && widget.clipper != null,
  ),
);
final _images = find.descendant(of: _preview, matching: find.byType(Image));
final _painted = find.descendant(of: _preview, matching: find.byType(RawImage));

Future<void> _open(WidgetTester tester) async {
  final title = find.descendant(of: _tile, matching: find.text('Anime4K'));
  await Scrollable.ensureVisible(tester.element(title), alignment: 0.5);
  await tester.pump();
  expect(title.hitTestable(), findsOneWidget);
  await tester.tap(title);
  await pumpUntil(
    tester,
    () =>
        _painted.evaluate().length == 2 &&
        tester.widgetList<RawImage>(_painted).every((w) => w.image != null),
    'decoded layers in the actual Anime4K settings dialog',
  );
  await Scrollable.ensureVisible(tester.element(_preview), alignment: 0.5);
  await tester.pumpAndSettle();
  expect(_surface.hitTestable(), findsOneWidget);
  final view = tester.widget<Anime4kSamplePreview>(_preview);
  expect(view.mode, Anime4kMode.a);
  expect(view.quality, Anime4kQuality.m);
  expect(view.shaderDirectory, isEmpty);
}

double _fraction(WidgetTester tester) {
  final rendered = tester.renderObject<RenderClipRect>(_clip);
  return rendered.clipper!.getClip(rendered.size).right / rendered.size.width;
}

Future<Digest> _samplePaint(WidgetTester tester, Rect rect) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  final digest = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final view = pixels.buffer.asUint8List(
        pixels.offsetInBytes,
        pixels.lengthInBytes,
      );
      final left = (rect.left + 10).ceil();
      final top = rect.center.dy.floor() - 12;
      final rowBytes = ((rect.right - 10).floor() - left) * 4;
      final sample = Uint8List(rowBytes * 24);
      for (var i = 0; i < 24; i++) {
        final row = ((top + i) * image.width + left) * 4;
        sample.setRange(i * rowBytes, (i + 1) * rowBytes, view, row);
      }
      return sha256.convert(sample);
    } finally {
      image.dispose();
    }
  });
  expect(digest, isNotNull);
  return digest!;
}

void main() {
  for (final viewport in [const Size(1100, 950), const Size(430, 910)]) {
    testWidgets('Anime4K comparison drag changes only paint at $viewport', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = _Storage()
        ..settings['player_anime4k_enabled'] = true
        ..settings['player_anime4k_mode'] = 'a';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            appVersionProvider.overrideWith((ref) async => 'fixture'),
            deviceProfileProvider.overrideWith(
              (ref) async => const DeviceProfile(),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) =>
                RepaintBoundary(key: _frame, child: child!),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = find.descendant(
        of: find.byType(SettingsScreen),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        _tile,
        245,
        scrollable: scroll.first,
        maxScrolls: 45,
      );
      await _open(tester);

      final rect = tester.getRect(_surface);
      Offset point(double fraction) =>
          Offset(rect.left + rect.width * fraction, rect.center.dy);
      expect(_fraction(tester), closeTo(0.5, 0.0001));
      final start = await _samplePaint(tester, rect);
      final imageConfigs = Set<Image>.identity();
      final gestureConfigs = Set<GestureDetector>.identity();
      void observe() {
        imageConfigs.addAll(tester.widgetList<Image>(_images));
        gestureConfigs.add(tester.widget<GestureDetector>(_surface));
      }

      observe();
      await tester.tapAt(point(0.001));
      await tester.pump();
      expect(_fraction(tester), closeTo(0.02, 0.0001));
      observe();
      final drag = await tester.startGesture(point(0.1));
      await drag.moveTo(point(0.24));
      await tester.pump();
      for (var i = 0; i < 24; i++) {
        final fraction = 0.26 + (0.94 - 0.26) * i / 23;
        await drag.moveTo(point(fraction));
        await tester.pump();
        expect(_fraction(tester), closeTo(fraction, 0.001));
        observe();
      }
      await drag.up();
      await tester.pump();
      final right = await _samplePaint(tester, rect);
      expect(right, isNot(start));

      await tester.tapAt(point(0.5));
      await tester.pump();
      expect(_fraction(tester), closeTo(0.5, 0.0001));
      expect(await _samplePaint(tester, rect), start);
      observe();
      expect(imageConfigs, hasLength(2));
      expect(gestureConfigs, hasLength(1));

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      await _open(tester);
      expect(_fraction(tester), closeTo(0.5, 0.0001));
      expect(await _samplePaint(tester, tester.getRect(_surface)), start);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
