import 'package:animewitcher/core/account/witanime_account_models.dart';
import 'package:animewitcher/core/account/witanime_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_support_service.dart';
import 'package:animewitcher/core/extensions/providers/witanime_transport.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/features/details/presentation/widgets/anime_information_section.dart';
import 'package:animewitcher/features/details/presentation/widgets/witanime_report_dialog.dart';
import 'package:animewitcher/features/more/presentation/witanime_website_screen.dart';
import 'package:animewitcher/features/settings/presentation/widgets/witanime_account_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _MemoryTokenStorage extends SecureTokenStorage {
  _MemoryTokenStorage(super.legacy);
  final Map<String, String> _values = {};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class _StubTransport implements WitanimeTransport {
  _StubTransport(this.onRequest);

  final Future<WitanimeHttpResponse> Function(String method, Uri uri, Object? body)
  onRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<String> fetchHtml(
    Uri uri, {
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async => (await get(uri, cancelToken: cancelToken, operation: operation)).body;

  @override
  Future<WitanimeHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'get',
  }) => onRequest('GET', uri, null);

  @override
  Future<WitanimeHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) => onRequest('POST', uri, body);
}

class _StubAccountBackend implements WitanimeAccountBackend {
  @override
  Future<WitanimeProfile?> fetchProfile(String sessionCookie) async =>
      const WitanimeProfile(
        accountId: 'w-1',
        displayName: 'زائر Witanime',
        email: 'w@example.com',
        counts: WitanimeListCounts(
          watching: 4,
          completed: 9,
          planToWatch: 2,
          favorites: 5,
        ),
      );

  @override
  Future<void> signOut(String sessionCookie) async {}

  @override
  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {}

  @override
  Future<WitanimeProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    String? email,
    String? avatarUrl,
  }) async => WitanimeProfile(
    accountId: 'w-1',
    displayName: displayName,
    email: email,
  );
}

void main() {
  testWidgets('AnimeInformationSection shows country and studio action for Witanime', (
    tester,
  ) async {
    String? tappedStudio;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: AnimeInformationSection(
              item: MultimediaItem(
                title: 'Sample',
                url: 'https://witanime.site/anime/sample',
                posterUrl: '',
                provider: WitanimeProvider.id,
                source: 'مانجا',
                duration: 24,
                syncData: const {
                  'awCountry': 'اليابان',
                  'awStudio': 'MAPPA',
                },
              ),
              onStudioTap: (studio) => tappedStudio = studio,
            ),
          ),
        ),
      ),
    );
    expect(find.text('البلد'), findsOneWidget);
    expect(find.text('اليابان'), findsOneWidget);
    await tester.tap(find.text('MAPPA'));
    await tester.pumpAndSettle();
    expect(tappedStudio, 'MAPPA');
  });

  testWidgets('WitanimeReportDialog submits report with reason and details', (
    tester,
  ) async {
    Object? submittedBody;
    final transport = _StubTransport((method, uri, body) async {
      if (method == 'GET') {
        return const WitanimeHttpResponse(
          statusCode: 200,
          body: '<meta name="csrf-token" content="csrf-r">',
        );
      }
      submittedBody = body;
      return const WitanimeHttpResponse(statusCode: 200, body: '{"ok":true}');
    });
    final supportService = WitanimeSupportService(transport);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          witanimeSupportServiceProvider.overrideWithValue(supportService),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => FilledButton(
                onPressed: () => showWitanimeReportDialog(
                  context,
                  ref,
                  title: 'الحلقة 1',
                  targetUrl: 'https://witanime.site/watch/sample/1',
                ),
                child: const Text('فتح البلاغ'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('فتح البلاغ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حلقة خاطئة'));
    await tester.enterText(find.byType(TextField), 'الصوت متأخر');
    await tester.tap(find.text('إرسال البلاغ'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));

    expect(submittedBody.toString(), contains('wrong_episode'));
    expect(submittedBody.toString(), contains('الصوت متأخر'));
  });

  testWidgets('WitanimeWebsiteScreen in-app request form submits or falls back on Turnstile', (
    tester,
  ) async {
    final opened = <Uri>[];
    final transport = _StubTransport((method, uri, body) async {
      return const WitanimeHttpResponse(
        statusCode: 200,
        body: '<div class="cf-turnstile"></div>',
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          witanimeSupportServiceProvider.overrideWithValue(
            WitanimeSupportService(transport),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WitanimeWebsiteScreen(
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('طلب أنمي من التطبيق'));
    await tester.tap(find.text('طلب أنمي من التطبيق'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Frieren');
    await tester.tap(find.text('إرسال'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));

    expect(opened, [Uri.parse('https://witanime.site/request')]);
  });

  testWidgets('WitanimeAccountSection renders signed-in counters and signs out', (
    tester,
  ) async {
    final storage = MemoryStorageService();
    final service = WitanimeAccountService(
      tokenStorage: _MemoryTokenStorage(storage),
      backend: _StubAccountBackend(),
    );
    await service.completeBrowserAuth(sessionCookie: 'cookie-1');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          witanimeAccountServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: WitanimeAccountSection())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('زائر Witanime'), findsOneWidget);
    expect(find.textContaining('أشاهده 4'), findsOneWidget);
    await tester.tap(find.text('تسجيل الخروج من Witanime'));
    await tester.pumpAndSettle();
    expect(service.isSignedIn, isFalse);
  });
}
