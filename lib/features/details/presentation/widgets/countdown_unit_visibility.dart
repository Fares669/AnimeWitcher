/// Which countdown unit cards should render for a remaining duration.
///
/// Zero-value leading units are dropped so the remaining cards can be centered:
/// - hide days when days == 0
/// - hide hours only when days == 0 and hours == 0
/// - hide minutes only when days, hours, and minutes are all 0
/// Seconds stay visible for any positive remaining time.
class CountdownUnitVisibility {
  const CountdownUnitVisibility({
    required this.showDays,
    required this.showHours,
    required this.showMinutes,
    required this.showSeconds,
  });

  final bool showDays;
  final bool showHours;
  final bool showMinutes;
  final bool showSeconds;

  factory CountdownUnitVisibility.fromRemaining(Duration remaining) {
    final count = visibleCountFor(remaining);
    return CountdownUnitVisibility(
      showDays: count >= 4,
      showHours: count >= 3,
      showMinutes: count >= 2,
      showSeconds: count >= 1,
    );
  }

  /// The number of trailing units to display, without allocating a record.
  static int visibleCountFor(Duration remaining) {
    if (remaining <= Duration.zero) return 0;
    if (remaining.inDays > 0) return 4;
    if (remaining.inHours > 0) return 3;
    if (remaining.inMinutes > 0) return 2;
    return 1;
  }

  int get visibleCount =>
      (showDays ? 1 : 0) +
      (showHours ? 1 : 0) +
      (showMinutes ? 1 : 0) +
      (showSeconds ? 1 : 0);
}
