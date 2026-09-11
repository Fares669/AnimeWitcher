import 'download_job_store.dart';

/// Returns only a strong HTTP ETag. Weak ETags are unsuitable for byte-range
/// identity because RFC If-Range requires a strong validator.
String? strongDownloadEtag(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (value.toLowerCase().startsWith('w/')) return null;
  return value;
}

/// Completion of a local artifact is a resource-integrity decision, not a
/// progress decision. [observedFileBytes] must therefore be compared against an
/// independently known resource size; it can never become its own expectation.
///
/// A matching prefix is required even when validators are absent. When both the
/// persisted and current resource expose comparable validators, any conflict
/// rejects the artifact. Signed/final URL rotation alone is intentionally not a
/// mismatch because [DownloadResourceFingerprint.compatibleWith] does not use
/// delivery URL as the stable identity.
bool downloadCompletionEvidenceMatches({
  required int observedFileBytes,
  required int expectedResourceBytes,
  required bool prefixMatches,
  DownloadResourceFingerprint? persistedFingerprint,
  DownloadResourceFingerprint? currentFingerprint,
}) {
  if (observedFileBytes <= 0 || expectedResourceBytes <= 0) return false;
  if (observedFileBytes != expectedResourceBytes) return false;
  if (!prefixMatches) return false;

  final persistedExpected = persistedFingerprint?.expectedBytes ?? -1;
  if (persistedExpected > 0 && persistedExpected != expectedResourceBytes) {
    return false;
  }
  final currentExpected = currentFingerprint?.expectedBytes ?? -1;
  if (currentExpected > 0 && currentExpected != expectedResourceBytes) {
    return false;
  }
  if (persistedFingerprint != null &&
      currentFingerprint != null &&
      !persistedFingerprint.compatibleWith(currentFingerprint)) {
    return false;
  }
  return true;
}

DownloadResourceFingerprint fingerprintWithExpectedBytes({
  required DownloadResourceFingerprint? remote,
  required int expectedBytes,
  String? fallbackFinalUrl,
}) {
  return DownloadResourceFingerprint(
    strongEtag: remote?.strongEtag,
    lastModified: remote?.lastModified,
    expectedBytes: expectedBytes > 0 ? expectedBytes : remote?.expectedBytes ?? -1,
    finalUrl: remote?.finalUrl ?? fallbackFinalUrl,
  );
}
