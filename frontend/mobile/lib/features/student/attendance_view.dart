import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';

/// Shared attendance surface for both roles.
///
/// Fetches `/api/{group}/lists`. While the attendance engine is the merge
/// slot (spec doc 06), the backend answers 501 and this view renders an
/// explicit **pending** state rather than an error — when the merge lands the
/// same fetch starts returning data with no change here.
class AttendanceView extends StatefulWidget {
  const AttendanceView({super.key, required this.api, required this.group});

  final ApiClient api;

  /// 'student' or 'lecturer' — selects the per-role API group.
  final String group;

  @override
  State<AttendanceView> createState() => _AttendanceViewState();
}

enum _State { loading, pending, data, error }

class _AttendanceViewState extends State<AttendanceView> {
  _State _state = _State.loading;
  List<dynamic> _lists = const [];
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = _State.loading);
    try {
      final lists = await widget.api.lists(widget.group);
      setState(() {
        _lists = lists;
        _state = _State.data;
      });
    } on ApiException catch (e) {
      setState(() {
        if (e.isPendingMerge) {
          _state = _State.pending;
          _message = 'Attendance engine is being merged.';
        } else if (e.isUnauthorized) {
          _state = _State.error;
          _message = 'Your session expired. Please sign in again.';
        } else {
          _state = _State.error;
          _message = e.message;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: switch (_state) {
        _State.loading => const Center(child: CircularProgressIndicator()),
        _State.pending => _PendingState(message: _message),
        _State.error => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(_message),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        _State.data => _lists.isEmpty
            ? const Center(child: Text('No class lists yet.'))
            : ListView.builder(
                itemCount: _lists.length,
                itemBuilder: (context, i) {
                  final m = _lists[i] as Map<String, dynamic>;
                  return ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: Text('${m['title'] ?? ''}'),
                    subtitle: Text('${m['room'] ?? ''} · ${m['date'] ?? ''}'),
                  );
                },
              ),
      },
    );
  }
}

class _PendingState extends StatelessWidget {
  const _PendingState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_top_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Attendance pending', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '$message\n\nLists, sessions, check-in and rolls appear here once the '
              'attendance logic merges in.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'docs/qaat-spec/06-attendance-module.md',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
