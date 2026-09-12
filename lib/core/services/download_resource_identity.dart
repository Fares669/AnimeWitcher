import 'download_job_store.dart';

/// Returns only a strong HTTP ETag. Weak ETags are unsuitable for byte-range
/// identity because RFC If-Range requires a strong validator.
String? strongDownloadEtag(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (value.toLowerCase().startsWith('w/')) return null;
  return value;
}

bool _matchingStableValidator(
  DownloadResourceFingerprint persisted,
  DownloadResourceFingerprint current,
) {
  final persistedEtag = strongDownloadEtag(persisted.strongEtag);
  final currentEtag = strongDownloadEtag(current.strongEtag);
  if (persistedEtag != null && currentEtag != null) {
    return persistedEtag == currentEtag;
  }
  final persistedModified = persisted.lastModified?.trim();
  final currentModified = current.lastModified?.trim();
  return persistedModified != null &&
      persistedModified.isNotEmpty &&
      currentModified != null &&
      currentModified.isNotEmpty &&
      persistedModified == currentModified;
}

/// Completion of a local artifact is a resource-integrity decision, not a
/// progress decision. [observedFileBytes] must therefore be compared against an
/// independently known resource size; it can never become its own expectation.
///
/// Strong validators are preferred. If no comparable validator survived,
/// callers must prove a byte prefix against the current resource. Signed/final
/// URL rotation alone is intentionally not a mismatch because delivery URL is
/// not treated as stable resource identity.
bool downloadCompletionEvidenceMatches({
  required int observedFileBytes,
  required int expectedResourceBytes,
  required bool prefixMatches,
  DownloadResourceFingerprint? persistedFingerprint,
  DownloadResourceFingerprint? currentFingerprint,
}) {
  if (observedFileBytes <= 0 || expectedResourceBytes <= 0) return false;
  if (observedFileBytes != expectedResourceBytes) return false;

  final persistedExpected = persistedFingerprint?.expectedBytes ?? -1;
  if (persistedExpected > 0 && persistedExpected != expectedResourceBytes) {
    return false;
  }
  final currentExpected = currentFingerprint?.expectedBytes ?? -1;
  if (currentExpected > 0 && currentExpected != expectedResourceBytes) {
    return false;
  }
  if (persistedFingerprint != null && currentFingerprint != null) {
    if (!persistedFingerprint.compatibleWith(currentFingerprint)) return false;
    if (prefixMatches ||
        _matchingStableValidator(persistedFingerprint, currentFingerprint)) {
      return true;
    }
  }
  return prefixMatches;
}

DownloadResourceFingerprint fingerprintWithExpectedBytes({
  required DownloadResourceFingerprint? remote,
  required int expectedBytes,
  String? fallbackFinalUrl,
}) {
  return DownloadResourceFingerprint(
    strongEtag: remote?.strongEtag,
    lastModified: remote?.lastModified,
    expectedBytes: expectedBytes > 0
        ? expectedBytes
        : remote?.expectedBytes ?? -1,
    finalUrl: remote?.finalUrl ?? fallbackFinalUrl,
  );
}
