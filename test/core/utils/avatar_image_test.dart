import 'package:animewitcher/core/utils/avatar_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the provider inside a real element so the helper can read the
/// device pixel ratio the way it does in the app.
Future<ImageProvider<Object>?> _resolve(
  WidgetTester tester, {
  required String? url,
  required double radius,
  required double devicePixelRatio,
}) async {
  ImageProvider<Object>? captured;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(devicePixelRatio: devicePixelRatio),
      child: Builder(
        builder: (context) {
          captured = avatarImage(context, url, radius: radius);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('decodes to the circle it is painted in, in device pixels', (
    tester,
  ) async {
    final provider = await _resolve(
      tester,
      url: 'https://example.test/avatar.jpg',
      radius: 20,
      devicePixelRatio: 3.0,
    );

    final resize = provider! as ResizeImage;
    // A radius-20 circle is 40 logical pixels across; at 3x that is 120.
    expect(resize.width, 120);
    expect(resize.height, isNull, reason: 'height follows the aspect ratio');
    expect(resize.allowUpscaling, isFalse);
    expect(resize.imageProvider, isA<CachedNetworkImageProvider>());
  });

  testWidgets('follows the radius and the screen', (tester) async {
    final large = await _resolve(
      tester,
      url: 'https://example.test/actor.jpg',
      radius: 35,
      devicePixelRatio: 2.0,
    );
    expect((large! as ResizeImage).width, 140);

    final onePx = await _resolve(
      tester,
      url: 'https://example.test/actor.jpg',
      radius: 18,
      devicePixelRatio: 1.0,
    );
    expect((onePx! as ResizeImage).width, 36);
  });

  testWidgets('a fractional ratio never asks for less than it paints', (
    tester,
  ) async {
    final provider = await _resolve(
      tester,
      url: 'https://example.test/avatar.jpg',
      radius: 20,
      devicePixelRatio: 2.75,
    );
    // 40 * 2.75 is 110 exactly; a ratio that does not divide evenly must
    // round up rather than down, or the circle is fed fewer pixels than it
    // paints and shows it.
    expect((provider! as ResizeImage).width, 110);

    final odd = await _resolve(
      tester,
      url: 'https://example.test/avatar.jpg',
      radius: 18.5,
      devicePixelRatio: 2.625,
    );
    expect((odd! as ResizeImage).width, 98); // 97.125 rounded up
  });

  testWidgets('no photo means no provider, so the icon shows instead', (
    tester,
  ) async {
    for (final empty in <String?>[null, '', '   ']) {
      expect(
        await _resolve(
          tester,
          url: empty,
          radius: 20,
          devicePixelRatio: 3.0,
        ),
        isNull,
        reason: 'url ${empty == null ? 'null' : '"$empty"'}',
      );
    }
  });

  testWidgets('a padded url still loads', (tester) async {
    final provider = await _resolve(
      tester,
      url: '  https://example.test/avatar.jpg  ',
      radius: 20,
      devicePixelRatio: 1.0,
    );
    final inner =
        (provider! as ResizeImage).imageProvider as CachedNetworkImageProvider;
    expect(inner.url, 'https://example.test/avatar.jpg');
  });
}
