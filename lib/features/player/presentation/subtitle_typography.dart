import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:google_fonts/google_fonts.dart';

import '../../settings/presentation/player_settings_provider.dart';

/// Indices are persisted in [PlayerSettings.subTypeface].
const subtitleBuiltInFonts = [
  'Normal (system sans-serif)',
  'Trebuchet MS',
  'Netflix Sans',
  'Google Sans',
  'Open Sans',
  'Futura',
  'Consola',
  'Gotham',
  'Lucida Grande',
  'STIX General',
  'Times New Roman',
  'Verdana',
  'Ubuntu',
  'Comic Sans',
  'Poppins',
];

const customSubtitleFontFamily = 'CustomSubtitleFont';

/// Returns false for a missing file; callers handle failures and widget state.
Future<bool> loadCustomSubtitleFont(String path) async {
  final file = File(path);
  if (!await file.exists()) return false;
  final bytes = await file.readAsBytes();
  final fontLoader = FontLoader(customSubtitleFontFamily);
  fontLoader.addFont(Future.value(ByteData.sublistView(bytes)));
  await fontLoader.load();
  return true;
}

TextStyle subtitleTextStyle(
  PlayerSettings settings, {
  required bool customFontLoaded,
}) {
  final index = settings.subTypeface;
  String? fontFamily;
  if (settings.subTypefaceFilePath != null && customFontLoaded) {
    fontFamily = customSubtitleFontFamily;
  } else if (index != null &&
      index > 0 &&
      index < subtitleBuiltInFonts.length) {
    fontFamily = subtitleBuiltInFonts[index];
  }

  final baseStyle = TextStyle(
    fontSize: settings.subFixedTextSize ?? 22.0,
    fontWeight: settings.subBold ? FontWeight.bold : FontWeight.normal,
    fontStyle: settings.subItalic ? FontStyle.italic : FontStyle.normal,
    color: Color(settings.subForegroundColor),
  );

  return switch (fontFamily?.toLowerCase()) {
    'open sans' => GoogleFonts.openSans(textStyle: baseStyle),
    'poppins' => GoogleFonts.poppins(textStyle: baseStyle),
    'ubuntu' => GoogleFonts.ubuntu(textStyle: baseStyle),
    null => baseStyle,
    _ => baseStyle.copyWith(fontFamily: fontFamily),
  };
}
