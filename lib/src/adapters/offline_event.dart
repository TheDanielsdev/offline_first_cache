/// Base class for all offline client events
abstract class OfflineEvent {
  final DateTime timestamp;
  OfflineEvent() : timestamp = DateTime.now();
}

/// Fired when a request is successfully queued for later retry
class RequestQueuedEvent extends OfflineEvent {
  final String requestId;
  final String method;
  final String url;
  final int priority;
  RequestQueuedEvent({
    required this.requestId,
    required this.method,
    required this.url,
    required this.priority,
  });
}

/// Fired when a queued request was a duplicate and was skipped
class RequestDedupedEvent extends OfflineEvent {
  final String existingId;
  final String url;
  RequestDedupedEvent({required this.existingId, required this.url});
}

/// Fired when the retry queue is fully flushed (all items processed)
class QueueFlushedEvent extends OfflineEvent {
  final int successCount;
  final int failedCount;
  final int deadLetteredCount;
  QueueFlushedEvent({
    required this.successCount,
    required this.failedCount,
    required this.deadLetteredCount,
  });
}

/// Fired when a single queued request succeeds on retry
class RetrySucceededEvent extends OfflineEvent {
  final String requestId;
  final String url;
  final int attemptNumber;
  RetrySucceededEvent({
    required this.requestId,
    required this.url,
    required this.attemptNumber,
  });
}

/// Fired when a retry attempt fails (but will be retried again)
class RetryFailedEvent extends OfflineEvent {
  final String requestId;
  final String url;
  final int attemptNumber;
  final String error;
  RetryFailedEvent({
    required this.requestId,
    required this.url,
    required this.attemptNumber,
    required this.error,
  });
}

/// Fired when a request permanently fails and moves to dead letter queue
class RequestDeadLetteredEvent extends OfflineEvent {
  final String requestId;
  final String url;
  final String reason;
  RequestDeadLetteredEvent({
    required this.requestId,
    required this.url,
    required this.reason,
  });
}

/// Fired when a GET response is served from cache
class CacheHitEvent extends OfflineEvent {
  final String url;
  final bool isStale;
  CacheHitEvent({required this.url, required this.isStale});
}

/// Fired when a GET response is stored in cache
class CacheWrittenEvent extends OfflineEvent {
  final String url;
  final int ttlSeconds;
  CacheWrittenEvent({required this.url, required this.ttlSeconds});
}

/// Fired when cached entries are invalidated by tag
class CacheInvalidatedEvent extends OfflineEvent {
  final String tag;
  final int itemsRemoved;
  CacheInvalidatedEvent({required this.tag, required this.itemsRemoved});
}

/// Fired when connectivity changes
class ConnectivityChangedEvent extends OfflineEvent {
  final bool isOnline;
  ConnectivityChangedEvent({required this.isOnline});
}

/// Fired when a stale-while-revalidate background refresh completes
class BackgroundRevalidatedEvent extends OfflineEvent {
  final String url;
  final bool success;
  BackgroundRevalidatedEvent({required this.url, required this.success});
}
