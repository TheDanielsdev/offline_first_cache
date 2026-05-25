# offline_first_cache

An offline-first HTTP client wrapper for Flutter and Dart built on top of [Dio](https://pub.dev/packages/dio), [Hive](https://pub.dev/packages/hive), and [connectivity_plus](https://pub.dev/packages/connectivity_plus).

It handles offline GET caching (with tag invalidation, stale-while-revalidate) and queues mutation requests (`POST`, `PUT`, `DELETE`, `PATCH`) locally while offline, automatically retrying them in priority order with exponential backoff when connection is restored.

---

## Features

- 📶 **Automatic Network State Handling**: Monitors network changes and automatically flushes the pending requests queue when the device goes back online.
- 📦 **GET Request Caching**:
  - Configurable TTL (Time-To-Live) per request or globally.
  - **Stale-While-Revalidate**: Serves cached data instantly while refreshing in the background when online.
  - **Tag-Based Invalidation**: Tag cached requests and invalidate multiple caches at once (e.g. invalidating all `'posts'` or `'users'` responses).
- 📬 **Offline Request Queue**:
  - Automatically intercepts mutation requests (`POST`, `PUT`, `PATCH`, `DELETE`) when offline and queues them.
  - Returns a standard `202 Accepted` response with the queue task ID to the caller.
  - Request deduplication to avoid queuing identical mutation tasks.
  - Configurable priority queues (Priority level sorted: Low, Normal, High, Critical).
  - Configurable individual request expiration (Request TTL).
  - Ability to bypass queueing entirely for critical requests (e.g. sign-in/payments).
- ☠️ **Dead Letter Queue (DLQ)**:
  - Moves requests that fail permanently (exceeded `maxRetries` or client errors like `400 Bad Request`) to a separate Dead Letter Box.
  - Allows inspecting and manually replaying or discarding dead-lettered requests.
- 🔒 **Optional AES Encryption**: Encrypts offline boxes using Hive AES ciphers. Keys are stored securely in keychain/keystore via `flutter_secure_storage` with key rotation support.
- 📊 **Reactive Event Stream**: Listen to events (`ConnectivityChangedEvent`, `CacheHitEvent`, `RetrySucceededEvent`, etc.) globally for analytics or in-app notifications.
- 🖥️ **Queue Inspector UI**: A built-in debug panel widget (`QueueInspector`) to monitor pending requests, inspect headers/payloads, replay dead letters, and trigger manual retries.

---

## Installation

Add this package to your `pubspec.yaml`:

```yaml
dependencies:
  offline_first_cache:
    path: # your local path or git URL
  dio: ^5.0.0
```

---

## Getting Started

### 1. Initialize the Client

Initialize the `OfflineHttpClient` with your base `Dio` instance.

```dart
import 'package:dio/dio.dart';
import 'package:offline_first_cache/offline_first_cache.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

  final client = OfflineHttpClient(
    dio,
    config: const OfflineClientConfig(
      defaultCacheTtl: Duration(minutes: 10),
      defaultRequestTtl: Duration(hours: 24),
      maxRetries: 3,
      maxCacheItems: 100,
      staleWhileRevalidate: true,
      logLevel: OfflineLogLevel.info,
    ),
  );

  // Initialize Hive boxes and connectivity listener
  // encryption is optional (enabled by default)
  await client.init(encrypt: true);

  runApp(MyApp(client: client));
}
```

---

## Usage Examples

### 1. GET Request with Caching and Invalidation Tags

Cache GET responses by specifying a cache TTL and grouping tags.

```dart
final response = await client.get(
  '/posts/1',
  cacheTtl: const Duration(minutes: 30),
  cacheTags: ['posts', 'post_1'],
);

// Later, invalidating all cache entries associated with "posts"
await client.invalidateCacheByTag('posts');
```

### 2. Queue Mutations Offline with Priority

When the device is offline, non-GET requests are queued and a `202 Accepted` response is returned.

```dart
final response = await client.post(
  '/posts',
  data: {'title': 'Offline First', 'body': 'Works offline!'},
  priority: 2, // High priority (Low = 0, Normal = 1, High = 2, Critical = 3)
  requestTtl: const Duration(hours: 12), // Discard request if not sent in 12h
);

if (response.statusCode == 202) {
  final isQueued = response.data['_offline_queued'] ?? false;
  if (isQueued) {
    print('Request queued locally with ID: ${response.data["id"]}');
  }
}
```

### 3. Bypassing the Queue for Specific Requests

For requests that should fail immediately if offline (e.g., login or checkout), pass the `skipQueue` flag.

```dart
try {
  final response = await client.post(
    '/auth/login',
    data: {'username': 'user', 'password': 'password'},
    skipQueue: true, // Will not queue request, throws DioException on network failure
  );
} on DioException catch (e) {
  print('Login failed: ${e.message}');
}
```

---

## Advanced Configurations

### Listening to Global Events

Perfect for showing network connection banners, retry success notifications, or database syncing loaders.

```dart
client.events.listen((event) {
  if (event is ConnectivityChangedEvent) {
    print(event.isOnline ? 'Network online! 🟢' : 'Network offline! 🔴');
  } else if (event is RequestQueuedEvent) {
    print('Queued: ${event.url}');
  } else if (event is RetrySucceededEvent) {
    print('Successfully replayed request: ${event.requestId}');
  } else if (event is RequestDeadLetteredEvent) {
    print('Request moved to DLQ: ${event.reason}');
  }
});
```

---

## Developer Debug Interface

The package ships with a **`QueueInspector`** widget. You can navigate to it from any developer drawer or settings menu.

```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => QueueInspector(
      queueBox: client.queueBox,
      deadLetterBox: client.deadLetterBox,
      retryAll: client.retryPending,
      replayDeadLetters: client.replayDeadLetters,
      replayDeadLetter: client.replayDeadLetter,
    ),
  ),
);
```

### Features of the Inspector:
1. **Pending Tab**: Displays all items currently waiting to be sent, ordered by priority, with detailed headers, method type, payload, and whether the item has expired. Supports deleting specific pending requests.
2. **Dead Letter Tab**: Displays requests that failed permanently. Shows the exact error message that caused the failure. Allows replaying requests individually/in bulk, or discarding them.

---

## License

This package is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

