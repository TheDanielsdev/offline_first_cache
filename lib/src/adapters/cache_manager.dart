import 'package:hive/hive.dart';
import 'package:offline_first_cache/src/adapters/offline_event.dart';
import 'package:offline_first_cache/src/adapters/offline_logger.dart';
import 'package:offline_first_cache/src/models/cached_item.dart';

/// Handles all cache read/write/invalidation logic.
class CacheManager {
  final Box<CachedItem> _box;
  final int maxItems;
  final OfflineLogger _logger;
  final void Function(OfflineEvent) _emit;

  CacheManager({
    required Box<CachedItem> box,
    required OfflineLogger logger,
    required void Function(OfflineEvent) emit,
    this.maxItems = 200,
  }) : _box = box,
       _logger = logger,
       _emit = emit;

  /// Read from cache. Returns null if missing or hard-expired.
  CachedItem? read(String key) {
    final item = _box.get(key);
    if (item == null) return null;
    if (item.isExpired) return null;
    _updateLastAccessed(item);
    return item;
  }

  /// Read allowing stale items (for stale-while-revalidate pattern).
  CachedItem? readAllowingStale(String key) {
    final item = _box.get(key);
    if (item != null) {
      _updateLastAccessed(item);
    }
    return item;
  }

  void _updateLastAccessed(CachedItem item) {
    item.lastAccessedAt = DateTime.now();
    item.save().catchError((e) {
      _logger.warning('Failed to save last accessed timestamp for ${item.key}: $e');
    });
  }

  /// Write a new cache entry, evicting LRU items if over capacity.
  Future<void> write(CachedItem item) async {
    await _enforceSizeLimit();
    await _box.put(item.key, item);
    _emit(CacheWrittenEvent(url: item.key, ttlSeconds: item.ttlSeconds));
    _logger.debug(
      'Cache write: ${item.key} (TTL: ${item.ttlSeconds}s, tags: ${item.tags})',
    );
  }

  /// Invalidate all cache entries that contain the given tag.
  Future<int> invalidateByTag(String tag) async {
    final toDelete = _box.values
        .where((item) => item.tags.contains(tag))
        .map((item) => item.key)
        .toList();

    for (final key in toDelete) {
      await _box.delete(key);
    }

    _emit(CacheInvalidatedEvent(tag: tag, itemsRemoved: toDelete.length));
    _logger.info(
      'Cache invalidated tag "$tag": removed ${toDelete.length} items',
    );
    return toDelete.length;
  }

  /// Invalidate a single cache entry by URL key.
  Future<void> invalidate(String key) async {
    await _box.delete(key);
    _logger.debug('Cache invalidated: $key');
  }

  /// Purge all expired entries (call periodically or on app resume).
  Future<int> purgeExpired() async {
    final expired = _box.values
        .where((item) => item.isExpired)
        .map((item) => item.key)
        .toList();

    for (final key in expired) {
      await _box.delete(key);
    }
    if (expired.isNotEmpty) {
      _logger.info('Purged ${expired.length} expired cache entries');
    }
    return expired.length;
  }

  /// Clear the entire cache.
  Future<void> clear() async {
    await _box.clear();
    _logger.info('Cache cleared');
  }

  int get itemCount => _box.length;

  /// LRU eviction: remove oldest (by lastAccessed) when over maxItems.
  Future<void> _enforceSizeLimit() async {
    if (_box.length < maxItems) return;

    final sorted = _box.values.toList()
      ..sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

    // Remove oldest 20% to avoid evicting one at a time
    final removeCount = (maxItems * 0.2).ceil();
    final toRemove = sorted.take(removeCount).map((e) => e.key).toList();
    for (final key in toRemove) {
      await _box.delete(key);
    }
    _logger.info(
      'True LRU eviction: removed $removeCount least-recently-accessed items (was at ${_box.length + removeCount})',
    );
  }
}
