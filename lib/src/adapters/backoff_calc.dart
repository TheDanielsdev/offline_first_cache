import 'dart:math';

/// Calculates retry delays using exponential backoff with full jitter.
///
/// Formula: random(0, min(cap, base * 2^attempt))
/// This spreads retry load across clients and avoids thundering herd.
class BackoffCalculator {
  final Duration base;
  final Duration cap;
  final Random _random;

  BackoffCalculator({
    this.base = const Duration(seconds: 1),
    this.cap = const Duration(minutes: 5),
    Random? random,
  }) : _random = random ?? Random();

  /// Returns the delay before the given retry attempt (0-indexed).
  Duration delayFor(int attempt) {
    // Exponential: base * 2^attempt
    final exponential = base.inMilliseconds * (1 << attempt.clamp(0, 20));
    // Cap the upper bound
    final capped = min(exponential, cap.inMilliseconds);
    // Full jitter: uniform random between 0 and capped
    final jittered = _random.nextInt(capped + 1);
    return Duration(milliseconds: jittered);
  }

  /// Convenience: returns delay as seconds string for logging
  String delayDescription(int attempt) {
    final d = delayFor(attempt);
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }
}
