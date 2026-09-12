import 'package:animewitcher/core/utils/download_resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-08 source refresh capability matrix', () {
    test('same-source native resume wins while the source is still valid', () {
      expect(
        planDownloadSourceRefreshResume(
          sourceRefreshRequired: false,
          canNativeResumeCurrentSource: true,
          hasOpaqueNativeResume: true,
          visiblePartialBytes: 0,
          isMultipart: false,
        ),
        DownloadSourceRefreshResumeAction.nativeResume,
      );
    });

    test('expired source with visible bytes migrates through prefix proof', () {
      expect(
        planDownloadSourceRefreshResume(
          sourceRefreshRequired: true,
          canNativeResumeCurrentSource: true,
          hasOpaqueNativeResume: true,
          visiblePartialBytes: 4096,
          isMultipart: false,
        ),
        DownloadSourceRefreshResumeAction.visiblePrefix,
      );
    });

    test('multipart owns visible child bytes and can refresh in place', () {
      expect(
        planDownloadSourceRefreshResume(
          sourceRefreshRequired: true,
          canNativeResumeCurrentSource: false,
          hasOpaqueNativeResume: false,
          visiblePartialBytes: 0,
          isMultipart: true,
        ),
        DownloadSourceRefreshResumeAction.multipartRefresh,
      );
    });

    test('opaque native bytes cannot be discarded across source refresh', () {
      expect(
        planDownloadSourceRefreshResume(
          sourceRefreshRequired: true,
          canNativeResumeCurrentSource: true,
          hasOpaqueNativeResume: true,
          visiblePartialBytes: 0,
          isMultipart: false,
        ),
        DownloadSourceRefreshResumeAction.restartRequired,
      );
    });

    test('zero evidence may restart cleanly after source replacement', () {
      expect(
        planDownloadSourceRefreshResume(
          sourceRefreshRequired: true,
          canNativeResumeCurrentSource: false,
          hasOpaqueNativeResume: false,
          visiblePartialBytes: 0,
          isMultipart: false,
        ),
        DownloadSourceRefreshResumeAction.restartFromZero,
      );
    });
  });
}
