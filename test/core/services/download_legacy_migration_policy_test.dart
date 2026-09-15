import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('legacy multipart migration policy', () {
    test('incomplete legacy manifest continues on legacy executor', () {
      expect(
        planLegacyDownloadAdoption(
          hasLegacyManifest: true,
          legacyIncompleteParts: true,
          hasPluginTask: false,
          finalFileComplete: false,
          userPaused: false,
          legacyWriterActive: false,
          pluginWriterActive: false,
        ),
        LegacyDownloadAdoption.continueLegacy,
      );
    });

    test('plugin task without legacy manifest rehydrates plugin executor', () {
      expect(
        planLegacyDownloadAdoption(
          hasLegacyManifest: false,
          legacyIncompleteParts: false,
          hasPluginTask: true,
          finalFileComplete: false,
          userPaused: false,
          legacyWriterActive: false,
          pluginWriterActive: false,
        ),
        LegacyDownloadAdoption.pluginRehydrate,
      );
    });

    test('completed final file wins and launches no writer', () {
      expect(
        planLegacyDownloadAdoption(
          hasLegacyManifest: true,
          legacyIncompleteParts: true,
          hasPluginTask: true,
          finalFileComplete: true,
          userPaused: false,
          legacyWriterActive: false,
          pluginWriterActive: false,
        ),
        LegacyDownloadAdoption.completed,
      );
    });

    test('user-paused legacy session stays paused with no writer', () {
      expect(
        planLegacyDownloadAdoption(
          hasLegacyManifest: true,
          legacyIncompleteParts: true,
          hasPluginTask: false,
          finalFileComplete: false,
          userPaused: true,
          legacyWriterActive: false,
          pluginWriterActive: false,
        ),
        LegacyDownloadAdoption.paused,
      );
    });

    test('conflicting active ownership fails closed as orphaned', () {
      expect(
        planLegacyDownloadAdoption(
          hasLegacyManifest: true,
          legacyIncompleteParts: true,
          hasPluginTask: true,
          finalFileComplete: false,
          userPaused: false,
          legacyWriterActive: true,
          pluginWriterActive: true,
        ),
        LegacyDownloadAdoption.orphaned,
      );
    });

    test('legacy manifest remains authoritative over a dormant plugin row', () {
      expect(
        planLegacyDownloadAdoption(
          hasLegacyManifest: true,
          legacyIncompleteParts: true,
          hasPluginTask: true,
          finalFileComplete: false,
          userPaused: false,
          legacyWriterActive: false,
          pluginWriterActive: false,
        ),
        LegacyDownloadAdoption.continueLegacy,
      );
    });
  });
}
