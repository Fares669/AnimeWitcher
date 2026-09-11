import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'multipart resume adopts an exact-size local artifact before manifest fallback',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      final start = source.indexOf('Future<bool> _resumeDownloadTask(');
      final end = source.indexOf(
        'Future<ParallelDownloadTask?> _parallelParentForInternalPart(',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      final saved = body.indexOf('final saved = await _savedProgressFor(task);');
      final exactAdoption = body.indexOf(
        'saved.partialBytes == saved.totalSize',
        saved,
      );
      final refresh = body.indexOf('await _refreshTaskBeforeResume(', saved);
      final parallelRestore = body.indexOf(
        'if (task is ParallelDownloadTask)',
        saved,
      );

      expect(saved, greaterThanOrEqualTo(0));
      expect(
        exactAdoption,
        greaterThan(saved),
        reason:
            'an exact-size local parent file must have an explicit completion recovery path',
      );
      expect(
        exactAdoption,
        lessThan(refresh),
        reason:
            'completed local bytes should not require signed-URL refresh before adoption',
      );
      expect(
        exactAdoption,
        lessThan(parallelRestore),
        reason:
            'missing/corrupt multipart manifests must not strand an already-complete parent artifact',
      );

      final partialStart = source.indexOf(
        'Future<bool> _resumeUsingPartialFile(DownloadTask task)',
      );
      final partialEnd = source.indexOf(
        'Future<ParallelDownloadTask?> _parallelParentForInternalPart(',
        partialStart,
      );
      expect(partialStart, greaterThanOrEqualTo(0));
      expect(partialEnd, greaterThan(partialStart));
      final partialBody = source.substring(partialStart, partialEnd);
      final parallelReject = partialBody.indexOf(
        'if (task is ParallelDownloadTask) return false;',
      );
      final exactComplete = partialBody.indexOf(
        'existingBytes == expectedBytes',
      );
      expect(exactComplete, greaterThanOrEqualTo(0));
      expect(
        parallelReject,
        greaterThan(exactComplete),
        reason:
            'parallel tasks may reject partial append only after exact-size completion adoption',
      );
    },
  );
}
