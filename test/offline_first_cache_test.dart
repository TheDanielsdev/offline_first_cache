// ignore_for_file: avoid_print

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

// Single barrel import — works regardless of internal folder structure.
// Make sure your lib/offline_first_cache.dart re-exports everything needed.
import 'package:offline_first_cache/offline_first_cache.dart';
import 'package:offline_first_cache/src/adapters/backoff_calc.dart';

// ---------------------------------------------------------------------------
// Hive test bootstrap
//
// IMPORTANT: Hive.init('') crashes on the Dart VM with PathNotFoundException.
// We create a real OS temp directory instead, and clean it up in tearDownAll.
// ---------------------------------------------------------------------------

late Directory _hiveDir;

Future<void> _initHive() async {
  _hiveDir = await Directory.systemTemp.createTemp('hive_test_');
  Hive.init(_hiveDir.path);
  if (!Hive.isAdapterRegistered(0))
    Hive.registerAdapter(PendingRequestAdapter());
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(CachedItemAdapter());
  if (!Hive.isAdapterRegistered(2))
    Hive.registerAdapter(DeadLetterRequestAdapter());
}

Future<void> _tearDownHive() async {
  await Hive.close();
  await _hiveDir.delete(recursive: true);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
  setUpAll(_initHive);
  tearDownAll(_tearDownHive);

  // -------------------------------------------------------------------------
  // BackoffCalculator
  // -------------------------------------------------------------------------

  group('BackoffCalculator', () {
    test('delay for attempt 0 is between 0 and base', () {
      final calc = BackoffCalculator(base: const Duration(seconds: 1));
      final delay = calc.delayFor(0);
      expect(delay.inMilliseconds, greaterThanOrEqualTo(0));
      expect(delay.inMilliseconds, lessThanOrEqualTo(1000));
    });

    test('delay is capped at cap value', () {
      final calc = BackoffCalculator(
        base: const Duration(seconds: 10),
        cap: const Duration(seconds: 30),
      );
      for (var i = 0; i < 20; i++) {
        expect(calc.delayFor(i).inMilliseconds, lessThanOrEqualTo(30000));
      }
    });

    test('delay grows with attempt number on average', () {
      final calc = BackoffCalculator(base: const Duration(seconds: 1));
      double avg0 = 0, avg4 = 0;
      for (var i = 0; i < 100; i++) {
        avg0 += calc.delayFor(0).inMilliseconds;
        avg4 += calc.delayFor(4).inMilliseconds;
      }
      expect(avg4 / 100, greaterThan(avg0 / 100));
    });
  });

  // -------------------------------------------------------------------------
  // RequestDeduplicator
  // -------------------------------------------------------------------------

  group('RequestDeduplicator', () {
    test('same method + url + body produces same hash', () {
      final h1 = RequestDeduplicator.computeHash(
        method: 'POST',
        url: 'https://api.example.com/users',
        body: {'name': 'Alice', 'age': 30},
      );
      final h2 = RequestDeduplicator.computeHash(
        method: 'POST',
        url: 'https://api.example.com/users',
        body: {'name': 'Alice', 'age': 30},
      );
      expect(h1, equals(h2));
    });

    test('body key order does not matter', () {
      final h1 = RequestDeduplicator.computeHash(
        method: 'POST',
        url: 'https://api.example.com/users',
        body: {'a': 1, 'b': 2},
      );
      final h2 = RequestDeduplicator.computeHash(
        method: 'POST',
        url: 'https://api.example.com/users',
        body: {'b': 2, 'a': 1},
      );
      expect(h1, equals(h2));
    });

    test('different url produces different hash', () {
      final h1 = RequestDeduplicator.computeHash(
        method: 'POST',
        url: 'https://api.example.com/users',
        body: {},
      );
      final h2 = RequestDeduplicator.computeHash(
        method: 'POST',
        url: 'https://api.example.com/posts',
        body: {},
      );
      expect(h1, isNot(equals(h2)));
    });

    test('different method produces different hash', () {
      final h1 = RequestDeduplicator.computeHash(
        method: 'POST',
        url: 'https://api.example.com/users',
        body: {},
      );
      final h2 = RequestDeduplicator.computeHash(
        method: 'PUT',
        url: 'https://api.example.com/users',
        body: {},
      );
      expect(h1, isNot(equals(h2)));
    });
  });

  // -------------------------------------------------------------------------
  // CachedItem  (pure model, no Hive box needed)
  // -------------------------------------------------------------------------

  group('CachedItem', () {
    test('isExpired is false when TTL has not elapsed', () {
      final item = CachedItem(
        key: 'test',
        data: {'hello': 'world'},
        ttlSeconds: 300,
      );
      expect(item.isExpired, isFalse);
    });

    test('isExpired is true when TTL has elapsed', () {
      final item = CachedItem(
        key: 'test',
        data: {'hello': 'world'},
        ttlSeconds: 1,
        cachedAt: DateTime.now().subtract(const Duration(seconds: 10)),
      );
      expect(item.isExpired, isTrue);
    });

    test('expiresAt is cachedAt + ttl', () {
      final now = DateTime.now();
      final item = CachedItem(
        key: 'test',
        data: {},
        ttlSeconds: 60,
        cachedAt: now,
      );
      expect(item.expiresAt, equals(now.add(const Duration(seconds: 60))));
    });
  });

  // -------------------------------------------------------------------------
  // PendingRequest  (pure model, no Hive box needed)
  // -------------------------------------------------------------------------

  group('PendingRequest', () {
    PendingRequest make({int? expiresAtMs, Map<String, String?>? headers}) =>
        PendingRequest(
          id: '1',
          method: 'POST',
          url: 'https://example.com',
          headers: headers ?? {},
          body: {},
          retryCount: 0,
          createdAt: DateTime.now(),
          dedupHash: 'abc',
          expiresAtMs: expiresAtMs,
        );

    test('isExpired is false when no expiresAtMs set', () {
      expect(make().isExpired, isFalse);
    });

    test('isExpired is true when expiresAtMs is in the past', () {
      final past = DateTime.now()
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch;
      expect(make(expiresAtMs: past).isExpired, isTrue);
    });

    test('isExpired is false when expiresAtMs is in the future', () {
      final future = DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      expect(make(expiresAtMs: future).isExpired, isFalse);
    });

    test('maskedHeaders redacts Authorization, x-api-key, cookie', () {
      final req = make(
        headers: {
          'Authorization': 'Bearer secret',
          'Content-Type': 'application/json',
          'x-api-key': 'key123',
          'cookie': 'session=abc',
        },
      );
      final m = req.maskedHeaders;
      expect(m['Authorization'], equals('***REDACTED***'));
      expect(m['x-api-key'], equals('***REDACTED***'));
      expect(m['cookie'], equals('***REDACTED***'));
      expect(m['Content-Type'], equals('application/json'));
    });

    test('priorityLevel maps 0–3 correctly', () {
      for (var i = 0; i < 4; i++) {
        final req = PendingRequest(
          id: '$i',
          method: 'POST',
          url: 'u',
          headers: {},
          body: {},
          retryCount: 0,
          createdAt: DateTime.now(),
          dedupHash: 'h$i',
          priority: i,
        );
        expect(req.priorityLevel, equals(RequestPriority.values[i]));
      }
    });
  });

  // -------------------------------------------------------------------------
  // QueueManager  (requires Hive boxes)
  // -------------------------------------------------------------------------

  group('QueueManager', () {
    int n = 0; // suffix counter — ensures every setUp gets fresh box names

    late Box<PendingRequest> queueBox;
    late Box<DeadLetterRequest> deadLetterBox;
    late QueueManager manager;
    late List<OfflineEvent> events;

    setUp(() async {
      n++;
      queueBox = await Hive.openBox<PendingRequest>('q_$n');
      deadLetterBox = await Hive.openBox<DeadLetterRequest>('dl_$n');
      events = [];
      manager = QueueManager(
        queueBox: queueBox,
        deadLetterBox: deadLetterBox,
        logger: SilentOfflineLogger(),
        emit: events.add,
        maxRetries: 2,
      );
    });

    tearDown(() async {
      if (queueBox.isOpen) await queueBox.close();
      if (deadLetterBox.isOpen) await deadLetterBox.close();
    });

    test('enqueue adds item to queue', () async {
      final id = await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {'name': 'Widget'},
      );
      expect(id, isNotNull);
      expect(queueBox.length, equals(1));
      expect(events.whereType<RequestQueuedEvent>(), hasLength(1));
    });

    test('enqueue deduplicates identical requests', () async {
      final id1 = await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {'name': 'Widget'},
      );
      final id2 = await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {'name': 'Widget'},
      );
      expect(id1, isNotNull);
      expect(id2, isNull); // deduplicated
      expect(queueBox.length, equals(1));
      expect(events.whereType<RequestDedupedEvent>(), hasLength(1));
    });

    test('different bodies are not deduplicated', () async {
      final id1 = await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {'name': 'Widget A'},
      );
      final id2 = await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {'name': 'Widget B'},
      );
      expect(id1, isNotNull);
      expect(id2, isNotNull);
      expect(queueBox.length, equals(2));
    });

    test('recordFailure increments retryCount and returns willRetry', () async {
      await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {},
      );
      final pending = queueBox.values.first;
      final outcome = await manager.recordFailure(pending, 'timeout');
      expect(outcome, equals(RetryOutcome.willRetry));
      expect(pending.retryCount, equals(1));
    });

    test('recordFailure dead-letters after maxRetries exceeded', () async {
      await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {},
      );
      final pending = queueBox.values.first;
      // maxRetries = 2, so the 3rd failure dead-letters it
      await manager.recordFailure(pending, 'err');
      await manager.recordFailure(pending, 'err');
      final outcome = await manager.recordFailure(pending, 'err');

      expect(outcome, equals(RetryOutcome.deadLettered));
      expect(queueBox.isEmpty, isTrue);
      expect(deadLetterBox.length, equals(1));
      expect(events.whereType<RequestDeadLetteredEvent>(), hasLength(1));
    });

    test('recordSuccess removes item from queue', () async {
      await manager.enqueue(
        method: 'POST',
        url: 'https://api.example.com/items',
        headers: {},
        body: {},
      );
      final pending = queueBox.values.first;
      await manager.recordSuccess(pending);
      expect(queueBox.isEmpty, isTrue);
      expect(events.whereType<RetrySucceededEvent>(), hasLength(1));
    });

    test('prioritizedQueue sorts high priority first', () async {
      await manager.enqueue(
        method: 'POST',
        url: 'https://a.com/1',
        headers: {},
        body: {},
        priority: 0,
      );
      await manager.enqueue(
        method: 'POST',
        url: 'https://a.com/2',
        headers: {},
        body: {},
        priority: 2,
      );
      await manager.enqueue(
        method: 'POST',
        url: 'https://a.com/3',
        headers: {},
        body: {},
        priority: 1,
      );

      final sorted = manager.prioritizedQueue;
      expect(sorted[0].priority, equals(2));
      expect(sorted[1].priority, equals(1));
      expect(sorted[2].priority, equals(0));
    });

    test('replayDeadLetter moves item back to main queue', () async {
      await manager.enqueue(
        method: 'POST',
        url: 'https://example.com',
        headers: {},
        body: {},
      );
      final pending = queueBox.values.first;
      // Force into dead letter
      await manager.recordFailure(pending, 'err');
      await manager.recordFailure(pending, 'err');
      await manager.recordFailure(pending, 'err');

      expect(deadLetterBox.length, equals(1));
      final deadId = deadLetterBox.keys.first as String;
      final newId = await manager.replayDeadLetter(deadId);

      expect(newId, isNotNull);
      expect(deadLetterBox.isEmpty, isTrue);
      expect(queueBox.length, equals(1));
    });
  });

  // -------------------------------------------------------------------------
  // CacheManager  (requires Hive boxes)
  // -------------------------------------------------------------------------

  group('CacheManager', () {
    int n = 0;

    late Box<CachedItem> cacheBox;
    late CacheManager manager;

    setUp(() async {
      n++;
      cacheBox = await Hive.openBox<CachedItem>('cache_$n');
      manager = CacheManager(
        box: cacheBox,
        logger: SilentOfflineLogger(),
        emit: (_) {},
        maxItems: 5,
      );
    });

    tearDown(() async {
      if (cacheBox.isOpen) await cacheBox.close();
    });

    test('read returns null for missing key', () {
      expect(manager.read('not-there'), isNull);
    });

    test('read returns null for expired item', () async {
      await manager.write(
        CachedItem(
          key: 'k',
          data: {},
          ttlSeconds: 1,
          cachedAt: DateTime.now().subtract(const Duration(seconds: 10)),
        ),
      );
      expect(manager.read('k'), isNull);
    });

    test('read returns item when fresh', () async {
      await manager.write(
        CachedItem(key: 'k', data: {'x': 1}, ttlSeconds: 300),
      );
      final item = manager.read('k');
      expect(item, isNotNull);
      expect(item!.data['x'], equals(1));
    });

    test('invalidateByTag removes tagged items only', () async {
      await manager.write(
        CachedItem(key: 'a', data: {}, ttlSeconds: 300, tags: ['users']),
      );
      await manager.write(
        CachedItem(key: 'b', data: {}, ttlSeconds: 300, tags: ['posts']),
      );
      await manager.write(
        CachedItem(key: 'c', data: {}, ttlSeconds: 300, tags: ['users']),
      );

      final removed = await manager.invalidateByTag('users');
      expect(removed, equals(2));
      expect(cacheBox.length, equals(1));
      expect(cacheBox.get('b'), isNotNull);
    });

    test('LRU eviction triggers when over maxItems', () async {
      for (var i = 0; i < 6; i++) {
        await manager.write(
          CachedItem(
            key: 'item$i',
            data: {},
            ttlSeconds: 300,
            cachedAt: DateTime.now().add(Duration(milliseconds: i * 10)),
          ),
        );
      }
      expect(cacheBox.length, lessThanOrEqualTo(5));
    });

    test('purgeExpired removes only expired items', () async {
      await manager.write(CachedItem(key: 'fresh', data: {}, ttlSeconds: 300));
      await manager.write(
        CachedItem(
          key: 'stale',
          data: {},
          ttlSeconds: 1,
          cachedAt: DateTime.now().subtract(const Duration(seconds: 5)),
        ),
      );

      final purged = await manager.purgeExpired();
      expect(purged, equals(1));
      expect(cacheBox.get('fresh'), isNotNull);
      expect(cacheBox.get('stale'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // OfflineHttpClient  (construction-only smoke tests — no init() called)
  // -------------------------------------------------------------------------

  group('OfflineHttpClient', () {
    test('can be constructed without error', () {
      final client = OfflineHttpClient(Dio(), logger: SilentOfflineLogger());
      expect(client, isNotNull);
      // Do NOT call dispose() here — _queue is only set after init(),
      // and dispose() would throw LateInitializationError without it.
    });

    test('queueSizeNotifier starts at 0', () {
      final client = OfflineHttpClient(Dio(), logger: SilentOfflineLogger());
      expect(client.queueSizeNotifier.value, equals(0));
    });

    test('isOnline defaults to true before init()', () {
      final client = OfflineHttpClient(Dio(), logger: SilentOfflineLogger());
      expect(client.isOnline, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // OfflineEvent types  (pure Dart, no Hive needed)
  // -------------------------------------------------------------------------

  group('OfflineEvent types', () {
    test('all event types carry a recent timestamp', () {
      final allEvents = <OfflineEvent>[
        RequestQueuedEvent(
          requestId: '1',
          method: 'POST',
          url: 'u',
          priority: 1,
        ),
        RequestDedupedEvent(existingId: '1', url: 'u'),
        QueueFlushedEvent(
          successCount: 1,
          failedCount: 0,
          deadLetteredCount: 0,
        ),
        RetrySucceededEvent(requestId: '1', url: 'u', attemptNumber: 1),
        RetryFailedEvent(
          requestId: '1',
          url: 'u',
          attemptNumber: 1,
          error: 'timeout',
        ),
        RequestDeadLetteredEvent(
          requestId: '1',
          url: 'u',
          reason: 'max retries',
        ),
        CacheHitEvent(url: 'u', isStale: false),
        CacheWrittenEvent(url: 'u', ttlSeconds: 300),
        CacheInvalidatedEvent(tag: 'users', itemsRemoved: 3),
        ConnectivityChangedEvent(isOnline: true),
        BackgroundRevalidatedEvent(url: 'u', success: true),
      ];

      for (final event in allEvents) {
        expect(
          event.timestamp,
          isNotNull,
          reason: '${event.runtimeType} is missing timestamp',
        );
        expect(
          event.timestamp.difference(DateTime.now()).abs().inSeconds,
          lessThan(5),
          reason: '${event.runtimeType} timestamp is too far from now',
        );
      }
    });
  });
}
