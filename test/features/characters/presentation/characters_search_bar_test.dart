import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/characters/presentation/characters_screen.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SignedOutAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot();
  }
}

Future<ByteData> _fontBytes(String path) async {
  return ByteData.sublistView(await File(path).readAsBytes());
}

String? _firstExisting(List<String> paths) {
  for (final path in paths) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

Future<void> _loadWalkthroughFonts() async {
  const arabicRegular =
      '/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf';
  if (!File(arabicRegular).existsSync()) return;
  await (FontLoader('NotoSansArabic')
        ..addFont(_fontBytes(arabicRegular))
        ..addFont(
          _fontBytes('/usr/share/fonts/truetype/noto/NotoSansArabic-Bold.ttf'),
        ))
      .load();
  final roboto = _firstExisting(const <String>[
    '/opt/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
    '/home/ubuntu/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  ]);
  if (roboto != null) {
    await (FontLoader('Roboto')..addFont(_fontBytes(roboto))).load();
  }
  final icons = _firstExisting(const <String>[
    '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '/home/ubuntu/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
  if (icons != null) {
    await (FontLoader('MaterialIcons')..addFont(_fontBytes(icons))).load();
  }
}

Future<void> _writeShot(WidgetTester tester, String key, String filename) async {
  final artifacts = Directory('/opt/cursor/artifacts');
  if (!artifacts.existsSync()) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(ValueKey(key)),
  );
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('${artifacts.path}/$filename').writeAsBytesSync(bytes!.buffer.asUint8List());
}

Widget _app({required Widget home, required Key shotKey}) {
  return ProviderScope(
    overrides: [
      storageServiceProvider.overrideWithValue(StorageService()),
      animeWitcherAccountControllerProvider.overrideWith(
        _SignedOutAccount.new,
      ),
      extensionManagerProvider.overrideWithValue(
        const <AnimeWitcherProvider>[],
      ),
      activeProviderProvider.overrideWithValue(null),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'NotoSansArabic',
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEEC60A),
          surface: Color(0xFF000000),
          onSurface: Color(0xFFE5E7EB),
        ),
      ),
      home: RepaintBoundary(key: shotKey, child: home),
    ),
  );
}

void main() {
  testWidgets('more screen links to the characters experience', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    await tester.pumpWidget(
      _app(
        home: const MoreScreen(),
        shotKey: const ValueKey('more-characters-shot'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('الشخصيات'), findsOneWidget);
    expect(
      find.text('تصفح الشخصيات وابحث عنها وأدر المفضلة'),
      findsOneWidget,
    );

    await tester.runAsync(
      () => _writeShot(
        tester,
        'more-characters-shot',
        'more_characters_tile.png',
      ),
    );
  });

  testWidgets('characters page shows an on-page search field', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    await tester.pumpWidget(
      _app(
        home: const CharactersScreen(),
        shotKey: const ValueKey('characters-search-shot'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('الشخصيات'), findsWidgets);
    expect(find.text('من الذي ترغب بالبحث عنه؟'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.text('المفضلة'), findsOneWidget);

    await tester.runAsync(
      () => _writeShot(
        tester,
        'characters-search-shot',
        'characters_page_onpage_search.png',
      ),
    );
  });
}
