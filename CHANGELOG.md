## 0.0.6

* **Infinite Loop Fix (Stale-While-Revalidate):** Fixed a critical bug where background
  revalidation requests re-entered the interceptor, causing an infinite GET loop on stale
  cache entries. Background revalidations are now flagged with `_background_revalidate`
  to bypass the cache-hit branch.
* **Concurrent Revalidation Deduplication:** Background revalidations for the same URL are
  now deduplicated — multiple rapid GETs against a stale cache entry no longer fire
  redundant parallel network requests.