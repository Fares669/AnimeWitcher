/// A probe failure is not evidence that saved bytes belong to another source.
enum DownloadSourceVerificationFailure {
  timeout,
  network,
  http,
  cancelled,
  localFile,
  invalidResponse,
}

enum DownloadSourceVerificationPhase { connecting, responseHeaders, body }

enum DownloadSourceVerificationTimeout { inactivity, deadline }

final class DownloadSourceVerificationException implements Exception {
  const DownloadSourceVerificationException({
    required this.reason,
    this.httpStatus,
    this.verifiedBytes,
    this.phase,
    this.timeoutKind,
  });

  final DownloadSourceVerificationFailure reason;
  final int? httpStatus;
  final int? verifiedBytes;
  final DownloadSourceVerificationPhase? phase;
  final DownloadSourceVerificationTimeout? timeoutKind;

  bool get retryable => switch (reason) {
    DownloadSourceVerificationFailure.timeout ||
    DownloadSourceVerificationFailure.network ||
    DownloadSourceVerificationFailure.invalidResponse => true,
    DownloadSourceVerificationFailure.http =>
      httpStatus == 408 ||
          httpStatus == 425 ||
          httpStatus == 429 ||
          (httpStatus != null && httpStatus! >= 500 && httpStatus! < 600),
    DownloadSourceVerificationFailure.cancelled ||
    DownloadSourceVerificationFailure.localFile => false,
  };

  @override
  String toString() =>
      'DownloadSourceVerificationException(${reason.name}'
      '${httpStatus == null ? '' : ', HTTP $httpStatus'})';
}
