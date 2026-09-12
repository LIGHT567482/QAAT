import 'package:flutter/material.dart';

import '../../net/coordinator_client.dart';

/// THE ROOM YOU CAN ACTUALLY USE — a faithful port of the native `FreeRoomPicker`.
///
/// Lists every room in the institution that is free right now (all colleges, all
/// departments, all blocks), checked against the timetable AND live sessions.
/// Picking one marks the session as a provision and the QA monitors are told
/// before they set off. Needs signal — a cached answer would send two classes to
/// one room.
Future<ProvisionalRoom?> showFreeRoomPicker(
  BuildContext context, {
  required String token,
  required CoordinatorClient client,
}) {
  return showModalBottomSheet<ProvisionalRoom>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _FreeRoomPicker(token: token, client: client),
  );
}

/// The outcome when a coordinator commits to a room: the venue plus the reason.
class ProvisionalRoom {
  const ProvisionalRoom({required this.room, required this.reason});
  final FreeRoom room;
  final String reason;
}

class _FreeRoomPicker extends StatefulWidget {
  const _FreeRoomPicker({required this.token, required this.client});

  final String token;
  final CoordinatorClient client;

  @override
  State<_FreeRoomPicker> createState() => _FreeRoomPickerState();
}

class _FreeRoomPickerState extends State<_FreeRoomPicker> {
  List<FreeRoom>? _rooms;
  String? _error;
  var _onlyFree = true;
  FreeRoom? _chosen;
  String _reason = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _rooms = null;
      _error = null;
    });
    if (widget.token.isEmpty) {
      setState(() {
        _error = 'Not signed in';
        _rooms = const [];
      });
      return;
    }
    List<FreeRoom> list;
    try {
      list = await widget.client.freeRooms(widget.token);
    } on Object {
      list = const [];
      if (mounted) {
        setState(() => _error =
            'Could not check the rooms — you need signal for this.');
      }
    }
    if (!mounted) return;
    setState(() {
      _rooms = list;
      if (list.isEmpty && _error == null) _error = 'No rooms came back.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Find a free room',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            Text(
              'Every room in the institution, checked against the timetable and '
              'against sessions running right now. Needs signal — a cached answer '
              'would send two classes to one room.',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),

            if (_rooms == null)
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  const Text('Checking every room…'),
                ],
              ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 6),

            if (_chosen != null) _confirmCard(scheme) else _listCard(scheme),
          ],
        ),
      ),
    );
  }

  Widget _confirmCard(ColorScheme scheme) {
    final r = _chosen!;
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Use ${r.name}?', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              '${r.building.isEmpty ? 'no block listed' : r.building} · '
              '${r.school.isEmpty ? 'no college' : r.school}'
              '${r.capacity > 0 ? ' · seats ${r.capacity}' : ''}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() => _reason = v),
              decoration: const InputDecoration(
                labelText: 'Why the timetabled room could not be used',
                helperText: 'Optional, but it is the only record of the reason.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      ProvisionalRoom(room: r, reason: _reason.trim()),
                    ),
                    child: const Text('Use this room'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() {
                      _chosen = null;
                      _reason = '';
                    }),
                    child: const Text('Back'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The QA monitors, the QA office and the lecturer are told '
              'immediately, so nobody visits the empty room.',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _listCard(ColorScheme scheme) {
    final theme = Theme.of(context);
    final list = (_rooms ?? const <FreeRoom>[])
        .where((r) => !_onlyFree || r.free)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Checkbox(value: _onlyFree, onChanged: (v) => setState(() => _onlyFree = v ?? true)),
            const Text('Free only'),
            const Spacer(),
            TextButton(onPressed: _load, child: const Text('Refresh')),
          ],
        ),
        if (_rooms != null && list.isEmpty)
          Text(
            'Nothing is free right now anywhere in the institution. Untick '
            '"Free only" to see what is holding each room, and until when.',
            style: theme.textTheme.bodySmall,
          ),
        for (final MapEntry(key: block, value: inBlock)
            in _byBlock(list).entries) ...[
          Text(
            '$block · ${inBlock.where((r) => r.free).length} free of '
            '${inBlock.length}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          for (final r in inBlock)
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            '${r.school.isEmpty ? 'no college' : r.school}'
                            '${r.capacity > 0 ? ' · seats ${r.capacity}' : ''}'
                            '${r.free ? '' : ' · ${r.occupiedBy}'
                                '${r.occupiedUntil.isNotEmpty ? ' until ${r.occupiedUntil}' : ''}'
                                '${r.occupiedNote.isNotEmpty ? ' — ${r.occupiedNote}' : ''}'}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (r.free)
                      FilledButton(
                        onPressed: () => setState(() => _chosen = r),
                        child: const Text('Choose'),
                      )
                    else
                      Text(
                        'IN USE',
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  Map<String, List<FreeRoom>> _byBlock(List<FreeRoom> rooms) {
    final grouped = <String, List<FreeRoom>>{};
    for (final r in rooms) {
      grouped.putIfAbsent(r.building.isEmpty ? 'Unlisted block' : r.building, () => []).add(r);
    }
    return grouped;
  }
}