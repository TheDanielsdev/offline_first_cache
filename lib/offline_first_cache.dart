// lib/offline_first_cache.dart

// Core client
export 'src/offline_http_client_impl.dart';

// Models
export 'src/models/pending_request.dart';
export 'src/models/cached_item.dart';

// Adapters / utilities
export 'src/adapters/offline_event.dart';
export 'src/adapters/offline_logger.dart';
export 'src/adapters/backoff_calc.dart';
export 'src/adapters/cache_manager.dart';
export 'src/adapters/queue_manager.dart';
export 'src/adapters/req_duplicator.dart';
export 'src/adapters/retry_policy.dart';

// Debug UI (optional — only if you want consumers to have access)
export 'src/debug/queue_inspector.dart';
