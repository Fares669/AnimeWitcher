/// A probe failure is not evidence that saved bytes belong to another source.
enum DownloadSourceVerificationFailure {
  timeout,
  network,
  http,
  cancelled,
  localFile,
  invalidResponse,
}

final class DownloadSourceVerificationException implements Exception {
  const DownloadSourceVerificationException({
    required this.reason,
    this.httpStatus,
  });

  final DownloadSourceVerificationFailure reason;
  final int? httpStatus;

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
