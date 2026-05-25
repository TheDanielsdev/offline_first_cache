import 'dart:convert';

/// Generates a stable deduplication hash for a pending request.
/// Two requests with the same method, url, and body produce the same hash.
class RequestDeduplicator {
  /// Compute a hash key for deduplication purposes.
  /// We intentionally exclude headers (auth tokens rotate) and timestamps.
  static String computeHash({
    required String method,
    required String url,
    required Map<String, dynamic> body,
  }) {
    // Normalize the body by sorting keys so {b:2, a:1} == {a:1, b:2}
    final normalized = _sortedJson(body);
    final raw = '${method.toUpperCase()}|$url|$normalized';
    // Simple djb2-style hash — good enough for dedup, no crypto needed
    var hash = 5381;
    for (final codeUnit in raw.codeUnits) {
      hash = ((hash << 5) + hash) ^ codeUnit;
      hash &= 0xFFFFFFFF; // keep 32-bit
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _sortedJson(dynamic value) {
    if (value is Map) {
      final sorted = Map.fromEntries(
        value.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      );
      return jsonEncode(sorted.map((k, v) => MapEntry(k, _sortedJson(v))));
    } else if (value is List) {
      return jsonEncode(value.map(_sortedJson).toList());
    }
    return jsonEncode(value);
  }
}
