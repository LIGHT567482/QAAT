import 'dart:math';

import 'package:flutter/material.dart';

const List<String> kDays = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// One booked block of the grid.
class TtEntry {
  const TtEntry({
    required this.name,
    required this.dayOfWeek,
    required this.start,
    required this.durationMin,
    this.detail = '',
  });

  final String name;
  final int dayOfWeek;
  final String start;
  final int durationMin;
  final String detail;
}

/// A time × day grid of a week's lectures — the shared timetable the coordinator's
/// Home tab and the lecturer's Timetable both render. Coordinate conventions match
/// the native `TimetableGrid`: day 1=Mon…7=Sun, start is "HH:MM", and a unit runs
/// from its start for `durationMin` minutes.
class TimetableGrid extends StatelessWidget {
  const TimetableGrid({
    super.key,
    required this.entries,
    this.sessionType = '',
    this.unscheduledNames = const [],
    this.days,
  });

  final List<TtEntry> entries;
  final String sessionType;
  final List<String> unscheduledNames;

  /// Which day columns to show. When omitted: weekends for a "Weekend" session
  /// type, Monday→Friday otherwise. The lecturer passes all seven explicitly.
  final List<int>? days;

  static const double _rowH = 40;
  static const double _dayW = 108;
  static const double _timeW = 46;

  int _hourOf(String hhmm) {
    final i = int.tryParse(hhmm.split(':').first);
    return i ?? 0;
  }

  int _span(int mins) {
    final m = mins <= 0 ? 60 : mins;
    return max(1, (m + 59) ~/ 60);
  }

  String _ampmHour(int h) {
    if (h == 0) return '12 AM';
    if (h < 12) return '$h AM';
    if (h == 12) return '12 PM';
    return '${h - 12} PM';
  }

  String _formatTimes(String start, int durationMin) {
    if (start.isEmpty) return '';
    final parts = start.split(':');
    final h = int.tryParse(parts.first);
    final m = parts.length > 1 ? int.tryParse(parts[1]) : 0;
    if (h == null) return '';
    String hh(int hour, int minute) {
      final a = hour % 12 == 0 ? 12 : hour % 12;
      final mm = minute.toString().padLeft(2, '0');
      return '$a:$mm ${hour < 12 ? 'AM' : 'PM'}';
    }

    if (durationMin <= 0) return hh(h, m ?? 0);
    final end = h * 60 + (m ?? 0) + durationMin;
    return '${hh(h, m ?? 0)} – ${hh(end ~/ 60, end % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosenDays = days ?? (sessionType.toLowerCase().contains('weekend') ? [6, 7] : [1, 2, 3, 4, 5]);
    final scheduled =
        entries.where((e) => chosenDays.contains(e.dayOfWeek) && e.start.isNotEmpty).toList();
    final offDays = entries.where((e) => !chosenDays.contains(e.dayOfWeek) && e.start.isNotEmpty).toList();

    var lo = 8, hi = 19;
    for (final e in scheduled) {
      final h = _hourOf(e.start);
      lo = min(lo, h);
      hi = max(hi, h + _span(e.durationMin));
    }
    lo = lo.clamp(0, 23);
    hi = hi.clamp(lo + 1, 24);
    final hours = List<int>.generate(hi - lo, (i) => i + lo);

    final today = DateTime.now().weekday; // DateTime: Mon=1…Sun=7 — same as the days table.

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Time column.
              SizedBox(
                width: _timeW,
                child: Column(
                  children: [
                    Container(
                      height: 26,
                      alignment: Alignment.topLeft,
                      padding: const EdgeInsets.only(left: 4, top: 4),
                      child: Text(
                        'Time',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: scheme.primary),
                      ),
                    ),
                    for (final h in hours)
                      SizedBox(
                        height: _rowH,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _ampmHour(h),
                            style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              for (final d in chosenDays) _dayColumn(context, d, hours, scheduled, today == d),
            ],
          ),
        ),
        if (offDays.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            "Not on this week's days",
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: scheme.tertiary),
          ),
          for (final e in offDays)
            Text(
              '• ${e.name} — ${kDays[e.dayOfWeek]} ${e.start}'.trim(),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
        ],
        if (unscheduledNames.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Not yet scheduled',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: scheme.tertiary),
          ),
          for (final n in unscheduledNames)
            Text('• $n', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  Widget _dayColumn(
    BuildContext context,
    int day,
    List<int> hours,
    List<TtEntry> scheduled,
    bool isToday,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          width: _dayW,
          height: 26,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 4),
          decoration: BoxDecoration(color: isToday ? scheme.primary : scheme.surfaceContainerHighest),
          child: Text(
            isToday ? '${kDays[day]} •' : kDays[day],
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: isToday ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
        SizedBox(
          width: _dayW,
          height: _rowH * hours.length,
          child: Stack(
            children: [
              for (var i = 0; i < hours.length; i++)
                Positioned(
                  left: 0,
                  right: 0,
                  top: _rowH * i,
                  height: _rowH,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
                    ),
                  ),
                ),
              for (final e in scheduled.where((s) => s.dayOfWeek == day))
                Positioned(
                  left: 0,
                  right: 0,
                  top: _rowH * (_hourOf(e.start) - hours.first),
                  height: _rowH * _span(e.durationMin),
                  child: Padding(
                    padding: const EdgeInsets.all(1.5),
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: scheme.primary),
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            e.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.1,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                          if (e.durationMin > 0)
                            Text(
                              _formatTimes(e.start, e.durationMin),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 8, height: 1.2, color: scheme.onSurfaceVariant),
                            ),
                          if (e.detail.isNotEmpty)
                            Text(
                              e.detail,
                              maxLines: _span(e.durationMin) > 1 ? 3 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 8, height: 1.2, color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}