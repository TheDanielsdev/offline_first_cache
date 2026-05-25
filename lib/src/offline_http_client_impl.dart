// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:offline_first_cache/src/adapters/cache_manager.dart';
import 'package:offline_first_cache/src/adapters/offline_event.dart';
import 'package:offline_first_cache/src/adapters/offline_logger.dart';
import 'package:offline_first_cache/src/adapters/queue_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'models/pending_request.dart';
import 'models/cached_item.dart';

import 'package:flutter/foundation.dart';

/// Configuration for [OfflineHttpClient].
class OfflineClientConfig {
  /// Default cache TTL when no per-request TTL is specified.
  final Duration defaultCacheTtl;

  /// Default TTL for queued requests (null = never expire).
  final Duration? defaultRequestTtl;

  /// Maximum retry attempts before dead-lettering.
  final int maxRetries;

  /// Maximum cached entries before LRU eviction kicks in.
  final int maxCacheItems;

  /// Enable stale-while-revalidate: serve stale cache immediately,
  /// then refresh in background.
  final bool staleWhileRevalidate;

  /// Minimum log level for the built-in logger.
  final OfflineLogLevel logLevel;

  const OfflineClientConfig({
    this.defaultCacheTtl = const Duration(minutes: 30),
    this.defaultRequestTtl,
    this.maxRetries = 3,
    this.maxCacheItems = 200,
    this.staleWhileRevalidate = true,
    this.logLevel = OfflineLogLevel.info,
  });
}

/// A Dio-based HTTP client with offline-first capabilities:
///
/// - **Automatic caching** of GET responses with TTL, tags, and ETag support
/// - **Offline request queue** for mutating requests (POST/PUT/PATCH/DELETE)
/// - **Priority-based retry** with exponential backoff + jitter
/// - **Request deduplication** to prevent duplicate queued entries
/// - **Dead letter queue** for permanently failed requests
/// - **Stale-while-revalidate** cache strategy
/// - **Tag-based cache invalidation**
/// - **Event stream** for reactive UI updates
/// - **Pluggable logger** interface
/// - **Encrypted Hive storage** with key rotation support
class OfflineHttpClient {
  final Dio _dio;
  final OfflineClientConfig _config;
  final FlutterSecureStorage _secureStorage;
  final OfflineLogger _logger;

  late CacheManager _cache;
  late QueueManager _queue;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription? _connectivitySub;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  bool _isFlushing = false;
  bool _encrypt = true;

  // --- Event stream ---
  final _eventController = StreamController<OfflineEvent>.broadcast();

  /// Stream of all offline client events. Listen to drive UI badges,
  /// snackbars, analytics, etc.
  Stream<OfflineEvent> get events => _eventController.stream;

  /// Filtered stream of just queue-size-relevant events.
  Stream<int> get queueSizeStream => events
      .where(
        (e) =>
            e is RequestQueuedEvent ||
            e is RetrySucceededEvent ||
            e is RequestDeadLetteredEvent ||
            e is QueueFlushedEvent,
      )
      .map((_) => _queue.queueLength);

  /// ValueNotifier that always reflects the current queue length.
  /// Use this to drive a badge counter in the UI.
  late final ValueNotifier<int> queueSizeNotifier;

  static const String _encryptionKeyStorage = 'offline_first_encryption_key';

  OfflineHttpClient(
    this._dio, {
    OfflineClientConfig config = const OfflineClientConfig(),
    FlutterSecureStorage? secureStorage,
    OfflineLogger? logger,
  }) : _config = config,
       _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _logger = logger ?? ConsoleOfflineLogger(minLevel: config.logLevel) {
    queueSizeNotifier = ValueNotifier(0);
    events.listen((e) {
      if (e is RequestQueuedEvent ||
          e is RetrySucceededEvent ||
          e is RequestDeadLetteredEvent ||
          e is QueueFlushedEvent) {
        queueSizeNotifier.value = _queue.queueLength;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Initialize Hive boxes, connectivity monitoring, and Dio interceptors.
  ///
  /// [hivePath] — custom Hive storage path (defaults to Flutter app documents dir)
  /// [encryptionKey] — provide a key directly (e.g. in tests). If null, one is
  ///   loaded from secure storage or generated.
  Future<void> init({
    String? hivePath,
    Uint8List? encryptionKey,
    String boxPrefix = '',
    bool encrypt = true,
  }) async {
    _encrypt = encrypt;
    if (hivePath != null) {
      Hive.init(hivePath);
    } else {
      await Hive.initFlutter();
    }
    if (!Hive.isAdapterRegistered(0))
      Hive.registerAdapter(PendingRequestAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(CachedItemAdapter());
    if (!Hive.isAdapterRegistered(2))
      Hive.registerAdapter(DeadLetterRequestAdapter());

    final HiveAesCipher? cipher;
    if (encrypt) {
      final key = encryptionKey ?? await loadOrCreateEncryptionKey();
      cipher = HiveAesCipher(key);
    } else {
      cipher = null;
    }

    final queueBox = await Hive.openBox<PendingRequest>(
      '${boxPrefix}offline_queue',
      encryptionCipher: cipher,
    );
    final cacheBox = await Hive.openBox<CachedItem>(
      '${boxPrefix}offline_cache',
      encryptionCipher: cipher,
    );
    final deadLetterBox = await Hive.openBox<DeadLetterRequest>(
      '${boxPrefix}offline_dead_letter',
      encryptionCipher: cipher,
    );

    _cache = CacheManager(
      box: cacheBox,
      logger: _logger,
      emit: _emit,
      maxItems: _config.maxCacheItems,
    );
    _queue = QueueManager(
      queueBox: queueBox,
      deadLetterBox: deadLetterBox,
      logger: _logger,
      emit: _emit,
      maxRetries: _config.maxRetries,
    );

    // Bootstrap connectivity state
    final result = await _connectivity.checkConnectivity();
    _isOnline = result != ConnectivityResult.none;

    _connectivitySub = _connectivity.onConnectivityChanged.listen((
      event,
    ) async {
      final wasOnline = _isOnline;
      _isOnline = event != ConnectivityResult.none;
      _emit(ConnectivityChangedEvent(isOnline: _isOnline));
      _logger.info('Connectivity changed: ${_isOnline ? "online" : "offline"}');
      if (!wasOnline && _isOnline) {
        _logger.info('Back online — flushing queue');
        await retryPending();
      }
    });

    _installInterceptors();
    _logger.info('OfflineHttpClient initialized (online=$_isOnline)');
  }

  // ---------------------------------------------------------------------------
  // Public HTTP API
  // ---------------------------------------------------------------------------

  /// GET with caching. Pass [cacheTags] to enable tag-based invalidation.
  Future<Response> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    List<String> cacheTags = const [],
    Duration? cacheTtl,
  }) {
    final extra = {
      ...?options?.extra,
      if (cacheTags.isNotEmpty) '_cache_tags': cacheTags,
      if (cacheTtl != null) 'cache_ttl_seconds': cacheTtl.inSeconds,
    };
    return _dio.get(
      path,
      queryParameters: queryParameters,
      options: (options ?? Options()).copyWith(extra: extra),
    );
  }

  /// POST — queued offline if network is unavailable.
  Future<Response> post(
    String path, {
    dynamic data,
    Options? options,
    int priority = 1,
    Duration? requestTtl,
    bool skipQueue = false,
  }) => _mutate(
    'POST',
    path,
    data: data,
    options: options,
    priority: priority,
    requestTtl: requestTtl,
    skipQueue: skipQueue,
  );

  /// PUT — queued offline if network is unavailable.
  Future<Response> put(
    String path, {
    dynamic data,
    Options? options,
    int priority = 1,
    Duration? requestTtl,
    bool skipQueue = false,
  }) => _mutate(
    'PUT',
    path,
    data: data,
    options: options,
    priority: priority,
    requestTtl: requestTtl,
    skipQueue: skipQueue,
  );

  /// PATCH — queued offline if network is unavailable.
  Future<Response> patch(
    String path, {
    dynamic data,
    Options? options,
    int priority = 1,
    Duration? requestTtl,
    bool skipQueue = false,
  }) => _mutate(
    'PATCH',
    path,
    data: data,
    options: options,
    priority: priority,
    requestTtl: requestTtl,
    skipQueue: skipQueue,
  );

  /// DELETE — queued offline if network is unavailable.
  Future<Response> delete(
    String path, {
    dynamic data,
    Options? options,
    int priority = 1,
    Duration? requestTtl,
    bool skipQueue = false,
  }) => _mutate(
    'DELETE',
    path,
    data: data,
    options: options,
    priority: priority,
    requestTtl: requestTtl,
    skipQueue: skipQueue,
  );

  Future<Response> _mutate(
    String method,
    String path, {
    dynamic data,
    Options? options,
    int priority = 1,
    Duration? requestTtl,
    bool skipQueue = false,
  }) {
    final extra = {
      ...?options?.extra,
      '_priority': priority,
      if (requestTtl != null) '_request_ttl_ms': requestTtl.inMilliseconds,
      if (skipQueue) '_skip_queue': true,
    };
    return _dio.request(
      path,
      data: data,
      options: (options ?? Options()).copyWith(method: method, extra: extra),
    );
  }

  // ---------------------------------------------------------------------------
  // Cache management
  // ---------------------------------------------------------------------------

  /// Invalidate all cached responses tagged with [tag].
  Future<int> invalidateCacheByTag(String tag) => _cache.invalidateByTag(tag);

  /// Invalidate a specific cached URL.
  Future<void> invalidateCache(String url) => _cache.invalidate(url);

  /// Purge all expired cache entries. Call on app resume to free disk space.
  Future<int> purgeExpiredCache() => _cache.purgeExpired();

  /// Read a value from cache by URL key (null if missing or expired).
  dynamic readCache(String key) => _cache.read(key)?.data;

  // ---------------------------------------------------------------------------
  // Queue management
  // ---------------------------------------------------------------------------

  /// Retry all pending requests in priority order with exponential backoff.
  Future<void> retryPending() async {
    if (_isFlushing) {
      _logger.info('Queue flush already in progress — skipping concurrent retryPending()');
      return;
    }
    _isFlushing = true;

    try {
      final pending = _queue.prioritizedQueue;
      if (pending.isEmpty) return;

      _logger.info('Retrying ${pending.length} pending requests');
      int success = 0, failed = 0, deadLettered = 0;

      // Purge expired requests first
      final purged = await _queue.purgeExpired();
      if (purged > 0) _logger.info('Purged $purged expired queued requests');

      for (final request in _queue.prioritizedQueue) {
        // Abort immediately if we went offline in the meantime or if _isOnline is false
        if (!_isOnline) {
          _logger.info('Aborting queue flush — client went offline');
          break;
        }

        // Apply backoff delay between retries (skip for first attempt)
        if (request.retryCount > 0) {
          final delay = _queue.backoff.delayFor(request.retryCount);
          await Future.delayed(delay);
        }

        // Re-check online status after delay
        if (!_isOnline) {
          _logger.info('Aborting queue flush — client went offline after delay');
          break;
        }

        try {
          final opts = Options(headers: request.headers);
          Response res;

          switch (request.method.toUpperCase()) {
            case 'POST':
              res = await _dio.post(
                request.url,
                data: request.body,
                options: opts,
              );
              break;
            case 'PUT':
              res = await _dio.put(
                request.url,
                data: request.body,
                options: opts,
              );
              break;
            case 'PATCH':
              res = await _dio.patch(
                request.url,
                data: request.body,
                options: opts,
              );
              break;
            case 'DELETE':
              res = await _dio.delete(
                request.url,
                data: request.body,
                options: opts,
              );
              break;
            default:
              await _queue.queueBox.delete(request.id);
              continue;
          }

          final statusCode = res.statusCode ?? 0;
          if (statusCode >= 200 && statusCode < 300) {
            await _queue.recordSuccess(request);
            success++;
          } else if (statusCode >= 400 && statusCode < 500 && statusCode != 408 && statusCode != 429) {
            // HTTP 4xx Client Error (excluding 408/429) -> dead letter immediately!
            await _queue.moveToDeadLetter(request, 'Client error: HTTP $statusCode');
            deadLettered++;
          } else {
            final outcome = await _queue.recordFailure(
              request,
              'HTTP $statusCode',
            );
            if (outcome == RetryOutcome.deadLettered)
              deadLettered++;
            else
              failed++;
          }
        } on DioException catch (e) {
          final isNetwork = _isNetworkError(e);

          if (isNetwork) {
            // Connection / network issue -> abort the flush loop immediately
            // to prevent exhausting retry limits for all subsequent requests!
            _logger.warning('Aborting queue flush — connection error: ${e.message}');
            // Also log a failure for the current request but keep it in the queue for next flush
            await _queue.recordFailure(request, e.toString());
            failed++;
            break;
          }

          final statusCode = e.response?.statusCode ?? 0;
          if (statusCode >= 400 && statusCode < 500 && statusCode != 408 && statusCode != 429) {
            // HTTP 4xx Client Error -> dead letter immediately!
            await _queue.moveToDeadLetter(request, 'Client error: DioException HTTP $statusCode (${e.message})');
            deadLettered++;
          } else {
            final outcome = await _queue.recordFailure(request, e.toString());
            if (outcome == RetryOutcome.deadLettered)
              deadLettered++;
            else
              failed++;
          }
        } catch (e) {
          final outcome = await _queue.recordFailure(request, e.toString());
          if (outcome == RetryOutcome.deadLettered)
            deadLettered++;
          else
            failed++;
        }
      }

      _emit(
        QueueFlushedEvent(
          successCount: success,
          failedCount: failed,
          deadLetteredCount: deadLettered,
        ),
      );
      _logger.info(
        'Queue flush complete: $success succeeded, $failed will retry, $deadLettered dead-lettered',
      );
    } finally {
      _isFlushing = false;
    }
  }

  /// Replay all dead-letter requests back into the main queue.
  Future<int> replayDeadLetters() => _queue.replayAllDeadLetters();

  /// Replay a single dead-letter request by ID.
  Future<String?> replayDeadLetter(String id) => _queue.replayDeadLetter(id);

  // ---------------------------------------------------------------------------
  // Accessors for QueueInspector / debug UI
  // ---------------------------------------------------------------------------

  Box<PendingRequest> get queueBox => _queue.queueBox;
  Box<DeadLetterRequest> get deadLetterBox => _queue.deadLetterBox;
  int get queueLength => _queue.queueLength;
  int get deadLetterLength => _queue.deadLetterLength;
  int get cacheSize => _cache.itemCount;

  // ---------------------------------------------------------------------------
  // Encryption / key management
  // ---------------------------------------------------------------------------

  Future<Uint8List> loadOrCreateEncryptionKey() async {
    final stored = await _secureStorage.read(key: _encryptionKeyStorage);
    if (stored != null) {
      try {
        return base64Decode(stored);
      } catch (_) {}
    }
    final key = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await _secureStorage.write(
      key: _encryptionKeyStorage,
      value: base64Encode(key),
    );
    return key;
  }

  Future<void> rotateEncryptionKey() async {
    if (!_encrypt) {
      _logger.warning('Key rotation skipped: encryption is disabled.');
      return;
    }
    try {
      final oldKey = await loadOrCreateEncryptionKey();
      final newKey = Uint8List.fromList(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      );
      await _reencryptAllBoxes(oldKey, newKey);
      await _secureStorage.write(
        key: _encryptionKeyStorage,
        value: base64Encode(newKey),
      );
      _logger.info('Encryption key rotated successfully');
    } catch (e, s) {
      _logger.error('Key rotation failed', error: e, stackTrace: s);
    }
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  Future<void> dispose() async {
    await _connectivitySub?.cancel();
    await _eventController.close();
    await _queue.queueBox.close();
    await _queue.deadLetterBox.close();
    queueSizeNotifier.dispose();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _emit(OfflineEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void _installInterceptors() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.method.toUpperCase() == 'GET') {
            final cacheKey = options.uri.toString();
            final stale = _cache.readAllowingStale(cacheKey);

            if (stale != null) {
              final isExpired = stale.isExpired;

              if (!_isOnline && !isExpired) {
                // Offline + fresh cache → serve immediately
                _emit(CacheHitEvent(url: cacheKey, isStale: false));
                return handler.resolve(_cachedResponse(options, stale));
              }

              if (!_isOnline && isExpired) {
                // Offline + stale cache → serve stale (best effort)
                _logger.warning('Serving stale cache (offline): $cacheKey');
                _emit(CacheHitEvent(url: cacheKey, isStale: true));
                return handler.resolve(_cachedResponse(options, stale));
              }

              if (_isOnline && !isExpired) {
                // Online + fresh → serve from cache
                _emit(CacheHitEvent(url: cacheKey, isStale: false));
                return handler.resolve(_cachedResponse(options, stale));
              }

              if (_isOnline && isExpired && _config.staleWhileRevalidate) {
                // Stale-while-revalidate: serve stale now, refresh in background
                _emit(CacheHitEvent(url: cacheKey, isStale: true));
                _revalidateInBackground(options);
                return handler.resolve(_cachedResponse(options, stale));
              }
            }

            // Attach ETag / Last-Modified for conditional requests
            if (stale?.etag != null) {
              options.headers['If-None-Match'] = stale!.etag;
            } else if (stale?.lastModified != null) {
              options.headers['If-Modified-Since'] = stale!.lastModified;
            }
          }
          return handler.next(options);
        },

        onResponse: (response, handler) async {
          if (response.requestOptions.method.toUpperCase() == 'GET') {
            // 304 Not Modified — update cachedAt timestamp to reset TTL
            if (response.statusCode == 304) {
              final key = response.requestOptions.uri.toString();
              final existing = _cache.readAllowingStale(key);
              if (existing != null) {
                await _cache.write(
                  CachedItem(
                    key: existing.key,
                    data: existing.data,
                    ttlSeconds: existing.ttlSeconds,
                    tags: existing.tags,
                    etag: existing.etag,
                    lastModified: existing.lastModified,
                  ),
                );
                return handler.resolve(
                  _cachedResponse(response.requestOptions, existing),
                );
              }
            }

            await _writeCacheFromResponse(response);
          }
          return handler.next(response);
        },

        onError: (err, handler) async {
          final options = err.requestOptions;
          final method = options.method.toUpperCase();
          final isNetworkError = _isNetworkError(err);
          final skipQueue = options.extra['_skip_queue'] as bool? ?? false;

          if (isNetworkError && method != 'GET' && !skipQueue) {
            final priority = options.extra['_priority'] as int? ?? 1;
            final ttlMs = options.extra['_request_ttl_ms'] as int?;
            final requestTtl = ttlMs != null
                ? Duration(milliseconds: ttlMs)
                : _config.defaultRequestTtl;

            final body = options.data is Map<String, dynamic>
                ? Map<String, dynamic>.from(options.data as Map)
                : <String, dynamic>{'raw': options.data?.toString()};

            final id = await _queue.enqueue(
              method: method,
              url: options.uri.toString(),
              headers: options.headers.map(
                (k, v) => MapEntry(k, v?.toString()),
              ),
              body: body,
              priority: priority,
              requestTtl: requestTtl,
            );

            // id is null if deduplicated
            return handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 202,
                data: {
                  '_offline_queued': id != null,
                  '_offline_deduped': id == null,
                  if (id != null) 'id': id,
                },
              ),
            );
          }

          // For network GET errors, fall back to stale cache
          if (isNetworkError && method == 'GET') {
            final stale = _cache.readAllowingStale(options.uri.toString());
            if (stale != null) {
              _logger.warning(
                'Network error — serving stale cache: ${options.uri}',
              );
              _emit(CacheHitEvent(url: options.uri.toString(), isStale: true));
              return handler.resolve(_cachedResponse(options, stale));
            }
          }

          return handler.next(err);
        },
      ),
    );
  }

  Future<void> _writeCacheFromResponse(Response response) async {
    final key = response.requestOptions.uri.toString();
    final ttl =
        response.requestOptions.extra['cache_ttl_seconds'] as int? ??
        _config.defaultCacheTtl.inSeconds;
    final tags =
        (response.requestOptions.extra['_cache_tags'] as List?)
            ?.cast<String>() ??
        <String>[];

    final etag = response.headers.value('etag');
    final lastModified = response.headers.value('last-modified');

    await _cache.write(
      CachedItem(
        key: key,
        data: response.data,
        ttlSeconds: ttl,
        tags: tags,
        etag: etag,
        lastModified: lastModified,
      ),
    );
  }

  void _revalidateInBackground(RequestOptions options) {
    final url = options.uri.toString();
    Future(() async {
      try {
        final res = await _dio.get(
          url,
          options: Options(headers: options.headers, extra: options.extra),
        );
        if (res.statusCode != null &&
            res.statusCode! >= 200 &&
            res.statusCode! < 300) {
          _emit(BackgroundRevalidatedEvent(url: url, success: true));
        }
      } catch (_) {
        _emit(BackgroundRevalidatedEvent(url: url, success: false));
      }
    });
  }

  Response _cachedResponse(RequestOptions options, CachedItem item) {
    return Response(
      requestOptions: options,
      data: item.data,
      statusCode: 200,
      headers: Headers.fromMap({
        'x-cache': ['HIT'],
        'x-cache-expires': [item.expiresAt.toIso8601String()],
      }),
    );
  }

  bool _isNetworkError(DioException err) {
    return err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.unknown ||
        err.error is SocketException ||
        !_isOnline;
  }

  Future<void> _reencryptAllBoxes(Uint8List oldKey, Uint8List newKey) async {
    for (final boxName in [
      'offline_queue',
      'offline_cache',
      'offline_dead_letter',
    ]) {
      // We re-open with old key, copy data, close, re-open with new key, write
      final oldBox = await Hive.openBox(
        boxName,
        encryptionCipher: HiveAesCipher(oldKey),
      );
      final data = {for (var k in oldBox.keys) k: oldBox.get(k)};
      await oldBox.close();

      final newBox = await Hive.openBox(
        boxName,
        encryptionCipher: HiveAesCipher(newKey),
      );
      for (final e in data.entries) await newBox.put(e.key, e.value);
      await newBox.close();
    }
  }
}
