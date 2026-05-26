import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:offline_first_cache/offline_first_cache.dart';

late Directory _hiveDir;

Future<void> _initHive() async {
  _mockConnectivity();
  _hiveDir = await Directory.systemTemp.createTemp('hive_integration_test_');
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

/// Builds a Dio instance that always succeeds with [responseData]

Dio _mockDio({
  int statusCode = 200,
  dynamic responseData = const {'ok': true},
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://mock.test'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response(
          requestOptions: options,
          statusCode: statusCode,
          data: responseData,
        ),
      ),
    ),
  );
  return dio;
}

/// Builds a Dio that always throws a connection error
Dio _offlineDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      ),
    ),
  );
  return dio;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_initHive);
  setUpAll(_mockConnectivity);
  tearDownAll(_tearDownHive);

  int n = 0;

  Future<OfflineHttpClient> makeClient(Dio dio) async {
    n++;
    final client = OfflineHttpClient(dio, logger: SilentOfflineLogger());
    await client.init(
      hivePath: _hiveDir.path,
      encryptionKey: Uint8List(
        32,
      ), // zeros — fine for tests, skips secure storage
      boxPrefix: 'test${n}_',
    );
    return client;
  }

  group('OfflineHttpClient integration', () {
    test('GET stores response in cache', () async {
      final client = await makeClient(_mockDio(responseData: {'id': 1}));
      final res = await client.get('/posts/1');
      expect(res.statusCode, equals(200));
      expect(client.cacheSize, equals(1));
      await client.dispose();
    });

    test('GET second call is served from cache', () async {
      int networkHits = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            networkHits++;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'id': 1},
              ),
            );
          },
        ),
      );

      final client = await makeClient(dio);
      await client.get('/posts/1', cacheTtl: const Duration(minutes: 5));
      await client.get('/posts/1', cacheTtl: const Duration(minutes: 5));

      expect(networkHits, equals(1)); // second call hit cache
      await client.dispose();
    });

    test('POST offline queues request and returns 202', () async {
      final client = await makeClient(_offlineDio());
      final res = await client.post('/posts', data: {'title': 'hello'});
      expect(res.statusCode, equals(202));
      expect(res.data['_offline_queued'], isTrue);
      expect(client.queueLength, equals(1));
      await client.dispose();
    });

    test('POST offline deduplicates identical requests', () async {
      final client = await makeClient(_offlineDio());
      final r1 = await client.post('/posts', data: {'title': 'hello'});
      final r2 = await client.post('/posts', data: {'title': 'hello'});
      expect(r1.data['_offline_queued'], isTrue);
      expect(r2.data['_offline_deduped'], isTrue);
      expect(client.queueLength, equals(1));
      await client.dispose();
    });

    test('retryPending flushes queue when back online', () async {
      // Queue a request while offline
      final offlineClient = await makeClient(_offlineDio());
      await offlineClient.post('/posts', data: {'title': 'hello'});
      expect(offlineClient.queueLength, equals(1));
      await offlineClient.dispose();

      // Now retry with a working Dio
      // (In real usage this is triggered automatically by connectivity change)
      final onlineClient = await makeClient(_mockDio());
      await onlineClient.retryPending();
      expect(onlineClient.queueLength, equals(0));
      await onlineClient.dispose();
    });

    test('tag-based cache invalidation removes correct entries', () async {
      final client = await makeClient(_mockDio());
      await client.get('/posts/1', cacheTags: ['posts']);
      await client.get('/users/1', cacheTags: ['users']);
      expect(client.cacheSize, equals(2));

      final removed = await client.invalidateCacheByTag('posts');
      expect(removed, equals(1));
      expect(client.cacheSize, equals(1));
      await client.dispose();
    });

    test('POST offline with skipQueue throws error instead of queueing',
        () async {
      final client = await makeClient(_offlineDio());
      expect(
        () => client.post('/posts', data: {'title': 'hello'}, skipQueue: true),
        throwsA(isA<DioException>()),
      );
      expect(client.queueLength, equals(0));
      await client.dispose();
    });

    test('init with encrypt: false opens boxes without cipher', () async {
      n++;
      final client =
          OfflineHttpClient(_mockDio(), logger: SilentOfflineLogger());
      await client.init(
        hivePath: _hiveDir.path,
        encrypt: false,
        boxPrefix: 'unencrypted_${n}_',
      );
      final res = await client.get('/posts/1');
      expect(res.statusCode, equals(200));
      expect(client.cacheSize, equals(1));

      // Key rotation should be skipped gracefully
      await client.rotateEncryptionKey();

      await client.dispose();
    });

    test('client errors during retry are dead-lettered immediately', () async {
      final offlineClient = await makeClient(_offlineDio());
      await offlineClient.post('/posts', data: {'val': 1});
      expect(offlineClient.queueLength, equals(1));
      await offlineClient.dispose();

      final client =
          await makeClient(_mockDio(statusCode: 400, responseData: 'Bad Data'));
      await client.retryPending();

      expect(client.queueLength, equals(0));
      expect(client.deadLetterLength, equals(1));
      await client.dispose();
    });

    test('connection errors during retry abort the queue flush', () async {
      final offlineClient = await makeClient(_offlineDio());
      await offlineClient.post('/posts/1', data: {'val': 1});
      await offlineClient.post('/posts/2', data: {'val': 2});
      expect(offlineClient.queueLength, equals(2));
      await offlineClient.dispose();

      final client = await makeClient(_offlineDio());
      await client.retryPending();

      final requests = client.queueBox.values.toList();
      expect(requests.length, equals(2));
      final retryCounts = requests.map((r) => r.retryCount).toList()..sort();
      expect(retryCounts, equals([0, 1]));

      await client.dispose();
    });
  });
}
