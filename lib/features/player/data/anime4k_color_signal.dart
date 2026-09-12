/// Conservative color-transfer classification used by the Apple Anime4K gate.
///
/// Native Metal is currently validated for SDR only. Any HDR/extended-range or
/// unknown transfer must fail closed to the existing mpv GLSL path until the
/// native pipeline has explicit HDR color-management coverage.
enum Anime4kColorSignal { sdr, hdr, unknown }

Anime4kColorSignal classifyAnime4kColorSignal({
  String? transfer,
  String? colorSystem,
}) {
  final normalizedTransfer = _normalizeAnime4kColorValue(transfer);
  final normalizedColorSystem = _normalizeAnime4kColorValue(colorSystem);

  // mpv has used both the current and legacy names across versions. Keep the
  // aliases so upgrading libmpv cannot silently move HDR into the SDR path.
  const hdrTransfers = <String>{
    'pq',
    'st2084',
    'smpte-st-2084',
    'hlg',
    'std-b67',
    'arib-std-b67',
    'scrgb',
  };
  if (hdrTransfers.contains(normalizedTransfer) ||
      normalizedColorSystem == 'scrgb') {
    return Anime4kColorSignal.hdr;
  }

  const sdrTransfers = <String>{
    'bt.1886',
    'bt1886',
    'srgb',
    'gamma1.8',
    'gamma2.0',
    'gamma2.2',
    'gamma2.4',
    'gamma2.6',
    'gamma2.8',
  };
  if (sdrTransfers.contains(normalizedTransfer)) {
    return Anime4kColorSignal.sdr;
  }

  // Do not infer SDR/HDR from BT.2020/BT.709 matrix metadata alone. Primaries
  // and matrices do not prove transfer/range, so ambiguity deliberately keeps
  // native Metal disabled.
  return Anime4kColorSignal.unknown;
}

String _normalizeAnime4kColorValue(String? value) {
  return value?.trim().toLowerCase().replaceAll('_', '-') ?? '';
}
