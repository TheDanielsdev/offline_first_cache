import 'package:hive/hive.dart';
import 'package:offline_first_cache/offline_first_cache.dart';
part 'cached_item.g.dart';

@HiveType(typeId: 1)
class CachedItem extends HiveObject {
  @override
  @HiveField(0)
  final String key;

  @HiveField(1)
  final dynamic data;

  @HiveField(2)
  final int ttlSeconds;

  @HiveField(3)
  final DateTime cachedAt;

  @HiveField(4)
  final List<String> tags;

  @HiveField(5)
  final String? etag;

  @HiveField(6)
  final String? lastModified;

  @HiveField(7)
  DateTime? lastAccessedAt;

  CachedItem({
    required this.key,
    required this.data,
    required this.ttlSeconds,
    DateTime? cachedAt,
    this.tags = const [],
    this.etag,
    this.lastModified,
    DateTime? lastAccessedAt,
  }) : cachedAt = cachedAt ?? DateTime.now(),
       lastAccessedAt = lastAccessedAt ?? cachedAt ?? DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(cachedAt).inSeconds >= ttlSeconds;

  bool get isStale => isExpired;

  DateTime get expiresAt => cachedAt.add(Duration(seconds: ttlSeconds));

  DateTime get lastAccessed => lastAccessedAt ?? cachedAt;
}

@HiveType(typeId: 2)
class DeadLetterRequest extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final PendingRequest original;

  @HiveField(2)
  final String failureReason;

  @HiveField(3)
  final DateTime failedAt;

  @HiveField(4)
  final int totalAttempts;

  DeadLetterRequest({
    required this.id,
    required this.original,
    required this.failureReason,
    required this.failedAt,
    required this.totalAttempts,
  });
}
