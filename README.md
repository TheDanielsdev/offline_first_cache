# offline_first_cache

[![pub package](https://img.shields.io/pub/v/offline_first_cache.svg)](https://pub.dev/packages/offline_first_cache)
[![pub points](https://img.shields.io/pub/points/offline_first_cache?color=2E7D32)](https://pub.dev/packages/offline_first_cache/score)
[![license](https://img.shields.io/github/license/TheDanielsdev/offline_first_cache)](https://github.com/TheDanielsdev/offline_first_cache)

An offline-first HTTP client wrapper for Flutter and Dart built on top of [Dio](https://pub.dev/packages/dio), [Hive](https://pub.dev/packages/hive), and [connectivity_plus](https://pub.dev/packages/connectivity_plus).

It handles offline GET caching (with tag invalidation, stale-while-revalidate) and queues mutation requests (`POST`, `PUT`, `DELETE`, `PATCH`) locally while offline, automatically retrying them in priority order with exponential backoff when connection is restored.

---

## Demo

![offline_first_cache demo](https://raw.githubusercontent.com/TheDanielsdev/offline_first_cache/main/20260625205340-ezgif.com-video-to-gif-converter.gif)

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
- 🔁 **Custom Retry Policies**: Fully control retry flow by deciding which HTTP status codes or exception types should trigger retries or go straight to the Dead Letter Queue.
- ⚡ **Optimistic Cache-Queue Merging**: Query pending mutations in real-time to merge offline updates with cached responses, providing a zero-latency, seamless Optimistic UI experience.

---

## Installation

Add this package to your project using `flutter pub add`:

```bash
flutter pub add offline_first_cache
```

Or manually add it to your `pubspec.yaml`:

```yaml
dependencies:
  offline_first_cache: ^0.0.8
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

### 4. Custom Pluggable Retry Policies

Write custom retry behaviors by defining an `OfflineRetryPolicy` to handle different failure modes (e.g., immediately dead-lettering custom application failures while retrying network or server-side issues).

```dart
class MyCustomRetryPolicy implements OfflineRetryPolicy {
  @override
  bool shouldRetry(DioException exception, int attemptCount) {
    if (attemptCount >= 5) return false; // Retry up to 5 times

    final statusCode = exception.response?.statusCode ?? 0;

    // Custom logic: do not retry unauthorized requests (401),
    // but retry on rate limits (429) or server-side errors (5xx)
    if (statusCode == 401) return false;

    return true;
  }
}

// Pass it to your client configuration:
final client = OfflineHttpClient(
  dio,
  config: const OfflineClientConfig(
    maxRetries: 5,
    retryPolicy: MyCustomRetryPolicy(),
  ),
);
```

### 5. Optimistic UI Updates (Cache-Queue Merging)

Query pending mutations in the queue matching a resource path and merge them with your cached GET response for instant, zero-latency Optimistic UI.

```dart
// 1. Fetch cached data
final cachedResponse = await client.get('/posts');
final List<Post> posts = parsePosts(cachedResponse.data);

// 2. Fetch pending local mutations from the queue
final pendingMutations = client.getPendingMutationsForPath('/posts');

// 3. Merge them optimistically!
for (final mutation in pendingMutations) {
  if (mutation.method == 'POST') {
    posts.insert(0, Post.fromJson(mutation.body));
  } else if (mutation.method == 'PUT') {
    final updatedPost = Post.fromJson(mutation.body);
    final idx = posts.indexWhere((p) => p.id == updatedPost.id);
    if (idx != -1) posts[idx] = updatedPost;
  }
}

// 4. Render 'posts' in your UI — it includes all offline changes instantly!
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

