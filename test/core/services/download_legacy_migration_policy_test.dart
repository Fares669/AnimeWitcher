import 'dart:io';

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

    test('startup recovery applies adoption before normal recovery planning', () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      final recoveryStart = source.indexOf(
        'Future<void> _recoverPersistedDownloads() async {',
      );
      final adoption = source.indexOf(
        'final legacyAdoption = planLegacyDownloadAdoption(',
        recoveryStart,
      );
      final conflict = source.indexOf(
        'legacyAdoption == LegacyDownloadAdoption.orphaned',
        adoption,
      );
      final normalRecovery = source.indexOf(
        'final recoveryPlan = planDownloadRecoveryWithJobAuthority(',
        conflict,
      );

      expect(recoveryStart, greaterThanOrEqualTo(0));
      expect(adoption, greaterThan(recoveryStart));
      expect(conflict, greaterThan(adoption));
      expect(normalRecovery, greaterThan(conflict));

      final guarded = source.substring(adoption, normalRecovery);
      expect(guarded, contains('_parallel.pause(task'));
      expect(guarded, contains('_nativeTransport.pause(task)'));
      expect(guarded, contains('state: DownloadJobState.orphaned'));
    });
  });
}
