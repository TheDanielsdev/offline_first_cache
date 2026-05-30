// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

// Single barrel import — works regardless of internal folder structure.
// Make sure your lib/offline_first_cache.dart re-exports everything needed.
import 'package:offline_first_cache/offline_first_cache.dart';

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
  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(PendingRequestAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(CachedItemAdapter());
  if (!Hive.isAdapterRegistered(2)) {
    Hive.registerAdapter(DeadLetterRequestAdapter());
  }
}

Future<void> _tearDownHive() async {
  await Hive.close();
  await _hiveDir.delete(recursive: true);
}

void _mockConnectivity() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (call) async {
      if (call.method == 'check') return ['wifi'];
      if (call.method == 'listen') return null;
      return null;
    },
  );
}

class MockOfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'Connection failed',
    );
  }

  @override
  void close({bool force = false}) {}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_initHive);
  setUpAll(_mockConnectivity);
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
      final future =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
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

  // -------------------------------------------------------------------------
  // DefaultOfflineRetryPolicy
  // -------------------------------------------------------------------------

  group('DefaultOfflineRetryPolicy', () {
    test('shouldRetry returns false when attemptCount exceeds maxRetries', () {
      const policy = DefaultOfflineRetryPolicy(maxRetries: 3);
      final ex = DioException(
        requestOptions: RequestOptions(path: 'u'),
        type: DioExceptionType.connectionError,
      );
      expect(policy.shouldRetry(ex, 3), isFalse);
      expect(policy.shouldRetry(ex, 4), isFalse);
      expect(policy.shouldRetry(ex, 2), isTrue);
    });

    test('shouldRetry returns false on standard 4xx client errors except 408/429', () {
      const policy = DefaultOfflineRetryPolicy(maxRetries: 3);
      
      final ex400 = DioException(
        requestOptions: RequestOptions(path: 'u'),
        response: Response(requestOptions: RequestOptions(path: 'u'), statusCode: 400),
        type: DioExceptionType.badResponse,
      );
      final ex401 = DioException(
        requestOptions: RequestOptions(path: 'u'),
        response: Response(requestOptions: RequestOptions(path: 'u'), statusCode: 401),
        type: DioExceptionType.badResponse,
      );
      final ex404 = DioException(
        requestOptions: RequestOptions(path: 'u'),
        response: Response(requestOptions: RequestOptions(path: 'u'), statusCode: 404),
        type: DioExceptionType.badResponse,
      );
      final ex408 = DioException(
        requestOptions: RequestOptions(path: 'u'),
        response: Response(requestOptions: RequestOptions(path: 'u'), statusCode: 408),
        type: DioExceptionType.badResponse,
      );
      final ex429 = DioException(
        requestOptions: RequestOptions(path: 'u'),
        response: Response(requestOptions: RequestOptions(path: 'u'), statusCode: 429),
        type: DioExceptionType.badResponse,
      );
      final ex500 = DioException(
        requestOptions: RequestOptions(path: 'u'),
        response: Response(requestOptions: RequestOptions(path: 'u'), statusCode: 500),
        type: DioExceptionType.badResponse,
      );

      expect(policy.shouldRetry(ex400, 1), isFalse);
      expect(policy.shouldRetry(ex401, 1), isFalse);
      expect(policy.shouldRetry(ex404, 1), isFalse);
      expect(policy.shouldRetry(ex408, 1), isTrue);
      expect(policy.shouldRetry(ex429, 1), isTrue);
      expect(policy.shouldRetry(ex500, 1), isTrue);
    });
  });
  // -------------------------------------------------------------------------
  // mergePendingMutations
  // -------------------------------------------------------------------------

  group('OfflineHttpClient.mergePendingMutations', () {
    late OfflineHttpClient client;
    int testNum = 0;

    setUp(() async {
      testNum++;
      final dio = Dio();
      dio.httpClientAdapter = MockOfflineAdapter();
      client = OfflineHttpClient(
        dio,
        logger: SilentOfflineLogger(),
      );
      // Initialize with config to set late variables
      await client.init(
        hivePath: _hiveDir.path,
        encryptionKey: Uint8List(32),
        boxPrefix: 'test_merge_$testNum',
      );
    });

    tearDown(() async {
      await client.dispose();
    });

    test('POST appends to the beginning of the list', () async {
      // Add a pending POST request to queue
      await client.post('/items', data: {'id': '2', 'name': 'Item 2'});

      final cached = [
        {'id': '1', 'name': 'Item 1'}
      ];

      final merged = client.mergePendingMutations('/items', cached);
      expect(merged, isList);
      expect(merged.length, equals(2));
      expect(merged[0]['id'], equals('2'));
      expect(merged[1]['id'], equals('1'));
    });

    test('PUT replaces matching item in list or appends if not found', () async {
      // 1. Replace existing
      await client.put('/items/1', data: {'id': '1', 'name': 'Item 1 Updated'});
      // 2. Put not found (inserts at beginning)
      await client.put('/items/99', data: {'id': '99', 'name': 'Item 99'});

      final cached = [
        {'id': '1', 'name': 'Item 1'},
        {'id': '2', 'name': 'Item 2'},
      ];

      final merged = client.mergePendingMutations('/items', cached);
      expect(merged, isList);
      expect(merged.length, equals(3));
      
      // Since it's processed in queue order, item 99 is inserted first, then item 1 is replaced
      final item99 = merged.firstWhere((item) => item['id'] == '99');
      final item1 = merged.firstWhere((item) => item['id'] == '1');
      expect(item99['name'], equals('Item 99'));
      expect(item1['name'], equals('Item 1 Updated'));
    });

    test('PATCH partially updates matching item in list and single map', () async {
      // 1. Patch item in list
      await client.patch('/items/1', data: {'name': 'Patched Name'});
      
      final cachedList = [
        {'id': '1', 'name': 'Item 1', 'desc': 'Original description'}
      ];

      final mergedList = client.mergePendingMutations('/items', cachedList);
      expect(mergedList[0]['id'], equals('1'));
      expect(mergedList[0]['name'], equals('Patched Name'));
      expect(mergedList[0]['desc'], equals('Original description'));

      // 2. Patch single map
      final cachedMap = {'id': '1', 'name': 'Item 1', 'desc': 'Original description'};
      final mergedMap = client.mergePendingMutations('/items/1', cachedMap);
      expect(mergedMap['id'], equals('1'));
      expect(mergedMap['name'], equals('Patched Name'));
      expect(mergedMap['desc'], equals('Original description'));
    });

    test('DELETE removes matching item from list and returns null for map', () async {
      // 1. Delete item in list
      await client.delete('/items/1');
      
      final cachedList = [
        {'id': '1', 'name': 'Item 1'},
        {'id': '2', 'name': 'Item 2'}
      ];

      final mergedList = client.mergePendingMutations('/items', cachedList);
      expect(mergedList.length, equals(1));
      expect(mergedList[0]['id'], equals('2'));

      // 2. Delete single map
      final cachedMap = {'id': '1', 'name': 'Item 1'};
      final mergedMap = client.mergePendingMutations('/items/1', cachedMap);
      expect(mergedMap, isNull);
    });
  });
}
