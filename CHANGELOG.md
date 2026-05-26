## 0.0.4

* **True Least-Recently-Used (LRU) Cache Eviction:** Optimized caching by replacing single-deletion with a true LRU algorithm that sorts and clears least-recently-accessed items when exceeding size capacity.
* **Custom Pluggable Retry Policies:** Added support for pluggable `OfflineRetryPolicy` strategies, allowing custom retry decisions (e.g. dynamic status checks, permanent client error handling) rather than hardcoded rules.
* **Optimistic UI Merging Helper:** Added the `getPendingMutationsForPath` helper to query and synchronize pending queued mutations (POST/PUT/PATCH/DELETE) directly with local widgets for instant UI updates.
* **Modernized Package Structure:** Restructured package assets, moving example components to a dedicated compliant `example/` folder, ensuring a 100/100 pub points score on pub.dev.
* **Interceptor & Queue Reliability Fixes:** Fixed deep interceptor-ordering issues in integration tests using network adapter-based mocks, and resolved recursive queueing race conditions during retries.

## 0.0.3

* Initial release of `offline_first_cache`.
* Added `OfflineHttpClient` wrapper on top of Dio and Hive.
* Supported offline GET request caching with configurable TTL, tag-based invalidation, and stale-while-revalidate.
* Supported offline request queueing (POST, PUT, DELETE, PATCH) with priority execution, exponential backoff with full jitter, and deduplication.
* Supported Dead Letter Queue (DLQ) for failed retries.
* Added optional secure storage-based AES encryption for local boxes.
* Included a built-in `QueueInspector` widget to visually debug and manage the request and dead-letter queues.
