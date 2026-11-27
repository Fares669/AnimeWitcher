import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/features/settings/presentation/account_management_screens.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/account_notifications_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/test_fonts.dart';

const _frame = ValueKey<String>('profile-avatar-test-frame');
const _photo = 'https://avatar.fixture.invalid/720.png';

const _profile = AnimeWitcherProfile(
  documentId: 'profile-1',
  uid: 'user-1',
  signInMethod: AnimeWitcherSignInMethod.email,
  email: 'avatar@example.invalid',
  userName: 'Avatar Reader',
  photoUrl: _photo,
);

class _SignedIn extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot(profile: _profile);
}

final class _SelectedImage extends PlatformFile {
  _SelectedImage(this.bytes);

  final Uint8List bytes;
  bool wasRead = false;

  @override
  Future<Uint8List> readAsBytes() async {
    wasRead = true;
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImagePicker extends FilePickerPlatform {
  PlatformFile? result;
  FileType? requestedType;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    requestedType = type;
    return result;
  }
}

class _FixtureImages extends Fake implements HttpClient {
  _FixtureImages(this.bytes);

  final Uint8List bytes;
  final requests = <Uri>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return _FixtureRequest(bytes);
  }
}

class _FixtureRequest extends Fake implements HttpClientRequest {
  _FixtureRequest(this.bytes);
  final Uint8List bytes;

  @override
  Future<HttpClientResponse> close() async => _FixtureResponse(bytes);
}

class _FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  _FixtureResponse(this.bytes);
  final Uint8List bytes;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Uint8List> _avatarBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawColor(const Color(0xff3060b0), ui.BlendMode.src)
    ..drawRect(
      Rect.fromLTRB(width / 2, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xffe8ab30),
    );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Finder _avatar(double radius) => find.byWidgetPredicate(
  (widget) => widget is CircleAvatar && widget.radius == radius,
);

Future<void> _pumpMore(WidgetTester tester, Size size, double dpr) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(
    () => TestFonts.loadFamily('Readex Pro', [
      'assets/fonts/readex_pro/ReadexPro-Regular.ttf',
      'assets/fonts/readex_pro/ReadexPro-Bold.ttf',
    ]),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeWitcherAccountControllerProvider.overrideWith(_SignedIn.new),
        accountNotificationCountProvider.overrideWith((ref) async => 0),
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(fontFamily: 'Readex Pro'),
        builder: (context, child) => RepaintBoundary(key: _frame, child: child),
        home: const MoreScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _waitUntil(WidgetTester tester, bool Function() check) async {
  for (var index = 0; index < 100 && !check(); index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(check(), isTrue);
  await tester.pumpAndSettle();
}

Future<List<int>> _samples(WidgetTester tester, Finder avatar) async {
  final box = tester.getRect(avatar);
  final frame = tester.renderObject<RenderRepaintBoundary>(find.byKey(_frame));
  return (await tester.runAsync(() async {
    final image = await frame.toImage();
    try {
      final bytes = (await image.toByteData())!;
      return [
        for (final x in [
          box.left + box.width * .32,
          box.left + box.width * .68,
        ])
          bytes.getUint32(
            (box.center.dy.floor() * image.width + x.floor()) * 4,
          ),
      ];
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  const stock = bool.fromEnvironment('STOCK_PROFILE_AVATAR');
  for (final (label, layout, dpr, radius, width, height) in [
    ('compact', const Size(428, 926), 1.0, 24.0, 720, 720),
    ('wide', const Size(1600, 1000), 2.0, 20.0, 720, 720),
    ('legacy landscape', const Size(428, 926), 2.0, 24.0, 1200, 600),
    ('legacy portrait', const Size(428, 926), 2.0, 24.0, 600, 1200),
  ]) {
    testWidgets('profile avatar shares a square cover across $label routes', (
      tester,
    ) async {
      final bytes = (await tester.runAsync(() => _avatarBytes(width, height)))!;
      final client = _FixtureImages(bytes);
      final savedHttp = debugNetworkImageHttpClientProvider;
      final cache = PaintingBinding.instance.imageCache;
      cache
        ..clear()
        ..clearLiveImages();
      debugNetworkImageHttpClientProvider = () => client;
      try {
        await _pumpMore(tester, layout, dpr);
        await _waitUntil(tester, () => cache.currentSize == 1);
        final diameter = (116 * dpr).ceil();
        final scale = diameter / (width < height ? width : height);
        final expectedBytes = stock
            ? width * height * 4
            : (width * scale).round() * (height * scale).round() * 4;
        debugPrint(
          'profile_avatar $label cache_bytes=${cache.currentSizeBytes}',
        );
        expect(cache.currentSizeBytes, expectedBytes);

        Future<void> expectPhoto(double radius) async {
          final avatar = _avatar(radius);
          expect(avatar, findsOneWidget);
          expect(tester.getSize(avatar), Size.square(radius * 2));
          expect(await _samples(tester, avatar), [0x3060b0ff, 0xe8ab30ff]);
          expect(client.requests, [Uri.parse(_photo)]);
          expect(cache.currentSizeBytes, expectedBytes);
        }

        await expectPhoto(radius);
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        if (layout.width < 740) {
          await tester.tap(find.text(_profile.userName!));
          await tester.pumpAndSettle();
        }
        await expectPhoto(46);
        for (var visit = 0; visit < 2; visit++) {
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    const AnimeWitcherProfileEditScreen(profile: _profile),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await expectPhoto(58);
          navigator.pop();
          await tester.pumpAndSettle();
        }
        await expectPhoto(46);
        if (layout.width < 740) {
          navigator.pop();
          await tester.pumpAndSettle();
        }
        await expectPhoto(radius);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugNetworkImageHttpClientProvider = savedHttp;
        cache
          ..clear()
          ..clearLiveImages();
      }
    });
  }

  testWidgets('locally cropped avatar previews at the actual editor size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(428, 926);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = (await tester.runAsync(() => _avatarBytes(720, 720)))!;
    final selected = _SelectedImage(bytes);
    final originalPicker = FilePickerPlatform.instance;
    final picker = _ImagePicker()..result = selected;
    FilePickerPlatform.instance = picker;
    final cache = PaintingBinding.instance.imageCache;
    cache
      ..clear()
      ..clearLiveImages();
    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            locale: Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AnimeWitcherProfileEditScreen(
              profile: AnimeWitcherProfile(
                documentId: 'profile-local',
                uid: 'user-local',
                signInMethod: AnimeWitcherSignInMethod.email,
              ),
            ),
          ),
        ),
      );
      final avatar = _avatar(58);
      expect(tester.widget<CircleAvatar>(avatar).foregroundImage, isNull);
      await tester.tap(find.byTooltip('تغيير صورة الحساب'));
      await _waitUntil(
        tester,
        () => find.text('استخدام الصورة').evaluate().isNotEmpty,
      );
      expect(selected.wasRead, isTrue);
      expect(picker.requestedType, FileType.image);
      await tester.tap(find.text('استخدام الصورة'));
      await _waitUntil(tester, () => cache.currentSize == 1);
      final diameter = (116 * tester.view.devicePixelRatio).ceil();
      expect(tester.getSize(avatar), const Size.square(116));
      expect(tester.widget<CircleAvatar>(avatar).foregroundImage, isNotNull);
      debugPrint(
        'profile_avatar local crop cache_bytes=${cache.currentSizeBytes}',
      );
      expect(
        cache.currentSizeBytes,
        (stock ? 720 * 720 : diameter * diameter) * 4,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      FilePickerPlatform.instance = originalPicker;
      cache
        ..clear()
        ..clearLiveImages();
    }
  });

  testWidgets('invalid profile image retains the existing person placeholder', (
    tester,
  ) async {
    final client = _FixtureImages(Uint8List.fromList([1, 2, 3, 4]));
    final savedHttp = debugNetworkImageHttpClientProvider;
    final cache = PaintingBinding.instance.imageCache;
    cache
      ..clear()
      ..clearLiveImages();
    debugNetworkImageHttpClientProvider = () => client;
    try {
      await _pumpMore(tester, const Size(428, 926), 1);
      await _waitUntil(
        tester,
        () => client.requests.length == 1 && cache.pendingImageCount == 0,
      );
      expect(
        find.descendant(
          of: _avatar(24),
          matching: find.byIcon(Icons.person_rounded),
        ),
        findsOneWidget,
      );
      expect(cache.currentSize, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugNetworkImageHttpClientProvider = savedHttp;
      cache
        ..clear()
        ..clearLiveImages();
    }
  });
}
