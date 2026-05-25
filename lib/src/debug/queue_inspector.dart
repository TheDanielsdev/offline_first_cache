import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:offline_first_cache/src/models/cached_item.dart';

import '../models/pending_request.dart';

/// Priority label and color for display.
extension _PriorityDisplay on RequestPriority {
  String get label => switch (this) {
    RequestPriority.low => 'Low',
    RequestPriority.normal => 'Normal',
    RequestPriority.high => 'High',
    RequestPriority.critical => 'Critical',
  };

  Color get color => switch (this) {
    RequestPriority.low => Colors.grey,
    RequestPriority.normal => Colors.blue,
    RequestPriority.high => Colors.orange,
    RequestPriority.critical => Colors.red,
  };
}

/// Developer debug panel for inspecting the offline queue and dead letter queue.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => QueueInspector(
///     client: myOfflineClient,
///   ),
/// ));
/// ```
class QueueInspector extends StatefulWidget {
  final Box<PendingRequest> queueBox;
  final Box<DeadLetterRequest> deadLetterBox;
  final Future<void> Function() retryAll;
  final Future<int> Function() replayDeadLetters;
  final Future<String?> Function(String) replayDeadLetter;

  const QueueInspector({
    super.key,
    required this.queueBox,
    required this.deadLetterBox,
    required this.retryAll,
    required this.replayDeadLetters,
    required this.replayDeadLetter,
  });

  @override
  State<QueueInspector> createState() => _QueueInspectorState();
}

class _QueueInspectorState extends State<QueueInspector>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Request Queue Inspector'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            ValueListenableBuilder(
              valueListenable: widget.queueBox.listenable(),
              builder: (_, box, __) => Tab(text: 'Pending (${box.length})'),
            ),
            ValueListenableBuilder(
              valueListenable: widget.deadLetterBox.listenable(),
              builder: (_, box, __) => Tab(text: 'Dead Letter (${box.length})'),
            ),
          ],
        ),
        actions: [
          if (_retrying)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry all pending',
              onPressed: _handleRetryAll,
            ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _PendingQueueTab(
            queueBox: widget.queueBox,
            onDelete: _deleteRequest,
            onRetryAll: _handleRetryAll,
          ),
          _DeadLetterTab(
            deadLetterBox: widget.deadLetterBox,
            onReplay: _replayOne,
            onReplayAll: _handleReplayAll,
            onDelete: _deleteDeadLetter,
          ),
        ],
      ),
    );
  }

  Future<void> _handleRetryAll() async {
    setState(() => _retrying = true);
    try {
      await widget.retryAll();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _handleReplayAll() async {
    setState(() => _retrying = true);
    try {
      final count = await widget.replayDeadLetters();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Replayed $count requests')));
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _deleteRequest(String key) async {
    await widget.queueBox.delete(key);
    setState(() {});
  }

  Future<void> _replayOne(String deadLetterId) async {
    final newId = await widget.replayDeadLetter(deadLetterId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newId != null
                ? 'Replayed as request $newId'
                : 'Duplicate — already queued',
          ),
        ),
      );
    }
    setState(() {});
  }

  Future<void> _deleteDeadLetter(String key) async {
    await widget.deadLetterBox.delete(key);
    setState(() {});
  }
}

// ---------------------------------------------------------------------------
// Pending Queue Tab
// ---------------------------------------------------------------------------

class _PendingQueueTab extends StatelessWidget {
  final Box<PendingRequest> queueBox;
  final Future<void> Function(String key) onDelete;
  final Future<void> Function() onRetryAll;

  const _PendingQueueTab({
    required this.queueBox,
    required this.onDelete,
    required this.onRetryAll,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: queueBox.listenable(),
      builder: (context, box, _) {
        if (box.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
                SizedBox(height: 12),
                Text('No pending requests', style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }

        // Sort by priority desc
        final sorted = box.values.toList()
          ..sort((a, b) {
            final pCmp = b.priority.compareTo(a.priority);
            if (pCmp != 0) return pCmp;
            return a.createdAt.compareTo(b.createdAt);
          });

        return ListView.builder(
          itemCount: sorted.length,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemBuilder: (context, index) => _PendingCard(
            request: sorted[index],
            onDelete: () => onDelete(sorted[index].id),
            onRetryAll: onRetryAll,
          ),
        );
      },
    );
  }
}

class _PendingCard extends StatelessWidget {
  final PendingRequest request;
  final VoidCallback onDelete;
  final VoidCallback onRetryAll;

  const _PendingCard({
    required this.request,
    required this.onDelete,
    required this.onRetryAll,
  });

  @override
  Widget build(BuildContext context) {
    final priority = request.priorityLevel;
    final isExpired = request.isExpired;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: isExpired ? Colors.red.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                _MethodBadge(method: request.method),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    request.url,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _PriorityBadge(priority: priority),
              ],
            ),
            const SizedBox(height: 8),

            // Metadata row
            Row(
              children: [
                _InfoChip(label: 'Retries', value: '${request.retryCount}'),
                const SizedBox(width: 8),
                _InfoChip(
                  label: 'Created',
                  value: _formatTime(request.createdAt),
                ),
                if (isExpired) ...[
                  const SizedBox(width: 8),
                  const _InfoChip(label: 'EXPIRED', value: '', isError: true),
                ],
              ],
            ),
            const SizedBox(height: 10),

            // Body
            _ExpandableSection(title: 'Body', content: request.body.toString()),
            const SizedBox(height: 6),

            // Headers (masked)
            _ExpandableSection(
              title: 'Headers (sensitive fields redacted)',
              content: request.maskedHeaders.toString(),
            ),
            const SizedBox(height: 12),

            // Actions
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Delete'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: onRetryAll,
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Retry All'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dead Letter Tab
// ---------------------------------------------------------------------------

class _DeadLetterTab extends StatelessWidget {
  final Box<DeadLetterRequest> deadLetterBox;
  final Future<void> Function(String id) onReplay;
  final Future<void> Function() onReplayAll;
  final Future<void> Function(String key) onDelete;

  const _DeadLetterTab({
    required this.deadLetterBox,
    required this.onReplay,
    required this.onReplayAll,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: deadLetterBox.listenable(),
      builder: (context, box, _) {
        if (box.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mail_outline, size: 48, color: Colors.grey),
                SizedBox(height: 12),
                Text(
                  'Dead letter queue is empty',
                  style: TextStyle(fontSize: 16),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${box.length} permanently failed request(s)',
                      style: const TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onReplayAll,
                    icon: const Icon(Icons.replay, size: 16),
                    label: const Text('Replay All'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: box.length,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemBuilder: (context, index) {
                  final key = box.keys.elementAt(index) as String;
                  final dead = box.get(key);
                  if (dead == null) return const SizedBox();
                  return _DeadLetterCard(
                    dead: dead,
                    onReplay: () => onReplay(key),
                    onDelete: () => onDelete(key),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DeadLetterCard extends StatelessWidget {
  final DeadLetterRequest dead;
  final VoidCallback onReplay;
  final VoidCallback onDelete;

  const _DeadLetterCard({
    required this.dead,
    required this.onReplay,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _MethodBadge(method: dead.original.method),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dead.original.url,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _InfoChip(label: 'Attempts', value: '${dead.totalAttempts}'),
                const SizedBox(width: 8),
                _InfoChip(label: 'Failed', value: _formatTime(dead.failedAt)),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 14, color: Colors.red),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      dead.failureReason,
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: onReplay,
                  icon: const Icon(Icons.replay, size: 16),
                  label: const Text('Replay'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Discard'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared small widgets
// ---------------------------------------------------------------------------

class _MethodBadge extends StatelessWidget {
  final String method;
  const _MethodBadge({required this.method});

  Color get _color => switch (method.toUpperCase()) {
    'GET' => Colors.green,
    'POST' => Colors.blue,
    'PUT' => Colors.orange,
    'PATCH' => Colors.purple,
    'DELETE' => Colors.red,
    _ => Colors.grey,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _color.withOpacity(0.5)),
      ),
      child: Text(
        method.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: _color,
        ),
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  final RequestPriority priority;
  const _PriorityBadge({required this.priority});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: priority.color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: priority.color.withOpacity(0.4)),
      ),
      child: Text(
        priority.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: priority.color,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  final bool isError;

  const _InfoChip({
    required this.label,
    required this.value,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isError ? Colors.red.shade100 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isError ? label : '$label: $value',
        style: TextStyle(
          fontSize: 11,
          color: isError ? Colors.red : Colors.grey.shade700,
          fontWeight: isError ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

class _ExpandableSection extends StatefulWidget {
  final String title;
  final String content;

  const _ExpandableSection({required this.title, required this.content});

  @override
  State<_ExpandableSection> createState() => _ExpandableSectionState();
}

class _ExpandableSectionState extends State<_ExpandableSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: Colors.grey,
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration:
                  BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4),
                      )
                      as BoxDecoration?,
              child: Text(
                widget.content,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
