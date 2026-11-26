import 'dart:io';

import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/widgets/subtitle_appearance_dialog.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
// Use the same Flutter Material widgets as the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _previewImage = 'assets/images/subtitles_preview_background.jpg';

class _SubtitlePreviewBundle extends CachingAssetBundle {
  _SubtitlePreviewBundle(this.previewBytes);

  final ByteData previewBytes;

  @override
  Future<ByteData> load(String key) {
    if (key == _previewImage) return Future<ByteData>.value(previewBytes);
    return rootBundle.load(key);
  }
}

class _Player extends PlayerController {
  @override
  PlayerState build() => const PlayerState();
}

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

void main() {
  testWidgets('subtitle preview decodes for the viewport and reuses buckets', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(860, 1600);
    tester.view.devicePixelRatio = 2;

    // Use the app's Arabic font rather than the much wider test font when
    // laying out the real subtitle settings at a phone width.
    const fontFamily = 'Readex Pro';
    await tester.runAsync(
      () =>
          (FontLoader(fontFamily)..addFont(
                rootBundle.load(
                  'assets/fonts/readex_pro/ReadexPro-Regular.ttf',
                ),
              ))
              .load(),
    );
    // This unwired dialog is exercised directly by tests. Keep the original
    // JPEG out of the app bundle while exercising the real image decoder.
    final manifest = await tester.runAsync(
      () => AssetManifest.loadFromAssetBundle(rootBundle),
    );
    expect(manifest!.listAssets(), isNot(contains(_previewImage)));
    final previewBundle = _SubtitlePreviewBundle(
      ByteData.sublistView(File(_previewImage).readAsBytesSync()),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(_Player.new),
          playerSettingsProvider.overrideWith(_Settings.new),
        ],
        child: MaterialApp(
          theme: ThemeData(fontFamily: fontFamily),
          home: DefaultAssetBundle(
            bundle: previewBundle,
            child: const SubtitleAppearanceDialog(wasPlaying: false),
          ),
        ),
      ),
    );

    final preview = find.descendant(
      of: find.byType(SubtitleAppearanceDialog),
      matching: find.byType(Image),
    );
    final rawImage = find.descendant(
      of: preview,
      matching: find.byType(RawImage),
    );
    Future<(int?, int?)> decodedSize() async {
      final provider = tester.widget<Image>(preview).image;
      await tester.runAsync(
        () => precacheImage(
          provider,
          tester.element(preview),
        ).timeout(const Duration(seconds: 10)),
      );
      await tester.pump();
      final image = tester.widget<RawImage>(rawImage);
      expect(image.fit, BoxFit.cover);
      return (image.image?.width, image.image?.height);
    }

    expect(await decodedSize(), (1024, 682));
    final firstProvider = tester.widget<Image>(preview).image;
    tester.view.physicalSize = const Size(900, 1600);
    await tester.pump();
    expect(tester.widget<Image>(preview).image, firstProvider);

    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1290, 2400);
    await tester.pump();
    expect(await decodedSize(), (1536, 1023));

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(3840, 2160);
    await tester.pump();
    expect(tester.widget<Image>(preview).image, isA<AssetImage>());
    expect(await decodedSize(), (2560, 1706));
    expect(tester.takeException(), isNull);
  });
}
