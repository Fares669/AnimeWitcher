import 'dart:typed_data';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/features/settings/presentation/account_management_screens.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  late FilePickerPlatform originalPicker;
  late _ImagePicker picker;

  setUp(() {
    originalPicker = FilePickerPlatform.instance;
    picker = _ImagePicker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() => FilePickerPlatform.instance = originalPicker);

  Future<void> showProfile(WidgetTester tester) => tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        locale: Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AnimeWitcherProfileEditScreen(
          profile: AnimeWitcherProfile(
            documentId: 'test-profile',
            uid: 'test-user',
            signInMethod: AnimeWitcherSignInMethod.email,
            userName: 'Viewer',
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'cancelling a single profile image pick leaves editing available',
    (tester) async {
      await showProfile(tester);
      await tester.tap(find.byTooltip('تغيير صورة الحساب'));
      await tester.pumpAndSettle();

      expect(picker.requestedType, FileType.image);
      expect(find.text('تعديل الملف الشخصي'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selected profile image is read using the stable picker API', (
    tester,
  ) async {
    final selected = _SelectedImage(Uint8List(0));
    picker.result = selected;
    await showProfile(tester);
    await tester.tap(find.byTooltip('تغيير صورة الحساب'));
    await tester.pump();

    expect(selected.wasRead, isTrue);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AnimeWitcherProfileEditScreen)),
    );
    final notifications = container.read(notificationServiceProvider);
    expect(notifications.toasts.single.message, 'اختر صورة صالحة.');
    notifications.clearToasts();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
