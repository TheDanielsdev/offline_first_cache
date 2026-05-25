// example/main.dart
//
// Full working example demonstrating every new feature of OfflineHttpClient.
// Run on a device/emulator — it will work online and gracefully degrade offline.

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:offline_first_cache/offline_first_cache.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dio = Dio(BaseOptions(baseUrl: 'https://jsonplaceholder.typicode.com'));

  final client = OfflineHttpClient(
    dio,
    config: const OfflineClientConfig(
      defaultCacheTtl: Duration(minutes: 5),
      defaultRequestTtl: Duration(hours: 24), // Queue items expire after 24h
      maxRetries: 3,
      maxCacheItems: 100,
      staleWhileRevalidate: true,
      logLevel: OfflineLogLevel.debug,
    ),
    // Provide your own logger to route to Crashlytics, Sentry, etc:
    // logger: SentryOfflineLogger(),
  );

  await client.init();

  // --- Listen to events globally (e.g. for analytics or UI badges) ---
  client.events.listen((event) {
    switch (event) {
      case ConnectivityChangedEvent(:final isOnline):
        debugPrint('Network: ${isOnline ? "🟢 Online" : "🔴 Offline"}');
      case RequestQueuedEvent(:final requestId, :final url):
        debugPrint('Queued $url → $requestId');
      case RequestDedupedEvent(:final url):
        debugPrint('Deduped (already queued): $url');
      case RetrySucceededEvent(:final requestId):
        debugPrint('Retry success: $requestId');
      case RequestDeadLetteredEvent(:final url, :final reason):
        debugPrint('Dead lettered $url: $reason');
      case QueueFlushedEvent(:final successCount, :final deadLetteredCount):
        debugPrint('Queue flushed: $successCount ok, $deadLetteredCount dead');
      case CacheHitEvent(:final url, :final isStale):
        debugPrint(
          'Cache hit${isStale ? " (stale-while-revalidate)" : ""}: $url',
        );
      default:
        break;
    }
  });

  runApp(MyApp(client: client));
}

class MyApp extends StatelessWidget {
  final OfflineHttpClient client;
  const MyApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline First Demo',
      home: HomeScreen(client: client),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final OfflineHttpClient client;
  const HomeScreen({super.key, required this.client});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _output = 'Tap a button to try a feature';
  bool _loading = false;

  void _log(String msg) {
    setState(() => _output = msg);
    debugPrint(msg);
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _loading = true);
    try {
      await fn();
    } catch (e) {
      _log('Error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline First Demo'),
        actions: [
          // --- Feature: Queue size badge via ValueNotifier ---
          ValueListenableBuilder<int>(
            valueListenable: widget.client.queueSizeNotifier,
            builder: (_, count, __) => Padding(
              padding: const EdgeInsets.all(8),
              child: Badge(
                isLabelVisible: count > 0,
                label: Text('$count'),
                child: const Icon(Icons.cloud_upload_outlined),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Open Queue Inspector',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => QueueInspector(
                  queueBox: widget.client.queueBox,
                  deadLetterBox: widget.client.deadLetterBox,
                  retryAll: widget.client.retryPending,
                  replayDeadLetters: widget.client.replayDeadLetters,
                  replayDeadLetter: widget.client.replayDeadLetter,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status output
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Text(
                      _output,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
            ),
            const SizedBox(height: 16),

            // --- Feature: GET with tag-based cache invalidation ---
            _FeatureButton(
              icon: Icons.download,
              label: 'GET /posts/1 (cached, tagged "posts")',
              onTap: () => _run(() async {
                final res = await widget.client.get(
                  '/posts/1',
                  cacheTags: ['posts'],
                  cacheTtl: const Duration(minutes: 10),
                );
                _log(
                  '✅ ${res.statusCode}: ${res.data.toString().substring(0, 60)}...',
                );
              }),
            ),

            // --- Feature: Tag-based invalidation ---
            _FeatureButton(
              icon: Icons.delete_sweep,
              label: 'Invalidate cache tag "posts"',
              onTap: () => _run(() async {
                final count = await widget.client.invalidateCacheByTag('posts');
                _log(
                  '🗑️ Invalidated $count cached entry/entries tagged "posts"',
                );
              }),
            ),

            // --- Feature: POST with priority + request TTL ---
            _FeatureButton(
              icon: Icons.send,
              label: 'POST /posts (high priority, 1h TTL)',
              onTap: () => _run(() async {
                final res = await widget.client.post(
                  '/posts',
                  data: {
                    'title': 'My Post',
                    'body': 'Hello world',
                    'userId': 1,
                  },
                  priority: 2, // high
                  requestTtl: const Duration(hours: 1),
                );
                if (res.statusCode == 202) {
                  final queued = res.data['_offline_queued'] as bool? ?? false;
                  final deduped =
                      res.data['_offline_deduped'] as bool? ?? false;
                  _log(
                    queued
                        ? '📦 Queued offline (id=${res.data["id"]})'
                        : deduped
                        ? '♻️ Deduplicated — already in queue'
                        : '',
                  );
                } else {
                  _log('✅ ${res.statusCode}: Posted (id=${res.data["id"]})');
                }
              }),
            ),

            // --- Feature: Replay dead letters ---
            _FeatureButton(
              icon: Icons.replay,
              label: 'Replay all dead letters',
              onTap: () => _run(() async {
                final count = await widget.client.replayDeadLetters();
                _log(
                  '↩️ Replayed $count dead-letter request(s) back into queue',
                );
              }),
            ),

            // --- Feature: Manual retry + queue flush ---
            _FeatureButton(
              icon: Icons.cloud_sync,
              label: 'Flush pending queue now',
              onTap: () => _run(() async {
                await widget.client.retryPending();
                _log(
                  '🔄 Queue flush complete. Pending: ${widget.client.queueLength}',
                );
              }),
            ),

            // --- Feature: Cache stats ---
            _FeatureButton(
              icon: Icons.storage,
              label: 'Show cache + queue stats',
              onTap: () => _run(() async {
                _log(
                  '📊 Cache: ${widget.client.cacheSize} items\n'
                  '📬 Queue: ${widget.client.queueLength} pending\n'
                  '☠️  Dead letter: ${widget.client.deadLetterLength} items',
                );
              }),
            ),

            // --- Feature: Purge expired cache entries ---
            _FeatureButton(
              icon: Icons.cleaning_services,
              label: 'Purge expired cache',
              onTap: () => _run(() async {
                final purged = await widget.client.purgeExpiredCache();
                _log('🧹 Purged $purged expired cache entries');
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _FeatureButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: ElevatedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    );
  }
}
