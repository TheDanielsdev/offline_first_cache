import 'dart:math';

import 'package:hive/hive.dart';
import 'package:offline_first_cache/src/adapters/backoff_calc.dart';
import 'package:offline_first_cache/src/adapters/offline_event.dart';
import 'package:offline_first_cache/src/adapters/offline_logger.dart';
import 'package:offline_first_cache/src/adapters/req_duplicator.dart';
import 'package:offline_first_cache/src/models/cached_item.dart';
import '../models/pending_request.dart';

/// Result of a single retry attempt
enum RetryOutcome { success, willRetry, deadLettered, skipped }

/// Manages the pending request queue: enqueue, prioritize, retry, dead-letter.
class QueueManager {
  final Box<PendingRequest> _queueBox;
  final Box<DeadLetterRequest> _deadLetterBox;
  final int maxRetries;
  final BackoffCalculator backoff;
  final OfflineLogger _logger;
  final void Function(OfflineEvent) _emit;

  QueueManager({
    required Box<PendingRequest> queueBox,
    required Box<DeadLetterRequest> deadLetterBox,
    required OfflineLogger logger,
    required void Function(OfflineEvent) emit,
    this.maxRetries = 3,
    BackoffCalculator? backoff,
  }) : _queueBox = queueBox,
       _deadLetterBox = deadLetterBox,
       _logger = logger,
       _emit = emit,
       backoff = backoff ?? BackoffCalculator();

  /// Enqueue a request. Returns null if deduplicated, or the new request ID.
  Future<String?> enqueue({
    required String method,
    required String url,
    required Map<String, String?> headers,
    required Map<String, dynamic> body,
    int priority = 1,
    Duration? requestTtl,
  }) async {
    // Compute dedup hash
    final hash = RequestDeduplicator.computeHash(
      method: method,
      url: url,
      body: body,
    );

    // Check for duplicate
    final existing = _queueBox.values
        .where((r) => r.dedupHash == hash && !r.isExpired)
        .firstOrNull;

    if (existing != null) {
      _logger.info('Dedup: skipping $method $url (existing id=${existing.id})');
      _emit(RequestDedupedEvent(existingId: existing.id, url: url));
      return null;
    }

    final id = _generateId();
    final expiresAtMs = requestTtl != null
        ? DateTime.now().add(requestTtl).millisecondsSinceEpoch
        : null;

    final pending = PendingRequest(
      id: id,
      method: method,
      url: url,
      headers: headers,
      body: body,
      retryCount: 0,
      createdAt: DateTime.now(),
      dedupHash: hash,
      priority: priority,
      expiresAtMs: expiresAtMs,
    );

    await _queueBox.put(id, pending);
    _emit(
      RequestQueuedEvent(
        requestId: id,
        method: method,
        url: url,
        priority: priority,
      ),
    );
    _logger.info('Queued $method $url (id=$id, priority=$priority)');
    return id;
  }

  /// Returns all pending requests sorted by priority desc, then createdAt asc.
  List<PendingRequest> get prioritizedQueue {
    return _queueBox.values.toList()..sort((a, b) {
      final pCmp = b.priority.compareTo(a.priority);
      if (pCmp != 0) return pCmp;
      return a.createdAt.compareTo(b.createdAt);
    });
  }

  /// Remove expired requests and move permanently-failed ones to dead letter.
  Future<int> purgeExpired() async {
    final expired = _queueBox.values.where((r) => r.isExpired).toList();
    for (final r in expired) {
      await moveToDeadLetter(r, 'Request TTL expired');
    }
    return expired.length;
  }

  /// Mark a request as having failed one attempt.
  /// Returns the outcome: willRetry or deadLettered.
  Future<RetryOutcome> recordFailure(
    PendingRequest pending,
    String error,
  ) async {
    pending.retryCount++;
    _emit(
      RetryFailedEvent(
        requestId: pending.id,
        url: pending.url,
        attemptNumber: pending.retryCount,
        error: error,
      ),
    );

    if (pending.retryCount > maxRetries) {
      await moveToDeadLetter(
        pending,
        'Max retries ($maxRetries) exceeded. Last error: $error',
      );
      return RetryOutcome.deadLettered;
    }

    await pending.save();
    _logger.warning(
      'Retry ${pending.retryCount}/$maxRetries for ${pending.url}. '
      'Next delay: ~${backoff.delayDescription(pending.retryCount)}',
    );
    return RetryOutcome.willRetry;
  }

  /// Mark a request as successfully retried and remove from queue.
  Future<void> recordSuccess(PendingRequest pending) async {
    await _queueBox.delete(pending.id);
    _emit(
      RetrySucceededEvent(
        requestId: pending.id,
        url: pending.url,
        attemptNumber: pending.retryCount,
      ),
    );
    _logger.info('Retry success: ${pending.method} ${pending.url}');
  }

  /// Replay a request from the dead letter queue back into the main queue.
  Future<String?> replayDeadLetter(String deadLetterId) async {
    final dead = _deadLetterBox.get(deadLetterId);
    if (dead == null) return null;

    final newId = await enqueue(
      method: dead.original.method,
      url: dead.original.url,
      headers: dead.original.headers,
      body: dead.original.body,
      priority: dead.original.priority,
    );

    if (newId != null) {
      await _deadLetterBox.delete(deadLetterId);
      _logger.info('Replayed dead letter $deadLetterId as $newId');
    }
    return newId;
  }

  /// Replay all dead letter items.
  Future<int> replayAllDeadLetters() async {
    final ids = _deadLetterBox.keys.cast<String>().toList();
    int replayed = 0;
    for (final id in ids) {
      if (await replayDeadLetter(id) != null) replayed++;
    }
    return replayed;
  }

  Box<DeadLetterRequest> get deadLetterBox => _deadLetterBox;
  Box<PendingRequest> get queueBox => _queueBox;
  int get queueLength => _queueBox.length;
  int get deadLetterLength => _deadLetterBox.length;

  Future<void> moveToDeadLetter(PendingRequest pending, String reason) async {
    final dead = DeadLetterRequest(
      id: pending.id,
      original: pending,
      failureReason: reason,
      failedAt: DateTime.now(),
      totalAttempts: pending.retryCount,
    );
    await _deadLetterBox.put(pending.id, dead);
    await _queueBox.delete(pending.id);
    _emit(
      RequestDeadLetteredEvent(
        requestId: pending.id,
        url: pending.url,
        reason: reason,
      ),
    );
    _logger.warning(
      'Dead lettered: ${pending.method} ${pending.url} — $reason',
    );
  }

  String _generateId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${_randomHex(6)}';
  final _rand = Random.secure();

  String _randomHex(int length) {
    const chars = '0123456789abcdef';
    return List.generate(length, (_) => chars[_rand.nextInt(16)]).join();
  }
}
