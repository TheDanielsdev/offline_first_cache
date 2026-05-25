/// Log levels for the offline client
enum OfflineLogLevel { debug, info, warning, error }

/// Abstract logger interface — implement this to plug in your own logging solution
/// (e.g. Firebase Crashlytics, Sentry, custom file logger)
abstract class OfflineLogger {
  void log(
    OfflineLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });

  void debug(String message) => log(OfflineLogLevel.debug, message);
  void info(String message) => log(OfflineLogLevel.info, message);
  void warning(String message, {Object? error}) =>
      log(OfflineLogLevel.warning, message, error: error);
  void error(String message, {Object? error, StackTrace? stackTrace}) =>
      log(OfflineLogLevel.error, message, error: error, stackTrace: stackTrace);
}

/// Default logger — prints to console with level prefixes
class ConsoleOfflineLogger extends OfflineLogger {
  final OfflineLogLevel minLevel;

  ConsoleOfflineLogger({this.minLevel = OfflineLogLevel.debug});

  @override
  void log(
    OfflineLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.index < minLevel.index) return;

    final prefix = switch (level) {
      OfflineLogLevel.debug => '🔍 [DEBUG]',
      OfflineLogLevel.info => 'ℹ️  [INFO]',
      OfflineLogLevel.warning => '⚠️  [WARN]',
      OfflineLogLevel.error => '❌ [ERROR]',
    };

    // ignore: avoid_print
    print('$prefix [OfflineClient] $message');
    if (error != null) {
      // ignore: avoid_print
      print('  Error: $error');
    }
    if (stackTrace != null) {
      // ignore: avoid_print
      print('  Stack: $stackTrace');
    }
  }
}

/// No-op logger for production or testing where logs are unwanted
class SilentOfflineLogger extends OfflineLogger {
  @override
  void log(
    OfflineLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {}
}
