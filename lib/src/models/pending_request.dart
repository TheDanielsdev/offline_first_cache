import 'package:hive/hive.dart';

part 'pending_request.g.dart';

enum RequestPriority { low, normal, high, critical }

@HiveType(typeId: 0)
class PendingRequest extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String method;

  @HiveField(2)
  final String url;

  @HiveField(3)
  final Map<String, String?> headers;

  @HiveField(4)
  final Map<String, dynamic> body;

  @HiveField(5)
  int retryCount;

  @HiveField(6)
  final DateTime createdAt;

  @HiveField(7)
  final String dedupHash;

  /// Priority: 0=low, 1=normal, 2=high, 3=critical
  @HiveField(8)
  final int priority;

  /// Unix timestamp after which this request should be discarded (null = never)
  @HiveField(9)
  final int? expiresAtMs;

  PendingRequest({
    required this.id,
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.retryCount,
    required this.createdAt,
    required this.dedupHash,
    this.priority = 1,
    this.expiresAtMs,
  });

  bool get isExpired {
    if (expiresAtMs == null) return false;
    return DateTime.now().millisecondsSinceEpoch > expiresAtMs!;
  }

  RequestPriority get priorityLevel =>
      RequestPriority.values[priority.clamp(0, 3)];

  /// Safe copy of headers with Authorization masked
  Map<String, String?> get maskedHeaders {
    return headers.map((k, v) {
      final lower = k.toLowerCase();
      if (lower == 'authorization' ||
          lower == 'x-api-key' ||
          lower == 'cookie') {
        return MapEntry(k, v != null ? '***REDACTED***' : null);
      }
      return MapEntry(k, v);
    });
  }
}
