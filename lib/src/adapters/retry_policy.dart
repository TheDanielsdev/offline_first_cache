import 'package:dio/dio.dart';

/// Defines a pluggable policy for determining whether a failed request should be retried.
abstract class OfflineRetryPolicy {
  /// Determines if a request should be retried based on the intercepted [DioException]
  /// and the current [attemptCount].
  ///
  /// Returns `true` if it should retry, or `false` if it should be immediately dead-lettered.
  bool shouldRetry(DioException exception, int attemptCount);
}

/// Default retry policy that retries on network errors, timeouts, and server errors (5xx)
/// but immediately dead-letters on client errors (4xx, except 408/429) or once [maxRetries] is reached.
class DefaultOfflineRetryPolicy implements OfflineRetryPolicy {
  final int maxRetries;

  const DefaultOfflineRetryPolicy({this.maxRetries = 3});

  @override
  bool shouldRetry(DioException exception, int attemptCount) {
    if (attemptCount >= maxRetries) {
      return false;
    }

    final response = exception.response;
    if (response != null) {
      final statusCode = response.statusCode ?? 0;
      // Client errors (HTTP 4xx, except 408 Request Timeout and 429 Too Many Requests)
      // indicate the payload or request is malformed/unauthorized and should not be retried.
      if (statusCode >= 400 && statusCode < 500 && statusCode != 408 && statusCode != 429) {
        return false;
      }
    }
    return true;
  }
}
