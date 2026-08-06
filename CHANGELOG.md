## 0.0.9

* **Structured Logging:** Replaced console `print` calls in core interceptors with configurable `OfflineLogger` calls.
* **Dependency Optimization:** Cleaned up unused transitive dependencies and updated package environment constraints.
* **Documentation:** Fixed installation instructions and added package status badges in README.

## 0.0.8

* **Infinite Loop Fix (Stale-While-Revalidate):** Fixed a critical bug where background
  revalidation requests re-entered the interceptor, causing an infinite GET loop on stale
  cache entries. Background revalidations are now flagged with `_background_revalidate`
  to bypass the cache-hit branch.
* **Concurrent Revalidation Deduplication:** Background revalidations for the same URL are
  now deduplicated — multiple rapid GETs against a stale cache entry no longer fire
  redundant parallel network requests.