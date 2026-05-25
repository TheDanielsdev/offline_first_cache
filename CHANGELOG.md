## 0.0.2

* Initial release of `offline_first_cache`.
* Added `OfflineHttpClient` wrapper on top of Dio and Hive.
* Supported offline GET request caching with configurable TTL, tag-based invalidation, and stale-while-revalidate.
* Supported offline request queueing (POST, PUT, DELETE, PATCH) with priority execution, exponential backoff with full jitter, and deduplication.
* Supported Dead Letter Queue (DLQ) for failed retries.
* Added optional secure storage-based AES encryption for local boxes.
* Included a built-in `QueueInspector` widget to visually debug and manage the request and dead-letter queues.
